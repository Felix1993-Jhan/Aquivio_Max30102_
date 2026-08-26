// ============================================================================
// Max30102HrvCalculator — HRV 純計算（無狀態，可單元測試）
// ============================================================================
// 【由 Dart 版 k2_hrv_calculator.dart 轉譯,行為完全一致】
//
// 只負責「給一份累積好的 RR → 算出 HRV」:
//   clean()   全體中位數 ±(MAD 穩健) 再濾一次
//   hrvFrom() SDNN / RMSSD / SD1 / SD2 / meanHr / pnn50 / hrvScore / 有效對數
//   stats()   = hrvFrom(clean(...)) 的方便包裝
//
// 資料型別(純物件):
//   HrvRrSample = { rr, startAbs, endAbs, recovered }  一筆累積的 RR
//   HrvRrPoint  = { rr, startAbs, endAbs }             乾淨 RR(判連續/繪圖用)
//   HrvStats    = { meanRr, sdnn, rmssd, sd1, sd2, meanHr, beats,
//                   pairs, totalPairs, pnn50, hrvScore }
//
// RMSSD 關鍵:只累加「時間相鄰(前一筆終谷 == 這筆起谷)」的相鄰對,跨洞對不計入。
// SD1 = RMSSD/√2；SD2 = √(2·SDNN²−SD1²)。
// ============================================================================

class Max30102HrvCalculator {
  // bigJumpRel:相鄰兩拍差 > 此比例×平均 = 一次「大跳」。僅供 Poincaré 圖散點上色用。
  static bigJumpRel = 0.25;
  // 暖機:乾淨拍 < 此數 → HRV 樣本太少不穩。
  static minBeatsForHrv = 9;
  // clean() 的穩健離群倍率 —— 剔除條件 |rr − 中位數| > thresh。
  static madK = 2.5;
  // MAD → 標準差的一致性換算(常態下 σ ≈ 1.4826 × MAD)。
  static madScale = 1.4826;
  // 門檻下限 = 中位數 × 此比例(只擋真漏拍/切拍,不砍真拍的中等擺動)。
  static minRelThresh = 0.5;

  // ── H1:疑似異位拍(早搏)偵測參數 ──
  static ectopicK = 4.0; // |ΔRR| 門檻倍率:median + K×MAD
  static ectopicWindow = 10; // 自適應統計窗(近 N 拍);乾淨拍 < N → 不啟動
  static ectopicReturnTol = 0.20; // 回歸容差:前/後拍需回到 中位 ±20% 內

  /// 用全體中位數 ± MAD 穩健門檻再濾一次（排開頭尖刺）。
  /// includeRecovered=false → 排除補漏拍補回的拍。
  /// apply=false → 不做 MAD 離群濾(clean 開關關閉時);RR 全收。
  /// 回傳 HrvRrPoint[]。
  static clean(history, { includeRecovered, apply = true }) {
    const base = [];
    for (const e of history) {
      if (includeRecovered || !e.recovered) {
        base.push({ rr: e.rr, startAbs: e.startAbs, endAbs: e.endAbs });
      }
    }
    if (!apply) return base; // clean 關 → 全收
    if (base.length < 4) return base;
    const rrs = base.map((e) => e.rr);
    const med = Max30102HrvCalculator._median(rrs);
    if (med <= 0) return base;
    const mad = Max30102HrvCalculator._median(rrs.map((v) => Math.abs(v - med)));
    if (mad <= 0) return base; // 資料幾乎全等 → 不剔
    const thresh = Math.max(
      Max30102HrvCalculator.madK * Max30102HrvCalculator.madScale * mad,
      Max30102HrvCalculator.minRelThresh * med,
    );
    return base.filter((e) => Math.abs(e.rr - med) <= thresh);
  }

  /// clean() 的「互補集合」= 顯示時被 MAD 剔掉的離群拍(透明化用)。
  static cleanRejects(history, { includeRecovered, apply = true }) {
    if (!apply) return [];
    const base = [];
    for (const e of history) {
      if (includeRecovered || !e.recovered) {
        base.push({ rr: e.rr, startAbs: e.startAbs, endAbs: e.endAbs });
      }
    }
    if (base.length < 4) return [];
    const rrs = base.map((e) => e.rr);
    const med = Max30102HrvCalculator._median(rrs);
    if (med <= 0) return [];
    const mad = Max30102HrvCalculator._median(rrs.map((v) => Math.abs(v - med)));
    if (mad <= 0) return [];
    const thresh = Math.max(
      Max30102HrvCalculator.madK * Max30102HrvCalculator.madScale * mad,
      Max30102HrvCalculator.minRelThresh * med,
    );
    return base.filter((e) => Math.abs(e.rr - med) > thresh);
  }

  /// H1:偵測「疑似異位拍(早搏)」—— **純標記,不從池移除**(不動任何 HRV 數字)。
  /// 簽章:前拍正常 → 這拍大幅變短 → 下拍大幅變長(反向代償) → 再下拍回歸基線。
  /// 回傳判定為早搏那顆(短拍)的 HrvRrPoint[];找不到或拍數不足(< window)→ 回空。
  static ectopics(history, {
    k = Max30102HrvCalculator.ectopicK,
    window = Max30102HrvCalculator.ectopicWindow,
    returnTol = Max30102HrvCalculator.ectopicReturnTol,
    includeRecovered = false,
  } = {}) {
    const pts = [];
    for (const e of history) {
      if (includeRecovered || !e.recovered) {
        pts.push({ rr: e.rr, startAbs: e.startAbs, endAbs: e.endAbs });
      }
    }
    const out = [];
    if (pts.length < window) return out; // 資料太少 → 不啟動

    for (let i = 1; i < pts.length - 2; i++) {
      // 四拍必須時間相鄰(中間沒有被剔的洞)
      if (pts[i].startAbs !== pts[i - 1].endAbs) continue;
      if (pts[i + 1].startAbs !== pts[i].endAbs) continue;
      if (pts[i + 2].startAbs !== pts[i + 1].endAbs) continue;

      // 以 i 為中心取近 window 拍 → 局部中位數 M
      const lo = Math.max(0, i - Math.trunc(window / 2));
      const hi = Math.min(pts.length, lo + window);
      const mArr = [];
      for (let j = lo; j < hi; j++) mArr.push(pts[j].rr);
      const m = Max30102HrvCalculator._median(mArr);
      if (m <= 0) continue;

      // 自適應門檻:近 window 拍「時間相鄰」逐拍差的 median + k×MAD
      const dabs = [];
      for (let j = lo + 1; j < hi; j++) {
        if (pts[j].startAbs === pts[j - 1].endAbs) {
          dabs.push(Math.abs(pts[j].rr - pts[j - 1].rr));
        }
      }
      if (dabs.length < 3) continue; // 逐拍差樣本太少 → 跳過
      const dmed = Max30102HrvCalculator._median(dabs);
      const dmad = Max30102HrvCalculator._median(dabs.map((x) => Math.abs(x - dmed)));
      const thr = dmed + k * dmad;

      const d1 = pts[i].rr - pts[i - 1].rr; // 進早搏:應大幅變短(負)
      const d2 = pts[i + 1].rr - pts[i].rr; // 出早搏:應大幅變長(正)
      const shortDrop = d1 < -thr;
      const compRise = d2 > thr;
      const preNormal = Math.abs(pts[i - 1].rr - m) <= returnTol * m;
      const ret = Math.abs(pts[i + 2].rr - m) <= returnTol * m;
      if (shortDrop && compRise && preNormal && ret) {
        out.push(pts[i]); // 早搏那顆(短拍;endAbs 即早搏谷)
      }
    }
    return out;
  }

  /// 中位數(複製後排序,不動輸入;偶數取上中,與原 clean 慣例一致)。
  static _median(xs) {
    if (xs.length === 0) return 0;
    const s = [...xs].sort((a, b) => a - b);
    return s[Math.trunc(s.length / 2)];
  }

  /// 便利包裝:clean 後直接算 HRV。回傳 null 表示拍數不足。
  static stats(history, { includeRecovered, apply = true }) {
    return Max30102HrvCalculator.hrvFrom(
      Max30102HrvCalculator.clean(history, { includeRecovered, apply }),
    );
  }

  /// 由一份乾淨 RR(含起/終谷) 算 HRV。回傳 HrvStats 或 null(拍數不足)。
  /// SDNN／平均:與順序/連續性無關,照全體算。
  /// RMSSD:只累加「時間相鄰」的相鄰對,分母=連續對數。
  static hrvFrom(pts) {
    // 暖機:湊滿 minBeatsForHrv 拍(拍 = 間距 pts.length + 1)才開始算。
    if (pts.length + 1 < Max30102HrvCalculator.minBeatsForHrv) return null;
    const mean = pts.reduce((a, e) => a + e.rr, 0) / pts.length;
    let varSum = 0;
    for (const e of pts) varSum += (e.rr - mean) * (e.rr - mean);
    const sdnn = Math.sqrt(varSum / (pts.length - 1)); // 樣本標準差(N−1)
    let sucSq = 0;
    let pairs = 0;
    let nn50 = 0;
    for (let i = 1; i < pts.length; i++) {
      if (pts[i].startAbs !== pts[i - 1].endAbs) continue; // 不連續 → 略過
      const df = pts[i].rr - pts[i - 1].rr;
      sucSq += df * df;
      pairs++;
      if (Math.abs(df) > 50) nn50++; // pNN50(絕對 50ms)
    }
    const rmssd = pairs > 0 ? Math.sqrt(sucSq / pairs) : 0.0;
    const pnn50 = pairs > 0 ? (nn50 / pairs) * 100 : 0.0;
    // ln(RMSSD)×20 → 0~100 分。僅供「跟自己比」。
    const hrvScore = rmssd > 0
      ? Math.min(Math.max(Math.log(rmssd) * 20, 0.0), 100.0)
      : 0.0;
    const sd1 = Math.sqrt(0.5) * rmssd;
    const sd2v = 2 * sdnn * sdnn - sd1 * sd1;
    const sd2 = sd2v > 0 ? Math.sqrt(sd2v) : 0.0;

    return {
      meanRr: mean,
      sdnn,
      rmssd,
      sd1,
      sd2,
      meanHr: mean > 0 ? 60000 / mean : 0,
      beats: pts.length + 1,
      pairs, // RMSSD 實際用到的「連續相鄰對」數
      totalPairs: pts.length - 1, // 全部相鄰對(含被跳過的跨洞對)
      pnn50,
      hrvScore,
    };
  }
}

module.exports = { Max30102HrvCalculator };
