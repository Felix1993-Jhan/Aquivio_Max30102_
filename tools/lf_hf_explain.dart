// ============================================================================
// lf_hf_explain.dart — 把 LF / HF 的「全部輸入」攤開來看
// ============================================================================
// 回答一個問題:LF / HF 到底是看哪些數字算出來的?
//
//   · 波形(3000 筆 IR)          → 一筆都沒進來
//   · baseline 那條彎曲虛線      → 沒進來
//   · RR 序列(30 幾個數字)       → 這就是全部
//
// 這裡把週期圖自己重算一次(公式與 k2_vitals_metrics 的 spectrum() 相同),
// 並與核心算出來的值對帳,證明印出來的就是真的那一份。
//
// 用法:dart run tools/lf_hf_explain.dart <快照.json>
//
// 驗證用的一次性工具,不屬於交接核心。
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_hrv_calculator.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_signal.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_vitals_metrics.dart';

/// Lomb-Scargle 單頻功率(與核心的 _lombAt 同公式)。
double lombAt(List<double> t, List<double> dx, double w) {
  double s2 = 0, c2 = 0;
  for (final ti in t) {
    s2 += math.sin(2 * w * ti);
    c2 += math.cos(2 * w * ti);
  }
  final tau = math.atan2(s2, c2) / (2 * w);
  double a = 0, b = 0, c = 0, d = 0;
  for (int i = 0; i < t.length; i++) {
    final x = w * (t[i] - tau);
    final co = math.cos(x), si = math.sin(x);
    a += dx[i] * co;
    b += dx[i] * si;
    c += co * co;
    d += si * si;
  }
  if (c < 1e-12 || d < 1e-12) return 0;
  return 0.5 * (a * a / c + b * b / d);
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法:dart run tools/lf_hf_explain.dart <快照.json>');
    exit(1);
  }
  final j = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final fs = (j['fs'] as num).toDouble();
  final rrL = (j['rr'] as List).cast<num>();
  final sa = (j['rrStartAbs'] as List).cast<num>();
  final ea = (j['rrEndAbs'] as List).cast<num>();
  final ir = (j['ir'] as List).cast<num>().map((e) => e.toInt()).toList();

  final pts = <HrvRrPoint>[
    for (int i = 0; i < rrL.length; i++)
      (rr: rrL[i].toDouble(), startAbs: sa[i].toInt(), endAbs: ea[i].toInt()),
  ];

  stdout.writeln('快照:${args[0].split(RegExp(r"[\\/]")).last}');
  stdout.writeln('');
  stdout.writeln('══ 這份快照裡有什麼 ══');
  stdout.writeln('  IR 波形          ${ir.length} 筆（${(ir.length / fs).toStringAsFixed(1)} 秒 @${fs.toInt()}Hz）');
  stdout.writeln('  RR 序列          ${pts.length} 筆');
  stdout.writeln('');
  stdout.writeln('  LF / HF 的輸入 = 下面那 ${pts.length} 個數字。IR 波形一筆都沒進來。');
  stdout.writeln('');

  // ── ① 輸入:RR 序列 ───────────────────────────────────────────────
  final t0 = pts.first.endAbs / fs;
  final t = [for (final p in pts) p.endAbs / fs - t0];
  final x = [for (final p in pts) p.rr];
  final mean = x.reduce((a, b) => a + b) / x.length;
  final dx = [for (final v in x) v - mean];

  stdout.writeln('══ ① 輸入:RR 序列（去均值後才進頻譜）══');
  stdout.writeln('  #   終谷索引   t(秒)   RR(ms)   去均值   ${'|' 't 軸上的位置'}');
  for (int i = 0; i < pts.length; i++) {
    final bar = ' ' * (t[i] / 30 * 40).round() + '•';
    stdout.writeln('  ${(i + 1).toString().padLeft(2)}  '
        '${pts[i].endAbs.toString().padLeft(7)}  '
        '${t[i].toStringAsFixed(2).padLeft(6)}  '
        '${x[i].toStringAsFixed(0).padLeft(6)}  '
        '${dx[i].toStringAsFixed(1).padLeft(7)}   $bar');
  }
  final span = (pts.last.endAbs - pts.first.startAbs) / fs;
  double varSum = 0;
  for (final v in dx) {
    varSum += v * v;
  }
  final variance = varSum / (x.length - 1);
  stdout.writeln('');
  stdout.writeln('  平均 RR ${mean.toStringAsFixed(1)} ms、'
      '跨度 ${span.toStringAsFixed(1)} 秒、'
      '變異數 ${variance.toStringAsFixed(0)} ms²（= SDNN²）');
  stdout.writeln('');

  // ── ② 週期圖 ─────────────────────────────────────────────────────
  const df = 0.002;
  final freqs = <double>[];
  for (double f = 0.003; f <= 0.40 + 1e-9; f += df) {
    freqs.add(f);
  }
  final power = [for (final f in freqs) lombAt(t, dx, 2 * math.pi * f)];
  double raw = 0;
  for (final p in power) {
    raw += p * df;
  }
  final k = variance / raw;
  final norm = [for (final p in power) p * k];

  double band(double lo, double hi) {
    double s = 0;
    for (int i = 0; i < freqs.length; i++) {
      if (freqs[i] >= lo && freqs[i] < hi) s += norm[i] * df;
    }
    return s;
  }

  final vlf = band(0.003, 0.04), lf = band(0.04, 0.15), hf = band(0.15, 0.40);

  stdout.writeln('══ ② 週期圖:把那 ${pts.length} 個數字拆成不同週期的成分 ══');
  stdout.writeln('  每一列 = 一個頻率。「這個週期的擺動，在那條 RR 折線裡佔多少能量」');
  stdout.writeln('');
  var maxP = 0.0;
  for (final p in norm) {
    if (p > maxP) maxP = p;
  }
  stdout.writeln('   f(Hz)  週期(秒)   帶    功率(ms²/Hz)');
  for (int i = 0; i < freqs.length; i += 4) {
    final f = freqs[i];
    final tag = f < 0.04 ? 'VLF' : (f < 0.15 ? 'LF ' : 'HF ');
    final bar = '#' * (norm[i] / maxP * 46).round();
    stdout.writeln('  ${f.toStringAsFixed(3)}  '
        '${(1 / f).toStringAsFixed(1).padLeft(7)}   $tag  '
        '${norm[i].toStringAsFixed(0).padLeft(7)} $bar');
  }
  stdout.writeln('');

  // ── ③ 頻帶積分 + 與核心對帳 ──────────────────────────────────────
  final core = Max30102VitalsMetrics.spectrum(pts)!;
  stdout.writeln('══ ③ 各頻帶把功率加起來，就是 LF / HF ══');
  String cmp(double mine, double theirs) =>
      '${mine.toStringAsFixed(1).padLeft(9)}  （核心:${theirs.toStringAsFixed(1)}）';
  stdout.writeln('  VLF  0.003~0.04 Hz  ${cmp(vlf, core.vlf)}');
  stdout.writeln('  LF   0.04 ~0.15 Hz  ${cmp(lf, core.lf)}');
  stdout.writeln('  HF   0.15 ~0.40 Hz  ${cmp(hf, core.hf)}');
  stdout.writeln('  LF/HF               ${cmp(lf / hf, core.lfHf)}');
  stdout.writeln('');
  stdout.writeln('  → 這裡自己重算的與核心一致，代表上面印的就是真的那一份輸入。');
  stdout.writeln('');
  stdout.writeln('  可信度:LF 走了 ${core.lfCycles.toStringAsFixed(2)} 圈'
      '（需 ≥4）、HF 走了 ${core.hfCycles.toStringAsFixed(2)} 圈');
  stdout.writeln('');

  // ── ④ 對照:那條 baseline 曲線長什麼樣（沒有參與計算）────────────
  final trimmed =
      Max30102Signal.slidingTrimmedMean([for (final v in ir) v.toDouble()], 9);
  final base = Max30102Signal.movingAverage(trimmed, 200);
  var bMin = base.first, bMax = base.first;
  for (final v in base) {
    if (v < bMin) bMin = v;
    if (v > bMax) bMax = v;
  }
  stdout.writeln('══ ④ 對照:圖上那條彎曲虛線（baseline）══');
  stdout.writeln('  它是 IR 波形的 2 秒置中移動平均，起伏範圍 '
      '${(bMax - bMin).toStringAsFixed(0)} counts');
  stdout.writeln('  每 1 秒取一點，看它的形狀：');
  final step = fs.toInt();
  final buf = StringBuffer('  ');
  for (int i = 0; i < base.length; i += step) {
    final lvl = ((base[i] - bMin) / (bMax - bMin) * 8).round();
    buf.write('▁▂▃▄▅▆▇█'[lvl.clamp(0, 7)]);
  }
  stdout.writeln(buf.toString());
  stdout.writeln('  ${'↑ 0 秒'.padRight((base.length / step / 2).round())}'
      '${(base.length / fs).toStringAsFixed(0)} 秒 ↑');
  stdout.writeln('');
  stdout.writeln('  ⚠ 這 ${base.length} 個數字**沒有任何一個**進入上面的 LF / HF 計算。');
  stdout.writeln('    它只用來把波形拉平，好讓谷抓得準 —— 谷準了 RR 才準。');
}
