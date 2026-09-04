// ============================================================================
// Max30102VitalsMetrics — 軟體端(Strapi / Koa)要的衍生指標
// ============================================================================
// ⚠️ **這一檔不屬於原本的 K2 交接核心。**
//    交接核心吐的是 bpm / spo2 / SDNN / RMSSD / SD1 / SD2 / pNN50 這些「一手量」。
//    但整合方(aquivio-strapi 的 deepseek.ts、aquivio-station 的 useVitalScans.ts)
//    的介面要的是另一組名字與另一組指標:
//
//      mean_hr  sdnn  rmssd  ln_rmssd  lf_hf  sqi  snr_db
//      confidence  pns  ans  stress
//
//    本檔就是那道「翻譯 + 補算」層。每個欄位都標了它在對方介面裡的名字。
//
// ── 為什麼放在核心層而不是 ui/ ────────────────────────────────────
//   bin/max30102_server.dart 的鐵則是「只能 import 純 Dart + 核心(扣掉 ui/)」。
//   這些指標之後很可能要從 /vitals 導出,放 ui/ 就得搬家。所以放這裡,
//   並且**不 import 任何 package:flutter**。
//
// ── 這一檔全部是純函式 / 不可變資料 ───────────────────────────────
//   沒有狀態、沒有 Timer、沒有 I/O。2 分鐘的 RR 累積是有狀態的事,
//   做在 ui/k2_lf_experiment.dart,不在這裡。
//
// ── 誠實聲明(很重要,不要拿掉)────────────────────────────────────
//   · LF/HF 需要**至少 2 分鐘、標準是 5 分鐘**的記錄。30 秒窗算出來的 LF
//     只涵蓋 0.04Hz 的 1.2 個週期 —— [HrvSpectrum.lfCycles] 會誠實回報這件事,
//     [HrvSpectrum.lfUsable] 在不足時回 false。**呈現層有義務把它擋掉或標記。**
//   · [pns] / [sns] / [ansTimeDomain] 的常模常數是文獻上健康成年人的近似值,
//     不是 Kubios 的資料庫。方向可信,絕對值**不會**跟 Kubios 對得上。
//   · [ansTimeDomain] 與對方介面的 `ans`(源自 LF/HF)**定義不同**,
//     兩台裝置的數字不可互相比較。要用必須先跟整合方講清楚。
// ============================================================================

import 'dart:math' as math;

import 'k2_config.dart';
import 'k2_hrv_calculator.dart';

// ════════════════════════════════════════════════════════════════════
// 一、Lomb-Scargle 週期圖 —— RR 序列的頻譜
// ════════════════════════════════════════════════════════════════════

/// 頻域分析的結果(單位:功率為 ms²)。
class HrvSpectrum {
  /// 極低頻 0.003~0.04 Hz。30 秒窗完全測不到,只是把它算出來讓總功率合得起來。
  final double vlf;

  /// 低頻 0.04~0.15 Hz。壓力反射(Mayer wave)為主,交感副交感混合。
  final double lf;

  /// 高頻 0.15~0.4 Hz。呼吸性竇性心律不整(RSA),迷走神經主導。
  final double hf;

  /// 三個頻帶的總和。歸一化之後它會非常接近 SDNN²(Parseval)。
  final double totalPower;

  /// 正規化單位:lf / (lf + hf) × 100。去掉 VLF 之後的相對占比。
  final double lfNu;
  final double hfNu;

  /// 對方介面的 `lf_hf`。
  final double lfHf;

  // ── 以下是「這個數字可不可信」的證據,不是生理量 ──────────────────

  /// 這段記錄實際涵蓋幾秒(末拍終谷 − 首拍起谷)。
  final double spanSeconds;

  /// 在 LF 的低頻邊緣(0.04 Hz)觀測到幾個完整週期。
  /// 30 秒 → 1.2;2 分鐘 → 4.8;5 分鐘 → 12。
  final double lfCycles;

  /// 整條 LF 頻帶跨越幾個頻率解析格(Δf = 1/T)。
  /// 30 秒 → 3.3 格;2 分鐘 → 13.2 格。
  final double lfBins;

  /// 參與計算的拍數。
  final int beats;

  const HrvSpectrum({
    required this.vlf,
    required this.lf,
    required this.hf,
    required this.totalPower,
    required this.lfNu,
    required this.hfNu,
    required this.lfHf,
    required this.spanSeconds,
    required this.lfCycles,
    required this.lfBins,
    required this.beats,
  });

  // ── 可用性門檻 ────────────────────────────────────────────────────
  //
  // ⚠️ **門檻由「需要多久」決定,不可以拿手上的資料去反推。**
  //    早期版本曾把 HF 門檻訂在 25 秒,那是為了讓我們自己的 30 秒視窗通過
  //    而調的 —— 方向完全相反,等於先射箭再畫靶。現在改成單一規則,
  //    兩個頻帶各自從自己的下緣頻率導出,沒有可以手動調的空間。

  /// 一個頻帶要估得準,至少要在它**最低的那個頻率**上看到幾個完整週期。
  ///
  /// 取 4:低於這個數,週期圖在該頻帶只剩兩三個獨立的自由度,估計值的
  /// 變異數會跟估計值本身同一個量級(見 [lfCycles] 的實測)。
  /// 這是工程判斷,不是學術標準 —— 但它是**從頻率導出的**,不是湊出來的。
  static const double minBandCycles = 4.0;

  /// **LF 這個數字能不能用。** 下緣 0.04Hz(週期 25 秒)→ 需要 **100 秒**。
  ///
  /// 國際標準(Task Force 1996)要求的是 **300 秒**,所以 true 只代表
  /// 「勉強站得住」,不代表符合標準。
  /// 30 秒窗只有 1.2 圈,一定是 false —— 那正是這個旗標存在的理由。
  bool get lfUsable => spanSeconds * HrvBands.lfLow >= minBandCycles;

  /// **HF 這個數字能不能用。** 下緣 0.15Hz(週期 6.7 秒)→ 需要 **26.7 秒**。
  ///
  /// 產品的 30 秒視窗實際跨度約 27~29 秒,所以**剛好在線上** ——
  /// 偶爾會落到 false,那不是 bug,是它真的處在邊緣。要精確判斷請看
  /// 連續值 [hfCycles],不要只看這個布林。
  bool get hfUsable => spanSeconds * HrvBands.hfLow >= minBandCycles;

  /// HF 下緣(0.15Hz)在這段窗裡走了幾個完整週期。與 [lfCycles] 對照用。
  double get hfCycles => spanSeconds * HrvBands.hfLow;

  // ── 整合方(aquivio-vitals)的單位換算 ──────────────────────────────
  //
  // 他們的 hrv.py freq_domain():
  //     rr(秒) → CubicSpline 內插到 4Hz → welch(fs=4, nfft=4096)
  //     lf = pxx[(f>=0.04)&(f<0.15)].sum()      ← **直接加總 bin,沒乘 df**
  //
  // 所以他們的數字 = 頻帶功率(s²) ÷ df,而我們是頻帶功率(ms²):
  //     df    = fs / nfft = 4 / 4096 = 0.0009766 Hz
  //     他們  = 我們(ms²) ÷ 1e6 × (1/df) = 我們 × 1.024e-3
  //
  // ⚠️ 這是**單位與正規化慣例的換算**,不是重寫 Welch。兩個估計器
  //    (Welch vs Lomb-Scargle)對同一段訊號的估計本來就會有差,
  //    這裡只保證數量級與語意一致。[lfHf] 是比值,縮放約分掉,不受影響。
  static const double _aquivioScale = 1024.0 / 1e6;

  /// LF 功率,換算成整合方 `lf` 欄位的單位。原始 ms² 值請看 [lf]。
  double get lfAquivio => lf * _aquivioScale;

  /// HF 功率,換算成整合方 `hf` 欄位的單位。原始 ms² 值請看 [hf]。
  double get hfAquivio => hf * _aquivioScale;
}

/// 頻帶邊界(Task Force 1996 標準)。
class HrvBands {
  static const double vlfLow = 0.003;
  static const double vlfHigh = 0.04;
  static const double lfLow = 0.04;
  static const double lfHigh = 0.15;
  static const double hfLow = 0.15;
  static const double hfHigh = 0.40;

  /// 頻率掃描的格距(Hz)。**固定值** —— 兩種窗長要用同一個格點才能公平比較,
  /// 不能各自用 1/T 去決定(那樣長窗天生格子多,比的就不只是窗長了)。
  static const double df = 0.002;
}

class Max30102VitalsMetrics {
  // ──────────────────────────────────────────────────────────────
  // Lomb-Scargle
  // ──────────────────────────────────────────────────────────────

  /// 對**不等間隔**的 RR 序列做頻譜分析。
  ///
  /// 為什麼不用 FFT:RR 序列本來就不等間隔(每一拍的時間戳由心跳決定),
  /// 而且 SQI 差 / 誤拍過濾會在序列上留下**洞**。FFT 兩個前提都不成立。
  /// Lomb-Scargle 是為這種資料設計的 —— 它直接對每個頻率做最小平方擬合,
  /// 不需要重取樣、不需要內插,洞多洞少都能算(只是洞越多估計越差)。
  ///
  /// [pts] 要帶絕對位置(startAbs / endAbs),時間軸由它們換算而來。
  /// 拍數 < 8 回 null —— 再少擬合沒有意義。
  static HrvSpectrum? spectrum(List<HrvRrPoint> pts) {
    if (pts.length < 8) return null;
    const fs = Max30102Config.samplingRateHz;

    // 時間軸:每一筆 RR 掛在它「終谷」發生的時刻上(秒)。
    // 以第一筆為原點 → 數值小,三角函數的精度比較好。
    final t0 = pts.first.endAbs / fs;
    final t = <double>[for (final p in pts) p.endAbs / fs - t0];
    final x = <double>[for (final p in pts) p.rr];
    final n = x.length;

    final span = (pts.last.endAbs - pts.first.startAbs) / fs;
    if (span <= 0) return null;

    // 去均值(Lomb-Scargle 的前提)
    final mean = x.reduce((a, b) => a + b) / n;
    final dx = <double>[for (final v in x) v - mean];

    // 變異數用 N−1,與 Max30102HrvCalculator 的 sdnn 同一個定義 →
    // 歸一化之後 totalPower 才會真的對得上 SDNN²。
    double varSum = 0;
    for (final v in dx) {
      varSum += v * v;
    }
    final variance = varSum / (n - 1);
    if (variance <= 0) return null;

    // 掃描格點:從 VLF 下緣到 HF 上緣
    final freqs = <double>[];
    for (double f = HrvBands.vlfLow; f <= HrvBands.hfHigh; f += HrvBands.df) {
      freqs.add(f);
    }

    final power = <double>[];
    for (final f in freqs) {
      power.add(_lombAt(t, dx, 2 * math.pi * f));
    }

    // ── 歸一化:讓 Σ(P·Δf) = 變異數 ────────────────────────────────
    // 這樣 VLF+LF+HF ≈ SDNN²,數字可以拿去跟畫面上的 SDNN 對帳。
    // 也讓不同窗長的功率值落在同一個尺度上(否則長窗的絕對值天生比較大,
    // 比出來的差異一半是尺度造成的)。
    double rawIntegral = 0;
    for (final p in power) {
      rawIntegral += p * HrvBands.df;
    }
    if (rawIntegral <= 0) return null;
    final k = variance / rawIntegral;

    double band(double lo, double hi) {
      double s = 0;
      for (int i = 0; i < freqs.length; i++) {
        if (freqs[i] >= lo && freqs[i] < hi) s += power[i] * HrvBands.df;
      }
      return s * k;
    }

    final vlf = band(HrvBands.vlfLow, HrvBands.vlfHigh);
    final lf = band(HrvBands.lfLow, HrvBands.lfHigh);
    final hf = band(HrvBands.hfLow, HrvBands.hfHigh);
    final total = vlf + lf + hf;
    final lfHfDenom = lf + hf;

    return HrvSpectrum(
      vlf: vlf,
      lf: lf,
      hf: hf,
      totalPower: total,
      lfNu: lfHfDenom > 0 ? lf / lfHfDenom * 100 : 0,
      hfNu: lfHfDenom > 0 ? hf / lfHfDenom * 100 : 0,
      lfHf: hf > 0 ? lf / hf : 0,
      spanSeconds: span,
      lfCycles: span * HrvBands.lfLow,
      lfBins: (HrvBands.lfHigh - HrvBands.lfLow) * span,
      beats: n,
    );
  }

  /// 單一角頻率 [w] 上的 Lomb-Scargle 功率。
  ///
  /// 先解出時間位移 τ 讓 cos/sin 兩項正交,再各自做最小平方擬合:
  ///   τ  : tan(2ωτ) = Σsin(2ωt) / Σcos(2ωt)
  ///   P  = ½ · [ A²/C + B²/D ]
  /// 其中 A/B 是投影量、C/D 是各自的基底能量。
  static double _lombAt(List<double> t, List<double> dx, double w) {
    if (w <= 0) return 0;
    double s2 = 0, c2 = 0;
    for (final ti in t) {
      s2 += math.sin(2 * w * ti);
      c2 += math.cos(2 * w * ti);
    }
    final tau = math.atan2(s2, c2) / (2 * w);

    double a = 0, b = 0, c = 0, d = 0;
    for (int i = 0; i < t.length; i++) {
      final arg = w * (t[i] - tau);
      final co = math.cos(arg);
      final si = math.sin(arg);
      a += dx[i] * co;
      b += dx[i] * si;
      c += co * co;
      d += si * si;
    }
    // C 或 D 塌到 0 表示這個頻率上基底退化(取樣點剛好都落在節點上)→ 不計。
    final left = c > 1e-12 ? a * a / c : 0.0;
    final right = d > 1e-12 ? b * b / d : 0.0;
    return 0.5 * (left + right);
  }

  // ──────────────────────────────────────────────────────────────
  // 二、Baevsky 壓力指數 —— 對方介面的 `stress`
  // ──────────────────────────────────────────────────────────────

  /// Baevsky 壓力指數(Stress Index,SI)。**純時域**,不需要頻譜,
  /// 所以它是 30 秒窗下少數還算得出來的「交感側」指標。
  ///
  /// 把 RR 做成直方圖(50ms 一格),取三個量:
  ///   Mo     眾數 —— 最多拍落在哪一格(秒)
  ///   AMo    眾數振幅 —— 那一格佔全體的百分比
  ///   MxDMn  變異全距 —— 最大 RR − 最小 RR(秒)
  ///
  ///   SI = AMo / (2 × Mo × MxDMn)
  ///
  /// 直覺:心跳被壓得又快又規律 → 直方圖又高又窄 → AMo 大、MxDMn 小 → SI 衝高。
  ///
  /// ⚠️ **30 秒下這個數字很薄。** 不是普通的「樣本少所以有雜訊」,而是 SI 剛好由
  ///    兩個對小樣本最敏感的統計量組成:AMo 是「最高那格佔多少」(35 個樣本分到
  ///    8~10 格,哪格最高幾乎隨機),MxDMn 是全距(只由兩個極端值決定,多收一拍
  ///    就可能整個變)。要跟 5 分鐘的值比較時務必記得這件事。
  ///
  /// 回傳 Kubios 慣例的 **√SI**(取平方根讓分布接近常態);null = 算不出來。
  static double? stressIndex(List<double> rr) {
    if (rr.length < 5) return null;
    const binMs = 50.0;

    double lo = rr.first, hi = rr.first;
    for (final v in rr) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    final mxdmn = (hi - lo) / 1000.0; // 秒
    if (mxdmn <= 0) return null; // 所有 RR 完全相同 → 分母為 0

    // 直方圖:以 0 為原點切格,格號 = (rr / binMs).floor()
    final counts = <int, int>{};
    for (final v in rr) {
      final b = (v / binMs).floor();
      counts[b] = (counts[b] ?? 0) + 1;
    }
    int modalBin = counts.keys.first;
    int modalCount = 0;
    counts.forEach((b, c) {
      if (c > modalCount) {
        modalCount = c;
        modalBin = b;
      }
    });

    final mo = (modalBin + 0.5) * binMs / 1000.0; // 該格中心(秒)
    final amo = modalCount / rr.length * 100.0; // 百分比
    if (mo <= 0) return null;

    final si = amo / (2 * mo * mxdmn);
    return si > 0 ? math.sqrt(si) : null;
  }

  // ──────────────────────────────────────────────────────────────
  // 三、PNS / SNS 指數 —— 對方介面的 `pns` 與 `ans`
  // ──────────────────────────────────────────────────────────────

  // ⚠️ 以下常模常數是**文獻上健康成年人的近似值**,不是 Kubios 的資料庫。
  //    Kubios 的 PNS/SNS index 是拿他們自己的常模做 z-score,我們沒有那份資料,
  //    所以算出來的數字**方向可信、絕對值不會跟 Kubios 對齊**。
  //    要對齊只有兩條路:拿到那份常模,或自己收一批人建立基準。
  static const double _normMeanRr = 926.0, _sdMeanRr = 90.0; // ms
  static const double _normRmssd = 42.0, _sdRmssd = 15.0; // ms
  static const double _normSd1 = 29.7, _sdSd1 = 11.0; // ms(=RMSSD/√2)
  static const double _normMeanHr = 64.8, _sdMeanHr = 6.5; // bpm
  static const double _normSi = 10.0, _sdSi = 3.0; // √SI
  static const double _normSd2 = 100.0, _sdSd2 = 30.0; // ms

  static double _z(double v, double mean, double sd) => (v - mean) / sd;

  /// **副交感神經活性指數**(Kubios 風格的 PNS index)→ 對方介面的 `pns`。
  ///
  /// 三個成分的 z-score 平均:平均 RR、RMSSD、SD1。
  /// 越大代表越偏「休息與消化」(放鬆、恢復)。
  ///
  /// ⚠️ SD1 = RMSSD/√2 是**恆等式**(見 k2_hrv_calculator),所以這三項其實只有
  ///    兩份獨立資訊,SD1 那一項等於把 RMSSD 加權兩次。這是 Kubios 自己的定義,
  ///    照做即可,但別誤以為它是三個獨立證據。
  static double pns(HrvStats hv) => (_z(hv.meanRr, _normMeanRr, _sdMeanRr) +
          _z(hv.rmssd, _normRmssd, _sdRmssd) +
          _z(hv.sd1, _normSd1, _sdSd1)) /
      3;

  /// **交感神經活性指數**(Kubios 風格的 SNS index)。**全時域**,不碰 LF。
  ///
  /// 三個成分:平均心率、壓力指數(√SI)、SD2(取負號 —— SD2 越小越偏交感)。
  /// [si] 為 null(算不出壓力指數)時只用另外兩項。
  static double sns(HrvStats hv, double? si) {
    final zHr = _z(hv.meanHr, _normMeanHr, _sdMeanHr);
    final zSd2 = -_z(hv.sd2, _normSd2, _sdSd2);
    if (si == null) return (zHr + zSd2) / 2;
    return (zHr + _z(si, _normSi, _sdSi) + zSd2) / 3;
  }

  /// **自律神經平衡的時域替代值** → 可放進對方介面的 `ans`,但**定義不同**。
  ///
  /// = SNS − PNS。正值偏交感(緊張),負值偏副交感(放鬆)。
  ///
  /// ⚠️ 對方的 `ans` 源自 LF/HF(頻域)。這一版走的是完全不同的路徑,
  ///    **數值不可與攝影機那邊的 ans 互相比較或存進同一張表**。
  ///    它的價值在於:30 秒就算得出來,而 LF/HF 不行。
  static double ansTimeDomain(HrvStats hv, double? si) => sns(hv, si) - pns(hv);

  // ══════════════════════════════════════════════════════════════════
  // 三之二、整合方(aquivio-vitals)的 0~100 分數
  // ══════════════════════════════════════════════════════════════════
  //
  // 以下四個公式**逐字對應** aquivio-vitals 的 `core.py::derived_scores()`。
  // 我們原本用的是 Kubios 式的 z-score(見上面的 [pns] / [sns]),那在
  // 統計上比較講究,但**整合方的 prompt 是照他們這套校準的** ——
  // deepseek.ts 把這幾個欄位印成 `X/100`,而且判斷門檻(`LF/HF > 1.5`、
  // `high stress`、`low PNS`)都是對著這個尺度寫的。
  //
  // 所以對外送這一套,自己面板留 Kubios 那一套。兩者都保留、各有用途:
  //   · 這一套 → 跟攝影機端數值可互換
  //   · Kubios 那套 → 有常模依據,適合我們自己判讀
  //
  // ⚠️ 他們的 docstring 自己標明:
  //    "These mappings are heuristic (consumer-device style), not clinical."
  //    這幾個分數只是既有指標的重新縮放,沒有引入任何新資訊:
  //      pns      就是 RMSSD
  //      ans      就是 LF/HF
  //      stress   就是前兩者的線性組合
  //      activity 就是心率

  /// 整合方的 `pns`(畫面上叫 "Recovery")—— **就是 RMSSD 的對數縮放**。
  ///
  /// `RMSSD 10ms → 0 分`、`80ms → 100 分`,超出兩端夾住。
  static double? pnsScore(double? rmssd) {
    if (rmssd == null || rmssd <= 0) return null;
    final v = (math.log(rmssd) / math.ln10 - 1.0) /
        (math.log(80) / math.ln10 - 1.0);
    return v.clamp(0.0, 1.0) * 100.0;
  }

  /// 整合方的 `ans` —— **就是 LF/HF 取 log2 後縮放**。
  ///
  /// `LF/HF 0.25 → 0`、`1.0 → 50`(中性)、`4.0 → 100`。
  /// **越大代表越偏交感**(緊張)。
  static double? ansScore(double? lfHf) {
    if (lfHf == null || lfHf <= 0) return null;
    final v = 0.5 + (math.log(lfHf) / math.ln2) / 4.0;
    return v.clamp(0.0, 1.0) * 100.0;
  }

  /// 整合方的 `stress` —— **前兩者的加權混合**,不是 Baevsky 壓力指數。
  ///
  /// `0.6 × (100−pns)/100 + 0.4 × ans/100`。
  /// 兩個輸入任一為 null 就回 null(與他們的 `if pns and ans` 一致)。
  static double? stressScore(double? pnsScore, double? ansScore) {
    if (pnsScore == null || ansScore == null) return null;
    final v = 0.6 * (100 - pnsScore) / 100 + 0.4 * ansScore / 100;
    return v.clamp(0.0, 1.0) * 100.0;
  }

  /// 整合方的 `activity` —— **就是心率超出靜息基準多少**。
  ///
  /// `(mean_hr − 60) / 80`,夾在 0~1 再 ×100。
  static double? activityScore(double? meanHr) {
    if (meanHr == null) return null;
    return ((meanHr - 60.0) / 80.0).clamp(0.0, 1.0) * 100.0;
  }

  /// 整合方的 `confidence` —— **只看 SNR,與拍數無關**。
  ///
  /// 對應 aquivio-vitals 的 `hrv_confidence()`:
  /// `≥6.0 dB → good`、`≥1.0 dB → rough`、其餘 `very rough`。
  ///
  /// 他們選 6 dB 的理由寫在 core.py 的註解裡:低於約 6 dB 時
  /// RMSSD 的雜訊底線會超過典型靜息 HRV(實測:1.5 dB 時真值 19ms
  /// 會膨脹到約 60ms)。
  static const double snrGoodDb = 6.0;
  static const double snrRoughDb = 1.0;

  static String? confidenceFromSnr(double? snrDb) {
    if (snrDb == null) return null;
    if (snrDb >= snrGoodDb) return 'good';
    if (snrDb >= snrRoughDb) return 'rough';
    return 'very rough';
  }

  // ──────────────────────────────────────────────────────────────
  // 四、confidence(我們自己的版本)
  // ──────────────────────────────────────────────────────────────

  /// 量測可信度 → 對方介面的 `'good' | 'rough' | 'very rough'`。
  ///
  /// 這**不是生理指標**,是工程指標:「這次的數字該信幾分」。
  /// 三個依據:
  ///   · [beats] 拍數 —— HRV 統計量的抽樣誤差隨拍數縮小。核心的暖機門檻是 9 拍。
  ///   · [sqiOk] 這一輪訊號品質有沒有過關(攝影機那邊沒有的一層)。
  ///   · [settling] 沉澱期 —— 手指剛放上,數字還沒穩,不該用。
  ///
  /// 拍數不足 9(核心根本不出 HRV)或沉澱期 → 回 null。
  static String? confidence({
    required int beats,
    required bool sqiOk,
    required bool settling,
  }) {
    if (settling) return null;
    if (beats < Max30102HrvCalculator.minBeatsForHrv) return null;
    if (beats >= 25 && sqiOk) return 'good';
    if (beats >= 15) return 'rough';
    return 'very rough';
  }

  // ──────────────────────────────────────────────────────────────
  // 五、波形訊噪比 —— 對方介面的 `snr_db`
  // ──────────────────────────────────────────────────────────────

  /// 波形的頻帶訊噪比(dB) → 對方介面的 `snr_db`。
  ///
  /// ⚠️ 這**不是**我們的 SQI/spike。spike 是時域的「最大起伏 ÷ 典型起伏」,
  ///    這裡是頻域的「脈搏諧波能量 ÷ 其餘頻帶能量」。兩者不能互相換算。
  ///    做這一支是因為對方介面有這個欄位,而攝影機那邊給的就是頻域 SNR。
  ///
  /// 作法(rPPG 領域的常見定義):
  ///   1. 去趨勢 + Hann 窗 → FFT
  ///   2. 訊號 = 基頻 f0(=bpm/60) ±0.1Hz 與二次諧波 2·f0 ±0.2Hz 的能量
  ///   3. 雜訊 = 0.5~5Hz 內其餘的能量
  ///   4. 10·log10(訊號 / 雜訊)
  ///
  /// [ir] 原始 IR 波形;[bpm] 目前心率(用來定位基頻)。回 null = 資料不足。
  static double? snrDb(List<int> ir, double? bpm) {
    if (bpm == null || bpm <= 0) return null;
    final fs = Max30102Config.samplingRateHz.toDouble();
    final n = ir.length;
    if (n < fs * 5) return null; // 不足 5 秒 → 頻率解析度太差

    // 去趨勢(減平均)+ Hann 窗(降低頻譜洩漏)
    double mean = 0;
    for (final v in ir) {
      mean += v;
    }
    mean /= n;

    final size = _nextPow2(n);
    final re = List<double>.filled(size, 0);
    final im = List<double>.filled(size, 0);
    for (int i = 0; i < n; i++) {
      final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
      re[i] = (ir[i] - mean) * w;
    }
    _fft(re, im);

    final f0 = bpm / 60.0;
    final binHz = fs / size;
    double sig = 0, noise = 0;
    for (int k = 1; k < size ~/ 2; k++) {
      final f = k * binHz;
      if (f < 0.5 || f > 5.0) continue;
      final p = re[k] * re[k] + im[k] * im[k];
      final nearF0 = (f - f0).abs() <= 0.1;
      final nearH2 = (f - 2 * f0).abs() <= 0.2;
      if (nearF0 || nearH2) {
        sig += p;
      } else {
        noise += p;
      }
    }
    if (sig <= 0 || noise <= 0) return null;
    return 10 * math.log(sig / noise) / math.ln10;
  }

  static int _nextPow2(int n) {
    int p = 1;
    while (p < n) {
      p <<= 1;
    }
    return p;
  }

  /// 就地 radix-2 Cooley-Tukey FFT。[re]/[im] 長度必須是 2 的冪。
  /// 只有 [snrDb] 用得到 —— 波形是等間隔取樣,可以用 FFT;RR 序列不行(見 [spectrum])。
  static void _fft(List<double> re, List<double> im) {
    final n = re.length;
    if (n <= 1) return;

    // 位元反轉重排
    for (int i = 1, j = 0; i < n; i++) {
      int bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }

    for (int len = 2; len <= n; len <<= 1) {
      final ang = -2 * math.pi / len;
      final wr = math.cos(ang), wi = math.sin(ang);
      for (int i = 0; i < n; i += len) {
        double cr = 1, ci = 0;
        for (int k = 0; k < len ~/ 2; k++) {
          final ur = re[i + k], ui = im[i + k];
          final vr = re[i + k + len ~/ 2] * cr - im[i + k + len ~/ 2] * ci;
          final vi = re[i + k + len ~/ 2] * ci + im[i + k + len ~/ 2] * cr;
          re[i + k] = ur + vr;
          im[i + k] = ui + vi;
          re[i + k + len ~/ 2] = ur - vr;
          im[i + k + len ~/ 2] = ui - vi;
          final ncr = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = ncr;
        }
      }
    }
  }

  // ──────────────────────────────────────────────────────────────
  // 六、打包 —— 一次算齊對方介面要的全部欄位
  // ──────────────────────────────────────────────────────────────

  /// 由「一段 RR + 當下狀態」算出對方介面要的全部欄位。
  ///
  /// [pts] 這段的 RR(帶絕對位置);[hv] 同一段算出來的 HRV 統計;
  /// [ir] 波形(算 snr_db 用,給 null 就不算);其餘是核心的狀態旗標。
  static VitalsMetrics compute({
    required List<HrvRrPoint> pts,
    required HrvStats? hv,
    required bool sqiOk,
    required bool settling,
    double? bpm,
    List<int>? ir,
  }) {
    final rr = [for (final p in pts) p.rr];
    final spec = spectrum(pts);
    final si = stressIndex(rr);
    return VitalsMetrics(
      hrv: hv,
      spectrum: spec,
      stress: si,
      pns: hv == null ? null : pns(hv),
      sns: hv == null ? null : sns(hv, si),
      ansTimeDomain: hv == null ? null : ansTimeDomain(hv, si),
      confidence: confidence(
        beats: rr.length + 1,
        sqiOk: sqiOk,
        settling: settling,
      ),
      snrDb: ir == null ? null : snrDb(ir, bpm),
      sqiOk: sqiOk,
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// 打包後的結果
// ════════════════════════════════════════════════════════════════════

/// 對方介面要的全部欄位,算好放在一起。
///
/// 每個 getter 的註解都標了它在 aquivio-station / aquivio-strapi 裡的欄位名。
class VitalsMetrics {
  final HrvStats? hrv;
  final HrvSpectrum? spectrum;

  /// √(Baevsky SI) → `stress`
  final double? stress;

  /// 副交感指數 → `pns`
  final double? pns;

  /// 交感指數(時域;對方介面沒有這個欄位,但 ans 由它導出)
  final double? sns;

  /// 自律神經平衡的**時域替代值** → 可填 `ans`,但定義與對方不同
  final double? ansTimeDomain;

  /// → `confidence`
  final String? confidence;

  /// → `snr_db`
  final double? snrDb;

  final bool sqiOk;

  const VitalsMetrics({
    required this.hrv,
    required this.spectrum,
    required this.stress,
    required this.pns,
    required this.sns,
    required this.ansTimeDomain,
    required this.confidence,
    required this.snrDb,
    required this.sqiOk,
  });

  /// → `mean_hr`
  double? get meanHr => hrv?.meanHr;

  /// → `sdnn`
  double? get sdnn => hrv?.sdnn;

  /// → `rmssd`
  double? get rmssd => hrv?.rmssd;

  /// → `ln_rmssd`。對數常態的 RMSSD 取 ln 之後才適合做線性運算/比較。
  double? get lnRmssd {
    final r = hrv?.rmssd;
    return (r != null && r > 0) ? math.log(r) : null;
  }

  /// → `lf_hf`。
  ///
  /// ⚠️ **這裡照送,不再因為視窗不足而回 null。**
  ///
  /// 原本的規則是「30 秒測不到 LF 就送 null」。後來確認**攝影機端
  /// (aquivio-vitals)也是 30 秒視窗**(見他們 docs/VITALS.md:
  /// "The window is 30s (not 60s) across the station and the SDK"),
  /// 而且他們照樣把 lf_hf 算出來送。
  ///
  /// 我們送 null 而他們送數字,只會讓同一個欄位在兩台裝置上行為不一致,
  /// 下游反而更難處理 —— 分不出「沒有這個能力」和「刻意保留」。
  ///
  /// 改成照送,但**可信度資訊一起送**([HrvSpectrum.lfUsable] /
  /// [HrvSpectrum.lfCycles] 會出現在 `lf_reliable` / `lf_cycles`),
  /// 讓上層自己判斷。誠實靠標註,不靠藏數字。
  double? get lfHf => spectrum?.lfHf;

  // ── 整合方 0~100 分數(逐字對應 aquivio-vitals 的 derived_scores)──
  //
  // ⚠️ 與上面的 [pns] / [sns] / [ansTimeDomain] **不是同一組東西**。
  //    那組是 Kubios 式 z-score(有常模依據,適合我們自己判讀);
  //    這組是整合方的啟發式縮放(與攝影機端數值可互換)。

  /// → `pns`(0~100,他們畫面上叫 "Recovery")
  double? get pnsScore => Max30102VitalsMetrics.pnsScore(hrv?.rmssd);

  /// → `ans`(0~100,越大越偏交感)
  double? get ansScore => Max30102VitalsMetrics.ansScore(lfHf);

  /// → `stress`(0~100)。ans 為 null 時跟著 null,與他們的行為一致。
  double? get stressScore =>
      Max30102VitalsMetrics.stressScore(pnsScore, ansScore);

  /// → `activity`(0~100)
  double? get activityScore =>
      Max30102VitalsMetrics.activityScore(hrv?.meanHr);

  /// → `confidence`。改用 SNR 門檻,與整合方一致(見 [confidenceFromSnr])。
  String? get confidenceBySnr =>
      Max30102VitalsMetrics.confidenceFromSnr(snrDb);

  /// → `sqi`。對方的型別是 number,我們的是二元閘門 → 1 / 0。
  ///
  /// ⚠️ 連續版做不出來:SQI 的三個零件裡只有 spike 被核心導出,cv 與 keptCount
  ///    只活在 Max30102Sqi 內部。要給連續值得先改交接核心。
  int get sqi => sqiOk ? 1 : 0;

  /// 照對方介面(`aquivio-station` 的 `VitalsResult`)的欄位名與**單位**打包。
  ///
  /// 每一個欄位都對齊 `aquivio-vitals` 的實作,所以數值與攝影機端可互換:
  ///   · `pns` / `ans` / `stress` / `activity` —— 逐字照他們的 derived_scores()
  ///   · `confidence` —— 照他們的 SNR 門檻(6.0 / 1.0 dB)
  ///   · `lf` / `hf` —— **換算成他們的單位**(見 [HrvSpectrum.lfAquivio]);
  ///     我們原本的 ms² 值另外放在 `lf_ms2` / `hf_ms2`
  ///
  /// 宣告的 12 個欄位**一個都不會缺**,沒有值就是 null —— 對方把 `activity`
  /// 之類宣告成 `number | null` 而非 optional,少了 key 那側會拿到
  /// `undefined` 而不是 `null`,型別就對不上。缺值用 null 表達。
  Map<String, dynamic> toStrapiJson() {
    final s = spectrum;
    return {
      // ── VitalsResult 宣告的 12 個欄位 ────────────────────────────
      'mean_hr': meanHr,
      'sdnn': sdnn,
      'rmssd': rmssd,
      'ln_rmssd': lnRmssd,
      'lf_hf': lfHf,
      'sqi': sqi,
      'snr_db': snrDb,
      'confidence': confidenceBySnr,
      'pns': pnsScore,
      'ans': ansScore,
      'stress': stressScore,
      'activity': activityScore,

      // ── 額外欄位(靠介面的 `[key: string]: unknown` 帶過去)────────
      //
      // lf / hf 用**他們的單位**,才不會同名不同義。
      'lf': s?.lfAquivio,
      'hf': s?.hfAquivio,
      // 我們自己的原始值,**明確標單位**。兩者差 1.024e-3 的換算因子,
      // 想回推或跟我們的畫面對帳就用這兩個。
      'lf_ms2': s?.lf,
      'hf_ms2': s?.hf,
      'vlf_ms2': s?.vlf,

      // 誠實性資訊:數字照送,但可不可信一起講清楚。
      // 30 秒窗的 LF 只涵蓋 0.04Hz 的約 1.1 個週期 —— 攝影機端同樣是
      // 30 秒,所以這不是我們獨有的限制,而是兩邊共同的。
      'lf_reliable': s?.lfUsable ?? false,
      'hf_reliable': s?.hfUsable ?? false,
      'lf_cycles': s?.lfCycles,
      'hf_cycles': s?.hfCycles,
      'window_sec': s?.spanSeconds,

      // 我們自己那套(Kubios 式 z-score)—— 與上面的 0~100 分數**不同尺度**,
      // 名字刻意分開,不會誤用。有常模依據,適合需要統計解讀時參考。
      'pns_z': pns,
      'sns_z': sns,
      'ans_time_domain': ansTimeDomain,
      'stress_baevsky': stress,
      'confidence_by_beats': confidence,
    };
  }
}
