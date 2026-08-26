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
//   ① K2Engine    —— 持有 Max30102K2,負責計算 + 累積波形供畫圖
//   ② FeedSource  —— 進料來源(串口 / HTTP 餵料),同一時間只有一種作用中
//   ③ ApiServer   —— HTTP/WS API 層(dart:io HttpServer)
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libserialport/libserialport.dart';

import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_config.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_core.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_protocol.dart';

// ════════════════════════════════════════════════════════════════════════════
// 常數與小工具
// ════════════════════════════════════════════════════════════════════════════

/// 取樣率(Hz)。核心固定 100Hz,波形秒數↔筆數的換算都靠它。
const int kFs = Max30102Config.samplingRateHz;

void _log(String msg) {
  final t = DateTime.now().toIso8601String().substring(11, 23);
  stdout.writeln('[$t] $msg');
}

// ════════════════════════════════════════════════════════════════════════════
// ① K2Engine —— 計算引擎 + 波形累積
// ════════════════════════════════════════════════════════════════════════════

/// 包住 [Max30102K2]:餵資料進來、算出結果、順便替上層累積一段波形。
///
/// 核心本身**不囤長歷史**(只留 config.dataHistoryMs),要畫圖得由外面自己存 ——
/// 這裡就是那個「外面」,把每次 feedData 回傳的 newIr/newRed 接起來。
class K2Engine {
  K2Engine({int waveSeconds = 30, bool resetOnFingerOff = true})
      : _waveCap = waveSeconds * kFs,
        // 免洗式量測(一人一次):確認手指離開時核心連絕對索引一起歸零,
        // 下一位使用者完全從零開始。核心預設是 false,這裡明確打開。
        k2 = Max30102K2(
          config: Max30102Config(resetOnFingerOff: resetOnFingerOff),
        );

  final Max30102K2 k2;

  /// 波形保留上限(筆)。超過就從頭裁掉。
  final int _waveCap;

  final List<int> _waveIr = [];
  final List<int> _waveRed = [];

  /// `_waveIr[0]` 的**絕對樣本位置**。上層靠它把波形對齊到 troughAbs / rrPoints。
  int _waveBase = 0;

  /// 每算出一份新結果就 push 給 WS 訂閱者。
  final StreamController<Map<String, dynamic>> _vitals =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get vitalsStream => _vitals.stream;

  int get totalSamples => k2.totalSamples;

  /// 餵一個 MCU 原始封包(含表頭與 CS)。回傳這次有沒有算出新結果。
  ///
  /// 封包壞掉 / 不是資料回應 → 核心回 empty,這裡就什麼都不做。
  bool feedPacket(List<int> packet) {
    final r = k2.feedData(packet);

    // 核心自行清空過(絕對索引到頂)→ 我們存的波形與 base 全部作廢。
    if (r.didReset) _clearWave();

    if (r.newIr.isNotEmpty) {
      // ⚠️ 核心在空轉期/沉澱期會**丟棄樣本**,所以 firstAbs 不保證等於
      //    「上一批結尾 + 1」。對不上就整段重接,不要硬接 —— 硬接會讓波形
      //    索引與 troughAbs 錯開,而且錯得很安靜。
      final expected = _waveBase + _waveIr.length;
      if (_waveIr.isEmpty || r.firstAbs != expected) {
        _waveIr.clear();
        _waveRed.clear();
        _waveBase = r.firstAbs;
      }
      _waveIr.addAll(r.newIr);
      _waveRed.addAll(r.newRed);

      final over = _waveIr.length - _waveCap;
      if (over > 0) {
        _waveIr.removeRange(0, over);
        _waveRed.removeRange(0, over);
        _waveBase += over; // 裁掉幾筆,base 就往前推幾筆
      }
    }

    if (r.computed != null) {
      if (!_vitals.isClosed) _vitals.add(vitalsJson());
      return true;
    }
    return false;
  }

  /// 重置:核心 + 波形都清乾淨。切換進料來源時一定要呼叫。
  void reset() {
    k2.reset();
    _clearWave();
  }

  void _clearWave() {
    _waveIr.clear();
    _waveRed.clear();
    _waveBase = 0;
  }

  /// 最新一次計算結果。沒手指 / 沉澱中時對應欄位為 null,照核心現況輸出。
  Map<String, dynamic> vitalsJson() {
    final c = k2.latest;
    final hv = c?.hrv;
    return {
      'fingerPresent': c?.fingerPresent ?? false,
      'sqiOk': c?.sqiOk ?? false,
      'settling': c?.settling ?? false,
      'bpm': c?.bpm,
      'spo2': c?.spo2,
      'hrv': hv == null
          ? null
          : {
              'sdnn': hv.sdnn,
              'rmssd': hv.rmssd,
              'pnn50': hv.pnn50,
              'sd1': hv.sd1,
              'sd2': hv.sd2,
              'meanRr': hv.meanRr,
              'meanHr': hv.meanHr,
              'hrvScore': hv.hrvScore,
              'beats': hv.beats,
            },
      'totalSamples': k2.totalSamples,
    };
  }

  /// 近一段波形。[seconds] 為 null → 給出全部保留的長度。
  ///
  /// `firstAbs` 是回傳陣列第 0 筆的絕對位置 —— 上層要把波形跟 `troughAbs`
  /// 對齊就靠它:`陣列索引 = abs - firstAbs`。
  Map<String, dynamic> waveformJson({int? seconds}) {
    var from = 0;
    if (seconds != null && seconds > 0) {
      final want = seconds * kFs;
      if (_waveIr.length > want) from = _waveIr.length - want;
    }
    return {
      'firstAbs': _waveBase + from,
      'fs': kFs,
      'count': _waveIr.length - from,
      'ir': _waveIr.sublist(from),
      'red': _waveRed.sublist(from),
    };
  }

  Future<void> dispose() async {
    await _vitals.close();
  }
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

  final K2Engine engine;
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

  @override
  String get name => 'serial';

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
      try {
        engine.feedPacket(pkt);
      } catch (e) {
        _log('⚠ feedPacket 失敗:$e');
      }
    };

    final port = SerialPort(portName);
    if (!port.openReadWrite()) {
      port.dispose();
      throw StateError(
          '無法開啟串口 $portName(是否被佔用?權限是否在 dialout 群組?)');
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
          _log('⚠ 解析失敗:$e');
        }
      },
      onError: (Object e) {
        // USB 被拔掉多半走這裡。記錄後讓計時器那邊去累積錯誤次數。
        _lastError = '$e';
        _log('⚠ 串口讀取錯誤:$e');
      },
      cancelOnError: false,
    );

    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) => _poll());
    _log('🟢 串口模式啟動:$portName @$baud,board=0x${board.toRadixString(16)},'
        '每 ${intervalMs}ms 詢問一次');
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
        _log('❌ 串口連續失敗 $_consecutiveErrors 次,停止輪詢(HTTP 服務繼續運行)');
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
    _log('⏸ 串口模式已停止:$portName');
  }
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

  final K2Engine engine;
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
    _log('🌐 HTTP 監聽 0.0.0.0:${opts.port}(目前模式:$mode)');
    server.listen(_handle, onError: (Object e) => _log('⚠ HTTP 錯誤:$e'));
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
        default:
          await _json(
              req, {'error': 'not found', 'path': path}, HttpStatus.notFound);
      }
    } catch (e, st) {
      _log('⚠ 處理 $path 失敗:$e\n$st');
      try {
        await _json(req, {'error': '$e'}, HttpStatus.internalServerError);
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
            'reason': '目前是 $mode 模式,POST /feed 只在 feed 模式可用',
            'hint': '先 POST /mode {"mode":"feed"}',
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
        await _json(req, {'error': 'JSON 解析失敗:$e'}, HttpStatus.badRequest);
        return;
      }
    } else {
      bytes = raw;
    }

    if (bytes == null || bytes.isEmpty) {
      await _json(req, {'error': 'body 是空的'}, HttpStatus.badRequest);
      return;
    }

    final computed = engine.feedPacket(bytes);
    await _json(req, {
      'accepted': bytes.length,
      'computed': computed,
      'totalSamples': engine.totalSamples,
    });
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
      await _json(req, {'error': 'JSON 解析失敗:$e'}, HttpStatus.badRequest);
      return;
    }

    final want = (body['mode'] as String?)?.toLowerCase();
    if (want != 'serial' && want != 'feed') {
      await _json(
          req,
          {'error': 'mode 必須是 "serial" 或 "feed"', 'got': body['mode']},
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

      try {
        await next.start();
        _source = next;
        _log('🔄 已切換到 $mode 模式');
        await _json(req, {'mode': mode, 'source': _source.status()});
      } catch (e) {
        // 新來源起不來(例如串口不存在)→ 退回 feed 模式,不要留下半死狀態。
        _log('❌ 切換到 $want 失敗:$e → 退回 feed 模式');
        _source = HttpFeedSource();
        await _source.start();
        await _json(
            req,
            {
              'error': '$e',
              'mode': mode,
              'note': '切換失敗,已退回 feed 模式',
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
    _log('🔌 WS 訂閱者接上(/stream)');
    // 一接上先給一份現況,對方不必等下一次計算才有畫面。
    ws.add(jsonEncode(engine.vitalsJson()));
    final sub = engine.vitalsStream.listen(
      (v) {
        try {
          ws.add(jsonEncode(v));
        } catch (_) {}
      },
      onError: (Object _) {},
    );
    ws.done.whenComplete(() {
      sub.cancel();
      _log('🔌 WS 訂閱者離線');
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
  });

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
    );
  }
}

const String _usage = '''
max30102_server — MAX30102 K2 無頭伺服器

用法:
  max30102_server [選項]

選項:
  --mode <serial|feed>   預設進料模式(預設 feed;可執行中用 POST /mode 改)
  --serial <path>        串口路徑,serial 模式用(預設 /dev/ttyUSB0)
  --baud <n>             鮑率(預設 115200)
  --port <n>             HTTP 監聽埠(預設 8770)
  --board <48|49>        表頭板子 byte,十進位(48=0x30 主板,49=0x31 擴充板;預設 49)
  --interval <ms>        串口輪詢間隔(預設 100)
  --wave-seconds <n>     /waveform 保留秒數(預設 30)
  --reset-on-finger-off <true|false>
                         免洗模式:確認手指離開時連絕對索引一起歸零(預設 true)
  --help                 顯示這份說明

環境變數(優先度低於命令列):
  K2_MODE K2_SERIAL K2_BAUD K2_PORT K2_BOARD K2_INTERVAL K2_WAVE_SECONDS
  K2_RESET_ON_FINGER_OFF

API:
  GET  /health           存活探測 + 目前模式
  GET  /vitals           最新計算結果
  GET  /waveform?seconds=10   近一段波形
  POST /feed             餵原始 MCU bytes(僅 feed 模式)
  POST /mode             切換進料模式
  WS   /stream           每算出新結果就推播一份 /vitals
''';

// ════════════════════════════════════════════════════════════════════════════
// main
// ════════════════════════════════════════════════════════════════════════════

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.write(_usage);
    return;
  }

  final opts = ServerOptions.parse(args);
  final engine = K2Engine(
    waveSeconds: opts.waveSeconds,
    resetOnFingerOff: opts.resetOnFingerOff,
  );

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
    _log('❌ 啟動失敗:$e');
    if (opts.mode == 'serial') {
      _log('→ 退回 feed 模式繼續啟動(可稍後用 POST /mode 重試串口)');
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
    _log('收到 $sig,正在關閉…');
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
    _log('ℹ️ 本平台(Windows)沒有 $name,略過註冊(不影響服務運行)');
    return;
  }
  try {
    sig.watch().listen((_) => onSignal(name));
  } catch (e) {
    _log('⚠ 無法註冊 $name:$e(不影響服務運行)');
  }
}
