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
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_vitals_metrics.dart';

// 版本號單獨一支檔 —— 改版只動 server_version.dart,那裡也記著沿革。
import 'server_version.dart';

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

  // 原始樣本
  final List<int> _waveIr = [];
  final List<int> _waveRed = [];

  // 截尾平滑後的樣本 —— 核心已經算好了(K2FeedResult.newIrTrim/newRedTrim),
  // 要畫「乾淨線」就用這組。核心的原則是 raw 與 trim **兩個都給,呈現層自己選**,
  // server 只是忠實轉發,不該在中間丟掉其中一半。
  final List<double> _waveIrTrim = [];
  final List<double> _waveRedTrim = [];

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
        _clearWave();
        _waveBase = r.firstAbs;
      }
      _waveIr.addAll(r.newIr);
      _waveRed.addAll(r.newRed);
      // raw 與 trim 逐筆對應(核心保證兩者等長),必須同步累積與裁切,
      // 否則兩條線的索引會錯開。
      _waveIrTrim.addAll(r.newIrTrim);
      _waveRedTrim.addAll(r.newRedTrim);

      final over = _waveIr.length - _waveCap;
      if (over > 0) {
        _waveIr.removeRange(0, over);
        _waveRed.removeRange(0, over);
        _waveIrTrim.removeRange(0, over);
        _waveRedTrim.removeRange(0, over);
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
    _waveIrTrim.clear();
    _waveRedTrim.clear();
    _waveBase = 0;
  }

  /// 最新一次計算結果。沒手指 / 沉澱中時對應欄位為 null,照核心現況輸出。
  ///
  /// ⚠️ **`/vitals` 與 `/stream` 吐的是同一個函式的輸出** —— WS 一接上先推
  ///    一份現況,之後每算完一次推一份。所以改這裡兩個端點會自動同步,
  ///    不會有一邊漏改。
  ///
  ///    **唯一的例外是 `wave`**(v0.0.0.5 起):`/stream` 會在這份輸出之外再蓋
  ///    一個 `wave` 區塊,`/vitals` 沒有。理由是 `wave` 給的是**增量**(自這個
  ///    訂閱者上次收到之後的新樣本),那需要「上次收到哪裡」這個**每連線一份**
  ///    的狀態 —— HTTP 輪詢沒有連線可依附,問十次就會拿到十份不相接的碎片。
  ///    要用 HTTP 拿波形請走 `GET /waveform`,那邊是「近 N 秒」的絕對切片。
  ///
  /// 回應分兩區:
  ///   · 頂層 + `hrv` —— **我們自己的欄位**,名稱與型別照核心的語意。
  ///   · `strapi` —— **整合方介面的形狀**(aquivio-station 的 `VitalsResult`),
  ///     欄位名與型別完全照他們的宣告,可以直接 `const v: VitalsResult = json.strapi`
  ///     零映射取用。
  ///
  /// 為什麼不直接把頂層欄位改名成他們的:**有些根本不是同一個量**。
  ///   · `sqiOk`(布林閘門) vs `sqi`(number 1/0)—— 型別不同
  ///   · `bpm`(最近 6 拍**中位**) vs `mean_hr`(全窗**平均**)—— 同一次量測
  ///     會差 1~3 bpm,改名等於送錯值
  /// 所以兩區並存,重複幾個 byte 不是問題。
  Map<String, dynamic> vitalsJson() {
    final c = k2.latest;
    final hv = c?.hrv;
    return {
      'fingerPresent': c?.fingerPresent ?? false,
      'sqiOk': c?.sqiOk ?? false,
      'settling': c?.settling ?? false,
      // 通道方向的判定結果(v0.0.0.6 起)。'unknown' = 還在判,此時波形與血氧
      // 都還不會出來(心率照給)。'swapped' = 手上這片模組把兩顆 LED 裝反了,
      // **輸出已經由核心轉正**,這個欄位只是讓上層知道、可以記錄或警示。
      'channelOrient': (c?.orient ?? K2ChannelOrient.unknown).name,
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
      'strapi': strapiJson(),
    };
  }

  /// 整合方介面(`VitalsResult`)形狀的區塊。
  ///
  /// ⚠️ **與 `hrv` 區塊必須同源。** 兩區的 `sdnn` / `rmssd` / `mean_hr` 是同一份
  ///    `HrvStats` 導出的,不可以各算各的 —— 各算一次就會有一天只改到一邊。
  ///    這裡直接把 `c.hrv` 傳進 [Max30102VitalsMetrics.compute]。
  Map<String, dynamic> strapiJson() {
    final c = k2.latest;
    final m = Max30102VitalsMetrics.compute(
      pts: c?.rrPoints ?? const [],
      hv: c?.hrv,
      sqiOk: c?.sqiOk ?? false,
      settling: c?.settling ?? false,
      bpm: c?.bpm,
      ir: _waveIr,
    );
    // 欄位、單位與可信度資訊全部由 toStrapiJson() 決定 —— server 不再自己
    // 補欄位。之前這裡加過 lf / hf / lf_reliable 等等,結果與核心那邊重複,
    // 兩處都要改才不會漂移。現在只有一個地方定義那份契約。
    return m.toStrapiJson();
  }

  /// 近一段波形。[seconds] 為 null → 給出全部保留的長度。
  ///
  /// `firstAbs` 是回傳陣列第 0 筆的絕對位置 —— 上層要把波形跟 `troughAbs`
  /// 對齊就靠它:`陣列索引 = abs - firstAbs`。
  ///
  /// 四個陣列**逐筆對應、等長**:
  ///   · `ir` / `red`         —— 感測器原始讀值
  ///   · `irTrim` / `redTrim` —— 核心截尾平滑後的值,要畫乾淨線就用這組
  /// 兩組都給,由呈現層自己選(與核心 K2FeedResult 的做法一致)。
  Map<String, dynamic> waveformJson({int? seconds}) {
    var from = 0;
    if (seconds != null && seconds > 0) {
      final want = seconds * kFs;
      if (_waveIr.length > want) from = _waveIr.length - want;
    }
    // 平滑值取一位小數就夠 —— IR 讀值是 ~90000 的量級,更多位數只是把
    // JSON 撐大(未修剪的 double 一筆可以長到 18 個字元)。
    List<double> round1(List<double> v) =>
        [for (final x in v.sublist(from)) (x * 10).roundToDouble() / 10];
    return {
      'firstAbs': _waveBase + from,
      'fs': kFs,
      'count': _waveIr.length - from,
      'ir': _waveIr.sublist(from),
      'red': _waveRed.sublist(from),
      'irTrim': round1(_waveIrTrim),
      'redTrim': round1(_waveRedTrim),
    };
  }

  /// WS `/stream` 用的**增量**波形:只給 IR 的截尾平滑值。
  ///
  /// 為什麼是「IR + trim」這個組合,而不是四條線都送:
  ///   · **IR** —— 心跳本身就是從這一路算出來的。手指偵測看 IR DC,谷點偵測
  ///     (`irTroughs`)跑在 IR 上,RED 只在算 SpO2 的 ratio 時才用到。畫 IR
  ///     等於畫「演算法看到的那條線」,畫面上的谷就是我們數的拍。
  ///   · **trim** —— 截尾滑動平均(去突波)。核心的主計算本來就跑在 trim 上
  ///     (見 k2_algorithm「殺掉尖刺型假谷」),raw 上那些尖刺是我們**判定為
  ///     雜訊而不採信**的東西。送 trim 不是美化,是與計算一致。
  /// 想要 RED 或 raw 就走 `GET /waveform`,那邊四條線照舊全給。
  ///
  /// [fromAbs] = 呼叫端**上次收到的下一筆**絕對位置;null = 沒收過。
  /// 遊標落在保留範圍外時**整段重送**,不硬接 —— 有兩種情況會這樣:
  ///   · 免洗歸零(下一位使用者)→ base 掉回 0,遊標比 nextAbs 還大
  ///   · 訂閱者太久沒收 / 剛接上 → 要的樣本已經被 `_waveCap` 裁掉了
  /// 兩種都是「接不上」,硬接會讓波形與 `troughAbs` 錯開,而且錯得很安靜。
  Map<String, dynamic> waveSinceJson(int? fromAbs) {
    final nextAbs = _waveBase + _waveIrTrim.length;
    final from = (fromAbs == null || fromAbs < _waveBase || fromAbs > nextAbs)
        ? _waveBase
        : fromAbs;
    // 一位小數就夠 —— IR 讀值是 ~90000 的量級(與 waveformJson 同樣的理由)。
    final slice = [
      for (final x in _waveIrTrim.sublist(from - _waveBase))
        (x * 10).roundToDouble() / 10,
    ];
    return {
      'firstAbs': from,
      'fs': kFs,
      'count': slice.length,
      'irTrim': slice,
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
  }

  /// RESET:軟體復位 → 晶片進入 POR 休眠。
  /// ⚠️ 復位後晶片**不可用**,必須再 [initChip] 才會恢復採樣。
  Future<void> resetChip() async {
    await request(
      Max30102Protocol.buildReset(board: board),
      Max30102Protocol.kSubReset,
    );
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
      // 晶片狀態變了 → 之前累積的波形與拍全部作廢。
      engine.reset();
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

      final cfg = engine.k2.config;
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

    // ⚠️ 遊標是**每個訂閱者一份**,不能提到 K2Engine 去共用 —— 兩個訂閱者接上的
    //    時間不同,共用一份的話先接上的那個會把樣本「領走」,後接上的只收得到
    //    殘缺片段,而且不會報錯。
    int? cursor;
    void push(Map<String, dynamic> v) {
      // 順序有意義:`_vitals.add()` 是在波形累積**之後**才發的(見 feedPacket),
      // 所以這裡讀到的緩衝已經含這一輪的新樣本。
      final w = engine.waveSinceJson(cursor);
      cursor = (w['firstAbs'] as int) + (w['count'] as int);
      try {
        ws.add(jsonEncode({...v, 'wave': w}));
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
max30102_server v$kServerVersion — MAX30102 K2 無頭伺服器 / headless vitals service

用法 / Usage:
  max30102_server [選項 / options]

選項 / Options:
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
      免洗模式:確認手指離開時連絕對索引一起歸零(預設 true)
      single-session mode: reset the sample index when the finger is
      confirmed removed (default: true)

  --help
      顯示這份說明 / show this help

  --version
      只印出版本號 / print the version and exit

環境變數(優先度低於命令列)/ Environment variables (lower precedence than CLI):
  K2_MODE  K2_SERIAL  K2_BAUD  K2_PORT  K2_BOARD  K2_INTERVAL
  K2_WAVE_SECONDS  K2_RESET_ON_FINGER_OFF

API:
  GET  /health                存活探測 + 目前模式 / liveness + current mode
  GET  /vitals                最新計算結果 / latest computed values
  GET  /waveform?seconds=10   近一段波形(原始 + 截尾平滑)
                              recent waveform (raw + trim-smoothed)
  POST /feed                  餵原始 MCU bytes(僅 feed 模式)
                              push raw MCU bytes (feed mode only)
  POST /mode                  切換進料模式 / switch input mode
  WS   /stream                每算出新結果就推播(約 1 秒一次),內容 = /vitals
                              再加一個 wave 區塊(IR 截尾平滑的增量樣本)
                              push on every new result (~1/s): /vitals plus a
                              `wave` block of incremental trim-smoothed IR
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
