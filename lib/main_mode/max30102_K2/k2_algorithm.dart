// ============================================================================
// Max30102Algorithm - 上位機端 HR / SpO2 計算（新版：波形圖2 這條線）
// ============================================================================
// 晶片只吐原始 RED/IR，HR/SpO2 由上位機自己算。本檔是「新版(Maxim 風格)」主計算:
//   逐拍 B 點內插 + 中位數 R + prominence 找谷 + SQI。
//
// 分工:
//   - 訊號處理 / 數學(截尾/移動平均/去趨勢/找峰/DC-AC/中位數/R→SpO2) → Max30102Signal
//   - 本檔 compute():手指偵測 + _computeMaxim(逐拍 B 點 + 中位數 R + 找谷 + SQI)
//
// 流程：
//   1. 手指偵測：IR 平均 < 門檻 → 直接判無手指、回 invalid
//   2. _computeMaxim:去趨勢 → prominence 找谷 → 逐拍 R 中位 → SpO2 + SQI
//
// 純函式、無狀態，方便單元測試。O(N)、N≈500，主執行緒每秒跑一次無感。
//
// ── 2026-07 交接收尾:已清除的東西 ────────────────────────────────────
//   · k2_legacy_algorithm(舊版帶通 HR,波形圖1 用)—— 整檔刪除,K2 不需要
//   · HrSpo2Result 的 20 個舊欄位(舊版 HR/SpO2 原始+截尾各一份、截尾 DC/AC、
//     峰數、rank4a 的 P98 對照觀測)—— 算了沒人讀,只佔交接介面面積
//   結果:欄位 30 → 10,每輪省掉兩次完整帶通濾波 + 找峰。
// ============================================================================

import 'dart:math' as math;

import 'k2_signal.dart';
import 'k2_sqi.dart';

/// 一次演算視窗的計算結果(精簡後只留 K2 真正需要的欄位)。
class HrSpo2Result {
  /// 是否偵測到手指（IR DC ≥ 門檻）
  final bool fingerPresent;

  /// IR / RED 的 DC(視窗平均位準)與 AC(去 DC 後 RMS 脈動振幅)。
  /// 核心本身不用,但**保留給軟體端**:`fingerThreshold` 就是與 [irDc] 同單位,
  /// 沒有這組數字就沒辦法替不同感測器/貼合狀況調門檻,也看不出訊號強弱。
  final double irDc;
  final double irAc;
  final double redDc;
  final double redAc;

  /// 逐拍 B 點內插算出的 R 比值取中位。SpO2 由它經
  /// [Max30102Signal.spo2FromR] 換算。0 = 這輪算不出。
  final double spo2Ratio;

  /// 由 [spo2Ratio] 換算出的血氧(%);0 = 算不出。
  final double spo2;

  /// ⚠️ **目前控制層沒有採用這個旗標** —— 它代表「拍可信(中位間距在生理範圍)
  /// 且血氧落在 70~100」。k2_core 現在只看 `spo2Ratio > 0` 就輸出血氧,
  /// 等於拍不可信、值超出生理範圍時照樣吐。
  /// 這是**待決定事項**,不是死碼:要不要讓核心改成只在此旗標為 true 時輸出。
  final bool spo2Valid;

  /// 偵測到的「谷底」視窗內索引（0 = 視窗最舊）;NN 序列的來源。
  final List<int> irTroughs;

  /// 訊號品質閘門（間距變異 cv + 振幅突波 spike 都在容許內）→ true 才可信。
  final bool sqiOk;

  /// 振幅突波比 max/p70;越大越可能在體動。給軟體端判斷用。
  final double sqiSpikeMax;

  const HrSpo2Result({
    required this.fingerPresent,
    this.irDc = 0,
    this.irAc = 0,
    this.redDc = 0,
    this.redAc = 0,
    this.spo2Ratio = 0,
    this.spo2 = 0,
    this.spo2Valid = false,
    this.irTroughs = const [],
    this.sqiOk = false,
    this.sqiSpikeMax = 0,
  });

  /// 無手指 / 無資料的空結果
  static const HrSpo2Result empty = HrSpo2Result(fingerPresent: false);
}

class Max30102Algorithm {
  /// 主計算入口
  ///
  /// [red] / [ir]：演算法視窗的原始值（oldest → newest，長度通常 = 視窗筆數）
  /// [fs]：取樣率（Hz），預設 100
  static HrSpo2Result compute({
    required List<int> red,
    required List<int> ir,
    int fs = 100,
    double bandLowHz = 0.5,
    double bandHighHz = 4.0,
    int fingerThreshold = 50000,
    double hrMin = 30,
    double hrMax = 240,
    double spo2Min = 70,
    double spo2Max = 100,
    int trimWindow = 9,
    double promRatio = 0.5,
    bool spo2Linear = false,
  }) {
    final n = math.min(red.length, ir.length);
    if (n < fs) {
      // 不足 1 秒資料 → 無法判斷
      return HrSpo2Result.empty;
    }

    // ---- 0. 先算 IR/RED 的 DC（平均）與 AC（去 DC 後 RMS）——不論有無手指都算 ----
    final irD = List<double>.generate(n, (i) => ir[i].toDouble());
    final redD = List<double>.generate(n, (i) => red[i].toDouble());
    final dcIr = Max30102Signal.meanD(irD, n);
    final dcRed = Max30102Signal.meanD(redD, n);
    final acIr = Max30102Signal.rmsAc(irD, dcIr, n);
    final acRed = Max30102Signal.rmsAc(redD, dcRed, n);

    // 截尾滑動平均後的訊號(去突波)—— 主計算跑在這上面
    final irTrim = Max30102Signal.slidingTrimmedMean(irD, trimWindow);
    final redTrim = Max30102Signal.slidingTrimmedMean(redD, trimWindow);

    // ---- 1. 手指偵測（IR DC ≥ 門檻）----
    final fingerPresent = dcIr >= fingerThreshold;
    if (!fingerPresent) {
      return HrSpo2Result(
        fingerPresent: false,
        irDc: dcIr,
        irAc: acIr,
        redDc: dcRed,
        redAc: acRed,
      );
    }

    // ---- 2. 主計算(Maxim 風格)：跑在「截尾(去突波)訊號」上 + prominence 門檻 ----
    // 用 irTrim/redTrim 而非原始 → 殺掉尖刺型假谷
    final mx = _computeMaxim(
      irTrim,
      redTrim,
      fs,
      bandLowHz,
      bandHighHz,
      hrMin,
      hrMax,
      spo2Min,
      spo2Max,
      n,
      promRatio,
      spo2Linear,
    );

    return HrSpo2Result(
      fingerPresent: true,
      irDc: dcIr,
      irAc: acIr,
      redDc: dcRed,
      redAc: acRed,
      spo2Ratio: mx.ratio,
      spo2: mx.spo2,
      spo2Valid: mx.spo2Valid,
      irTroughs: mx.troughs,
      sqiOk: mx.sqiOk,
      sqiSpikeMax: mx.spikeMax,
    );
  }

  // ============================================================
  // 新版(Maxim 風格)：逐拍 B 點 + 中位數 R + prominence 找谷 + SQI
  // ============================================================
  static ({
    double spo2,
    bool spo2Valid,
    double ratio,
    List<int> troughs,
    bool sqiOk,
    double spikeMax,
  })
  _computeMaxim(
    List<double> irRaw,
    List<double> redRaw,
    int fs,
    double bandLow,
    double bandHigh,
    double hrMin,
    double hrMax,
    double spo2Min,
    double spo2Max,
    int n,
    double promRatio,
    bool spo2Linear,
  ) {
    // 1) 去趨勢 IR（減長視窗移動平均 = 高通，擋呼吸漂移），輕度平滑
    final hpWin = (fs / bandLow).round().clamp(1, n);
    final lpWin = (fs / (2 * bandHigh)).round().clamp(1, n);
    final baseline = Max30102Signal.movingAverage(irRaw, hpWin);
    final detrended = List<double>.generate(n, (i) => irRaw[i] - baseline[i]);
    final smoothed = Max30102Signal.movingAverage(detrended, lpWin);

    // 2) 找谷：對 -smoothed 找峰（谷=供血）。門檻用「百分位數」抗突波
    final neg = List<double>.generate(n, (i) => -smoothed[i]);
    final posOfNeg = <double>[];
    for (final v in neg) {
      if (v > 0) posOfNeg.add(v);
    }
    final p70 = Max30102Signal.percentile(posOfNeg, 70);
    final minDist = (60 * fs / hrMax).floor().clamp(1, n);
    // 顯著度門檻取代絕對深度：門檻=promRatio×p70(prominence)，內部自算(同尺度)
    final troughs = Max30102Signal.findProminentPeaks(neg, minDist, promRatio);

    const empty = (
      spo2: 0.0,
      spo2Valid: false,
      ratio: 0.0,
      troughs: <int>[],
      sqiOk: false,
      spikeMax: 0.0,
    );
    if (troughs.length < 3) {
      return (
        spo2: 0.0,
        spo2Valid: false,
        ratio: 0.0,
        troughs: troughs,
        sqiOk: false,
        spikeMax: 0.0,
      );
    }

    // 3) HR：谷間距 → 生理閘門 + 與中位數比剔除離群 → 取中位數
    final intervals = <double>[];
    for (int i = 1; i < troughs.length; i++) {
      intervals.add((troughs[i] - troughs[i - 1]).toDouble());
    }
    final medInt = Max30102Signal.median(List<double>.from(intervals));
    final kept = <double>[];
    for (final d in intervals) {
      final bpm = 60 * fs / d;
      if (bpm < hrMin || bpm > hrMax) continue; // 生理範圍閘門
      if (medInt > 0 && (d > medInt * 1.5 || d < medInt * 0.5)) {
        continue; // 漏拍(×2)/多抓(½)剔除
      }
      kept.add(d);
    }
    // 拍是否可信(給 SpO2 閘門 + 空結果判斷用):中位間距落在生理範圍即可。
    // 顯示用 HR 已改由 NN 序列(BeatSeries)取(B 階),這裡不再算 median(kept)→hr(去重)。
    // 中位間距 ∈ [60·fs/hrMax, 60·fs/hrMin] ⇔ HR ∈ [hrMin, hrMax]。
    bool beatsOk = false;
    if (kept.length >= 2) {
      final medKept = Max30102Signal.median(List<double>.from(kept));
      beatsOk = medKept >= 60 * fs / hrMax && medKept <= 60 * fs / hrMin;
    }
    // cv（間距變異）改由 Max30102Sqi 內部從 kept 算 → 見下方 SQI 段。

    // 4) SpO2：逐拍 B點內插（用原始 IR/RED），逐拍 R → 中位數
    final rList = <double>[];
    for (int j = 0; j < troughs.length - 1; j++) {
      final a = troughs[j], b = troughs[j + 1];
      if (b - a < 3) continue;
      final irBeat = _acDcBeat(irRaw, a, b);
      final redBeat = _acDcBeat(redRaw, a, b);
      if (irBeat.dc <= 0 || redBeat.dc <= 0 || irBeat.ac <= 0) continue;
      final r = (redBeat.ac / redBeat.dc) / (irBeat.ac / irBeat.dc);
      if (r > 0.1 && r < 3.0) rList.add(r);
    }
    double ratio = 0, spo2 = 0;
    bool spo2Valid = false;
    if (rList.isNotEmpty) {
      ratio = Max30102Signal.median(List<double>.from(rList));
      spo2 = Max30102Signal.spo2FromR(ratio, spo2Linear);
      spo2Valid = beatsOk && spo2 >= spo2Min && spo2 <= spo2Max;
    }

    // 5) SQI：間距變異(cv) + 振幅突波(spike) → 品質閘門。抽成 Max30102Sqi。
    //    cv 吃已粗篩的 kept;spike 吃原始 neg + p70。行為與抽取前一致。
    final sqi = Max30102Sqi.from(kept: kept, neg: neg, p70: p70);

    if (!beatsOk && rList.isEmpty) return empty;
    return (
      spo2: spo2,
      spo2Valid: spo2Valid,
      ratio: ratio,
      troughs: troughs,
      sqiOk: sqi.ok,
      spikeMax: sqi.spike,
    );
  }

  /// 一拍 [a,b](兩谷)之間：DC=段內峰值；AC=峰值 − 兩谷線性內插到峰值位置的基線(B點)
  static ({double ac, double dc}) _acDcBeat(List<double> x, int a, int b) {
    int pk = a;
    double pv = x[a];
    for (int i = a; i <= b; i++) {
      if (x[i] > pv) {
        pv = x[i];
        pk = i;
      }
    }
    final base = x[a] + (x[b] - x[a]) * (pk - a) / (b - a); // B點
    return (ac: pv - base, dc: pv);
  }
}
