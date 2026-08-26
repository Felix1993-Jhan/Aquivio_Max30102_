// ============================================================================
// Max30102Algorithm - 上位機端 HR / SpO2 計算（新版：波形圖2 這條線）
// ============================================================================
// 【由 Dart 版 k2_algorithm.dart 轉譯,行為完全一致】
//
// 晶片只吐原始 RED/IR,HR/SpO2 由上位機自己算。本檔是「Maxim 風格」主計算:
//   逐拍 B 點內插 + 中位數 R + prominence 找谷 + SQI。
//
// 分工:
//   - 訊號處理 / 數學 → Max30102Signal
//   - 本檔 compute():手指偵測 + _computeMaxim(逐拍 B 點 + 中位數 R + 找谷 + SQI)
//
// 純函式、無狀態。O(N)、N≈500。
// ============================================================================

const { Max30102Signal } = require('./k2_signal');
const { Max30102Sqi } = require('./k2_sqi');

/** clamp:對應 Dart num.clamp(lo, hi)。 */
function clamp(x, lo, hi) { return x < lo ? lo : (x > hi ? hi : x); }

/// 一次演算視窗的計算結果(精簡後只留 K2 真正需要的欄位)。
class HrSpo2Result {
  constructor({
    fingerPresent,
    irDc = 0,
    irAc = 0,
    redDc = 0,
    redAc = 0,
    spo2Ratio = 0,
    spo2 = 0,
    spo2Valid = false,
    irTroughs = [],
    sqiOk = false,
    sqiSpikeMax = 0,
  }) {
    /// 是否偵測到手指（IR DC ≥ 門檻）
    this.fingerPresent = fingerPresent;
    /// IR / RED 的 DC(視窗平均位準)與 AC(去 DC 後 RMS 脈動振幅)。
    /// 核心本身不用,但保留給軟體端:fingerThreshold 與 irDc 同單位。
    this.irDc = irDc;
    this.irAc = irAc;
    this.redDc = redDc;
    this.redAc = redAc;
    /// 逐拍 B 點內插算出的 R 比值取中位。0 = 這輪算不出。
    this.spo2Ratio = spo2Ratio;
    /// 由 spo2Ratio 換算出的血氧(%);0 = 算不出。
    this.spo2 = spo2;
    /// ⚠️ 目前控制層沒有採用這個旗標(待決定事項)。
    /// 代表「拍可信 且 血氧落在 70~100」。
    this.spo2Valid = spo2Valid;
    /// 偵測到的「谷底」視窗內索引（0 = 視窗最舊）;NN 序列的來源。
    this.irTroughs = irTroughs;
    /// 訊號品質閘門（cv + spike 都在容許內）→ true 才可信。
    this.sqiOk = sqiOk;
    /// 振幅突波比 max/p70;越大越可能在體動。
    this.sqiSpikeMax = sqiSpikeMax;
  }
}

/// 無手指 / 無資料的空結果
HrSpo2Result.empty = new HrSpo2Result({ fingerPresent: false });

class Max30102Algorithm {
  /// 主計算入口。以 options 物件傳參(對應 Dart 具名參數)。
  ///   red / ir:演算法視窗的原始值（oldest → newest）
  ///   fs:取樣率（Hz），預設 100
  static compute({
    red,
    ir,
    fs = 100,
    bandLowHz = 0.5,
    bandHighHz = 4.0,
    fingerThreshold = 50000,
    hrMin = 30,
    hrMax = 240,
    spo2Min = 70,
    spo2Max = 100,
    trimWindow = 9,
    promRatio = 0.5,
    spo2Linear = false,
  }) {
    const n = Math.min(red.length, ir.length);
    if (n < fs) {
      // 不足 1 秒資料 → 無法判斷
      return HrSpo2Result.empty;
    }

    // ---- 0. 先算 IR/RED 的 DC（平均）與 AC（去 DC 後 RMS）——不論有無手指都算 ----
    const irD = new Array(n);
    const redD = new Array(n);
    for (let i = 0; i < n; i++) { irD[i] = ir[i]; redD[i] = red[i]; }
    const dcIr = Max30102Signal.meanD(irD, n);
    const dcRed = Max30102Signal.meanD(redD, n);
    const acIr = Max30102Signal.rmsAc(irD, dcIr, n);
    const acRed = Max30102Signal.rmsAc(redD, dcRed, n);

    // 截尾滑動平均後的訊號(去突波)—— 主計算跑在這上面
    const irTrim = Max30102Signal.slidingTrimmedMean(irD, trimWindow);
    const redTrim = Max30102Signal.slidingTrimmedMean(redD, trimWindow);

    // ---- 1. 手指偵測（IR DC ≥ 門檻）----
    const fingerPresent = dcIr >= fingerThreshold;
    if (!fingerPresent) {
      return new HrSpo2Result({
        fingerPresent: false,
        irDc: dcIr, irAc: acIr, redDc: dcRed, redAc: acRed,
      });
    }

    // ---- 2. 主計算(Maxim 風格):跑在「截尾(去突波)訊號」上 + prominence 門檻 ----
    const mx = Max30102Algorithm._computeMaxim(
      irTrim, redTrim, fs, bandLowHz, bandHighHz,
      hrMin, hrMax, spo2Min, spo2Max, n, promRatio, spo2Linear,
    );

    return new HrSpo2Result({
      fingerPresent: true,
      irDc: dcIr, irAc: acIr, redDc: dcRed, redAc: acRed,
      spo2Ratio: mx.ratio,
      spo2: mx.spo2,
      spo2Valid: mx.spo2Valid,
      irTroughs: mx.troughs,
      sqiOk: mx.sqiOk,
      sqiSpikeMax: mx.spikeMax,
    });
  }

  // ============================================================
  // 新版(Maxim 風格):逐拍 B 點 + 中位數 R + prominence 找谷 + SQI
  // 回傳 { spo2, spo2Valid, ratio, troughs, sqiOk, spikeMax }
  // ============================================================
  static _computeMaxim(
    irRaw, redRaw, fs, bandLow, bandHigh, hrMin, hrMax, spo2Min, spo2Max, n,
    promRatio, spo2Linear,
  ) {
    // 1) 去趨勢 IR（減長視窗移動平均 = 高通，擋呼吸漂移），輕度平滑
    const hpWin = clamp(Math.round(fs / bandLow), 1, n);
    const lpWin = clamp(Math.round(fs / (2 * bandHigh)), 1, n);
    const baseline = Max30102Signal.movingAverage(irRaw, hpWin);
    const detrended = new Array(n);
    for (let i = 0; i < n; i++) detrended[i] = irRaw[i] - baseline[i];
    const smoothed = Max30102Signal.movingAverage(detrended, lpWin);

    // 2) 找谷:對 -smoothed 找峰（谷=供血）。門檻用「百分位數」抗突波
    const neg = new Array(n);
    for (let i = 0; i < n; i++) neg[i] = -smoothed[i];
    const posOfNeg = [];
    for (const v of neg) if (v > 0) posOfNeg.push(v);
    const p70 = Max30102Signal.percentile(posOfNeg, 70);
    const minDist = clamp(Math.floor(60 * fs / hrMax), 1, n);
    const troughs = Max30102Signal.findProminentPeaks(neg, minDist, promRatio);

    const empty = {
      spo2: 0.0, spo2Valid: false, ratio: 0.0, troughs: [], sqiOk: false, spikeMax: 0.0,
    };
    if (troughs.length < 3) {
      return {
        spo2: 0.0, spo2Valid: false, ratio: 0.0, troughs, sqiOk: false, spikeMax: 0.0,
      };
    }

    // 3) HR：谷間距 → 生理閘門 + 與中位數比剔除離群 → 取中位數
    const intervals = [];
    for (let i = 1; i < troughs.length; i++) {
      intervals.push(troughs[i] - troughs[i - 1]);
    }
    const medInt = Max30102Signal.median([...intervals]);
    const kept = [];
    for (const d of intervals) {
      const bpm = 60 * fs / d;
      if (bpm < hrMin || bpm > hrMax) continue; // 生理範圍閘門
      if (medInt > 0 && (d > medInt * 1.5 || d < medInt * 0.5)) continue; // 漏拍/多抓剔除
      kept.push(d);
    }
    // 拍是否可信:中位間距落在生理範圍即可。
    let beatsOk = false;
    if (kept.length >= 2) {
      const medKept = Max30102Signal.median([...kept]);
      beatsOk = medKept >= 60 * fs / hrMax && medKept <= 60 * fs / hrMin;
    }

    // 4) SpO2：逐拍 B點內插（用原始 IR/RED），逐拍 R → 中位數
    const rList = [];
    for (let j = 0; j < troughs.length - 1; j++) {
      const a = troughs[j], b = troughs[j + 1];
      if (b - a < 3) continue;
      const irBeat = Max30102Algorithm._acDcBeat(irRaw, a, b);
      const redBeat = Max30102Algorithm._acDcBeat(redRaw, a, b);
      if (irBeat.dc <= 0 || redBeat.dc <= 0 || irBeat.ac <= 0) continue;
      const r = (redBeat.ac / redBeat.dc) / (irBeat.ac / irBeat.dc);
      if (r > 0.1 && r < 3.0) rList.push(r);
    }
    let ratio = 0, spo2 = 0;
    let spo2Valid = false;
    if (rList.length > 0) {
      ratio = Max30102Signal.median([...rList]);
      spo2 = Max30102Signal.spo2FromR(ratio, spo2Linear);
      spo2Valid = beatsOk && spo2 >= spo2Min && spo2 <= spo2Max;
    }

    // 5) SQI：間距變異(cv) + 振幅突波(spike) → 品質閘門。
    const sqi = Max30102Sqi.from({ kept, neg, p70 });

    if (!beatsOk && rList.length === 0) return empty;
    return {
      spo2, spo2Valid, ratio, troughs, sqiOk: sqi.ok, spikeMax: sqi.spike,
    };
  }

  /// 一拍 [a,b](兩谷)之間:DC=段內峰值;AC=峰值 − 兩谷線性內插到峰值位置的基線(B點)
  /// 回傳 { ac, dc }。
  static _acDcBeat(x, a, b) {
    let pk = a;
    let pv = x[a];
    for (let i = a; i <= b; i++) {
      if (x[i] > pv) { pv = x[i]; pk = i; }
    }
    const base = x[a] + (x[b] - x[a]) * (pk - a) / (b - a); // B點
    return { ac: pv - base, dc: pv };
  }
}

module.exports = { HrSpo2Result, Max30102Algorithm };
