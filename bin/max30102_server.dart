// ============================================================================
// max30102_server — MAX30102 K2 無頭伺服器(headless server)
// ============================================================================
// 把 K2 計算核心包成 HTTP/WebSocket 服務,給上層(React + Koa)呼叫。
// 目標平台:Linux AMD64,用 `dart compile exe` 編成單一執行檔。
//
// ⚠️ 這支檔案**只能 import 純 Dart**:
//     · dart:*
//     · package:libserialport(純 Dart FFI,不是 flutter_libserialport)
//     · lib/main_mode/max30102_K2/ 的核心(扣掉 ui/)
//   一旦混進 package:flutter 或 ui/ 底下的東西,dart compile exe 會直接編不過。
//
// 內部分三塊:
//   ① 引擎        —— 持有計算核心,負責計算 + 累積波形供畫圖。兩種計算模式各一支檔:
//                     engine_base.dart     共用骨架(波形累積、WS 推送通道)
//                     engine_fixed30.dart  固定 30 秒(預設)
//                     engine_realtime.dart 即時(`--calc realtime`)
//   ② FeedSource  —— 進料來源(串口 / HTTP 餵料),同一時間只有一種作用中
//   ③ ApiServer   —— HTTP/WS API 層(dart:io HttpServer)
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libserialport/libserialport.dart';

import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/fixed30/k2_core_fixed30.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_config.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_hrv_calculator.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/realtime/k2_core.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_protocol.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_signal.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_vitals_metrics.dart';

// 版本號單獨一支檔 —— 改版只動 server_version.dart,那裡也記著沿革。
import 'server_version.dart';

part 'engine_base.dart';
part 'engine_fixed30.dart';
part 'engine_realtime.dart';

// ════════════════════════════════════════════════════════════════════════════
// 常數與小工具
// ════════════════════════════════════════════════════════════════════════════

/// 取樣率(Hz)。核心固定 100Hz,波形秒數↔筆數的換算都靠它。
const int kFs = Max30102Config.samplingRateHz;

/// 輸出一行日誌,**中英雙語**。
///
/// 這支服務的維運方通常同時有中文與英文使用者(韌體端看中文、部署與整合端
/// 看英文),日誌是出事時唯一的線索 —— 只給其中一種語言,等於有一半的人
/// 看不懂發生什麼事。所以同一行兩種都給,用 ` | ` 分隔。
void _log(String zh, [String? en]) {
  final t = DateTime.now().toIso8601String().substring(11, 23);
  stdout.writeln(en == null ? '[$t] $zh' : '[$t] $zh | $en');
}

/// 帶中英兩種說法的錯誤。
///
/// 錯誤訊息最後會進到 HTTP 回應裡給人看,而看的人可能是任一種語言。
/// 用這個類別把兩種說法一起帶著走,回應時就能拆成 `error` / `errorZh` 兩個欄位,
/// 而不是把兩種語言黏成一長串。
class BilingualException implements Exception {
  const BilingualException(this.zh, this.en);
  final String zh;
  final String en;

  @override
  String toString() => '$zh | $en';
}

/// 從任意例外取出中文說法(不是雙語例外就原樣回傳)。
String _errZh(Object e) => e is BilingualException ? e.zh : '$e';

/// 從任意例外取出英文說法。
String _errEn(Object e) => e is BilingualException ? e.en : '$e';

/// 組一則「前綴 + 例外內容」的雙語訊息,回傳 (中文, 英文)。
///
/// 多數例外(尤其是函式庫拋的)訊息本身就是英文,兩邊都接上去會變成
/// 同一串英文印兩遍。所以這裡先比對:兩種說法相同就只在中文側留前綴,
/// 細節交給英文側講一次就好。
(String, String) _biError(String zhPrefix, String enPrefix, Object e) {
  final zh = _errZh(e);
  final en = _errEn(e);
  return (zh == en ? zhPrefix : '$zhPrefix:$zh', '$enPrefix: $en');
}

// ════════════════════════════════════════════════════════════════════════════
// ② FeedSource —— 進料來源
// ════════════════════════════════════════════════════════════════════════════
//
// ⚠️ 兩種來源**不可同時**餵同一個引擎:串口的時間軸與外部餵料的時間軸混在一起,
//    RR 會被算成亂數,而且不會報錯。所以切換模式時一律 engine.reset()。

abstract class FeedSource {
  /// 模式名稱,對外 API 用這個字串。
  String get name;

  /// 啟動。失敗要丟例外,讓 /mode 能回報錯誤而不是默默不動。
  Future<void> start();

  /// 停止並釋放資源(串口一定要真的關掉,否則下次開埠會失敗)。
  Future<void> stop();

  /// 這個來源是否接受 POST /feed。
  bool get acceptsHttpFeed => false;

  /// 給 /health 附加的狀態說明。
  Map<String, dynamic> status() => const {};
}

/// 架構②:被動來源 —— 不開任何 I/O,資料由上層 POST /feed 推進來。
class HttpFeedSource extends FeedSource {
  @override
  String get name => 'feed';

  @override
  bool get acceptsHttpFeed => true;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

/// 架構①:主動來源 —— 開串口,定時送 QUERY_FIFO,把回應丟進引擎。
class SerialSource extends FeedSource {
  SerialSource({
    required this.engine,
    required this.portName,
    required this.baud,
    required this.board,
    required this.intervalMs,
  });

  final VitalsEngine engine;
  final String portName;
  final int baud;
  final int board;
  final int intervalMs;

  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _sub;
  Timer? _timer;

  /// 串口是 byte stream,封包會被切碎/黏在一起 → 一定要走組框器,
  /// 不能把讀到的 chunk 直接丟給 feedData。
  final Max30102RxParser _parser = Max30102RxParser();

  /// 連續失敗次數。累積過多就自己停掉,但**不讓 process 死掉** ——
  /// HTTP 服務要活著,上層才能靠 /health 看到狀態並決定重連。
  int _consecutiveErrors = 0;
  static const int _maxConsecutiveErrors = 20;
  String? _lastError;
  bool _stopped = false;

  // ── 指令的請求／回應配對 ──────────────────────────────────────────────
  //
  // QUERY_FIFO 是「一直問、一直收」的串流,但 INIT / RESET / READ_REG 是
  // 「問一句、等一句」。兩者的回應混在同一條串口上,靠 sub-cmd 分流:
  //   sub == 0x00(QUERY_FIFO) → 資料,丟給核心
  //   其餘                     → 是某個指令的回覆,交給等在那裡的人
  //
  // 同時只允許一個等待中的指令 —— 這些操作都是偶發的人為動作(初始化、查狀態),
  // 沒有平行化的需要;允許併發只會讓「哪個回應對應哪個請求」變得難以確定。
  Completer<Uint8List>? _pending;
  int _pendingSub = -1;

  /// 指令逾時。MCU 正常時 100ms 內就會回,1 秒已經很寬鬆。
  static const Duration _cmdTimeout = Duration(seconds: 1);

  @override
  String get name => 'serial';

  /// 送一個指令並等它的回覆。逾時或串口沒開都會丟例外。
  Future<Uint8List> request(Uint8List packet, int expectSub) async {
    final port = _port;
    if (port == null || !port.isOpen) {
      throw const BilingualException('串口未開啟', 'serial port is not open');
    }
    if (_pending != null) {
      throw const BilingualException('已有另一個指令在等回應,請稍後再試',
          'another command is already awaiting a reply; try again shortly');
    }

    final completer = Completer<Uint8List>();
    _pending = completer;
    _pendingSub = expectSub;
    try {
      port.write(packet);
    } catch (e) {
      _pending = null;
      _pendingSub = -1;
      rethrow;
    }

    try {
      return await completer.future.timeout(_cmdTimeout);
    } on TimeoutException {
      throw BilingualException(
          'MCU 沒有回應(逾時 ${_cmdTimeout.inMilliseconds}ms)',
          'no reply from MCU (timeout ${_cmdTimeout.inMilliseconds}ms)');
    } finally {
      // 不論成功、逾時或例外,都要把位子讓出來,否則之後的指令全被擋住。
      _pending = null;
      _pendingSub = -1;
    }
  }

  @override
  Map<String, dynamic> status() => {
        'serial': portName,
        'baud': baud,
        'board': '0x${board.toRadixString(16)}',
        'intervalMs': intervalMs,
        'open': _port?.isOpen ?? false,
        'lastError': _lastError,
      };

  @override
  Future<void> start() async {
    _parser.onPacket = (pkt) {
      _consecutiveErrors = 0; // 收到完整封包 = 連線是好的

      // ── 分流:資料歸資料,指令回覆歸指令 ──
      final sub = pkt.length > 4 ? pkt[4] : -1;
      if (sub != Max30102Protocol.kSubQueryFifo) {
        // 這是某個指令的回覆。有人在等就交給他;沒人等就是遲到的回覆,丟掉。
        final waiting = _pending;
        if (waiting != null && !waiting.isCompleted && sub == _pendingSub) {
          waiting.complete(pkt);
        }
        return; // ⚠️ 絕對不能往下丟給核心 —— 固定長度回覆的 byte[5] 是暫存器
                //    位址,被 decodeFifoResponse 當成資料長度解讀是錯的。
      }

      try {
        engine.feedPacket(pkt);
      } catch (e) {
        final (zh, en) = _biError('⚠ feedPacket 失敗', 'feedPacket failed', e);
        _log(zh, en);
      }
    };

    final port = SerialPort(portName);
    if (!port.openReadWrite()) {
      port.dispose();
      throw BilingualException(
          '無法開啟串口 $portName(是否被佔用?權限是否在 dialout 群組?)',
          'cannot open serial port $portName '
              '(in use? is the user in the dialout group?)');
    }
    port.config = SerialPortConfig()
      ..baudRate = baud
      ..bits = 8
      ..parity = SerialPortParity.none
      ..stopBits = 1;
    _port = port;

    final reader = SerialPortReader(port);
    _reader = reader;
    _sub = reader.stream.listen(
      (data) {
        try {
          _parser.feed(data);
        } catch (e) {
          final (zh, en) = _biError('⚠ 解析失敗', 'parse failed', e);
          _log(zh, en);
        }
      },
      onError: (Object e) {
        // USB 被拔掉多半走這裡。記錄後讓計時器那邊去累積錯誤次數。
        _lastError = '$e';
        final (zh, en) = _biError('⚠ 串口讀取錯誤', 'serial read error', e);
        _log(zh, en);
      },
      cancelOnError: false,
    );

    // ── 連上就先初始化一次晶片 ──────────────────────────────────────────
    //
    // 韌體開機時本來就會 init 一次,這裡是**保險**:server 可能在韌體跑了很久
    // 之後才連上,期間晶片的狀態可能被別的東西改過(例如有人按過 RESET)。
    //
    // 失敗不阻斷啟動 —— 串口是通的,只是晶片沒回話。硬要中斷的話,上層連
    // /health 都看不到,反而更難查。把原因記進 lastError 讓人看得見就好。
    try {
      await initChip();
      _log('✅ 晶片初始化完成', 'chip initialised');
    } catch (e) {
      final (zh, en) = _biError('初始化晶片失敗', 'chip init failed', e);
      _lastError = '$zh | $en';
      _log('⚠ $zh(串口仍在運作,可稍後用 POST /chip/init 重試)',
          '$en (serial port still running; retry later with POST /chip/init)');
    }

    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) => _poll());
    _log(
        '🟢 串口模式啟動:$portName @$baud,'
            'board=0x${board.toRadixString(16)},每 ${intervalMs}ms 詢問一次',
        'serial mode started: $portName @$baud, '
            'board=0x${board.toRadixString(16)}, polling every ${intervalMs}ms');
  }

  // ══════════════════════════════════════════════════════════════
  // 晶片控制(都要等 MCU 回覆確認,不是送出去就當作成功)
  // ══════════════════════════════════════════════════════════════

  /// RE-INIT:把晶片重新初始化成可用狀態。
  /// 回覆的 byte[5]:1 = 成功、0 = 失敗。
  Future<void> initChip() async {
    final res = await request(
      Max30102Protocol.buildReInit(board: board),
      Max30102Protocol.kSubReInit,
    );
    if (res.length > 5 && res[5] != 1) {
      throw const BilingualException('MCU 回報初始化失敗(晶片是否接好?)',
          'MCU reported init failure (is the chip connected?)');
    }
    engine.chipAsleep = false; // 確認初始化成功才恢復收資料
  }

  /// RESET:軟體復位 → 晶片進入 POR 休眠。
  /// ⚠️ 復位後晶片**不可用**,必須再 [initChip] 才會恢復採樣。
  ///
  /// [VitalsEngine.chipAsleep] 在**送出之前**就設好:reset 那一刻前後回來的 FIFO
  /// 資料正是要擋的東西,等 MCU 確認才設就漏掉了。送失敗(MCU 沒回)就還原,
  /// 晶片多半還醒著,不該把資料擋掉。
  Future<void> resetChip() async {
    final wasAsleep = engine.chipAsleep;
    engine.chipAsleep = true;
    try {
      await request(
        Max30102Protocol.buildReset(board: board),
        Max30102Protocol.kSubReset,
      );
    } catch (_) {
      engine.chipAsleep = wasAsleep;
      rethrow;
    }
  }

  /// 讀一顆暫存器,回傳讀到的值。
  Future<int> readReg(int reg) async {
    final res = await request(
      Max30102Protocol.buildReadReg(reg, board: board),
      Max30102Protocol.kSubReadReg,
    );
    if (res.length < 7) {
      throw const BilingualException(
          'READ_REG 回覆長度不足', 'READ_REG reply too short');
    }
    return Max30102Protocol.parseReg(res).value;
  }

  void _poll() {
    if (_stopped) return;
    final port = _port;
    if (port == null) return;
    try {
      port.write(Max30102Protocol.buildQueryFifo(board: board));
    } catch (e) {
      _lastError = '$e';
      _consecutiveErrors++;
      if (_consecutiveErrors >= _maxConsecutiveErrors) {
        _log(
            '❌ 串口連續失敗 $_consecutiveErrors 次,停止輪詢(HTTP 服務繼續運行)',
            'serial failed $_consecutiveErrors times in a row; polling stopped '
                '(HTTP service stays up)');
        // 不要在這裡 await —— 這是計時器回呼。
        unawaited(stop());
      }
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    // 有人還在等回覆就先叫醒他,否則那個 Future 會一直懸著到逾時。
    final waiting = _pending;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(
          const BilingualException('串口已關閉', 'serial port closed'));
    }
    _pending = null;
    _pendingSub = -1;
    // 每一段都各自 try,任何一步失敗都不能擋住後面的釋放。
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      _reader?.close();
    } catch (_) {}
    _reader = null;
    try {
      _port?.close();
    } catch (_) {}
    try {
      _port?.dispose();
    } catch (_) {}
    _port = null;
    _parser.onPacket = null;
    _log('⏸ 串口模式已停止:$portName', 'serial mode stopped: $portName');
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 晶片控制動作
// ════════════════════════════════════════════════════════════════════════════

enum _ChipAction {
  /// RE-INIT:重新初始化成可用狀態。日常修復用這個。
  init,

  /// RESET:軟體復位 → 晶片進入 POR 休眠。⚠️ 之後必須 init 才會恢復。
  reset,

  /// RESET + RE-INIT:完整重來。包成一個動作,init 不會被忘記。
  resetInit;

  /// 這個動作對應的封包序列(feed 模式下交給上層自己送)。
  List<List<int>> packets(int board) => switch (this) {
        _ChipAction.init => [
            Max30102Protocol.buildReInit(board: board).toList()
          ],
        _ChipAction.reset => [
            Max30102Protocol.buildReset(board: board).toList()
          ],
        _ChipAction.resetInit => [
            Max30102Protocol.buildReset(board: board).toList(),
            Max30102Protocol.buildReInit(board: board).toList(),
          ],
      };
}

// ════════════════════════════════════════════════════════════════════════════
// ③ ApiServer —— HTTP / WebSocket
// ════════════════════════════════════════════════════════════════════════════

class ApiServer {
  ApiServer({
    required this.engine,
    required this.opts,
    required FeedSource initial,
  }) : _source = initial;

  final VitalsEngine engine;
  final ServerOptions opts;

  FeedSource _source;
  final DateTime _startedAt = DateTime.now();
  HttpServer? _http;

  /// 模式切換必須序列化 —— 兩個 POST /mode 同時進來會把串口開兩次。
  Future<void> _switching = Future.value();

  String get mode => _source.name;

  Future<void> start() async {
    await _source.start();
    final server = await HttpServer.bind(
        InternetAddress.anyIPv4, opts.port, shared: false);
    _http = server;
    _log(
        '🌐 HTTP 監聽 0.0.0.0:${opts.port}(目前模式:$mode,'
            'v$kServerVersion)',
        'HTTP listening on 0.0.0.0:${opts.port} '
            '(mode: $mode, v$kServerVersion)');
    server.listen(_handle,
        onError: (Object e) {
      final (zh, en) = _biError('⚠ HTTP 錯誤', 'HTTP error', e);
      _log(zh, en);
    });
  }

  Future<void> _handle(HttpRequest req) async {
    // 給 Koa 從瀏覽器端直連留的餘地;正式部署通常是 Koa 在同機轉發。
    req.response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Headers', 'Content-Type')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');

    final path = req.uri.path;
    try {
      if (req.method == 'OPTIONS') {
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
        return;
      }

      if (path == '/stream' && WebSocketTransformer.isUpgradeRequest(req)) {
        await _handleStream(req);
        return;
      }

      switch ('${req.method} $path') {
        case 'GET /health':
          await _json(req, {
            'ok': true,
            'version': kServerVersion,
            'calcMode': engine.calcMode,
            'mode': mode,
            'uptimeMs': DateTime.now().difference(_startedAt).inMilliseconds,
            'totalSamples': engine.totalSamples,
            'resetOnFingerOff': opts.resetOnFingerOff,
            'source': _source.status(),
          });
        case 'GET /vitals':
          await _json(req, engine.vitalsJson());
        case 'GET /waveform':
          final s = int.tryParse(req.uri.queryParameters['seconds'] ?? '');
          await _json(req, engine.waveformJson(seconds: s));
        case 'POST /feed':
          await _handleFeed(req);
        case 'POST /mode':
          await _handleMode(req);
        case 'GET /chip':
          await _handleChipStatus(req);
        case 'POST /chip/init':
          await _handleChipCommand(req, _ChipAction.init);
        case 'POST /chip/reset':
          await _handleChipCommand(req, _ChipAction.reset);
        case 'POST /chip/reset-init':
          await _handleChipCommand(req, _ChipAction.resetInit);
        default:
          await _json(
              req, {'error': 'not found', 'path': path}, HttpStatus.notFound);
      }
    } catch (e, st) {
      _log('⚠ 處理 $path 失敗:$e\n$st', 'failed handling $path: $e');
      try {
        await _json(req, {'error': _errEn(e), 'errorZh': _errZh(e)},
            HttpStatus.internalServerError);
      } catch (_) {}
    }
  }

  // ── POST /feed ─────────────────────────────────────────────────────────
  //
  // 串口模式下**拒絕**餵料(409),不是默默吃掉:兩條時間軸混進同一個核心,
  // 心率與 HRV 會被算成垃圾,而且完全不會報錯。寧可讓上層看到明確的錯。
  Future<void> _handleFeed(HttpRequest req) async {
    if (!_source.acceptsHttpFeed) {
      await _json(
          req,
          {
            'error': 'feed rejected',
            'reason': 'currently in $mode mode; POST /feed is only available '
                'in feed mode',
            'reasonZh': '目前是 $mode 模式,POST /feed 只在 feed 模式可用',
            'hint': 'switch first: POST /mode {"mode":"feed"}',
            'hintZh': '先 POST /mode {"mode":"feed"}',
          },
          HttpStatus.conflict);
      return;
    }

    final raw = await _readBody(req);
    List<int>? bytes;

    // 兩種格式都收:原始 octet-stream(正式用),或 JSON 陣列(curl 手測方便)。
    final ct = req.headers.contentType?.mimeType ?? '';
    if (ct == 'application/json' ||
        (raw.isNotEmpty && (raw.first == 0x7B || raw.first == 0x5B))) {
      try {
        final decoded = jsonDecode(utf8.decode(raw));
        if (decoded is List) {
          bytes = decoded.cast<num>().map((e) => e.toInt()).toList();
        } else if (decoded is Map && decoded['bytes'] is List) {
          bytes = (decoded['bytes'] as List)
              .cast<num>()
              .map((e) => e.toInt())
              .toList();
        }
      } catch (e) {
        await _json(
            req,
            {'error': 'invalid JSON: $e', 'errorZh': 'JSON 解析失敗:$e'},
            HttpStatus.badRequest);
        return;
      }
    } else {
      bytes = raw;
    }

    if (bytes == null || bytes.isEmpty) {
      await _json(req, {'error': 'empty body', 'errorZh': 'body 是空的'},
          HttpStatus.badRequest);
      return;
    }

    final computed = engine.feedPacket(bytes);
    await _json(req, {
      'accepted': bytes.length,
      'computed': computed,
      'totalSamples': engine.totalSamples,
    });
  }

  // ── 晶片控制 /chip/* ───────────────────────────────────────────────────
  //
  // 晶片控制是「對 MAX30102 下指令」,與進料模式無關 —— 但**誰能把指令送上線**
  // 兩種模式不同:
  //   serial → server 持有串口,直接送並等 MCU 確認
  //   feed   → server 沒有串口,只能把算好的封包交給上層,由上層自己送
  // 兩種模式都回 200,差別在 `sent` 欄位。上層看 sent==false 就知道要自己送。
  Future<void> _handleChipCommand(HttpRequest req, _ChipAction action) async {
    final src = _source;

    if (src is! SerialSource) {
      // feed 模式:給封包,讓上層用自己的串口送出去。
      // 這樣上層不必碰協定(表頭 / checksum 算錯會被 MCU 靜默丟棄,極難查)。
      await _json(req, {
        'ok': true,
        'sent': false,
        'action': action.name,
        'packet': action.packets(opts.board).first,
        if (action == _ChipAction.resetInit)
          'packets': action.packets(opts.board),
        'note': action == _ChipAction.resetInit
            ? 'no serial port in feed mode — send the two packets in `packets` '
                'in order (RESET, wait 500ms, RE-INIT)'
            : 'no serial port in feed mode — please send this packet yourself',
        'noteZh': action == _ChipAction.resetInit
            ? 'feed 模式下 server 沒有串口。請依序送出 packets 內的兩個封包'
                '(RESET → 等 500ms → RE-INIT)'
            : 'feed 模式下 server 沒有串口,請自行送出這個封包',
      });
      return;
    }

    try {
      switch (action) {
        case _ChipAction.init:
          await src.initChip();
        case _ChipAction.reset:
          await src.resetChip();
        case _ChipAction.resetInit:
          await src.resetChip();
          // 復位後晶片進入 POR 休眠,要留時間讓它安定再初始化。
          await Future<void>.delayed(const Duration(milliseconds: 500));
          await src.initChip();
      }
      // 晶片狀態變了 → 交給引擎決定要清什麼。
      //   即時模式:波形與拍全部作廢(= 舊寫法 engine.reset())。
      //   固定 30 秒:init → 全清(含結果);只有 reset 關燈 → 結果保留給軟體讀。
      // 〔0.0.1-fixed30s 舊寫法,換成 afterChipCommand:固定模式 reset 時不能清掉結果〕
      // engine.reset();
      engine.afterChipCommand(initialized: action != _ChipAction.reset);
      // 立刻推一筆(fingerPresent: false)。不推的話 reset 後 FIFO 一直是空的、
      // 核心不再計算,訂閱者會一直停在指令之前的最後一筆(v0.0.0.9)。
      engine.pushVitals();
      _log('🔧 晶片指令完成:${action.name}',
          'chip command done: ${action.name}');
      await _json(req, {
        'ok': true,
        'sent': true,
        'confirmed': true,
        'action': action.name,
        if (action == _ChipAction.reset)
          'warning': 'the chip is now asleep; call /chip/init to resume sampling',
        if (action == _ChipAction.reset)
          'warningZh': '晶片已進入休眠,必須再呼叫 /chip/init 才會恢復採樣',
      });
    } catch (e) {
      await _json(
          req,
          {
            'ok': false,
            'sent': true,
            'action': action.name,
            'error': _errEn(e),
            'errorZh': _errZh(e),
          },
          HttpStatus.internalServerError);
    }
  }

  // ── GET /chip ──────────────────────────────────────────────────────────
  //
  // 一次 READ_REG 就能分辨兩層:
  //   逾時沒回應      → MCU 沒回話(線斷了 / 韌體沒跑)
  //   有回應但非 0x15 → MCU 正常,但 MAX30102 讀不到(晶片沒接好 / 壞了)
  //   有回應且 0x15   → 兩層都健康
  // 這是 /health 做不到的 —— 它只知道「串口開著」。
  Future<void> _handleChipStatus(HttpRequest req) async {
    final src = _source;
    if (src is! SerialSource) {
      await _json(
          req,
          {
            'error': 'not available in feed mode',
            'reason': 'no serial port in feed mode, so the chip cannot be queried',
            'reasonZh': 'feed 模式下 server 沒有串口,無法查詢晶片',
            'hint': 'send READ_REG(0xFF) yourself and check whether byte[6] '
                'of the reply is 0x15',
            'hintZh': '請自行送出 READ_REG(0xFF) 並檢查回覆的 byte[6] 是否為 0x15',
            'packet': Max30102Protocol.buildReadReg(
                    Max30102Protocol.kRegPartId,
                    board: opts.board)
                .toList(),
          },
          HttpStatus.conflict);
      return;
    }

    try {
      final partId = await src.readReg(Max30102Protocol.kRegPartId);
      final ledRed = await src.readReg(Max30102Protocol.kRegLedRed);
      final ledIr = await src.readReg(Max30102Protocol.kRegLedIr);

      final cfg = engine.config;
      final chipOk = partId == Max30102Protocol.kPartIdValue;
      // 晶片實際的 LED 電流與本程式設定的是否一致。不一致代表晶片被別的東西
      // 改過(或復位回 baseline 0x24) → 演算法用的參數與硬體實況對不上。
      final inSync =
          chipOk && ledRed == cfg.ledCurrentRed && ledIr == cfg.ledCurrentIr;

      await _json(req, {
        'mcu': {'online': true},
        'chip': {
          'online': chipOk,
          'partId': '0x${partId.toRadixString(16).padLeft(2, '0')}',
          'ledRed': ledRed,
          'ledIr': ledIr,
        },
        'expected': {
          'partId': '0x${Max30102Protocol.kPartIdValue.toRadixString(16)}',
          'ledRed': cfg.ledCurrentRed,
          'ledIr': cfg.ledCurrentIr,
        },
        'inSync': inSync,
        if (!chipOk) ...{
          'hint': 'PART_ID is not 0x15 — the chip is not connected or is faulty',
          'hintZh': 'PART_ID 不是 0x15 —— 晶片沒接好或已損壞',
        },
        if (chipOk && !inSync) ...{
          'hint': 'LED currents differ from the configured values (the chip may '
              'have been reset to baseline). POST /chip/init to realign',
          'hintZh': 'LED 電流與本服務的設定不符(晶片可能被復位回 baseline)。'
              '呼叫 POST /chip/init 可讓兩邊回到一致',
        },
      });
    } catch (e) {
      // 讀不到 = MCU 根本沒回話
      await _json(req, {
        'mcu': {'online': false, 'error': _errEn(e), 'errorZh': _errZh(e)},
        'chip': {'online': false},
        'inSync': false,
        'hint': 'no reply from the MCU. The serial port itself is fine '
            '(otherwise /health would show open:false), but nobody is answering '
            '— check that the firmware is running and the wiring is correct',
        'hintZh': 'MCU 沒有回應。串口是通的(否則 /health 的 open 會是 false),'
            '但另一端沒有人回話 —— 檢查韌體是否運行、接線是否正確',
      });
    }
  }

  // ── POST /mode ─────────────────────────────────────────────────────────
  Future<void> _handleMode(HttpRequest req) async {
    final raw = await _readBody(req);
    Map<String, dynamic> body;
    try {
      body = raw.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(utf8.decode(raw)) as Map).cast<String, dynamic>();
    } catch (e) {
      await _json(
          req,
          {'error': 'invalid JSON: $e', 'errorZh': 'JSON 解析失敗:$e'},
          HttpStatus.badRequest);
      return;
    }

    final want = (body['mode'] as String?)?.toLowerCase();
    if (want != 'serial' && want != 'feed') {
      await _json(
          req,
          {
            'error': 'mode must be "serial" or "feed"',
            'errorZh': 'mode 必須是 "serial" 或 "feed"',
            'got': body['mode'],
          },
          HttpStatus.badRequest);
      return;
    }

    // 串成一條鏈,確保同時打進來的切換請求不會交錯執行。
    final completer = Completer<void>();
    final previous = _switching;
    _switching = completer.future;
    await previous;

    try {
      final next = want == 'serial'
          ? SerialSource(
              engine: engine,
              portName: (body['serial'] as String?) ?? opts.serialPath,
              baud: (body['baud'] as num?)?.toInt() ?? opts.baud,
              board: (body['board'] as num?)?.toInt() ?? opts.board,
              intervalMs:
                  (body['intervalMs'] as num?)?.toInt() ?? opts.intervalMs,
            )
          : HttpFeedSource();

      await _source.stop();
      // 換來源 = 換時間軸,核心與波形都要從乾淨狀態重新開始。
      engine.reset();
      // 休眠旗標也清掉:切到 feed 模式時 server 無從得知晶片狀態,留著會把上層
      // POST 的資料全部丟掉;切到 serial 則由開串口時的自動 init 重新決定。
      engine.chipAsleep = false;

      try {
        await next.start();
        _source = next;
        _log('🔄 已切換到 $mode 模式', 'switched to $mode mode');
        await _json(req, {'mode': mode, 'source': _source.status()});
      } catch (e) {
        // 新來源起不來(例如串口不存在)→ 退回 feed 模式,不要留下半死狀態。
        final (ezh, een) = _biError(
            '❌ 切換到 $want 失敗', 'switch to $want failed', e);
        _log('$ezh → 退回 feed 模式', '$een -> falling back to feed mode');
        _source = HttpFeedSource();
        await _source.start();
        await _json(
            req,
            {
              'error': _errEn(e),
              'errorZh': _errZh(e),
              'mode': mode,
              'note': 'switch failed; fell back to feed mode',
              'noteZh': '切換失敗,已退回 feed 模式',
            },
            HttpStatus.badRequest);
      }
    } finally {
      completer.complete();
    }
  }

  // ── WS /stream ─────────────────────────────────────────────────────────
  Future<void> _handleStream(HttpRequest req) async {
    final ws = await WebSocketTransformer.upgrade(req);
    _log('🔌 WS 訂閱者接上(/stream)', 'WS subscriber connected (/stream)');

    // ⚠️ 遊標是**每個訂閱者一份**,不能提到引擎去共用 —— 兩個訂閱者接上的
    //    時間不同,共用一份的話先接上的那個會把樣本「領走」,後接上的只收得到
    //    殘缺片段,而且不會報錯。
    int? cursor;
    void push(Map<String, dynamic> v) {
      // 順序有意義:`_vitals.add()` 是在波形累積**之後**才發的(見 feedPacket),
      // 所以這裡讀到的緩衝已經含這一輪的新樣本。
      final r = engine.waveSinceJson(cursor);
      // 兩個區塊涵蓋**同一批樣本**(同 firstAbs / 同 count),所以遊標只推一次。
      // 這是刻意的:兩邊逐筆對齊,上層可以直接把它們疊起來比對。
      cursor = (r.wave['firstAbs'] as int) + (r.wave['count'] as int);
      try {
        ws.add(jsonEncode({...v, 'wave': r.wave, 'raw_wave': r.rawWave}));
      } catch (_) {}
    }

    // 一接上先給一份現況,對方不必等下一次計算才有畫面。
    // 此時 cursor 還是 null → 波形會把保留緩衝(預設 30 秒)整段給出去,
    // 圖表一連上就有東西可畫,不必空等一秒。
    push(engine.vitalsJson());
    final sub = engine.vitalsStream.listen(push, onError: (Object _) {});
    ws.done.whenComplete(() {
      sub.cancel();
      _log('🔌 WS 訂閱者離線', 'WS subscriber disconnected');
    });
  }

  // ── helpers ────────────────────────────────────────────────────────────
  Future<List<int>> _readBody(HttpRequest req) async {
    final chunks = <int>[];
    await for (final c in req) {
      chunks.addAll(c);
    }
    return chunks;
  }

  Future<void> _json(HttpRequest req, Object body,
      [int status = HttpStatus.ok]) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType('application', 'json', charset: 'utf-8')
      ..write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> shutdown() async {
    await _source.stop();
    await _http?.close(force: true);
    await engine.dispose();
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 啟動參數
// ════════════════════════════════════════════════════════════════════════════

class ServerOptions {
  ServerOptions({
    required this.mode,
    required this.serialPath,
    required this.baud,
    required this.port,
    required this.board,
    required this.intervalMs,
    required this.waveSeconds,
    required this.resetOnFingerOff,
    this.calc = 'fixed30',
  });

  /// 計算模式:`fixed30`(預設)/ `realtime`。不帶參數 = fixed30,軟體的啟動指令不必改。
  final String calc;

  final String mode;
  final String serialPath;
  final int baud;
  final int port;
  final int board;
  final int intervalMs;
  final int waveSeconds;

  /// 免洗模式:確認手指離開時核心連絕對索引一起歸零(預設開啟)。
  final bool resetOnFingerOff;

  /// 解析順序:命令列參數 > 環境變數 > 預設值。
  static ServerOptions parse(List<String> args) {
    final map = <String, String>{};
    for (int i = 0; i < args.length; i++) {
      final a = args[i];
      if (!a.startsWith('--')) continue;
      final key = a.substring(2);
      // 支援 --key=value 與 --key value 兩種寫法
      if (key.contains('=')) {
        final idx = key.indexOf('=');
        map[key.substring(0, idx)] = key.substring(idx + 1);
      } else if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        map[key] = args[++i];
      } else {
        map[key] = 'true';
      }
    }

    String str(String cli, String env, String def) =>
        map[cli] ?? Platform.environment[env] ?? def;
    bool flag(String cli, String env, bool def) {
      final v = str(cli, env, '$def').toLowerCase();
      return v == 'true' || v == '1' || v == 'yes';
    }
    int num_(String cli, String env, int def) =>
        int.tryParse(str(cli, env, '$def')) ?? def;

    return ServerOptions(
      mode: str('mode', 'K2_MODE', 'feed').toLowerCase(),
      serialPath: str('serial', 'K2_SERIAL', '/dev/ttyUSB0'),
      baud: num_('baud', 'K2_BAUD', 115200),
      port: num_('port', 'K2_PORT', 8770),
      board: num_('board', 'K2_BOARD', Max30102Protocol.kBoardExpansion),
      intervalMs: num_('interval', 'K2_INTERVAL', 100),
      waveSeconds: num_('wave-seconds', 'K2_WAVE_SECONDS', 30),
      resetOnFingerOff:
          flag('reset-on-finger-off', 'K2_RESET_ON_FINGER_OFF', true),
      calc: str('calc', 'K2_CALC', 'fixed30').toLowerCase(),
    );
  }
}

const String _usage = '''
max30102_server v$kServerVersion — MAX30102 K2 無頭伺服器 / headless vitals service

用法 / Usage:
  max30102_server [選項 / options]

選項 / Options:
  --calc <fixed30|realtime>
      計算模式(預設 fixed30):固定 30 秒後一次算 / 即時每秒算
      calculation mode (default: fixed30): compute once after 30 s / every second

  --mode <serial|feed>
      預設進料模式(預設 feed;可執行中用 POST /mode 改)
      input mode at startup (default: feed; changeable at runtime via POST /mode)

  --serial <path>
      串口路徑,serial 模式用(預設 /dev/ttyUSB0)
      serial device path, used in serial mode (default: /dev/ttyUSB0)

  --baud <n>
      鮑率(預設 115200) / baud rate (default: 115200)

  --port <n>
      HTTP 監聽埠(預設 8770) / HTTP listen port (default: 8770)

  --board <48|49>
      表頭板子 byte,十進位(48=0x30 主板,49=0x31 擴充板;預設 49)
      board id byte, decimal (48=0x30 main, 49=0x31 expansion; default: 49)

  --interval <ms>
      串口輪詢間隔(預設 100) / serial polling interval (default: 100)

  --wave-seconds <n>
      /waveform 保留秒數(預設 30)
      seconds of waveform retained for /waveform (default: 30)

  --reset-on-finger-off <true|false>
      免洗模式:確認手指離開時連絕對索引一起歸零(預設 true;只影響 realtime,
      fixed30 一律一人一次)
      single-session mode: reset the sample index when the finger is
      confirmed removed (default: true; realtime only, fixed30 always resets)

  --help
      顯示這份說明 / show this help

  --version
      只印出版本號 / print the version and exit

環境變數(優先度低於命令列)/ Environment variables (lower precedence than CLI):
  K2_CALC  K2_MODE  K2_SERIAL  K2_BAUD  K2_PORT  K2_BOARD  K2_INTERVAL
  K2_WAVE_SECONDS  K2_RESET_ON_FINGER_OFF

API:
  GET  /health                存活探測 + 目前模式 / liveness + current mode
  GET  /vitals                最新計算結果 / latest computed values
  GET  /waveform?seconds=10   近一段波形(原始 + 截尾平滑)
                              recent waveform (raw + trim-smoothed)
  POST /feed                  餵原始 MCU bytes(僅 feed 模式)
                              push raw MCU bytes (feed mode only)
  POST /mode                  切換進料模式 / switch input mode
  WS   /stream                約 1 秒推播一次,內容 = /vitals 再加一個 wave 區塊
                              (IR 找谷線的增量樣本)。fixed30 由計時器每秒推,
                              結果算出時另外立刻推一次
                              pushed ~1/s: /vitals plus a `wave` block of
                              incremental samples. fixed30 pushes on a 1 s timer,
                              plus once immediately when the result is ready
  GET  /chip                  MCU 與 MAX30102 在線狀態(僅 serial 模式)
                              MCU and MAX30102 status (serial mode only)
  POST /chip/init             初始化晶片(RE-INIT) / initialise the chip
  POST /chip/reset            復位晶片(⚠ 之後會休眠,必須再 init)
                              reset the chip (⚠ it then sleeps; init required)
  POST /chip/reset-init       復位後立刻初始化 / reset then initialise
''';

// ════════════════════════════════════════════════════════════════════════════
// main
// ════════════════════════════════════════════════════════════════════════════

Future<void> main(List<String> args) async {
  if (args.contains('--version') || args.contains('-v')) {
    stdout.writeln(kServerVersion);
    return;
  }
  if (args.contains('--help') || args.contains('-h')) {
    stdout.write(_usage);
    return;
  }

  final opts = ServerOptions.parse(args);
  final VitalsEngine engine = opts.calc == 'realtime'
      ? K2Engine(
          waveSeconds: opts.waveSeconds,
          resetOnFingerOff: opts.resetOnFingerOff,
        )
      : K2EngineFixed30(waveSeconds: opts.waveSeconds);
  if (opts.calc != 'realtime' && opts.calc != 'fixed30') {
    _log('⚠ 不認得的 --calc "${opts.calc}",改用 fixed30',
        'unknown --calc "${opts.calc}", using fixed30');
  }

  FeedSource initial = HttpFeedSource();
  if (opts.mode == 'serial') {
    initial = SerialSource(
      engine: engine,
      portName: opts.serialPath,
      baud: opts.baud,
      board: opts.board,
      intervalMs: opts.intervalMs,
    );
  }

  final api = ApiServer(engine: engine, opts: opts, initial: initial);

  try {
    await api.start();
  } catch (e) {
    // 串口起不來不該讓整支 server 死掉 —— 退回 feed 模式繼續服務,
    // 上層可以之後用 POST /mode 再試一次。
    final (zh, en) = _biError('❌ 啟動失敗', 'startup failed', e);
    _log(zh, en);
    if (opts.mode == 'serial') {
      _log('→ 退回 feed 模式繼續啟動(可稍後用 POST /mode 重試串口)',
          '-> starting in feed mode instead (retry serial later via POST /mode)');
      final fallback =
          ApiServer(engine: engine, opts: opts, initial: HttpFeedSource());
      await fallback.start();
      _installSignalHandlers(fallback);
      return;
    }
    exitCode = 1;
    return;
  }

  _installSignalHandlers(api);
}

/// 常駐執行直到被關閉。收到訊號時把串口好好釋放掉再退出。
///
/// **Windows 與 Linux 都支援**,差別只在各平台實際存在哪些訊號:
///   · SIGINT (Ctrl+C)  —— 兩個平台都有
///   · SIGTERM          —— 只有 POSIX 有(systemd stop / docker stop 用它);
///                          Windows 在 OS 層面就沒有這個概念
/// 所以這裡是「能掛的就掛」,不是「挑一個平台支援」。server 的功能在兩邊完全相同。
void _installSignalHandlers(ApiServer api) {
  Future<void> bye(String sig) async {
    _log('收到 $sig,正在關閉…', 'received $sig, shutting down...');
    await api.shutdown();
    exit(0);
  }

  _tryWatchSignal(ProcessSignal.sigint, 'SIGINT', bye);
  _tryWatchSignal(ProcessSignal.sigterm, 'SIGTERM', bye);
}

/// 安全地註冊一個系統訊號:平台不支援就跳過,不讓整支 process 死掉。
///
/// ⚠️ 為什麼要先問 [Platform.isWindows] 而不是直接 try/catch:
///    在 Windows 上 `sigterm.watch()` 丟的是**非同步**例外(SignalException),
///    try/catch 根本攔不到,會變成 Unhandled exception → exit 255。
///    只能在註冊前就避開。
void _tryWatchSignal(
  ProcessSignal sig,
  String name,
  Future<void> Function(String) onSignal,
) {
  // Windows 只有 SIGINT 可用;其餘訊號在該平台不存在,直接跳過。
  if (Platform.isWindows && sig != ProcessSignal.sigint) {
    _log('ℹ️ 本平台(Windows)沒有 $name,略過註冊(不影響服務運行)',
        '$name does not exist on Windows; skipped (service unaffected)');
    return;
  }
  try {
    sig.watch().listen((_) => onSignal(name));
  } catch (e) {
    final (zh, en) =
        _biError('⚠ 無法註冊 $name', 'could not register $name', e);
    _log('$zh(不影響服務運行)', '$en (service unaffected)');
  }
}
