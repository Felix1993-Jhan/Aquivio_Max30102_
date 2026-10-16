// ============================================================================
// 公式帶入面板測試
// ============================================================================
// 這個面板存在的意義是「把送出去的數字攤開給人看」，所以最重要的只有一件事：
// **每一列的值必須就是 toStrapiJson() 裡同名欄位的值**。對不上的話，
// 畫面上講的推導就是另一份數字的推導，比沒有這個面板更糟。
// ============================================================================

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_hrv_calculator.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_vitals_metrics.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/ui/k2_formula_panel.dart';

/// 由一串 RR(ms) 組出連續的 HrvRrPoint(100 Hz 取樣 → 1 個樣本 = 10ms)。
List<HrvRrPoint> pointsOf(List<double> rr) {
  var at = 0;
  return [
    for (final r in rr)
      (() {
        final s = at;
        at += (r / 10).round();
        return (rr: r, startAbs: s, endAbs: at);
      })(),
  ];
}

VitalsMetrics metricsOf(List<double> rr, {bool withIr = true}) {
  final pts = pointsOf(rr);
  final hv = Max30102HrvCalculator.hrvFrom(pts);
  final bpm = hv?.meanHr;
  List<int>? ir;
  if (withIr && bpm != null) {
    // 10 秒、脈搏頻率的正弦 + 一點固定種子的雜訊 → snr_db 算得出來
    final rnd = math.Random(1);
    final f0 = bpm / 60;
    ir = [
      for (int i = 0; i < 1000; i++)
        (50000 +
                800 * math.sin(2 * math.pi * f0 * i / 100) +
                rnd.nextDouble() * 200)
            .round(),
    ];
  }
  return Max30102VitalsMetrics.compute(
    pts: pts,
    hv: hv,
    sqiOk: true,
    settling: false,
    bpm: bpm,
    ir: ir,
  );
}

/// 約 30 秒的正常休息 RR:平均 ~970ms,帶一點呼吸性起伏。
final normalRr = [
  for (int i = 0; i < 30; i++)
    970 + 45 * math.sin(i * 2 * math.pi / 5) + (i % 3) * 8,
];

void main() {
  group('k2FormulaRows', () {
    test('① 每一列的值必須就是 toStrapiJson() 裡同名欄位的值', () {
      for (final m in [
        metricsOf(normalRr),
        metricsOf(normalRr, withIr: false),
        metricsOf(normalRr.sublist(0, 5)), // 拍數不足
        metricsOf(const []), // 完全沒有資料
      ]) {
        final json = m.toStrapiJson();
        final rows = k2FormulaRows(m, beats: 30);
        for (final r in rows) {
          expect(json.containsKey(r.api), isTrue, reason: '${r.api} 不是送出的欄位');
          expect(r.value, json[r.api], reason: '${r.api} 與送出的值不同');
        }
      }
    });

    test('② 9 列、照依賴順序排,而且標出由誰帶入', () {
      final rows = k2FormulaRows(metricsOf(normalRr), beats: 30);
      expect(rows.map((r) => r.api).toList(), [
        'mean_hr',
        'sdnn',
        'rmssd',
        'lf_ms2',
        'hf_ms2',
        'lf_hf',
        'pns',
        'ans',
        'stress',
        'snr_db',
        'confidence',
      ]);
      Map<String, List<String>> inputs = {
        for (final r in rows) r.api: r.inputs,
      };
      expect(inputs['lf_hf'], ['lf_ms2', 'hf_ms2']);
      expect(inputs['pns'], ['rmssd']);
      expect(inputs['ans'], ['lf_hf']);
      expect(inputs['stress'], ['pns', 'ans']);
      expect(inputs['confidence'], [
        'snr_db',
      ], reason: '送出的 confidence 看 SNR,不是看拍數');
      // 正常資料每一列都要有值
      for (final r in rows) {
        expect(r.value, isNotNull, reason: r.api);
      }
    });

    test('③ 代入的中間量要能重現結果(stress = 兩項相加)', () {
      final m = metricsOf(normalRr);
      final pns = m.pnsScore!, ans = m.ansScore!;
      final stress = k2FormulaRows(
        m,
        beats: 30,
      ).firstWhere((r) => r.api == 'stress');
      final a = 0.6 * (100 - pns), b = 0.4 * ans;
      expect(a + b, closeTo(m.stressScore!, 1e-9));
      expect(stress.sub, contains(a.toStringAsFixed(1)));
      expect(stress.sub, contains(b.toStringAsFixed(1)));
    });

    test('⑥ LF、HF:比值對得上 lf_hf,三個頻帶加起來對得上 SDNN²', () {
      final m = metricsOf(normalRr);
      final rows = k2FormulaRows(m, beats: 30);
      final lf = rows.firstWhere((r) => r.api == 'lf_ms2').value as double;
      final hf = rows.firstWhere((r) => r.api == 'hf_ms2').value as double;
      expect(lf / hf, closeTo(m.lfHf!, 1e-12));
      final s = m.spectrum!;
      // 附註裡攤開的帳:VLF + LF + HF ≈ SDNN²(歸一化讓總和 = RR 變異數)
      expect(
        s.vlf + s.lf + s.hf,
        closeTo(m.sdnn! * m.sdnn!, m.sdnn! * m.sdnn! * 0.02),
      );
      // 兩列都要標明「不送給 LLM」
      for (final api in ['lf_ms2', 'hf_ms2']) {
        expect(
          rows.firstWhere((r) => r.api == api).notes.map((n) => n.key),
          contains('k2_fx_note_not_sent'),
        );
      }
    });

    test('④ 高 HRV 撞頂時要標出「夾到 100」', () {
      // 800 / 1100 交錯 → RMSSD ≈ 300ms,遠超過 PNS 量表的 80ms 端點
      final m = metricsOf([
        for (int i = 0; i < 30; i++) i.isEven ? 800.0 : 1100.0,
      ]);
      final pns = k2FormulaRows(m, beats: 30).firstWhere((r) => r.api == 'pns');
      expect(pns.value, 100);
      expect(pns.notes.map((n) => n.key), contains('k2_fx_note_clamp'));
    });

    test('⑤ 資料不足時要講原因,不可以只留空白', () {
      final rows = k2FormulaRows(metricsOf(normalRr.sublist(0, 5)), beats: 6);
      for (final api in ['mean_hr', 'sdnn', 'rmssd']) {
        final r = rows.firstWhere((e) => e.api == api);
        expect(r.value, isNull);
        expect(r.notes.map((n) => n.key), contains('k2_fx_na_beats'));
        expect(r.notes.first.params['n'], 6);
      }
      final pns = rows.firstWhere((e) => e.api == 'pns');
      expect(pns.notes.map((n) => n.key), contains('k2_fx_na_dep'));
    });
  });
}
