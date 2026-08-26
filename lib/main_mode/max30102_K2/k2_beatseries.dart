// ============================================================================
// Max30102BeatSeries — RR/NN 序列的「過濾器」（有狀態，唯一真相來源）
// ============================================================================
// 把「谷 → RR → 生理閘門 → 誤拍過濾(_rrAccept) → search-back 補漏 → 累積 NN 序列」
// 收成一個盒子。HRV 從它取；(未來 B 階)HR 也改從它取。抽自 Max30102Controller。
//
// 邊界（盒子不擁有這些，只透過「回讀 / 回傳」互動）:
//   · irAt(回呼)：search-back 要回讀原始 IR 波形時才問一筆(-1=已捲出緩衝)。
//   · feed() 回傳 Max30102BeatFeed：這一輪「剔了哪些 / 補回哪些 / 要寫哪些 log」，
//     由 controller 去施作(HRV 篩除記錄面板 / 橘點顯示 / 主事件日誌)。盒子不碰 UI。
//   · config(參考)：讀 hrMin/hrMax(生理閘門)、searchBackEnabled/promRatio/bandLowHz。
//
// 兩層設計提醒:這裡是「序列層(累積、要保留變異)」；窗層品質(cv/spike)在 Max30102Sqi。
// 兩者唯一連接是 feed(peakAbsNew, sqiOk) 的 sqiOk 布林(整輪閘門，rank7)。
// ============================================================================

import 'dart:math' as math;

import 'k2_config.dart';
import 'k2_hrv_calculator.dart';
import 'k2_signal.dart';

/// feed() 一輪的產物：交回 controller 施作的「副作用資料」(盒子只回報，不自己動)。
typedef Max30102BeatFeed = ({
  List<({int absIndex, double rr, String reason})> rejects, // → HRV 篩除記錄
  List<int> recovered, // search-back 補回的谷絕對位置 → 橘點顯示
  List<String> logs, // → 主事件日誌（如「🔁 補漏拍…」）
});

class Max30102BeatSeries {
  /// 可調參數（運行中可改；controller 是就地 mutate 同一物件，持參考安全）。
  final Max30102Config config;

  /// search-back 回讀原始 IR：給絕對樣本位置，回該筆 IR 值；已捲出緩衝回 -1。
  final int Function(int absPos) irAt;

  /// NN 序列上限（拍數）。
  final int maxBeats;

  Max30102BeatSeries({
    required this.config,
    required this.irAt,
    this.maxBeats = 300,
  });

  // ── 狀態：唯一一條 NN 序列（平行陣列同步）──
  final List<double> _rr = []; // RR(ms)
  final List<bool> _recovered = []; // 該拍是否為 search-back 補回
  final List<int> _startAbs = []; // 每筆起谷絕對位置
  final List<int> _endAbs = []; // 每筆終谷絕對位置
  int _lastTroughAbs = -1; // 上一個已轉成 RR 的波谷絕對位置

  // ── 對外讀取（getter；不重算，直接遞出存好的狀態）──
  List<double> get rrHistory => _rr;
  List<int> get rrStartAbs => _startAbs;
  List<int> get rrEndAbs => _endAbs;
  List<bool> get rrRecovered => _recovered;

  /// 組成 HrvRrSample 清單餵給純計算模組。
  List<HrvRrSample> get samples => [
    for (int i = 0; i < _rr.length; i++)
      (
        rr: _rr[i],
        startAbs: _startAbs[i],
        endAbs: _endAbs[i],
        recovered: _recovered[i],
      ),
  ];

  /// 乾淨 RR + 起/終谷（含補漏拍）。給 tachogram 折線用。clean 開關關 → 全收。
  List<HrvRrPoint> rrCleanPts() => Max30102HrvCalculator.clean(
    samples,
    includeRecovered: true,
    apply: config.cleanEnabled,
  );

  /// 乾淨 RR 值（含補漏拍）。
  List<double> rrClean() => [for (final e in rrCleanPts()) e.rr];

  /// clean() 顯示時剔掉的離群拍(透明化:給「HRV 篩除記錄」面板看)。clean 關 → 空。
  List<HrvRrPoint> cleanRejects() => Max30102HrvCalculator.cleanRejects(
    samples,
    includeRecovered: true,
    apply: config.cleanEnabled,
  );

  /// H1(A 階段):疑似異位拍(早搏)——純標記,供 UI 標紫點/計數。
  /// 不從池移除、不影響任何 HRV 數字(SDNN/RMSSD/…);只是「看有沒有抓到早搏」的透明化。
  List<HrvRrPoint> ectopicPts() => Max30102HrvCalculator.ectopics(samples);

  /// HRV 統計（含補漏拍）。null=拍數不足。
  HrvStats? hrvStats() => Max30102HrvCalculator.stats(
    samples,
    includeRecovered: true,
    apply: config.cleanEnabled,
  );

  /// HRV 統計（排除補漏拍；給「補漏拍 開/關」對照）。
  HrvStats? hrvStatsNoSearchBack() => Max30102HrvCalculator.stats(
    samples,
    includeRecovered: false,
    apply: config.cleanEnabled,
  );

  /// (B 階) 顯示用 HR：取「最近 lastN 拍」的中位 RR → 60000/中位。
  ///   用「拍數」而非「時間窗」:不受 _totalSamples/餵拍順序/SQI差空窗 影響,只要序列
  ///   有 ≥2 拍就一定算得出(時間窗版會在 SQI 差空窗時整段滑過去 → 掉 null)。
  ///   中位數抗離群;顯示端另有 EMA 平滑。不足 2 拍回 null(交由呼叫端凍結)。
  ///   與 HRV 同一條 NN 序列 → HR 與 HRV 從此單一真相、不再各算各的。
  double? hrRecent(int lastN) {
    if (_rr.length < 2) return null;
    final take = _rr.length < lastN ? _rr.length : lastN;
    final recent = _rr.sublist(_rr.length - take)..sort();
    final med = recent[recent.length ~/ 2];
    return med > 0 ? 60000.0 / med : null;
  }

  /// 全清（重新量測 / 清波形）。
  void reset() {
    _rr.clear();
    _recovered.clear();
    _startAbs.clear();
    _endAbs.clear();
    _lastTroughAbs = -1;
  }

  /// 只斷「連續性基準」，不清歷史（手指離開 → 下一 RR 不要跨斷層）。
  void markDiscontinuity() => _lastTroughAbs = -1;

  /// 把「比上次更新」的波谷轉成 RR，累積進序列。
  /// rank7：整輪 sqiOk=false → 該輪新谷「消化不記」(記一筆 SQI差 篩除)。
  Max30102BeatFeed feed(List<int> peakAbsNew, bool sqiOk) {
    const fs = Max30102Config.samplingRateHz;
    final rejects = <({int absIndex, double rr, String reason})>[];
    final recovered = <int>[];
    final logs = <String>[];

    for (final abs in peakAbsNew) {
      if (abs <= _lastTroughAbs) continue; // 已處理過
      // H2：預設「量完就把量尺起點(_lastTroughAbs)往前移」。只有「過短側被剔(疑似偽谷/
      // 多抓)」例外——偽谷雖不進池，若推進基準會把下一段真間期切成假短 NN、灌爆 RMSSD。
      bool advance = true;
      if (_lastTroughAbs >= 0 && sqiOk) {
        final rr = (abs - _lastTroughAbs) * 1000.0 / fs; // ms
        // ── search-back 補漏拍：gap 明顯過大(疑似漏拍) 且開關開啟時，回 gap 內用
        //    放寬門檻找回真實波谷；只有切出的每段 RR 都合理才採用(不造假)。
        //    起步門檻與 HRV 暖機同步 minBeatsForHrv：早期基準太少，一次誤切就滾雪球。
        if (config.searchBackEnabled &&
            _rr.length + 1 >= Max30102HrvCalculator.minBeatsForHrv) {
          final med = _recentMedianRr();
          if (med > 0 && rr > 1.6 * med) {
            final rec = _searchBackFill(_lastTroughAbs, abs, med);
            if (rec.isNotEmpty) {
              var prev = _lastTroughAbs;
              for (final t in [...rec, abs]) {
                // 整段 gap 都靠補漏拍才存在 → 全標 recovered；相接(prev→t)可進 RMSSD 配對
                _push(
                  (t - prev) * 1000.0 / fs,
                  recovered: true,
                  startAbs: prev,
                  endAbs: t,
                );
                prev = t;
              }
              recovered.addAll(rec);
              _lastTroughAbs = abs;
              logs.add(
                '🔁 補漏拍：gap ${rr.toStringAsFixed(0)}ms 補回 ${rec.length} 拍',
              );
              continue;
            }
          }
        }
        // 生理閘門：RR 上下限由 config.hrMin/hrMax 換算(RR=60000/HR)，與 HR 同基準。
        // + 誤拍過濾(只取 NN 間距，擋漏拍/多抓)。被擋下的拍回報進篩除記錄。
        // 生理閘門 + 誤拍過濾。剔除時再分「短側(偽谷/多抓)」與「長側(疑似漏拍)」：
        //   過短 → advance=false，基準不動，讓下一顆真谷仍以 T0 起量得到真間期；
        //   過長 → advance 維持 true 照舊 resync(真拍谷沒被抓到時不移會連環量爆、全砍)。
        final rrMinMs = 60000.0 / config.hrMax; // 最快心跳 → 最短 RR
        final rrMaxMs = 60000.0 / config.hrMin; // 最慢心跳 → 最長 RR
        if (rr < rrMinMs) {
          rejects.add((absIndex: abs, rr: rr, reason: '生理閘門'));
          advance = false; // 過短=偽谷/多抓 → 基準不推進
        } else if (rr > rrMaxMs) {
          rejects.add((absIndex: abs, rr: rr, reason: '生理閘門'));
          // 過長=疑似漏拍 → advance 維持 true，resync
        } else if (!_rrAccept(rr)) {
          rejects.add((absIndex: abs, rr: rr, reason: '誤拍>40%'));
          final med = _recentRrMedian();
          if (med > 0 && rr < med) advance = false; // 短側=偽谷 → 基準不推進
        } else {
          _push(rr, startAbs: _lastTroughAbs, endAbs: abs);
        }
      } else if (_lastTroughAbs >= 0 && !sqiOk) {
        // rank7：整輪 SQI 差 → 這個谷消化不記，回報一筆篩除供研究
        rejects.add((
          absIndex: abs,
          rr: (abs - _lastTroughAbs) * 1000.0 / fs,
          reason: 'SQI差',
        ));
      }
      // H2：偽谷(短側剔)不推進量尺；正常拍/漏拍(長側)/初始/SQI差 照舊推進 resync。
      if (advance) _lastTroughAbs = abs;
    }
    return (rejects: rejects, recovered: recovered, logs: logs);
  }

  /// 推一筆 RR（與 recovered/起谷/終谷 同步），維持上限 maxBeats。
  void _push(
    double rr, {
    bool recovered = false,
    required int startAbs,
    required int endAbs,
  }) {
    _rr.add(rr);
    _recovered.add(recovered);
    _startAbs.add(startAbs);
    _endAbs.add(endAbs);
    while (_rr.length > maxBeats) {
      _rr.removeAt(0);
      _recovered.removeAt(0);
      _startAbs.removeAt(0);
      _endAbs.removeAt(0);
    }
  }

  /// **照時間裁** —— 丟掉「終谷早於 [minEndAbs]」的舊拍。
  ///
  /// 由控制層每輪呼叫,把池子維持在 `config.dataHistoryMs`(預設 30 秒)之內
  /// —— 與樣本緩衝同一個界線,兩邊涵蓋的時間一致。
  /// 用時間而非拍數:拍數上限會隨心率浮動,同一個數字在不同人身上長度不同。
  /// 序列本來就依 endAbs 遞增,所以只要從頭數出要丟幾筆、一次 removeRange。
  void trimOlderThan(int minEndAbs) {
    int drop = 0;
    while (drop < _endAbs.length && _endAbs[drop] < minEndAbs) {
      drop++;
    }
    if (drop <= 0) return;
    _rr.removeRange(0, drop);
    _recovered.removeRange(0, drop);
    _startAbs.removeRange(0, drop);
    _endAbs.removeRange(0, drop);
  }

  /// 最近 9 拍「乾淨(非補漏拍)」RR 的中位數(0=乾淨拍不足)。給 search-back 判 gap。
  /// 只用乾淨拍 → 補回的假拍不會把基準拉低、避免「假拍滾雪球」。
  double _recentMedianRr() {
    final clean = <double>[
      for (int i = 0; i < _rr.length; i++)
        if (!_recovered[i]) _rr[i],
    ];
    if (clean.length < 4) return 0; // 乾淨拍不足 → 不啟動補漏拍
    final recent = clean.sublist(math.max(0, clean.length - 9));
    final s = List<double>.from(recent)..sort();
    return s[s.length ~/ 2];
  }

  /// 誤拍過濾：新 RR 與「最近 9 拍中位數」相差 > 40% → 視為漏拍(併拍)/多抓，不納入。
  /// (2026-07 由 30% 放寬到 40%：以「近9拍當前節律」為主要基準,只擋明顯離群,
  ///  中等真變異留下;漏拍改由 search-back 回補,clean 全域離群降級為對照開關。)
  bool _rrAccept(double rr) {
    final med = _recentRrMedian();
    if (med <= 0) return true; // 起步 <3 拍或基準無效 → 全收(HRV 靠暖機把關)
    return (rr - med).abs() / med <= 0.40;
  }

  /// 誤拍過濾用的「近 9 拍中位數」(0 = 拍數不足<3 或基準無效)。
  /// 除了 _rrAccept，H2 也用它判斷「剔除是短側(偽谷/多抓)或長側(疑似漏拍)」。
  double _recentRrMedian() {
    if (_rr.length < 3) return 0; // 基準不足
    final recent = _rr.sublist(math.max(0, _rr.length - 9));
    final sorted = List<double>.from(recent)..sort();
    final med = sorted[sorted.length ~/ 2];
    return med > 0 ? med : 0;
  }

  /// search-back：在 [prevAbs, curAbs] 這段(疑似漏拍 gap) 用放寬門檻找回真實波谷。
  /// 回傳補回的波谷絕對位置(遞增)；找不到或切出的 RR 不合理 → 回空(不造假)。
  List<int> _searchBackFill(int prevAbs, int curAbs, double medRr) {
    const fs = Max30102Config.samplingRateHz;
    final cap = config.dataHistorySamples; // gap 不可能超過核心保留的長度
    final n = curAbs - prevAbs + 1;
    if (n < 6 || n > cap) return const [];
    final seg = List<double>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      final v = irAt(prevAbs + i);
      if (v < 0) return const []; // 已捲出緩衝，放棄
      seg[i] = v.toDouble();
    }
    // 去趨勢 → 把谷翻成峰(base − seg)，用放寬的 prominence 門檻找
    final base = Max30102Signal.movingAverage(
      seg,
      (fs / config.bandLowHz).round(),
    );
    final neg = List<double>.generate(n, (i) => base[i] - seg[i]);
    final minDist = ((medRr * 0.5) * fs / 1000).round().clamp(3, n);
    final relax = (config.promRatio * 0.4).clamp(0.05, 0.5);
    final found = Max30102Signal.findProminentPeaks(neg, minDist, relax);
    // 只收「嚴格落在 gap 內(避開兩端)」的谷
    final margin = ((medRr * 0.4) * fs / 1000).round();
    final recovered = <int>[
      for (final k in found)
        if (k > margin && k < n - margin) prevAbs + k,
    ]..sort();
    if (recovered.isEmpty) return const [];
    // 補回數上限：gap ≈ N×median 最多只能有 N−1 個漏拍；抓到更多 = 誤抓
    // (重搏切跡/波肩/雜訊) → 整批不採用(寧缺勿假)。
    final rrMs = (curAbs - prevAbs) * 1000.0 / fs;
    final maxRecover = (rrMs / medRr).round() - 1;
    if (maxRecover < 1 || recovered.length > maxRecover) return const [];
    // 驗證：插入後每段 RR 都要落在 [0.6,1.5]×med，否則整批不採用(寧缺勿假)
    final pts = [prevAbs, ...recovered, curAbs];
    for (int i = 1; i < pts.length; i++) {
      final seg2 = (pts[i] - pts[i - 1]) * 1000.0 / fs;
      if (seg2 < 0.6 * medRr || seg2 > 1.5 * medRr) return const [];
    }
    return recovered;
  }
}
