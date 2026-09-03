// ============================================================================
// K2LfExperiment — LF 窗長對照實驗(UI 層,有狀態)
// ============================================================================
// 回答一個問題:**我們的 30 秒量測算出來的 LF,跟比較正規的 2 分鐘差多少?**
//
// ── 為什麼是「同一段資料切窗」而不是「量兩次」────────────────────
//   量兩次的話,兩次之間人的呼吸、姿勢、放鬆程度都變了 —— 測到的差異
//   分不清是「窗長造成的」還是「生理狀態變了」,實驗就白做了。
//   所以這裡只錄**一段** 2 分鐘,然後:
//     · 用完整 2 分鐘算一份 LF → 當基準
//     · 把同一段切成多個 30 秒窗,各算一份 → 跟基準比
//   同一批心跳、同一個生理狀態,差異純粹來自窗長。
//
// ── 為什麼放在 ui/ 而不是核心 ─────────────────────────────────────
//   「累積 2 分鐘」是有狀態的事。核心的設計原則是不存歷史、不開 Timer、
//   記憶體有界(RR 池 30 秒),把長期累積塞進去會破壞那條界線 ——
//   而那條界線正是交接內容的一部分。所以累積做在這裡,
//   純計算(Lomb-Scargle 等)呼叫核心層的 k2_vitals_metrics。
//
// ⚠️ 本專案開了 resetOnFingerOff:量測中途手指離開 → 核心連絕對索引一起歸零。
//    那會讓已錄的資料與新資料接不起來,所以偵測到就**中止實驗**並說明原因,
//    不會默默把兩段接在一起(接了會算出一個沒有意義的數字,而且不會報錯)。
// ============================================================================

import 'package:flutter/foundation.dart';

import '../k2_config.dart';
import '../k2_hrv_calculator.dart';
import '../k2_vitals_metrics.dart';

/// 一個 30 秒窗的結果 + 它與基準的偏差。
typedef LfWindow = ({
  /// 這個窗在整段錄製裡的起訖秒數(相對錄製開始)。
  double startSec,
  double endSec,
  HrvSpectrum spec,

  /// 與基準的偏差(%)。正 = 比基準高。
  double lfHfDevPct,
  double lfNuDevPct,
});

/// 同一個窗長切出來的一組窗 + 它們的統計。
///
/// 錄 5 分鐘時會有兩組:30 秒(產品實際用的長度)與 2 分鐘 ——
/// 後者是為了回答「我們一直拿來當基準的 2 分鐘,本身夠不夠格當基準」。
class LfWindowGroup {
  final int windowSeconds;
  final int stepSeconds;
  final List<LfWindow> windows;

  const LfWindowGroup({
    required this.windowSeconds,
    required this.stepSeconds,
    required this.windows,
  });

  List<double> get _absDevs =>
      [for (final w in windows) w.lfHfDevPct.abs()]..sort();

  /// 偏差絕對值的中位數(%)。「這個窗長典型上會差多少」的單一數字答案。
  ///
  /// 用中位數而非平均:實測過手抖那次有一個窗偏差 818%,平均會被它整個帶走,
  /// 中位數不會(那次的中位數 58%,與其他次一致)。
  double? get medianAbsDevPct {
    final v = _absDevs;
    return v.isEmpty ? null : v[v.length ~/ 2];
  }

  double? get maxAbsDevPct => _absDevs.isEmpty ? null : _absDevs.last;
  double? get minAbsDevPct => _absDevs.isEmpty ? null : _absDevs.first;

  /// 落在基準 ±20% 以內的窗有幾個。
  ///
  /// 20% 這條線是**判讀輔助,不是學術標準** —— 它只是提供一個直覺:
  /// 如果多數窗都在這個範圍內,這個窗長或許有當代理指標的價值;
  /// 如果散得到處都是,那就是在量雜訊。
  int get within20 => windows.where((w) => w.lfHfDevPct.abs() <= 20).length;
}

/// 實驗結果。
class LfExperimentResult {
  /// 完整錄製長度算出來的頻譜 —— **基準**。
  final HrvSpectrum baseline;

  /// 各窗長分組(至少一組:30 秒)。
  final List<LfWindowGroup> groups;

  final double durationSec;
  final int totalBeats;
  final int targetSeconds;

  const LfExperimentResult({
    required this.baseline,
    required this.groups,
    required this.durationSec,
    required this.totalBeats,
    required this.targetSeconds,
  });

  /// 30 秒那一組 —— 產品實際用的長度,歷次摘要記的就是它。
  LfWindowGroup get primary => groups.first;
}

/// 一次錄製的摘要,存進歷次清單用。
///
/// 為什麼需要這個:實測發現**單次結果不能下結論** —— 第一次量到偏差中位數
/// 75%、第二次卻只有 15%,連 2 分鐘基準本身都從 1.06 跳到 1.97。
/// 也就是說「30 秒差多少」這件事本身就會變,必須看多次的分布才有意義。
typedef LfRunSummary = ({
  int index,
  DateTime time,

  /// 這次錄了幾秒(120 或 300)—— 不同長度的結果不能混在一起比。
  int targetSeconds,
  double baselineLfHf,
  double baselineLf,
  double baselineHf,
  double spanSec,
  int beats,
  double? medianAbsDevPct,
  double? minAbsDevPct,
  double? maxAbsDevPct,
  int within20,
  int windowCount,
});

class K2LfExperiment extends ChangeNotifier {
  /// 可選的錄製長度(秒)。
  ///   120 = 2 分鐘,0.04Hz 走 4.8 圈,勉強站得住,還能要求使用者忍受。
  ///   300 = 5 分鐘,**國際標準(Task Force 1996)的短時記錄長度**。
  static const List<int> durationOptions = [120, 300];

  /// 目前選定的錄製長度。錄製中不可改(start 之後才鎖定)。
  int targetSeconds = 120;

  /// 要比對的窗長清單:(窗長秒, 滑動步進秒)。
  ///
  /// 30 秒 = 產品實際用的長度,永遠會算。
  /// 120 秒 = 我們前面一直拿來當基準的長度 —— 錄 5 分鐘時順便切它,
  ///          就能回答「2 分鐘本身夠不夠格當基準」這個問題。
  static const List<(int, int)> windowSpecs = [(30, 10), (120, 30)];

  /// 一個窗長至少要切得出這麼多個窗才有比較的意義,否則跳過。
  static const int _minWindowsPerGroup = 4;

  static const int _fs = Max30102Config.samplingRateHz;

  // ── 狀態 ──────────────────────────────────────────────────────
  final List<HrvRrPoint> _pts = [];
  bool _running = false;
  int _baseAbs = 0; // 錄製起點的絕對樣本位置
  int _lastEndAbs = -1; // 去重用:已收進來的最後一顆終谷
  int _elapsedSamples = 0;
  String? _abortReason;
  LfExperimentResult? _result;

  /// 歷次完成的錄製摘要(最舊在前)。
  ///
  /// [clear] **不會**清掉它 —— 「清除,再測一次」的用意就是保留前面幾次
  /// 再測下一次。要整批丟掉請用 [clearHistory]。
  final List<LfRunSummary> _history = [];

  bool get running => _running;
  String? get abortReason => _abortReason;
  LfExperimentResult? get result => _result;

  List<LfRunSummary> get history => List.unmodifiable(_history);

  /// 歷次「基準 LF/HF」的最小 / 最大。兩者差很多 = 連 2 分鐘的基準都不穩,
  /// 那「基準」這個詞就要打折 —— 我們是在拿一把會動的尺量東西。
  (double, double)? get baselineRange {
    if (_history.isEmpty) return null;
    final v = [for (final h in _history) h.baselineLfHf]..sort();
    return (v.first, v.last);
  }

  /// 歷次「偏差中位數」的最小 / 最大。這是最終要回報的那個數字的分布。
  (double, double)? get medianDevRange {
    final v = [
      for (final h in _history)
        if (h.medianAbsDevPct != null) h.medianAbsDevPct!,
    ]..sort();
    if (v.isEmpty) return null;
    return (v.first, v.last);
  }

  void clearHistory() {
    _history.clear();
    notifyListeners();
  }

  int get elapsedSeconds => _elapsedSamples ~/ _fs;
  int get collectedBeats => _pts.length;

  /// 已收集的拍(唯讀)。給畫面畫 tachogram / 驗證用。
  List<HrvRrPoint> get points => List.unmodifiable(_pts);

  /// 0.0 ~ 1.0。
  double get progress =>
      (_elapsedSamples / (targetSeconds * _fs)).clamp(0.0, 1.0);

  /// 開始錄製。[totalSamples] 傳核心當下的 `core.totalSamples` 當起點。
  void start(int totalSamples) {
    _pts.clear();
    _running = true;
    _baseAbs = totalSamples;
    _lastEndAbs = -1;
    _elapsedSamples = 0;
    _abortReason = null;
    _result = null;
    notifyListeners();
  }

  /// 使用者主動取消。
  void cancel() {
    if (!_running) return;
    _running = false;
    _abortReason = 'cancelled';
    notifyListeners();
  }

  /// 清掉結果,回到未開始的狀態。
  void clear() {
    _pts.clear();
    _running = false;
    _result = null;
    _abortReason = null;
    _elapsedSamples = 0;
    notifyListeners();
  }

  /// 每一輪核心算完就餵一次。
  ///
  /// [pts] 給 `K2Compute.rrPoints`(核心當下 30 秒視窗的乾淨 RR),
  /// [totalSamples] 給 `core.totalSamples`。
  ///
  /// 相鄰兩輪的 [pts] 高度重疊(視窗只滑動了一點),所以這裡靠 `endAbs` 去重 ——
  /// 每一拍的終谷絕對位置是唯一且遞增的,比對它就不會重複收。
  void feed(List<HrvRrPoint> pts, int totalSamples) {
    if (!_running) return;

    // ── 核心歸零偵測 ─────────────────────────────────────────────
    // 絕對計數器只會遞增,除非核心 reset 了(免洗模式手指離開 / 索引到頂)。
    // 一旦歸零,新舊資料的時間軸接不起來 —— 硬接會算出一個沒有意義但看起來
    // 正常的數字,所以直接中止。
    if (totalSamples < _baseAbs + _elapsedSamples) {
      _running = false;
      _abortReason = 'reset';
      notifyListeners();
      return;
    }

    _elapsedSamples = totalSamples - _baseAbs;

    for (final p in pts) {
      // 只收「錄製開始之後」且「還沒收過」的拍
      if (p.startAbs < _baseAbs) continue;
      if (p.endAbs <= _lastEndAbs) continue;
      _pts.add(p);
      _lastEndAbs = p.endAbs;
    }

    if (_elapsedSamples >= targetSeconds * _fs) {
      _finish();
      return;
    }
    notifyListeners();
  }

  /// 錄滿 → 算基準 + 切窗。
  void _finish() {
    _running = false;
    final baseline = Max30102VitalsMetrics.spectrum(_pts);
    if (baseline == null) {
      _abortReason = 'insufficient';
      notifyListeners();
      return;
    }

    double dev(double v, double base) =>
        base != 0 ? (v - base) / base * 100 : 0;

    // 每個窗長切一組。滑動而非切斷 —— 5 分鐘用 30 秒窗可以切出 28 個、
    // 用 2 分鐘窗可以切出 7 個,看得到的是**分布**而不是幾個孤立的點。
    final groups = <LfWindowGroup>[];
    for (final (winSec, stepSec) in windowSpecs) {
      if (winSec > targetSeconds) continue;
      final windows = <LfWindow>[];
      for (int s = 0; s + winSec <= targetSeconds; s += stepSec) {
        final lo = _baseAbs + s * _fs;
        final hi = _baseAbs + (s + winSec) * _fs;
        final sub = [
          for (final p in _pts)
            if (p.startAbs >= lo && p.endAbs <= hi) p,
        ];
        final spec = Max30102VitalsMetrics.spectrum(sub);
        if (spec == null) continue; // 這個窗拍數不夠(訊號斷過)→ 跳過,不硬算

        windows.add((
          startSec: s.toDouble(),
          endSec: (s + winSec).toDouble(),
          spec: spec,
          lfHfDevPct: dev(spec.lfHf, baseline.lfHf),
          lfNuDevPct: dev(spec.lfNu, baseline.lfNu),
        ));
      }
      // 切不出足夠的窗就不列(例如錄 2 分鐘時的 2 分鐘窗只有 1 個,
      // 那等於拿基準跟自己比,沒有意義)。
      if (windows.length >= _minWindowsPerGroup) {
        groups.add(LfWindowGroup(
          windowSeconds: winSec,
          stepSeconds: stepSec,
          windows: windows,
        ));
      }
    }
    if (groups.isEmpty) {
      _abortReason = 'insufficient';
      notifyListeners();
      return;
    }

    final res = LfExperimentResult(
      baseline: baseline,
      groups: groups,
      durationSec: baseline.spanSeconds,
      totalBeats: _pts.length + 1,
      targetSeconds: targetSeconds,
    );
    _result = res;
    // 歷次摘要記的是 30 秒那一組 —— 那是產品實際用的長度。
    final g = res.primary;
    _history.add((
      index: _history.length + 1,
      time: DateTime.now(),
      targetSeconds: targetSeconds,
      baselineLfHf: baseline.lfHf,
      baselineLf: baseline.lf,
      baselineHf: baseline.hf,
      spanSec: baseline.spanSeconds,
      beats: res.totalBeats,
      medianAbsDevPct: g.medianAbsDevPct,
      minAbsDevPct: g.minAbsDevPct,
      maxAbsDevPct: g.maxAbsDevPct,
      within20: g.within20,
      windowCount: g.windows.length,
    ));
    notifyListeners();
  }
}
