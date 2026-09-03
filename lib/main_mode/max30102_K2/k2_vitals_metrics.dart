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

  /// **LF 這個數字能不能用。**
  ///
  /// 門檻取 110 秒(0.04Hz 走完 4.4 圈)。國際標準(Task Force 1996)要求的是
  /// **300 秒**,所以 true 只代表「勉強站得住」,不代表符合標準。
  /// 30 秒窗一定是 false —— 那正是這個旗標存在的理由。
  ///
  /// ⚠️ 為什麼是 110 而不是整數的 120:一段「錄滿 2 分鐘」的資料,實際跨度
  ///    必然略小於 120 秒 —— 第一拍的起谷落在 t=0 之後,最後一拍的終谷落在
  ///    t=120 之前,兩端各少一點。門檻若寫死 120,就會把它本來要接受的那種
  ///    錄製整批擋掉(實測是 119.x)。110 留了餘裕,同時離 30 秒還很遠。
  bool get lfUsable => spanSeconds >= 110;

  /// HF 的門檻寬鬆得多:0.15Hz 週期只有 6.7 秒,30 秒就有 4.5 圈。
  bool get hfUsable => spanSeconds >= 30;
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

  // ──────────────────────────────────────────────────────────────
  // 四、confidence —— 對方介面的 `confidence`
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

  /// → `lf_hf`。**視窗不足時回 null**,不回一個假的數字。
  /// 想看原始值(即使不可信)請直接讀 [spectrum]。
  double? get lfHf {
    final s = spectrum;
    if (s == null || !s.lfUsable) return null;
    return s.lfHf;
  }

  /// → `sqi`。對方的型別是 number,我們的是二元閘門 → 1 / 0。
  ///
  /// ⚠️ 連續版做不出來:SQI 的三個零件裡只有 spike 被核心導出,cv 與 keptCount
  ///    只活在 Max30102Sqi 內部。要給連續值得先改交接核心。
  int get sqi => sqiOk ? 1 : 0;

  /// 照對方介面的欄位名打包(給之後接 /vitals 用)。
  ///
  /// 兩個欄位**刻意恆為 null**,不是漏做:
  ///
  /// · `lf_hf` —— 視窗不足時([HrvSpectrum.lfUsable] 為 false)不出數字。
  ///   30 秒窗永遠落在這一類。寧可缺欄位,也不要送一個看起來合理、
  ///   實際上什麼都沒量到的數字過去。
  ///
  /// · `ans` —— 對方的 `ans` 定義是「LF/HF 導出的自律神經平衡」。我們有的是
  ///   [ansTimeDomain](時域 SNS−PNS),那是**另一個定義**、另一個尺度,
  ///   兩台裝置的數字不可互比。未經整合方同意就把它塞進這個欄位,
  ///   等於偷換定義 —— 所以這裡留 null,時域替代值請直接讀 [ansTimeDomain]。
  Map<String, dynamic> toStrapiJson() => {
        'mean_hr': meanHr,
        'sdnn': sdnn,
        'rmssd': rmssd,
        'ln_rmssd': lnRmssd,
        'lf_hf': lfHf,
        'sqi': sqi,
        'snr_db': snrDb,
        'confidence': confidence,
        'pns': pns,
        'ans': null,
        'stress': stress,
      };
}
