// ============================================================================
// Max30102Signal — MAX30102 共用「訊號處理 / 數學」工具（單一真相來源）
// ============================================================================
// 這裡是「截尾 / 移動平均 / 去趨勢 / 找峰找谷 / DC-AC / 中位數-百分位 / R→SpO2」
// 的**唯一**實作。演算法層(algorithm/legacy)與所有波形 painter 都呼叫這裡,
// 避免同一條公式散落多份、改一處要改多處。
//
// 全部 static、無狀態,方便單元測試。O(N)。
// ============================================================================

import 'dart:math' as math;

/// 一次做完的去趨勢管線結果（painter 重繪 / 找谷都吃這份）。
typedef PreprocessResult = ({
  List<double> trimmed, // 截尾滑動平均(去突波)
  List<double> baseline, // 截尾線的長視窗移動平均(≈呼吸基線)
  List<double> detrend, // trimmed − baseline(去趨勢)
  List<double> smoothed, // detrend 再低通平滑(找峰找谷實際看的線)
  List<double> neg, // −smoothed(找谷=在此找峰)
});

class Max30102Signal {
  // ---------------- 去趨勢管線 ----------------

  /// 原始 → 截尾 → 基線 → 去趨勢 → 平滑 → neg。視窗全部由呼叫端指定
  /// （各處視窗值不同：baselineWindow=fs/bandLow、smoothWindow 依用途）。
  static PreprocessResult preprocess(
    List<double> raw, {
    required int trimWindow,
    required int baselineWindow,
    required int smoothWindow,
  }) {
    final n = raw.length;
    final trimmed = slidingTrimmedMean(raw, trimWindow);
    final baseline = movingAverage(trimmed, baselineWindow);
    final detrend = List<double>.generate(n, (i) => trimmed[i] - baseline[i]);
    final smoothed = movingAverage(detrend, smoothWindow);
    final neg = List<double>.generate(n, (i) => -smoothed[i]);
    return (
      trimmed: trimmed,
      baseline: baseline,
      detrend: detrend,
      smoothed: smoothed,
      neg: neg,
    );
  }

  // ---------------- 平滑 / 截尾 ----------------

  /// 中心化移動平均（window 奇偶皆可，邊界用可得範圍）。前綴和 O(N)。
  static List<double> movingAverage(List<double> v, int window) {
    final n = v.length;
    final out = List<double>.filled(n, 0);
    if (window <= 1) {
      return List<double>.from(v);
    }
    final half = window ~/ 2;
    final prefix = List<double>.filled(n + 1, 0);
    for (int i = 0; i < n; i++) {
      prefix[i + 1] = prefix[i] + v[i];
    }
    for (int i = 0; i < n; i++) {
      final lo = math.max(0, i - half);
      final hi = math.min(n - 1, i + half);
      final count = hi - lo + 1;
      out[i] = (prefix[hi + 1] - prefix[lo]) / count;
    }
    return out;
  }

  /// 截尾滑動平均：以自身為中心的視窗，去 1 最高 + 1 最低再平均（抗突波）。
  ///
  /// ⚠️ 參數 win 不等於「實際抓幾筆」，用之前先看懂：
  ///   · 視窗是中心對稱 [c−half, c+half]，half = win ~/ 2（整數除法）
  ///     → 實際筆數 = 2×half + 1（永遠奇數）。
  ///   · 整數除法會捨去，所以 win=4 與 win=5 都 → half=2 → 實抓 5 筆
  ///     （4≡5、6≡7…；UI 上調偶數值和它 +1 的奇數值效果完全相同）。
  ///   · 例：win=4 → 抓 5 筆 → 去 1 最大 + 1 最小 → 平均剩下 3 筆（分母 = cnt−2）。
  ///   · 與原始設計意圖「抓 win 筆、去 2 筆、剩下 /2」不同：現行是中心對稱版，
  ///     多抓 1 筆、平均 (cnt−2) 筆。改中心對稱是為了「零相位」——濾波不位移谷底
  ///     位置，對後續找谷 / 算 RR 的時間定位有利（偶數窗會有半樣本相位偏移）。
  ///   · 只丟「1 個」最大 + 「1 個」最小 → 單點尖刺殺得掉；連續 ≥2 筆的突波只擋一部分。
  ///   · 邊界：視窗被夾短到 cnt≤2 → 不去頭尾、直接平均（避免把資料砍光）。
  static List<double> slidingTrimmedMean(List<double> a, int win) {
    final n = a.length;
    final out = List<double>.filled(n, 0);
    final half = win ~/ 2;
    for (int c = 0; c < n; c++) {
      final lo = c - half < 0 ? 0 : c - half;
      final hi = c + half >= n ? n - 1 : c + half;
      final cnt = hi - lo + 1;
      if (cnt <= 2) {
        double s = 0;
        for (int i = lo; i <= hi; i++) {
          s += a[i];
        }
        out[c] = s / cnt;
      } else {
        double s = 0, mn = a[lo], mx = a[lo];
        for (int i = lo; i <= hi; i++) {
          final v = a[i];
          s += v;
          if (v < mn) mn = v;
          if (v > mx) mx = v;
        }
        out[c] = (s - mn - mx) / (cnt - 2);
      }
    }
    return out;
  }

  // ---------------- DC / AC ----------------

  /// 視窗平均（DC 位準）。
  static double meanD(List<double> v, int n) {
    double sum = 0;
    for (int i = 0; i < n; i++) {
      sum += v[i];
    }
    return sum / n;
  }

  /// 去 DC 後的均方根（AC 振幅）。
  static double rmsAc(List<double> v, double dc, int n) {
    double sumSq = 0;
    for (int i = 0; i < n; i++) {
      final d = v[i] - dc;
      sumSq += d * d;
    }
    return math.sqrt(sumSq / n);
  }

  // ---------------- 統計 ----------------

  static double median(List<double> xs) {
    if (xs.isEmpty) return 0;
    xs.sort();
    final m = xs.length ~/ 2;
    return xs.length.isOdd ? xs[m] : (xs[m - 1] + xs[m]) / 2;
  }

  static double percentile(List<double> xs, double p) {
    if (xs.isEmpty) return 0;
    xs.sort();
    final idx = ((p / 100) * (xs.length - 1)).round().clamp(0, xs.length - 1);
    return xs[idx];
  }

  // ---------------- 找峰找谷 ----------------

  /// 顯著度(prominence)找峰：先找所有局部極大 → 算 prominence
  /// (峰值 − 左右「遇到更高峰前的最低谷」之較高者) → 門檻=promRatio×p70(prominence)
  /// → 過濾後按 prominence 高→低做距離去重。找谷時對 −訊號 呼叫。
  static List<int> findProminentPeaks(
      List<double> s, int distance, double promRatio) {
    final n = s.length;
    final cand = <int>[];
    for (int i = 1; i < n - 1; i++) {
      if (s[i] >= s[i - 1] && s[i] > s[i + 1]) cand.add(i);
    }
    if (cand.isEmpty) return [];

    final prom = <double>[];
    for (final p in cand) {
      final peak = s[p];
      double leftMin = peak;
      for (int i = p - 1; i >= 0; i--) {
        if (s[i] > peak) break;
        if (s[i] < leftMin) leftMin = s[i];
      }
      double rightMin = peak;
      for (int i = p + 1; i < n; i++) {
        if (s[i] > peak) break;
        if (s[i] < rightMin) rightMin = s[i];
      }
      prom.add(peak - math.max(leftMin, rightMin));
    }

    final minProm = promRatio * percentile(List<double>.from(prom), 70);
    final kept = <int>[];
    final keptProm = <double>[];
    for (int k = 0; k < cand.length; k++) {
      if (prom[k] >= minProm) {
        kept.add(cand[k]);
        keptProm.add(prom[k]);
      }
    }

    final order = List<int>.generate(kept.length, (i) => i);
    order.sort((a, b) => keptProm[b].compareTo(keptProm[a]));
    final chosen = <int>[];
    for (final oi in order) {
      final idx = kept[oi];
      bool ok = true;
      for (final c in chosen) {
        if ((c - idx).abs() < distance) {
          ok = false;
          break;
        }
      }
      if (ok) chosen.add(idx);
    }
    chosen.sort();
    return chosen;
  }

  /// 簡單找峰：高於 threshold 的局部極大；相鄰過近(<distance)保留較高者。
  /// （舊版 HR 用；保留在共用層供 legacy 呼叫。）
  static List<int> findPeaks(List<double> s, int distance, double threshold) {
    final peaks = <int>[];
    final n = s.length;
    for (int i = 1; i < n - 1; i++) {
      if (s[i] >= threshold && s[i] >= s[i - 1] && s[i] > s[i + 1]) {
        if (peaks.isNotEmpty && i - peaks.last < distance) {
          if (s[i] > s[peaks.last]) {
            peaks[peaks.length - 1] = i;
          }
        } else {
          peaks.add(i);
        }
      }
    }
    return peaks;
  }

  // ---------------- SpO2 ----------------

  /// R → SpO2(%)。linear=true 用 `110−25R`；false 用 `−45.06R²+30.354R+94.845`。
  static double spo2FromR(double r, bool linear) {
    return linear ? 110.0 - 25.0 * r : -45.06 * r * r + 30.354 * r + 94.845;
  }
}
