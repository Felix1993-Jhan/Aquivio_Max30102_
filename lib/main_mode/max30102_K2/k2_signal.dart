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

  // ---------------- 移動平均版的去趨勢(v0.0.0.7 的找谷 / 畫圖線)----------------
  //
  //   截尾平滑(9)→ 減 baseline(200)→ 低通平滑(13)
  //
  // v0.0.0.8 起找谷與畫圖都改走下面的 [troughLine](帶通)。這幾支留著:
  // baseline 視窗寬仍是沉澱期長度與波形圖 DC 虛線的依據。

  /// baseline(高通)移動平均的視窗寬 = `fs / bandLowHz`(預設 100 / 0.5 = 200 筆 = 2 秒)。
  ///
  /// 綁在最慢心跳上:baseline 要擋「比最慢的心跳還慢」的漂移;視窗比一個心動週期
  /// 短的話,它會跟著心跳跑,反而把脈搏本身抵消掉。
  static int baselineWindow(int fs, double bandLowHz) =>
      (fs / bandLowHz).round().clamp(1, 1 << 20);

  /// 低通移動平均的視窗寬 = `fs / (2 × bandHighHz)`(預設 100 / 8 = 12.5 → 13 筆)。
  static int lowpassWindow(int fs, double bandHighHz) =>
      (fs / (2 * bandHighHz)).round().clamp(1, 1 << 20);

  /// 減掉 baseline(置中移動平均)。`v[i] − movingAverage(v, window)[i]`。
  static List<double> detrend(List<double> v, int window) {
    final base = movingAverage(v, window);
    return List<double>.generate(v.length, (i) => v[i] - base[i]);
  }

  /// 減 baseline → 低通平滑。輸入是**已經截尾**的訊號(核心演算法自己先截尾,
  /// 因為 RED 也要截尾、血氧要用)。
  static List<double> detrendSmooth(
    List<double> trimmed, {
    required int baselineWindow,
    required int lowpassWindow,
  }) =>
      movingAverage(detrend(trimmed, baselineWindow), lowpassWindow);

  // ---------------- 找谷用的線 = 畫圖用的線(算法只有這一份)----------------
  //
  //   截尾平滑(9)→ 0.7~3.5 Hz 二階 Butterworth 帶通(正反各一次)
  //
  // 核心找谷(k2_core 對整段緩衝算一次,切片交給 k2_algorithm)、核心輸出的
  // newIrWave(= server 送出的 `wave`)、App 波形圖都走這裡 ——
  // **畫出來的線就是拿來找谷的那條線**。

  /// 原始值 → 找谷 / 畫圖用的線:截尾平滑 → 帶通([bandpass])。
  ///
  /// ⚠️ 帶通是 IIR、正反各跑一次:每一點都受**兩端所有資料**影響,越靠近陣列兩端越不準
  ///    (右緣 150 筆內誤差 > 1.4%,見 Max30102Config.troughGuardSamples)。
  ///    要穩定的值就得等右邊資料夠多再取 —— 核心找谷與 newIrWave 都等 150 筆。
  static List<double> troughLine(
    List<double> raw, {
    required int trimWindow,
    required int fs,
    required double lowHz,
    required double highHz,
  }) =>
      bandpass(
        slidingTrimmedMean(raw, trimWindow),
        fs,
        lowHz: lowHz,
        highHz: highHz,
      );

  // ---------------- 帶通(v0.0.0.8)----------------
  //
  // 為什麼換掉「減 2 秒移動平均」:移動平均的頻率響應有零點與旁瓣,0.5 Hz(快呼吸、按壓)
  // 完全擋不住、0.7 Hz 還放大 20%,殘留的斜坡會把谷推走(見 Max30102Config.beatBandLowHz)。

  /// 零相位帶通:2 階 Butterworth 高通 [lowHz] + 2 階 Butterworth 低通 [highHz],
  /// 各自正向跑一次、反向再跑一次(filtfilt)→ 相位抵消,谷的時間位置不偏移。
  ///
  /// 濾波器狀態從第一筆的穩態起跑(低通 = 第一筆的值、高通 = 0),
  /// 不然開頭那一階 DC(~90000)會讓濾波器響鈴好幾秒。
  ///
  /// 參數不合理(頻率 ≤ 0、高過 Nyquist、上下限顛倒)直接丟例外 —— 算出來的線會是錯的,
  /// 而找谷不會報錯,只會安靜地給錯的心率。
  static List<double> bandpass(
    List<double> x,
    int fs, {
    required double lowHz,
    required double highHz,
  }) {
    if (fs <= 0 || lowHz <= 0 || highHz <= lowHz || highHz >= fs / 2) {
      throw ArgumentError(
        'bandpass: 需要 0 < lowHz < highHz < fs/2(fs=$fs, lowHz=$lowHz, highHz=$highHz)',
      );
    }
    final hp = _filtfilt(x, _Biquad.butterworth(fs, lowHz, lowPass: false));
    return _filtfilt(hp, _Biquad.butterworth(fs, highHz, lowPass: true));
  }

  static List<double> _filtfilt(List<double> x, _Biquad f) {
    final fwd = f.run(x);
    return f.run(fwd.reversed.toList()).reversed.toList();
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

/// 2 階 IIR(biquad)—— [Max30102Signal.bandpass] 用。
/// 係數照 RBJ Audio EQ Cookbook,Q = 1/√2(Butterworth,通帶最平)。
class _Biquad {
  final double b0, b1, b2, a1, a2;
  final bool lowPass;

  const _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2, this.lowPass);

  factory _Biquad.butterworth(int fs, double f0, {required bool lowPass}) {
    final w0 = 2 * math.pi * f0 / fs;
    final c = math.cos(w0);
    final alpha = math.sin(w0) / (2 * math.sqrt1_2);
    final a0 = 1 + alpha;
    final k = lowPass ? (1 - c) / 2 : (1 + c) / 2;
    return _Biquad(
      k / a0,
      (lowPass ? 2 * k : -2 * k) / a0,
      k / a0,
      -2 * c / a0,
      (1 - alpha) / a0,
      lowPass,
    );
  }

  /// 正向跑一次。狀態從第一筆的穩態起跑:低通的輸出 = 輸入、高通的輸出 = 0。
  List<double> run(List<double> x) {
    final y = List<double>.filled(x.length, 0);
    if (x.isEmpty) return y;
    double x1 = x[0], x2 = x[0];
    double y1 = lowPass ? x[0] : 0, y2 = y1;
    for (int i = 0; i < x.length; i++) {
      final v = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      x2 = x1;
      x1 = x[i];
      y2 = y1;
      y1 = v;
      y[i] = v;
    }
    return y;
  }
}
