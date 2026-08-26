// ============================================================================
// Max30102Signal — MAX30102 共用「訊號處理 / 數學」工具（單一真相來源）
// ============================================================================
// 【由 Dart 版 k2_signal.dart 轉譯,行為完全一致】
//
// 「截尾 / 移動平均 / 去趨勢 / 找峰找谷 / DC-AC / 中位數-百分位 / R→SpO2」的**唯一**實作。
// 全部 static、無狀態。O(N)。
//
// ⚠️ 轉譯注意:Dart 的 list.sort() 預設是數值排序;JS 的預設是字典序,
//    因此本檔所有排序都補上 (a,b)=>a-b。median/percentile 會就地排序輸入陣列
//    (與 Dart 一致),呼叫端若在意請自行傳副本。
// ============================================================================

/** clamp:對應 Dart num.clamp(lo, hi)。 */
function clamp(x, lo, hi) { return x < lo ? lo : (x > hi ? hi : x); }

class Max30102Signal {
  // ---------------- 去趨勢管線 ----------------

  /// 原始 → 截尾 → 基線 → 去趨勢 → 平滑 → neg。
  /// 回傳物件 { trimmed, baseline, detrend, smoothed, neg }。
  static preprocess(raw, { trimWindow, baselineWindow, smoothWindow }) {
    const n = raw.length;
    const trimmed = Max30102Signal.slidingTrimmedMean(raw, trimWindow);
    const baseline = Max30102Signal.movingAverage(trimmed, baselineWindow);
    const detrend = new Array(n);
    for (let i = 0; i < n; i++) detrend[i] = trimmed[i] - baseline[i];
    const smoothed = Max30102Signal.movingAverage(detrend, smoothWindow);
    const neg = new Array(n);
    for (let i = 0; i < n; i++) neg[i] = -smoothed[i];
    return { trimmed, baseline, detrend, smoothed, neg };
  }

  // ---------------- 平滑 / 截尾 ----------------

  /// 中心化移動平均（window 奇偶皆可，邊界用可得範圍）。前綴和 O(N)。
  static movingAverage(v, window) {
    const n = v.length;
    const out = new Array(n).fill(0);
    if (window <= 1) return [...v];
    const half = Math.trunc(window / 2);
    const prefix = new Array(n + 1).fill(0);
    for (let i = 0; i < n; i++) prefix[i + 1] = prefix[i] + v[i];
    for (let i = 0; i < n; i++) {
      const lo = Math.max(0, i - half);
      const hi = Math.min(n - 1, i + half);
      const count = hi - lo + 1;
      out[i] = (prefix[hi + 1] - prefix[lo]) / count;
    }
    return out;
  }

  /// 截尾滑動平均：以自身為中心的視窗，去 1 最高 + 1 最低再平均（抗突波）。
  /// 視窗中心對稱 [c−half, c+half],half = win ~/ 2 → 實際筆數 2×half+1(奇數,零相位)。
  /// 只丟 1 個最大 + 1 個最小 → 單點尖刺殺得掉;連續突波只擋一部分。
  /// 邊界:視窗被夾短到 cnt≤2 → 不去頭尾、直接平均。
  static slidingTrimmedMean(a, win) {
    const n = a.length;
    const out = new Array(n).fill(0);
    const half = Math.trunc(win / 2);
    for (let c = 0; c < n; c++) {
      const lo = c - half < 0 ? 0 : c - half;
      const hi = c + half >= n ? n - 1 : c + half;
      const cnt = hi - lo + 1;
      if (cnt <= 2) {
        let s = 0;
        for (let i = lo; i <= hi; i++) s += a[i];
        out[c] = s / cnt;
      } else {
        let s = 0, mn = a[lo], mx = a[lo];
        for (let i = lo; i <= hi; i++) {
          const v = a[i];
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
  static meanD(v, n) {
    let sum = 0;
    for (let i = 0; i < n; i++) sum += v[i];
    return sum / n;
  }

  /// 去 DC 後的均方根（AC 振幅）。
  static rmsAc(v, dc, n) {
    let sumSq = 0;
    for (let i = 0; i < n; i++) {
      const d = v[i] - dc;
      sumSq += d * d;
    }
    return Math.sqrt(sumSq / n);
  }

  // ---------------- 統計 ----------------

  /// 中位數(就地排序,偶數取兩中平均)。
  static median(xs) {
    if (xs.length === 0) return 0;
    xs.sort((a, b) => a - b);
    const m = Math.trunc(xs.length / 2);
    return (xs.length % 2 === 1) ? xs[m] : (xs[m - 1] + xs[m]) / 2;
  }

  /// 第 p 百分位(就地排序)。
  static percentile(xs, p) {
    if (xs.length === 0) return 0;
    xs.sort((a, b) => a - b);
    const idx = clamp(Math.round((p / 100) * (xs.length - 1)), 0, xs.length - 1);
    return xs[idx];
  }

  // ---------------- 找峰找谷 ----------------

  /// 顯著度(prominence)找峰:局部極大 → 算 prominence → 門檻=promRatio×p70 →
  /// 過濾後按 prominence 高→低做距離去重。找谷時對 −訊號 呼叫。
  static findProminentPeaks(s, distance, promRatio) {
    const n = s.length;
    const cand = [];
    for (let i = 1; i < n - 1; i++) {
      if (s[i] >= s[i - 1] && s[i] > s[i + 1]) cand.push(i);
    }
    if (cand.length === 0) return [];

    const prom = [];
    for (const p of cand) {
      const peak = s[p];
      let leftMin = peak;
      for (let i = p - 1; i >= 0; i--) {
        if (s[i] > peak) break;
        if (s[i] < leftMin) leftMin = s[i];
      }
      let rightMin = peak;
      for (let i = p + 1; i < n; i++) {
        if (s[i] > peak) break;
        if (s[i] < rightMin) rightMin = s[i];
      }
      prom.push(peak - Math.max(leftMin, rightMin));
    }

    const minProm = promRatio * Max30102Signal.percentile([...prom], 70);
    const kept = [];
    const keptProm = [];
    for (let k = 0; k < cand.length; k++) {
      if (prom[k] >= minProm) {
        kept.push(cand[k]);
        keptProm.push(prom[k]);
      }
    }

    const order = Array.from({ length: kept.length }, (_, i) => i);
    order.sort((a, b) => keptProm[b] - keptProm[a]);
    const chosen = [];
    for (const oi of order) {
      const idx = kept[oi];
      let ok = true;
      for (const c of chosen) {
        if (Math.abs(c - idx) < distance) { ok = false; break; }
      }
      if (ok) chosen.push(idx);
    }
    chosen.sort((a, b) => a - b);
    return chosen;
  }

  /// 簡單找峰：高於 threshold 的局部極大；相鄰過近(<distance)保留較高者。
  static findPeaks(s, distance, threshold) {
    const peaks = [];
    const n = s.length;
    for (let i = 1; i < n - 1; i++) {
      if (s[i] >= threshold && s[i] >= s[i - 1] && s[i] > s[i + 1]) {
        if (peaks.length > 0 && i - peaks[peaks.length - 1] < distance) {
          if (s[i] > s[peaks[peaks.length - 1]]) {
            peaks[peaks.length - 1] = i;
          }
        } else {
          peaks.push(i);
        }
      }
    }
    return peaks;
  }

  // ---------------- SpO2 ----------------

  /// R → SpO2(%)。linear=true 用 110−25R;false 用 −45.06R²+30.354R+94.845。
  static spo2FromR(r, linear) {
    return linear ? 110.0 - 25.0 * r : -45.06 * r * r + 30.354 * r + 94.845;
  }
}

module.exports = { Max30102Signal };
