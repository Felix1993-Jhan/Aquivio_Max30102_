// ============================================================================
// Max30102K2Fixed30 — 控制層(固定 30 秒、最後一次算)
// ============================================================================
// 與即時版 [Max30102K2](realtime/k2_core.dart)並列的第二套控制層。
// 演算檔(signal / algorithm / beatseries / hrv / vitals_metrics)完全共用,
// 差別只在「什麼時候算、拿哪段資料算」:
//
//   即時版:每 100 筆在最近 5 秒找一次谷,逐輪收谷,數值每秒更新。
//   本檔  :倒數 30 秒期間**只算畫圖的線**;30 秒到(再多收 154 筆右緣前後文)
//          才對整段資料**一次**找谷 → 生理閘門 → classify → HRV。
//          找谷門檻(P70)、SQI、血氧 R 用整段緩衝(沉澱 + 30 秒 + 右緣 154 筆);
//          谷只收 30 秒窗內的 → classify(整段 RR 中位數 ±20%)、cleanShare 都以這 30 秒為準。
//
// 一次量測的時間軸(手指放上 = 絕對位置 0):
//
//   0 ── 150 ──────── ~293 ──────────────────── 30 秒到 ──── +154 筆 ─▶
//   │ 空轉 │ 沉澱(左側前後文) │ 倒數 30 秒(計算窗,真實時鐘) │ 右緣前後文 │ → 算一次
//                  └ windowStart(= 開始輸出 = 即時版開始收谷的同一點)
//
// 空轉 / 沉澱 / 右緣 是**資料量**的要求(濾波器前後文),照樣數筆數;
// 倒數 30 秒與「滿 28 秒」用**真實時鐘**(從倒數開始那一刻起算,見 [clockMs])。
//
// 狀態([K2Phase]):
//   waiting   ── 沒手指,或空轉 / 沉澱中
//   measuring ── 倒數中(只算線、交波形)
//   done      ── 已出結果
//   aborted   ── 倒數未滿 [earlyStopMs] 手指就離開
//   done / aborted 都**鎖到 [reset]**(= server 收到 init):期間資料一筆都不進量測,
//   手指拿開再放上也不會開始新的量測(只更新 fingerPresent)。
//
// 血氧的通道方向:先照 config.channelMode 的假設算 R,再用自動判定的門檻驗一次 ——
//   R < orientRatioNormal(0.9)   → 假設對,照給
//   R > orientRatioSwapped(1.3)  → 假設錯,紅光 / 紅外換回來重算一次血氧
//   兩者之間(模糊帶)            → 分不出「真缺氧」與「接反」,不給(null)
// 心率 / HRV 不受方向影響(兩路脈搏同一個),不重算。
//
// 倒數滿 [earlyStopMs](28 秒,真實時鐘)後才離開 → 照算:從離開判定的那一筆往回,
// 在截尾 IR 上找「開始往下掉」的點 L([liftAbs]),只收 L − [hold] 之前的谷
// (與正常結束同一條右緣規則)。
//
// 設計原則同即時版:不碰串口、不開 Timer;呼叫端收到 MCU 回應就丟進 [feedData]。
// ============================================================================

import 'dart:math' as math;
import 'dart:typed_data';

import '../k2_algorithm.dart';
import '../k2_beatseries.dart';
import '../k2_config.dart';
import '../k2_hrv_calculator.dart';
import '../k2_protocol.dart';
import '../k2_setting_limits.dart';
import '../k2_signal.dart';
import '../realtime/k2_core.dart' show K2ChannelOrient, K2Compute, K2FeedResult;

/// 量測階段(對外的 `phase` 欄位,取 `.name`)。
enum K2Phase { waiting, measuring, done, aborted }

/// 中止原因(對外的 `abortReason` 欄位,取 `.name`)。
enum K2AbortReason { fingerRemoved }

/// 一次量測的結果。
class K2Fixed30Result {
  /// 計算結果。⚠️ `bpm` = HRV 的平均心率(`hrv.meanHr`),不是即時版的「最近 6 拍中位」。
  final K2Compute compute;

  /// 計算窗起點(含)/ 終點(不含),絕對位置。只收這之間的谷。
  final int windowStartAbs;
  final int windowEndAbs;

  /// 計算窗的原始 IR(實際光源;算 snr_db 用)。
  final List<int> windowIr;

  /// 提早結束時,截尾 IR 開始往下掉的點 L(絕對位置)。正常結束 = null。
  final int? liftAbs;

  const K2Fixed30Result({
    required this.compute,
    required this.windowStartAbs,
    required this.windowEndAbs,
    required this.windowIr,
    this.liftAbs,
  });
}

class Max30102K2Fixed30 {
  /// 計算窗的名目長度(筆)= 30 秒 × 100 Hz。只用來估緩衝上限;倒數本身看 [windowMs]。
  static const int windowSamples = 30 * Max30102Config.samplingRateHz;

  /// 倒數長度(真實時鐘,ms)。
  static const int windowMs = 30000;

  /// 倒數經過這麼久(真實時鐘,ms)之後手指離開,照常計算(28 秒)。
  static const int earlyStopMs = 28000;

  // 〔0.0.1-fixed30s 舊寫法:倒數與「滿 28 秒」數樣本(3000 / 2800 筆)。換成真實時鐘
  //   ([windowMs] / [earlyStopMs]):實機上樣本到達不足 100 筆/秒時,碼表 30 秒倒數還剩 3~4 秒。〕
  // /// 倒數滿這麼多筆後手指離開,照常計算(28 秒)。
  // static const int earlyStopSamples = 28 * Max30102Config.samplingRateHz;

  /// 倒數期間最多收這麼多筆(名目 30 秒的 1.2 倍),到了就當作窗滿、開始收右緣。
  /// 防上層一次灌進大量積壓資料(feed 模式)時,緩衝無限長、或裁切吃進計算窗。
  static const int maxWindowSamples = windowSamples + windowSamples ~/ 5;

  /// 右緣:線要離最新資料這麼多筆才算定下來 = 截尾半窗(4)+ troughGuardSamples(150)。
  /// 與即時版的 `_lineHold` 同一個數字。
  static const int hold =
      Max30102Config.trimWindow ~/ 2 + Max30102Config.troughGuardSamples;

  /// 找 L 的容許範圍:平台中位數 − 這個倍數 × 平台內脈搏峰對峰。
  /// ⚠️ 待上機驗證(抬手指時 IR 的實際形狀還沒錄過)。
  static const double liftTolP2p = 2.0;

  /// 找 L 時拿來估「平台」的那段:離開判定點往前 [_plateauSkip] ~ [_plateauSkip] + [_plateauLen] 筆。
  /// 跳過最近 1 秒,避開已經在往下掉的那段。
  static const int _plateauSkip = Max30102Config.samplingRateHz;
  static const int _plateauLen = 3 * Max30102Config.samplingRateHz;

  /// 可調參數(與即時版共用同一個類別)。
  final Max30102Config config;

  /// 時鐘(ms,只看差值,起點任意)。預設 = 建構時開始跑的 [Stopwatch];測試可注入假時鐘。
  /// 核心不開 Timer:只在收到資料、或有人讀 [remainingSec] 時看一眼。
  final int Function() clockMs;

  Max30102K2Fixed30({Max30102Config? config, int Function()? clockMs})
      : config = config ?? Max30102Config(),
        clockMs = clockMs ?? _stopwatchClock() {
    Max30102SettingLimits.enforce(this.config);
    _noFingerBatches = this.config.fingerOffBatches; // 開機 = 沒手指(同即時版)
  }

  static int Function() _stopwatchClock() {
    final sw = Stopwatch()..start();
    return () => sw.elapsedMilliseconds;
  }

  // ── 樣本緩衝(本次量測;上限見 [_bufCap])──
  final List<int> _ir = [];
  final List<int> _red = [];

  /// 緩衝上限:沉澱 + 倒數最多收的筆數 + 右緣,再留 1 秒餘裕。
  int get _bufCap => config.settleSamples + maxWindowSamples + hold + 100;
  // 〔0.0.1-fixed30s 舊寫法:倒數固定 3000 筆。換成真實時鐘後筆數不固定,上限改用 maxWindowSamples。〕
  // int get _bufCap => config.settleSamples + windowSamples + hold + 100;

  int _totalSamples = 0;
  int _sinceFingerOn = 0;
  int _noFingerBatches = 0;
  bool _settled = false;

  /// 計算窗起點(絕對位置);-1 = 還沒開始倒數。
  int _windowStart = -1;

  /// 倒數開始那一刻的時鐘值(ms);-1 = 還沒開始倒數。
  int _windowStartMs = -1;

  /// 計算窗終點(絕對位置,不含):30 秒到的那一刻收到的總筆數;-1 = 還沒到。
  int _winEnd = -1;

  /// 原始樣本 / 處理後波形下一筆要輸出的絕對位置;-1 = 還沒開始輸出。
  int _rawNextAbs = -1;
  int _waveNextAbs = -1;

  K2Phase _phase = K2Phase.waiting;
  K2AbortReason? _abortReason;
  K2Fixed30Result? _result;

  // ══════════════════════════════════════════════════════════════════
  // 取值
  // ══════════════════════════════════════════════════════════════════

  K2Phase get phase => _phase;
  K2AbortReason? get abortReason => _abortReason;

  /// 最近一次量測的結果;還沒出 / 已清除 = null。
  K2Fixed30Result? get result => _result;

  /// 是否偵測到手指(去彈跳後)。
  bool get fingerPresent => _noFingerBatches < config.fingerOffBatches;

  /// 手指在、但還在空轉 / 沉澱(= 即時版的 settling)。
  bool get settling =>
      fingerPresent && !_settled && _phase == K2Phase.waiting;

  /// 倒數剩餘秒數(真實時鐘,無條件進位);只在 measuring 時有值。
  /// 30 秒到了、還在等右緣那 1.5 秒 → 0。
  int? get remainingSec {
    if (_phase != K2Phase.measuring) return null;
    final left = windowMs - (clockMs() - _windowStartMs);
    return left <= 0 ? 0 : (left / 1000).ceil();
  }
  // 〔0.0.1-fixed30s 舊寫法:剩餘筆數 ÷ 100。換成真實時鐘(原因見 [windowMs])。〕
  // int? get remainingSec {
  //   if (_phase != K2Phase.measuring) return null;
  //   final left = _windowStart + windowSamples - _totalSamples;
  //   return left <= 0 ? 0 : (left / Max30102Config.samplingRateHz).ceil();
  // }

  /// 本次量測的絕對位置基準。
  int get totalSamples => _totalSamples;

  /// 對外回報的通道方向。有結果時 = 結果裡用 R 驗證過的方向;
  /// 還沒算之前 = 設定上的假設(指標 0 回 unknown)。
  K2ChannelOrient get channelOrient =>
      _result?.compute.orient ??
      switch (config.channelMode) {
        Max30102Config.channelModeSwapped => K2ChannelOrient.swapped,
        Max30102Config.channelModeNormal => K2ChannelOrient.normal,
        _ => K2ChannelOrient.unknown,
      };

  /// 設定上假設的方向(指標 0 = 照 datasheet,當作 normal)。
  static K2ChannelOrient _assumedOf(Max30102Config config) =>
      config.channelMode == Max30102Config.channelModeSwapped
          ? K2ChannelOrient.swapped
          : K2ChannelOrient.normal;

  // ══════════════════════════════════════════════════════════════════
  // 進料
  // ══════════════════════════════════════════════════════════════════

  /// 餵 MCU 原始封包。指標 1(強制對調)在拆包這一刻對調,與即時版相同。
  K2FeedResult feedData(List<int> packet) {
    final pkt = packet is Uint8List ? packet : Uint8List.fromList(packet);
    if (!Max30102Protocol.verifyCs(pkt)) return K2FeedResult.empty;
    final samples = Max30102Protocol.decodeFifoResponse(pkt);
    if (samples.isEmpty) return K2FeedResult.empty;
    final swap = config.channelMode == Max30102Config.channelModeSwapped;
    return feedSamples(
      [for (final s in samples) swap ? s.ir : s.red],
      [for (final s in samples) swap ? s.red : s.ir],
    );
  }

  /// 餵已拆好的樣本(實際光源;快照重放走這裡)。
  /// 回傳的 `computed` 只有「這一批剛算出結果」時非 null。
  K2FeedResult feedSamples(List<int> red, List<int> ir) {
    final n = red.length < ir.length ? red.length : ir.length;
    if (n <= 0) return K2FeedResult.empty;
    Max30102SettingLimits.enforce(config);

    // ── 手指偵測:這批 IR 平均 + 去彈跳(同即時版)──
    double sum = 0;
    for (int i = 0; i < n; i++) {
      sum += ir[i];
    }
    final fingerNow = (sum / n) >= config.fingerThreshold;
    _noFingerBatches = fingerNow ? 0 : _noFingerBatches + 1;

    // 已出結果 / 中止中:只更新手指狀態,資料一筆都不進,等 reset()(= init)
    if (_phase == K2Phase.done || _phase == K2Phase.aborted) {
      return _emptyResult();
    }

    // ── 確認手指離開 ──
    if (!fingerNow && _noFingerBatches >= config.fingerOffBatches) {
      final alreadyClean = _ir.isEmpty && _sinceFingerOn == 0;
      if (alreadyClean) return _emptyResult();
      K2Fixed30Result? early;
      if (_phase == K2Phase.measuring) {
        // 先算(若倒數已滿 28 秒,真實時鐘)再清 —— 清了就沒資料可算
        if (clockMs() - _windowStartMs >= earlyStopMs) {
          early = _computeEarlyStop();
        }
        // 〔0.0.1-fixed30s 舊寫法:數樣本。換成真實時鐘(原因見 [windowMs])。〕
        // if (_totalSamples - _windowStart >= earlyStopSamples) {
        //   early = _computeEarlyStop();
        // }
        if (early != null) {
          _result = early;
          _phase = K2Phase.done;
        } else {
          _phase = K2Phase.aborted;
          _abortReason = K2AbortReason.fingerRemoved;
        }
      }
      // 空轉 / 沉澱中離開:倒數還沒開始,不算中止,回到 waiting
      _clearMeasurement();
      return K2FeedResult(
        firstAbs: 0,
        newIr: const [],
        newRed: const [],
        newIrTrim: const [],
        newRedTrim: const [],
        computed: early?.compute,
        didReset: true, // 時間軸歸零,呼叫端存的波形全部作廢(同即時版免洗模式)
      );
    }

    // ── 空轉期:丟棄 ──
    _sinceFingerOn += n;
    if (_sinceFingerOn <= config.fingerDeadSamples) {
      _totalSamples += n;
      return _emptyResult(firstAbs: _totalSamples - n);
    }

    // ── 進緩衝 ──
    for (int i = 0; i < n; i++) {
      _ir.add(ir[i]);
      _red.add(red[i]);
    }
    _totalSamples += n;
    final over = _ir.length - _bufCap;
    if (over > 0) {
      _ir.removeRange(0, over);
      _red.removeRange(0, over);
    }

    // ── 沉澱期 ──
    if (!_settled && _ir.length < config.settleSamples) {
      return _emptyResult(firstAbs: _totalSamples - n);
    }

    // ── 沉澱完成 → 開始倒數 ──
    if (!_settled) {
      _settled = true;
      _windowStart = _bufStart + config.settleSamples;
      _windowStartMs = clockMs(); // 正式放行 = 開始計時
      _rawNextAbs = _windowStart;
      _waveNextAbs = _windowStart;
      _phase = K2Phase.measuring;
    }

    // ── 交出這批的原始樣本與處理後波形 ──
    final rawFrom = _rawNextAbs;
    final rawLo = rawFrom - _bufStart;
    final outIr = _ir.sublist(rawLo);
    final outRed = _red.sublist(rawLo);
    _rawNextAbs = _totalSamples;
    final wave = _takeWave();

    // ── 30 秒到(真實時鐘)→ 記下計算窗終點;再等右緣 [hold] 筆到齊 → 算一次 ──
    // 倒數期間收到的筆數到了 [maxWindowSamples] 也當作窗滿(防積壓資料灌爆緩衝)。
    if (_winEnd < 0 &&
        (clockMs() - _windowStartMs >= windowMs ||
            _totalSamples - _windowStart >= maxWindowSamples)) {
      _winEnd = _totalSamples;
    }
    K2Compute? computed;
    // 〔0.0.1-fixed30s 舊寫法:窗終點固定 = 起點 + 3000 筆。換成真實時鐘(原因見 [windowMs])。〕
    // final winEnd = _windowStart + windowSamples;
    // if (_totalSamples >= winEnd + hold) {
    if (_winEnd >= 0 && _totalSamples >= _winEnd + hold) {
      final winEnd = _winEnd;
      final res = _computeWindow(dataEnd: winEnd + hold, winEnd: winEnd);
      _result = res;
      _phase = K2Phase.done;
      computed = res.compute;
      _clearMeasurement(); // 鎖到 init,緩衝用不到了
    }

    return K2FeedResult(
      firstAbs: rawFrom,
      newIr: outIr,
      newRed: outRed,
      newIrTrim: const [], // 本模式不提供(server 不用;畫圖用 newIrWave)
      newRedTrim: const [],
      computed: computed,
      waveFirstAbs: wave.firstAbs,
      newIrWave: wave.line,
      newIrWaveTrim: wave.trim,
    );
  }

  /// 全部清除:結果、中止狀態、量測緩衝(= server 收到 init 成功時呼叫)。
  void reset() {
    _clearMeasurement();
    _noFingerBatches = config.fingerOffBatches;
    _result = null;
    _abortReason = null;
    _phase = K2Phase.waiting;
  }

  /// 只丟掉進行中的量測,**保留結果與中止狀態**(= server 收到 reset 關燈時呼叫)。
  /// 倒數中被關燈 → 回到 waiting(關燈是軟體刻意的動作,不算使用者手指離開)。
  void dropMeasurement() {
    _clearMeasurement();
    _noFingerBatches = config.fingerOffBatches;
    if (_phase == K2Phase.measuring) _phase = K2Phase.waiting;
  }

  // ══════════════════════════════════════════════════════════════════
  // 內部
  // ══════════════════════════════════════════════════════════════════

  int get _bufStart => _totalSamples - _ir.length;

  void _clearMeasurement() {
    _ir.clear();
    _red.clear();
    _totalSamples = 0;
    _sinceFingerOn = 0;
    _settled = false;
    _windowStart = -1;
    _windowStartMs = -1;
    _winEnd = -1;
    _rawNextAbs = -1;
    _waveNextAbs = -1;
  }

  K2FeedResult _emptyResult({int? firstAbs}) => K2FeedResult(
        firstAbs: firstAbs ?? _totalSamples,
        newIr: const [],
        newRed: const [],
        newIrTrim: const [],
        newRedTrim: const [],
        computed: null,
      );

  static ({List<double> trim, List<double> line}) _lineOf(List<int> buf) {
    final d = List<double>.generate(buf.length, (i) => buf[i].toDouble());
    final trim = Max30102Signal.slidingTrimmedMean(d, Max30102Config.trimWindow);
    final line = Max30102Signal.bandpass(
      trim,
      Max30102Config.samplingRateHz,
      lowHz: Max30102Config.beatBandLowHz,
      highHz: Max30102Config.beatBandHighHz,
    );
    return (trim: trim, line: line);
  }

  /// 交出「右邊已有 [hold] 筆、線定下來」的處理後波形(做法同即時版 _takeWave)。
  ({int firstAbs, List<double> line, List<double> trim}) _takeWave() {
    final from = _waveNextAbs;
    final to = _totalSamples - hold;
    if (to <= from) return (firstAbs: from, line: const [], trim: const []);
    final w = _lineOf(_ir);
    final lo = from - _bufStart, hi = to - _bufStart;
    _waveNextAbs = to;
    return (
      firstAbs: from,
      line: w.line.sublist(lo, hi),
      trim: w.trim.sublist(lo, hi),
    );
  }

  /// 對緩衝 [_bufStart, dataEnd) 算一次線、一次找谷,只收 [_windowStart, winEnd) 的谷。
  /// dataEnd − winEnd 就是右緣前後文(正常結束 = [hold];提早結束 = L − (L − hold))。
  K2Fixed30Result _computeWindow({
    required int dataEnd,
    required int winEnd,
    int? liftAbs,
  }) {
    final len = dataEnd - _bufStart;
    return computeBuffer(
      red: _red.sublist(0, len),
      ir: _ir.sublist(0, len),
      bufStartAbs: _bufStart,
      windowStartAbs: _windowStart,
      windowEndAbs: winEnd,
      liftAbs: liftAbs,
      config: config,
    );
  }

  /// 固定版的計算本體(公開、純函式):**資料多長都算**,什麼時候算由呼叫端決定。
  ///
  /// 狀態機在「滿 30 秒 / ≥ 28 秒手指離開」時呼叫它;快照重放可以直接呼叫(12 秒也行)。
  /// 只用參數與區域變數,不碰任何共用狀態 → 多處同時呼叫各算各的。
  ///
  ///   [red] / [ir]      一段連續資料,第 0 筆的絕對位置 = [bufStartAbs]。
  ///                     要照 config.channelMode 的假設排好(指標 1 = 呼叫端已對調);
  ///                     快照存的是實際光源 → 用指標 2(強制正常)或 0。
  ///   [windowStartAbs]  計算窗起點(含)。前面那段 = 沉澱,只當帶通線的左側前後文,谷不收。
  ///   [windowEndAbs]    計算窗終點(不含)。後面到資料尾 = 右緣前後文,谷不收;
  ///                     正常應留 [hold] 筆,線的右緣才定下來。
  ///   [liftAbs]         提早結束的 L 點,只是原封放進結果(畫圖用),不影響計算。
  ///
  /// 找谷門檻(P70)、SQI、血氧 R 用整段資料;谷 → RR → classify → HRV 只用窗內的谷。
  static K2Fixed30Result computeBuffer({
    required List<int> red,
    required List<int> ir,
    required int bufStartAbs,
    required int windowStartAbs,
    required int windowEndAbs,
    required Max30102Config config,
    int? liftAbs,
  }) {
    Max30102SettingLimits.enforce(config);
    final bufStart = bufStartAbs;
    final r = _algo(red, ir, config);
    final spo2 = _verifiedSpo2(r, red, ir, config);

    // 只收計算窗內的谷;右緣前後文裡的谷(含最右一顆)自然被排除
    final troughs = [
      for (final t in r.irTroughs)
        if (bufStart + t >= windowStartAbs && bufStart + t < windowEndAbs)
          bufStart + t,
    ];

    // 谷 → RR(生理閘門)→ classify,與即時版同一支 BeatSeries。
    // SQI 只回報、不當閘門(sqiOk 一律傳 true),結果放在 K2Compute.sqiOk 給軟體判定。
    final beats = Max30102BeatSeries(
      config: config,
      irAt: (abs) {
        final i = abs - bufStart;
        return (i >= 0 && i < ir.length) ? ir[i] : -1;
      },
      maxBeats: Max30102Config.maxBeats,
    );
    beats.feed(troughs, true);
    // classify 用整段 RR 中位數(即時版是局部 ±4 拍,見 old_code/2026-11-24.md)
    final cleanPts = Max30102HrvCalculator.clean(
      beats.samples,
      includeRecovered: true,
      apply: config.cleanEnabled,
      wholeSeries: true,
    );
    final hv = Max30102HrvCalculator.hrvFrom(cleanPts);
    final troughAbs = <int>[];
    for (final p in cleanPts) {
      if (troughAbs.isEmpty || troughAbs.last != p.startAbs) {
        troughAbs.add(p.startAbs);
      }
      troughAbs.add(p.endAbs);
    }

    return K2Fixed30Result(
      compute: K2Compute(
        fingerPresent: true,
        sqiOk: r.sqiOk,
        orient: spo2.orient,
        bpm: hv?.meanHr, // ★ 固定模式:bpm = HRV 平均心率
        spo2: spo2.value,
        hrv: hv,
        rr: [for (final p in cleanPts) p.rr],
        rrPoints: cleanPts,
        spikeMax: r.sqiSpikeMax,
        troughAbs: troughAbs,
      ),
      windowStartAbs: windowStartAbs,
      windowEndAbs: windowEndAbs,
      windowIr: ir.sublist(windowStartAbs - bufStart, windowEndAbs - bufStart),
      liftAbs: liftAbs,
    );
  }

  static HrSpo2Result _algo(
    List<int> red,
    List<int> ir,
    Max30102Config config,
  ) =>
      Max30102Algorithm.compute(
        red: red,
        ir: ir,
        irLine: _lineOf(ir).line,
        fs: Max30102Config.samplingRateHz,
        beatBandLowHz: Max30102Config.beatBandLowHz,
        beatBandHighHz: Max30102Config.beatBandHighHz,
        fingerThreshold: config.fingerThreshold,
        hrMin: config.hrMin.toDouble(),
        hrMax: config.hrMax.toDouble(),
        spo2Min: Max30102Config.spo2Min.toDouble(),
        spo2Max: Max30102Config.spo2Max.toDouble(),
        trimWindow: Max30102Config.trimWindow,
        promRatio: config.promRatio,
        spo2Linear: Max30102Config.spo2Linear,
      );

  /// 用 R 驗證設定上假設的方向(門檻沿用即時版自動判定的 orientRatioNormal / Swapped):
  ///   R < 0.9 → 假設對,照給;R > 1.3 → 假設錯,兩路換回來重算一次血氧;
  ///   模糊帶或算不出 R → 不給(null),方向回報原本的假設。
  /// [red] / [ir] 是照假設排好的兩路(指標 1 在 feedData 已經對調過)。
  static ({double? value, K2ChannelOrient orient}) _verifiedSpo2(
    HrSpo2Result r,
    List<int> red,
    List<int> ir,
    Max30102Config config,
  ) {
    final assumed = _assumedOf(config);
    final ratio = r.spo2Ratio;
    if (ratio > 0 && ratio < Max30102Config.orientRatioNormal) {
      return (value: r.spo2 > 0 ? r.spo2 : null, orient: assumed);
    }
    if (ratio > Max30102Config.orientRatioSwapped) {
      final flipped = _algo(ir, red, config); // 紅光 ↔ 紅外
      return (
        value: flipped.spo2 > 0 ? flipped.spo2 : null,
        orient: assumed == K2ChannelOrient.swapped
            ? K2ChannelOrient.normal
            : K2ChannelOrient.swapped,
      );
    }
    return (value: null, orient: assumed);
  }

  /// 倒數滿 28 秒後手指離開:找 L,再用同一條右緣規則算。找不到合理的 L → null(當作中止)。
  K2Fixed30Result? _computeEarlyStop() {
    final lift = _findLiftAbs();
    if (lift == null) return null;
    // 30 秒已到、還在等右緣時離開 → 窗終點不超過 30 秒那一點
    final winEnd = math.min(lift - hold, _winEnd >= 0 ? _winEnd : _totalSamples);
    // 〔0.0.1-fixed30s 舊寫法:上限 = 起點 + 3000 筆。換成真實時鐘(原因見 [windowMs])。〕
    // final winEnd = math.min(lift - hold, _windowStart + windowSamples);
    // 計算窗至少要有 1 秒,否則等同沒資料
    if (winEnd - _windowStart < Max30102Config.samplingRateHz) return null;
    return _computeWindow(dataEnd: lift, winEnd: winEnd, liftAbs: lift);
  }

  /// 在截尾 IR 上,從緩衝最後一筆(離開判定點)往回找「最後一個還在平台上的點」L。
  ///
  /// 平台 = 判定點往前 1~4 秒那段的中位數;容許 = 平台 − [liftTolP2p] × 那段的峰對峰。
  /// 往回走,直到截尾 IR 回到容許範圍內 —— 那一筆的下一筆就是開始往下掉的地方。
  int? _findLiftAbs() {
    final n = _ir.length;
    if (n < _plateauSkip + _plateauLen) return null;
    final trim = Max30102Signal.slidingTrimmedMean(
      [for (final v in _ir) v.toDouble()],
      Max30102Config.trimWindow,
    );
    final ref = trim.sublist(n - _plateauSkip - _plateauLen, n - _plateauSkip)
      ..sort();
    final median = ref[ref.length ~/ 2];
    final p2p = ref[(ref.length * 0.95).floor()] - ref[(ref.length * 0.05).floor()];
    final floor = median - liftTolP2p * p2p;
    int i = n - 1;
    while (i > 0 && trim[i] < floor) {
      i--;
    }
    return _bufStart + i + 1;
  }
}
