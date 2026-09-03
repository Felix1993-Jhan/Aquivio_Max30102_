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

/// 實驗結果。
class LfExperimentResult {
  /// 完整錄製長度算出來的頻譜 —— **基準**。
  final HrvSpectrum baseline;

  /// 各個 30 秒窗(滑動,每 [K2LfExperiment.windowStepSeconds] 秒一個)。
  final List<LfWindow> windows;

  final double durationSec;
  final int totalBeats;

  const LfExperimentResult({
    required this.baseline,
    required this.windows,
    required this.durationSec,
    required this.totalBeats,
  });

  /// 各窗 LF/HF 偏差的絕對值,由小到大。
  List<double> get _absDevs {
    final v = [for (final w in windows) w.lfHfDevPct.abs()]..sort();
    return v;
  }

  /// 偏差絕對值的中位數(%)。這是「30 秒版典型上會差多少」的單一數字答案。
  double? get medianAbsDevPct {
    final v = _absDevs;
    if (v.isEmpty) return null;
    return v[v.length ~/ 2];
  }

  double? get maxAbsDevPct => _absDevs.isEmpty ? null : _absDevs.last;
  double? get minAbsDevPct => _absDevs.isEmpty ? null : _absDevs.first;

  /// 落在基準 ±20% 以內的窗有幾個。
  ///
  /// 20% 這條線是**判讀輔助,不是學術標準** —— 它只是提供一個直覺:
  /// 如果多數窗都在這個範圍內,30 秒版或許有當代理指標的價值;
  /// 如果散得到處都是,那就是在量雜訊。
  int get windowsWithin20pct =>
      windows.where((w) => w.lfHfDevPct.abs() <= 20).length;
}

class K2LfExperiment extends ChangeNotifier {
  /// 錄製目標長度(秒)。2 分鐘 —— 0.04Hz 走 4.8 圈,勉強站得住。
  /// 國際標準其實是 5 分鐘,這裡取 2 分鐘是「還能要求使用者忍受」的下限。
  static const int targetSeconds = 120;

  /// 對照窗長 = 我們產品實際用的長度。
  static const int windowSeconds = 30;

  /// 滑動步進。取 10 秒 → 2 分鐘可以切出 10 個窗,
  /// 看得到的是**分布**而不只是 4 個孤立的點。
  static const int windowStepSeconds = 10;

  static const int _fs = Max30102Config.samplingRateHz;

  // ── 狀態 ──────────────────────────────────────────────────────
  final List<HrvRrPoint> _pts = [];
  bool _running = false;
  int _baseAbs = 0; // 錄製起點的絕對樣本位置
  int _lastEndAbs = -1; // 去重用:已收進來的最後一顆終谷
  int _elapsedSamples = 0;
  String? _abortReason;
  LfExperimentResult? _result;

  bool get running => _running;
  String? get abortReason => _abortReason;
  LfExperimentResult? get result => _result;

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

    final windows = <LfWindow>[];
    for (int s = 0; s + windowSeconds <= targetSeconds; s += windowStepSeconds) {
      final lo = _baseAbs + s * _fs;
      final hi = _baseAbs + (s + windowSeconds) * _fs;
      final sub = [
        for (final p in _pts)
          if (p.startAbs >= lo && p.endAbs <= hi) p,
      ];
      final spec = Max30102VitalsMetrics.spectrum(sub);
      if (spec == null) continue; // 這個窗拍數不夠(訊號斷過)→ 跳過,不硬算

      double dev(double v, double base) =>
          base != 0 ? (v - base) / base * 100 : 0;

      windows.add((
        startSec: s.toDouble(),
        endSec: (s + windowSeconds).toDouble(),
        spec: spec,
        lfHfDevPct: dev(spec.lfHf, baseline.lfHf),
        lfNuDevPct: dev(spec.lfNu, baseline.lfNu),
      ));
    }

    _result = LfExperimentResult(
      baseline: baseline,
      windows: windows,
      durationSec: baseline.spanSeconds,
      totalBeats: _pts.length + 1,
    );
    notifyListeners();
  }
}
