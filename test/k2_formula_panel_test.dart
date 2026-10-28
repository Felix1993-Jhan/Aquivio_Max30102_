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
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/ui/k2_drink_preview.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/ui/k2_field_help.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/ui/k2_formula_panel.dart';
import 'package:flutter_firmware_tester_unified/shared/services/localization_service.dart';
import 'package:flutter_firmware_tester_unified/shared/ui/glass.dart';
import 'package:flutter/material.dart';

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
        'lf',
        'hf',
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
        'sqi',
        'RR',
      ], reason: '送出的 confidence 看 SQI + 拍數 + RR 空洞(v0.0.0.7),不是看 SNR');
      // 深色(LLM 看得到)的剛好是提示詞印出的那 8 個,其餘都是中間量
      expect(
        [
          for (final r in rows)
            if (r.llm) r.api,
        ],
        [
          'mean_hr',
          'sdnn',
          'rmssd',
          'lf_hf',
          'pns',
          'ans',
          'stress',
          'confidence',
        ],
      );
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

    test('⑦ lf / hf = ms² 值 × 1e-6 × 1024(畫面寫的換算必須就是核心用的)', () {
      final m = metricsOf(normalRr);
      final rows = k2FormulaRows(m, beats: 30);
      double v(String api) =>
          rows.firstWhere((r) => r.api == api).value as double;
      expect(v('lf'), closeTo(v('lf_ms2') * 1e-6 * 1024, 1e-12));
      expect(v('hf'), closeTo(v('hf_ms2') * 1e-6 * 1024, 1e-12));
      // 比值不受單位影響
      expect(v('lf') / v('hf'), closeTo(m.lfHf!, 1e-12));
    });

    test('⑧ 每一列的「?」說明視窗:必填段落兩種語言都要有', () {
      final rows = k2FormulaRows(metricsOf(normalRr), beats: 30);
      final loc = LocalizationService();
      final before = loc.currentLanguage;
      try {
        for (final lang in AppLanguage.values) {
          loc.setLanguage(lang);
          for (final r in rows) {
            for (final s in k2HelpRequired) {
              final k = k2HelpKey(r.api, s);
              expect(tr(k), isNot(k), reason: '$lang 缺 $k');
            }
          }
          for (final s in k2HelpSections) {
            expect(tr('k2_help_sec_$s'), isNot('k2_help_sec_$s'));
          }
        }
      } finally {
        loc.setLanguage(before);
      }
    });

    testWidgets('⑨ 每一個「?」視窗都打得開(玻璃開 / 關),不會排版爆掉', (tester) async {
      final rows = k2FormulaRows(metricsOf(normalRr), beats: 30);
      final glassBefore = globalGlassNotifier.value;
      try {
        for (final glass in [true, false]) {
          globalGlassNotifier.value = glass;
          for (final r in rows) {
            await tester.pumpWidget(
              MaterialApp(
                home: Builder(
                  builder: (ctx) => TextButton(
                    onPressed: () => showK2FieldHelp(ctx, r),
                    child: const Text('open'),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('open'));
            await tester.pumpAndSettle();
            expect(find.text(r.api), findsOneWidget, reason: r.api);
            expect(tester.takeException(), isNull, reason: r.api);
            Navigator.of(tester.element(find.text(r.api))).pop();
            await tester.pumpAndSettle();
          }
        }
      } finally {
        globalGlassNotifier.value = glassBefore;
      }
    });

    testWidgets('⑩ 視窗的深色框帶入這一筆的數字,而且跟著更新、沒資料時不清空', (tester) async {
      final a = k2FormulaRows(metricsOf(normalRr), beats: 30);
      final b = k2FormulaRows(
        metricsOf([for (final r in normalRr) r * 0.8]), // 心率變快的另一筆
        beats: 30,
      );
      final tick = ValueNotifier(0);
      List<K2FormulaRow>? current = a;
      K2FormulaRow row(List<K2FormulaRow> rs) =>
          rs.firstWhere((r) => r.api == 'mean_hr');

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showK2FieldHelp(
                ctx,
                row(a),
                listenable: tick,
                liveRows: () => current,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(row(a).sub!), findsOneWidget, reason: '代入的數字要在框裡');
      expect(find.text(row(a).result), findsOneWidget);

      current = b; // 頁面重算 → 通知
      tick.value++;
      await tester.pumpAndSettle();
      expect(find.text(row(b).result), findsOneWidget, reason: '要跟著更新');
      expect(find.text(row(a).result), findsNothing);

      current = null; // 手指離開、沒資料
      tick.value++;
      await tester.pumpAndSettle();
      expect(find.text(row(b).result), findsOneWidget, reason: '沒資料時停在上一份');
    });

    test('⑪ 投票欄:8 個 LLM 欄位都有一票,中間量沒有,而且與 ② 同一份', () {
      final m = metricsOf(normalRr);
      final drink = K2DrinkPreview.from(m.toStrapiJson());
      final votes = k2VotesByApi(drink);
      final rows = k2FormulaRows(m, beats: 30);
      for (final r in rows) {
        expect(votes.containsKey(r.api), r.llm, reason: '${r.api}:LLM 欄位才有投票');
      }
      // 對應表沒有漏:② 的每一票都對得到面板上的某一列
      expect(votes.length, drink.votes.length);
      for (final v in drink.votes) {
        expect(votes.values, contains(v));
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
