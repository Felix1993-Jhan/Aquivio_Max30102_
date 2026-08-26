// ============================================================================
// Max30102Sqi — 訊號品質指標（Signal Quality Index，逐「演算窗」計算）
// ============================================================================
// 每個演算窗(~5秒)算一次,判斷「這一輪偵測到的心跳可不可信」。純資料品質,
// 本身不算 HR/SpO2/HRV —— 它是「閘門」:sqiOk=false 的那一輪,該輪的谷不進 NN 序列
// (見 k2_beatseries.feed 的 'SQI差' 分支)。
//
// 兩個零件(互補):
//   cv    = 間距離散(標準差 / 平均)。吃「已粗篩的乾淨間距 kept」→ 不被單一漏拍灌爆。
//   spike = 最深起伏 / 典型起伏(max / p70)。吃原始 neg 訊號 → 抓體動大振幅。
//   (cv 管「間距規律度」、spike 管「振幅有無暴衝」;一個被遮住還有另一個接。)
//
// sqiOk = cv < 門檻 && spike < 門檻 && kept 夠多。
//
// 純資料 + 純函式、無狀態,方便單元測試。抽自原 Max30102Algorithm._computeMaxim。
//
// ── 2026-07 交接收尾:已清除 ─────────────────────────────────────────
//   · spikeP98 / spikeP98Thresh / okP98 —— 那是研究期的「rank4a 對照觀測」
//     (spike 分子改用 P98、略過最深 ~2% 的想法),算完沒有任何地方採用。
//     留著只會讓交接的人以為有兩套品質判斷、不知道該信哪個。
//     日後真要試 P98,就是改 [spike] 的分子那一行,不需要並存兩份。
// ============================================================================

import 'dart:math' as math;

class Max30102Sqi {
  /// 間距變異係數(標準差 / 平均)。越大代表拍與拍的間隔越不規律。
  final double cv;

  /// 突波比 = 最深起伏 / 典型起伏(max / p70)。越大越可能在體動。
  final double spike;

  /// 參與 [cv] 計算的乾淨間距數。太少 → 統計不可信,直接判 false。
  final int keptCount;

  // ── 門檻（觀測式初值，實測後再調）──
  static const double cvMax = 0.35;
  static const double spikeMaxThresh = 5.0;
  static const int minKept = 2;

  const Max30102Sqi({
    required this.cv,
    required this.spike,
    required this.keptCount,
  });

  /// 由「窗層原料」算出品質：
  ///   kept = 已過「生理閘門 + 中位×[0.5,1.5]」的乾淨谷間距（cv 用）
  ///   neg  = −平滑去趨勢訊號（spike 的分子 max 用）
  ///   p70  = neg 正值的第 70 百分位（spike 的分母）
  factory Max30102Sqi.from({
    required List<double> kept,
    required List<double> neg,
    required double p70,
  }) {
    // cv：kept < 2 → 1（必然不可信）；否則 標準差 / 平均
    double cv = 1;
    if (kept.length >= minKept) {
      final meanK = kept.reduce((a, b) => a + b) / kept.length;
      double varSum = 0;
      for (final d in kept) {
        varSum += (d - meanK) * (d - meanK);
      }
      cv = meanK > 0 ? math.sqrt(varSum / kept.length) / meanK : 1;
    }
    // spike：最深起伏 / 典型起伏
    final ampMax = neg.isEmpty ? 0.0 : neg.reduce(math.max);
    final spike = p70 > 0 ? ampMax / p70 : 99.0;
    return Max30102Sqi(cv: cv, spike: spike, keptCount: kept.length);
  }

  /// 這一輪可不可信:cv + spike + kept 數 三者都要過。
  bool get ok => cv < cvMax && spike < spikeMaxThresh && keptCount >= minKept;
}
