// ============================================================================
// Max30102HrvCalculator — HRV 純計算（無狀態，可單元測試）
// ============================================================================
// 只負責「給一份累積好的 RR → 算出 HRV」：
//   clean()   全體中位數 ±30% 再濾一次（可選是否含補漏拍補回的拍）
//   hrvFrom() SDNN / RMSSD / SD1 / SD2 / meanHr / 有效對數
//   stats()   = hrvFrom(clean(...)) 的方便包裝
//
// 「累積」(維護最近 300 拍 RR 歷史、補漏拍、收集時誤拍過濾) 是有狀態的事,
// 留在 Max30102Controller;本檔只吃「已累積的樣本清單」,不碰任何狀態/環形緩衝。
//
// RMSSD 關鍵:只累加「時間相鄰(前一筆終谷 == 這筆起谷)」的相鄰對,分母=連續對數,
// 跨掉拍/跨離群的假相減不計入 → 避免 RMSSD、SD1 被灌水。
// SD1 = RMSSD/√2；SD2 = √(2·SDNN²−SD1²)（與 Poincaré 圖同一組數字）。
// ============================================================================

import 'dart:math' as math;

/// 一筆累積的 RR：值 + 起/終谷絕對位置 + 是否為 search-back 補回的拍。
typedef HrvRrSample = ({double rr, int startAbs, int endAbs, bool recovered});

/// 乾淨 RR（僅值 + 起/終谷，供判連續與繪圖）。
typedef HrvRrPoint = ({double rr, int startAbs, int endAbs});

/// HRV 統計結果（單位：ms；meanHr=bpm；pairs/totalPairs=連續對數/全部相鄰對）。
typedef HrvStats = ({
  double meanRr,
  double sdnn,
  double rmssd,
  double sd1,
  double sd2,
  double meanHr,
  int beats,
  int pairs,
  int totalPairs,
  double pnn50, // 相鄰對中 |差|>50ms 的比例(%);只算時間相鄰對,副交感指標
  double hrvScore, // ln(RMSSD)×20 → clamp 0~100;「跟自己比」的親切分數(Elite HRV 風格)
});

class Max30102HrvCalculator {
  // bigJumpRel:相鄰兩拍差 > 此比例×平均 = 一次「大跳」。現在**只**給 Poincaré 圖的
  //   「紅=大跳」散點上色用(標出拉開點雲的那些拍),不再拿來判「可信/不可信」——
  //   那套(圓團/逐拍亂跳)已全移除:HRV 數字/形狀不反映品質,品質看波形乾不乾淨。
  static const double bigJumpRel = 0.25;
  // 暖機:乾淨拍 < 此數 → HRV 樣本太少不穩,UI 標「暖機中/僅供參考」。
  // 9 拍讓中位數基準紮實、離群也被 clean() 濾過;要 HRV 數字更穩可再拉高(如 20~30)。
  static const int minBeatsForHrv = 9;
  // rank6:clean() 的穩健離群倍率 —— 剔除條件 |rr − 中位數| > thresh。
  // 門檻隨資料自身離散度縮放(高 HRV 不誤剔)。
  static const double madK = 2.5;
  // MAD → 標準差的一致性換算(常態下 σ ≈ 1.4826 × MAD)。
  // 少了它,「2.5×MAD」其實只等於 ≈1.69σ —— 連完全正常的資料都會被砍掉約 9%,
  // 而且「心跳越穩 → MAD 越小 → 門檻越緊 → 砍越兇」,自打嘴巴。
  static const double madScale = 1.4826;
  // 門檻下限 = 中位數 × 此比例。clean 的定位改為「只擋真漏拍/切拍,不砍真拍的中等擺動」:
  //   0.5 → 保留 [0.5×, 1.5×] 中位數以內的拍;超出才視為漏拍(≈2×)/切拍(≈0.5×)剔除。
  //   為何不能用 0.15(舊值):安靜時 MAD 只有 40ms,2.5×1.4826×MAD≈148ms → 帶寬只 ±148,
  //   會把「真谷、真間距、只是中等偏離(如 630~1030,離中位 150~210ms)」的正常拍當離群砍掉
  //   (實測體動/訊號衰退期的真拍被誤剔)。真漏拍 820→1640(離 820=820ms)仍遠超 ±410,照擋。
  //   高 HRV 者(MAD 大)由 max() 的 2.5σ 項自動放更寬,不受此下限壓。
  static const double minRelThresh = 0.5;

  // ── H1：疑似異位拍(早搏)偵測參數 ──────────────────────────────────
  // A 階段「只標記、不從池移除」→ 不影響任何 HRV 數字。簽章:短→代償長→回歸,
  // 門檻用「近 window 拍逐拍差」的自適應值(median|ΔRR|+K·MAD),非固定百分比:
  //   高 HRV 者門檻自動放寬(不誤剔真 RSA→不製造假雪茄);心跳加速=持續變短不回頭→不觸發。
  static const double ectopicK = 4.0; // |ΔRR| 門檻倍率:median + K×MAD(3.5→4.0:少放輕度邊界,偏保守/通用)
  static const int ectopicWindow = 10; // 自適應統計窗(近 N 拍);乾淨拍 < N → 不啟動
  static const double ectopicReturnTol = 0.20; // 回歸容差:前/後拍需回到 中位 ±20% 內

  /// 用全體中位數 ±30% 再濾一次（排開頭尖刺）。
  /// includeRecovered=false → 排除補漏拍補回的拍（給「補漏拍 開/關」對照）。
  /// 保留起/終谷（下游靠「前終谷==此起谷」判相鄰是否連續）。
  /// 注意：這裡會「壓縮」清單(抽掉離群)，被抽掉處左右兩筆的谷位置就對不上 →
  /// RMSSD 自動略過那種跨洞相減。
  static List<HrvRrPoint> clean(
    List<HrvRrSample> history, {
    required bool includeRecovered,
    bool apply = true, // false → 不做 MAD 離群濾(clean 開關關閉時);RR 全收
  }) {
    final base = <HrvRrPoint>[
      for (final e in history)
        if (includeRecovered || !e.recovered)
          (rr: e.rr, startAbs: e.startAbs, endAbs: e.endAbs),
    ];
    if (!apply) return base; // clean 關 → 全收(漏拍仍由 ⑤/search-back 把關,不影響)
    if (base.length < 4) return base;
    // rank6:MAD 穩健離群(取代固定 ±30%)。門檻隨資料自身離散度縮放 →
    //   高 HRV 的寬尾巴不會被誤剔(±30% 會),仍砍得掉真離群。
    //   剔除條件:|rr − 中位數| > thresh,
    //   thresh = max(madK × 1.4826 × MAD, minRelThresh × 中位數)。
    //   下限那項不可省:RR 有 10ms 量化,安靜時 MAD 只有 1~2 格,純 MAD 門檻會
    //   塌到 ±25ms,把正常心率漂移(收 30s 時 RR 從 780 爬到 900)整段砍掉。
    final rrs = [for (final e in base) e.rr];
    final med = _median(rrs);
    if (med <= 0) return base;
    final mad = _median([for (final v in rrs) (v - med).abs()]);
    if (mad <= 0) return base; // 資料幾乎全等 → 不剔(避免除不出門檻而全砍)
    final thresh = math.max(madK * madScale * mad, minRelThresh * med);
    return [
      for (final e in base)
        if ((e.rr - med).abs() <= thresh) e,
    ];
  }

  /// clean() 的「互補集合」= 顯示時被 MAD 剔掉的離群拍(透明化用)。
  /// 與 clean() 同一組門檻;不足以計算門檻(拍數<4 / med/mad=0)時視為「沒剔任何拍」。
  static List<HrvRrPoint> cleanRejects(
    List<HrvRrSample> history, {
    required bool includeRecovered,
    bool apply = true, // false → clean 關閉 → 沒有任何拍被剔(紅點消失)
  }) {
    if (!apply) return const [];
    final base = <HrvRrPoint>[
      for (final e in history)
        if (includeRecovered || !e.recovered)
          (rr: e.rr, startAbs: e.startAbs, endAbs: e.endAbs),
    ];
    if (base.length < 4) return const [];
    final rrs = [for (final e in base) e.rr];
    final med = _median(rrs);
    if (med <= 0) return const [];
    final mad = _median([for (final v in rrs) (v - med).abs()]);
    if (mad <= 0) return const [];
    final thresh = math.max(madK * madScale * mad, minRelThresh * med);
    return [
      for (final e in base)
        if ((e.rr - med).abs() > thresh) e,
    ];
  }

  /// H1：偵測「疑似異位拍(早搏)」—— **純標記,不從池移除**(A 階段,不動任何 HRV 數字)。
  ///
  /// 簽章(四拍皆須時間相鄰,同一段連續節律):
  ///   前拍正常 → 這拍**大幅變短**(進早搏) → 下拍**大幅變長**(反向代償) → 再下拍**回歸基線**。
  /// 「大幅」用近 window 拍的逐拍差自適應門檻 median|ΔRR|+K·MAD(非固定%),
  /// 所以高 HRV 者不誤標(門檻自動放寬)、心跳加速(持續變短不回頭)不觸發。
  ///
  /// 回傳「判定為早搏那顆(短拍,其 endAbs = 早搏谷 E)」的清單,供 UI 標紫點/計數。
  /// 找不到或拍數不足(< window)→ 回空。
  static List<HrvRrPoint> ectopics(
    List<HrvRrSample> history, {
    double k = ectopicK,
    int window = ectopicWindow,
    double returnTol = ectopicReturnTol,
    bool includeRecovered = false,
  }) {
    final pts = <HrvRrPoint>[
      for (final e in history)
        if (includeRecovered || !e.recovered)
          (rr: e.rr, startAbs: e.startAbs, endAbs: e.endAbs),
    ];
    final out = <HrvRrPoint>[];
    if (pts.length < window) return out; // 資料太少 → 不啟動(避免亂判)

    // 對每個候選短拍 i,取 i-1..i+2 四拍檢查簽章。
    for (int i = 1; i < pts.length - 2; i++) {
      // 四拍必須時間相鄰(中間沒有被剔的洞)→ 才是同一段連續節律
      if (pts[i].startAbs != pts[i - 1].endAbs) continue;
      if (pts[i + 1].startAbs != pts[i].endAbs) continue;
      if (pts[i + 2].startAbs != pts[i + 1].endAbs) continue;

      // 以 i 為中心取近 window 拍 → 局部中位數 M(抗離群,不被這顆早搏拉歪)
      final lo = math.max(0, i - window ~/ 2);
      final hi = math.min(pts.length, lo + window);
      final m = _median([for (int j = lo; j < hi; j++) pts[j].rr]);
      if (m <= 0) continue;

      // 自適應門檻:近 window 拍「時間相鄰」逐拍差的 median + k×MAD
      final dabs = <double>[
        for (int j = lo + 1; j < hi; j++)
          if (pts[j].startAbs == pts[j - 1].endAbs)
            (pts[j].rr - pts[j - 1].rr).abs(),
      ];
      if (dabs.length < 3) continue; // 逐拍差樣本太少 → 門檻不穩,跳過
      final dmed = _median(dabs);
      final dmad = _median([for (final x in dabs) (x - dmed).abs()]);
      final thr = dmed + k * dmad;

      final d1 = pts[i].rr - pts[i - 1].rr; // 進早搏:應大幅變短(負)
      final d2 = pts[i + 1].rr - pts[i].rr; // 出早搏:應大幅變長(正,反向代償)
      final shortDrop = d1 < -thr; // 這拍突然變短超過門檻
      final compRise = d2 > thr; // 下拍突然變長超過門檻(反向)
      final preNormal =
          (pts[i - 1].rr - m).abs() <= returnTol * m; // 前拍在基線
      final ret = (pts[i + 2].rr - m).abs() <= returnTol * m; // 再下拍回歸基線
      if (shortDrop && compRise && preNormal && ret) {
        out.add(pts[i]); // 早搏那顆(短拍;endAbs 即早搏谷)
      }
    }
    return out;
  }

  /// 中位數(複製後排序,不動輸入;偶數取上中,與原 clean 慣例一致)。
  static double _median(List<double> xs) {
    if (xs.isEmpty) return 0;
    final s = List<double>.from(xs)..sort();
    return s[s.length ~/ 2];
  }

  /// 便利包裝：clean 後直接算 HRV。回傳 null 表示拍數不足。
  static HrvStats? stats(
    List<HrvRrSample> history, {
    required bool includeRecovered,
    bool apply = true, // clean 開關(false=不做 MAD 離群濾)
  }) => hrvFrom(
    clean(history, includeRecovered: includeRecovered, apply: apply),
  );

  /// 由一份乾淨 RR(含起/終谷) 算 HRV。
  /// SDNN／平均：與順序/連續性無關,照全體算。
  /// RMSSD：只累加「時間相鄰」的相鄰對,分母=連續對數。
  static HrvStats? hrvFrom(List<HrvRrPoint> pts) {
    // 暖機:湊滿 minBeatsForHrv 拍(拍 = 間距 pts.length + 1)才開始算 HRV;
    // 不足 → 回 null(不計算),讓數值建立在足夠樣本上。
    if (pts.length + 1 < minBeatsForHrv) return null;
    final mean =
        [for (final e in pts) e.rr].reduce((a, b) => a + b) / pts.length;
    double varSum = 0;
    for (final e in pts) {
      varSum += (e.rr - mean) * (e.rr - mean);
    }
    final sdnn = math.sqrt(varSum / (pts.length - 1)); // 樣本標準差(N−1 自由度)
    double sucSq = 0;
    int pairs = 0;
    int nn50 = 0; // 相鄰對中 |差|>50ms 的數(pNN50 用;絕對 50ms,非相對)
    for (int i = 1; i < pts.length; i++) {
      if (pts[i].startAbs != pts[i - 1].endAbs) continue; // 不連續 → 略過
      final df = pts[i].rr - pts[i - 1].rr;
      sucSq += df * df;
      pairs++;
      if (df.abs() > 50) nn50++; // pNN50(放鬆/迷走指標,絕對50ms)
    }
    final rmssd = pairs > 0 ? math.sqrt(sucSq / pairs) : 0.0;
    final pnn50 = pairs > 0 ? nn50 / pairs * 100 : 0.0;
    // ln(RMSSD)×20 → 0~100 分。RMSSD 對數常態、取 ln 才穩;僅供「跟自己比」。
    final hrvScore = rmssd > 0 ? (math.log(rmssd) * 20).clamp(0.0, 100.0) : 0.0;
    final sd1 = math.sqrt(0.5) * rmssd;
    final sd2v = 2 * sdnn * sdnn - sd1 * sd1;
    final sd2 = sd2v > 0 ? math.sqrt(sd2v) : 0.0;

    // ★「可信度守門(圓團 SD1≥SD2 / 逐拍亂跳)」整段已移除:HRV 數字/形狀不反映品質,
    //   品質看波形乾不乾淨。Poincaré「紅=大跳」散點仍用 bigJumpRel 常數自行標(見 hrv_chart)。

    return (
      meanRr: mean,
      sdnn: sdnn,
      rmssd: rmssd,
      sd1: sd1,
      sd2: sd2,
      meanHr: mean > 0 ? 60000 / mean : 0,
      beats: pts.length + 1,
      pairs: pairs, // RMSSD 實際用到的「連續相鄰對」數
      totalPairs: pts.length - 1, // 全部相鄰對(含被跳過的跨洞對)
      pnn50: pnn50,
      hrvScore: hrvScore,
    );
  }
}
