// ============================================================================
// Max30102Sqi — 訊號品質指標（Signal Quality Index，逐「演算窗」計算）
// ============================================================================
// 【由 Dart 版 k2_sqi.dart 轉譯,行為完全一致】
//
// 每個演算窗(~5秒)算一次,判斷「這一輪偵測到的心跳可不可信」。純資料品質。
// 它是「閘門」:sqiOk=false 的那一輪,該輪的谷不進 NN 序列。
//
// 兩個零件(互補):
//   cv    = 間距離散(標準差 / 平均)。吃「已粗篩的乾淨間距 kept」。
//   spike = 最深起伏 / 典型起伏(max / p70)。吃原始 neg 訊號 → 抓體動大振幅。
//
// sqiOk = cv < 門檻 && spike < 門檻 && kept 夠多。
// ============================================================================

class Max30102Sqi {
  // ── 門檻（觀測式初值，實測後再調）──
  static cvMax = 0.35;
  static spikeMaxThresh = 5.0;
  static minKept = 2;

  /// @param {{cv:number, spike:number, keptCount:number}} o
  constructor({ cv, spike, keptCount }) {
    /// 間距變異係數(標準差 / 平均)。越大代表拍與拍的間隔越不規律。
    this.cv = cv;
    /// 突波比 = 最深起伏 / 典型起伏(max / p70)。越大越可能在體動。
    this.spike = spike;
    /// 參與 cv 計算的乾淨間距數。太少 → 統計不可信,直接判 false。
    this.keptCount = keptCount;
  }

  /// 由「窗層原料」算出品質:
  ///   kept = 已過「生理閘門 + 中位×[0.5,1.5]」的乾淨谷間距（cv 用）
  ///   neg  = −平滑去趨勢訊號（spike 的分子 max 用）
  ///   p70  = neg 正值的第 70 百分位（spike 的分母）
  static from({ kept, neg, p70 }) {
    // cv：kept < 2 → 1（必然不可信）；否則 標準差 / 平均
    let cv = 1;
    if (kept.length >= Max30102Sqi.minKept) {
      const meanK = kept.reduce((a, b) => a + b, 0) / kept.length;
      let varSum = 0;
      for (const d of kept) varSum += (d - meanK) * (d - meanK);
      cv = meanK > 0 ? Math.sqrt(varSum / kept.length) / meanK : 1;
    }
    // spike：最深起伏 / 典型起伏
    const ampMax = neg.length === 0 ? 0.0 : neg.reduce((a, b) => Math.max(a, b));
    const spike = p70 > 0 ? ampMax / p70 : 99.0;
    return new Max30102Sqi({ cv, spike, keptCount: kept.length });
  }

  /// 這一輪可不可信:cv + spike + kept 數 三者都要過。
  get ok() {
    return this.cv < Max30102Sqi.cvMax &&
      this.spike < Max30102Sqi.spikeMaxThresh &&
      this.keptCount >= Max30102Sqi.minKept;
  }
}

module.exports = { Max30102Sqi };
