// ============================================================================
// lf_window_compare.dart — 同一份快照,10 秒 vs 30 秒,全欄位並排
// ============================================================================
// 同一個人、同一次量測、同一批 RR、同一份程式碼 —— 唯一的變因是視窗長度。
//
// 用法:
//   dart run tools/lf_window_compare.dart <快照.json>
//   dart run tools/lf_window_compare.dart <快照.json> --slide   # 加印滑動視窗
//
// 驗證用的一次性工具,不屬於交接核心。
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_hrv_calculator.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_vitals_metrics.dart';

/// 一個視窗算出來的全部東西。
class Win {
  Win(this.label, this.pts, this.ir, this.sqiOk);
  final String label;
  final List<HrvRrPoint> pts;
  final List<int> ir;
  final bool sqiOk;

  late final List<double> rr = [for (final p in pts) p.rr];
  late final HrvStats? hrv = Max30102HrvCalculator.stats(
    [for (final p in pts) (rr: p.rr, startAbs: p.startAbs, endAbs: p.endAbs, recovered: false)],
    includeRecovered: true,
  );
  late final HrvSpectrum? spec = Max30102VitalsMetrics.spectrum(pts);
  late final double? si = Max30102VitalsMetrics.stressIndex(rr);
  late final double? snr = Max30102VitalsMetrics.snrDb(ir, hrv?.meanHr);

  late final VitalsMetrics vm = VitalsMetrics(
    beats: pts.isEmpty ? 0 : pts.length + 1,
    rrGaps: Max30102VitalsMetrics.rrGaps(pts),
    cleanShare: Max30102VitalsMetrics.cleanShare(pts),
    hrv: hrv,
    spectrum: spec,
    stress: si == null ? null : math.sqrt(si!),
    pns: hrv == null ? null : Max30102VitalsMetrics.pns(hrv!),
    sns: hrv == null ? null : Max30102VitalsMetrics.sns(hrv!, si),
    ansTimeDomain:
        hrv == null ? null : Max30102VitalsMetrics.ansTimeDomain(hrv!, si),
    confidence: Max30102VitalsMetrics.confidence(
      beats: hrv?.beats ?? 0,
      sqiOk: sqiOk,
      settling: false,
    ),
    snrDb: snr,
    sqiOk: sqiOk,
  );
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法:dart run tools/lf_window_compare.dart <快照.json>');
    exit(1);
  }
  final j = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final fs = (j['fs'] as num).toDouble();
  final rr = (j['rr'] as List).cast<num>();
  final sa = (j['rrStartAbs'] as List).cast<num>();
  final ea = (j['rrEndAbs'] as List).cast<num>();
  final ir = (j['ir'] as List).cast<num>().map((e) => e.toInt()).toList();
  final gold = (j['goldTroughs'] as List).cast<num>();
  final sqiOk = j['sqiOk'] == true;

  final all = <HrvRrPoint>[
    for (int i = 0; i < rr.length; i++)
      (rr: rr[i].toDouble(), startAbs: sa[i].toInt(), endAbs: ea[i].toInt()),
  ];

  // ir[0] 的絕對索引:goldTroughs 是視窗內索引,rrEndAbs 是同一批谷的絕對索引。
  final offsets = <int>[
    for (int i = 0; i < gold.length && i < ea.length; i++)
      ea[i].toInt() - gold[i].toInt(),
  ]..sort();
  final irBase = offsets.isEmpty ? 0 : offsets[offsets.length ~/ 2];
  final spread = offsets.isEmpty ? 0 : offsets.last - offsets.first;

  final t0 = all.first.startAbs;
  final tEnd = all.last.endAbs;
  final total = (tEnd - t0) / fs;

  Win win(String label, double startSec, double winSec) {
    final lo = t0 + (startSec * fs).round();
    final hi = lo + (winSec * fs).round();
    final pts = [
      for (final p in all)
        if (p.startAbs >= lo && p.endAbs <= hi) p,
    ];
    final i0 = (lo - irBase).clamp(0, ir.length);
    final i1 = (hi - irBase).clamp(0, ir.length);
    return Win(label, pts, ir.sublist(i0, i1), sqiOk);
  }

  stdout.writeln('快照:${args[0].split(RegExp(r"[\\/]")).last}');
  stdout.writeln('RR ${all.length} 筆,總跨度 ${total.toStringAsFixed(1)} 秒,'
      '快照 bpm ${(j['bpm'] as num).toStringAsFixed(1)},'
      'spo2 ${(j['spo2'] as num).toStringAsFixed(1)},'
      '方向 ${j['channelOrient']}');
  stdout.writeln('(ir 對位偏移 $irBase,一致性誤差 $spread 筆)\n');

  final a = win('前 10 秒', 0, 10);
  final b = win('整段', 0, total + 1);

  String f(Object? v, [int d = 2]) {
    if (v == null) return '—';
    if (v is String) return v;
    if (v is bool) return v ? 'true' : 'false';
    if (v is int) return '$v';
    return (v as num).toDouble().toStringAsFixed(d);
  }

  String ratio(Object? x, Object? y) {
    if (x is num && y is num && x != 0 && y != 0) {
      final r = y / x;
      return r >= 1
          ? '×${r.toStringAsFixed(2)}'
          : '×${r.toStringAsFixed(2)}';
    }
    return '';
  }

  void line(String name, Object? x, Object? y, [int d = 2]) {
    stdout.writeln('${name.padRight(26)}${f(x, d).padLeft(10)}'
        '${f(y, d).padLeft(12)}   ${ratio(x, y)}');
  }

  void head(String t) => stdout.writeln('\n── $t ──');

  stdout.writeln('${''.padRight(26)}${'10 秒'.padLeft(9)}'
      '${'整段'.padLeft(12)}   30÷10');
  stdout.writeln('─' * 62);

  head('視窗');
  line('跨度(秒)', a.spec?.spanSeconds, b.spec?.spanSeconds, 1);
  line('拍數', a.hrv?.beats, b.hrv?.beats);

  head('時域 HRV');
  line('mean_hr (bpm)', a.hrv?.meanHr, b.hrv?.meanHr, 1);
  line('mean_rr (ms)', a.hrv?.meanRr, b.hrv?.meanRr, 1);
  line('sdnn (ms)', a.hrv?.sdnn, b.hrv?.sdnn, 1);
  line('rmssd (ms)', a.hrv?.rmssd, b.hrv?.rmssd, 1);
  line('ln_rmssd', a.vm.lnRmssd, b.vm.lnRmssd);
  line('pnn50 (%)', a.hrv?.pnn50, b.hrv?.pnn50, 1);
  line('sd1 (ms)', a.hrv?.sd1, b.hrv?.sd1, 1);
  line('sd2 (ms)', a.hrv?.sd2, b.hrv?.sd2, 1);
  line('壓力指數 SI', a.si, b.si, 1);

  head('頻域(原始 ms²)');
  line('vlf_ms2', a.spec?.vlf, b.spec?.vlf, 1);
  line('lf_ms2', a.spec?.lf, b.spec?.lf, 1);
  line('hf_ms2', a.spec?.hf, b.spec?.hf, 1);
  line('total_power', a.spec?.totalPower, b.spec?.totalPower, 1);
  line('lf_nu (%)', a.spec?.lfNu, b.spec?.lfNu, 1);
  line('hf_nu (%)', a.spec?.hfNu, b.spec?.hfNu, 1);
  line('LF/HF', a.spec?.lfHf, b.spec?.lfHf);

  head('頻域可信度');
  line('lf_cycles (需 ≥4)', a.spec?.lfCycles, b.spec?.lfCycles, 2);
  line('hf_cycles (需 ≥4)', a.spec?.hfCycles, b.spec?.hfCycles, 2);
  line('lf_reliable', a.spec?.lfUsable, b.spec?.lfUsable);
  line('hf_reliable', a.spec?.hfUsable, b.spec?.hfUsable);
  line('lf_bins', a.spec?.lfBins, b.spec?.lfBins, 2);

  head('送出去的 Strapi 分數(0~100)');
  line('pns (Recovery)', a.vm.pnsScore, b.vm.pnsScore, 1);
  line('ans (自律平衡)', a.vm.ansScore, b.vm.ansScore, 1);
  line('stress', a.vm.stressScore, b.vm.stressScore, 1);
  line('activity', a.vm.activityScore, b.vm.activityScore, 1);
  line('lf (他們的單位)', a.spec?.lfAquivio, b.spec?.lfAquivio, 3);
  line('hf (他們的單位)', a.spec?.hfAquivio, b.spec?.hfAquivio, 3);

  head('我們自己的判讀(不送出)');
  line('副交感 z (pns)', a.vm.pns, b.vm.pns);
  line('交感 z (sns)', a.vm.sns, b.vm.sns);
  line('自律平衡(時域 ans)', a.vm.ansTimeDomain, b.vm.ansTimeDomain);
  line('壓力 √SI', a.vm.stress, b.vm.stress, 1);

  head('品質');
  line('snr_db', a.snr, b.snr, 1);
  line('confidence (SNR)', a.vm.confidenceVideo, b.vm.confidenceVideo);
  line('confidence (拍數)', a.vm.confidence, b.vm.confidence);
  line('sqi', a.vm.sqi, b.vm.sqi);

  if (!args.contains('--slide')) return;

  stdout.writeln('\n── 同一次量測裡的 10 秒視窗,每 2 秒滑一次 ──');
  for (double st = 0; st + 10 <= total + 0.01; st += 2) {
    final w = win('', st, 10);
    final s = w.spec;
    stdout.writeln(
      '${st.toStringAsFixed(0).padLeft(2)}~${(st + 10).toStringAsFixed(0)}s'
      ' 拍 ${(w.hrv?.beats ?? 0).toString().padLeft(2)}'
      ' | rmssd ${f(w.hrv?.rmssd, 1).padLeft(6)}'
      ' | LF ${f(s?.lf, 1).padLeft(7)} HF ${f(s?.hf, 1).padLeft(7)}'
      ' LF/HF ${f(s?.lfHf).padLeft(5)}'
      ' | ans ${f(w.vm.ansScore, 1).padLeft(5)}'
      ' stress ${f(w.vm.stressScore, 1).padLeft(5)}',
    );
  }
}
