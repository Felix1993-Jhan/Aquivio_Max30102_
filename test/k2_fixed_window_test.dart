// ============================================================================
// K2FixedWindow（定長量測）行為測試
// ============================================================================
// 驗證六件事：
//   ① 凍結後真的不變 —— 再餵 30 秒，view(30) 回傳同一個物件實例
//   ② 零點正確 —— base = 空轉 + 沉澱，且窗內沒有早於 base 的拍
//   ③ 與「何時打開開關」無關 —— 餵完才第一次呼叫，結果與每輪都呼叫相同
//   ④ 切 N 的單調性 —— view(10).pts 是 view(20).pts 的前綴
//   ⑤ 手指離開 —— 標記結束但資料留著；再放上才清空重收
//   ⑥ 開頭還原段只影響顯示，不影響計算
//   ⑦ 問題點：空洞區塊 = confidence 數到的空洞，兩端落在谷標點上
//   ⑧ 問題點：乾淨訊號沒有任何問題區塊
//   ⑨ 圖上的 IR = 核心 newIrWave，窗後接 110 筆前後文 → 最後一秒也完整
//   ⑩ 窗還沒收滿 → 沒有後文
//   ⑪ 窗從「計入」開始：判定段只顯示、不計入
//
// 全部用 feedSamples 直接餵核心，再把 K2FeedResult 轉交給 K2FixedWindow，
// 不經串口、不經協定封包、不開 widget。
// ============================================================================

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_config.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_core.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_signal.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/ui/k2_fixed_window.dart';

const int kFs = Max30102Config.samplingRateHz; // 100
const int kBatch = 24; // 比照實機一次 QUERY_FIFO 的量

/// 合成一批「有手指」的 PPG：IR 基線 90000（遠高於門檻 50000）+ 正弦搏動。
({List<int> red, List<int> ir}) fingerBatch(int startIndex,
    {double bpm = 60, int n = kBatch}) {
  final red = <int>[];
  final ir = <int>[];
  for (int k = 0; k < n; k++) {
    final ph = 2 * pi * (bpm / 60.0) * ((startIndex + k) / kFs);
    ir.add(90000 + (3000 * sin(ph)).round());
    red.add(60000 + (1500 * sin(ph)).round());
  }
  return (red: red, ir: ir);
}

({List<int> red, List<int> ir}) noFingerBatch({int n = kBatch}) => (
      red: List<int>.filled(n, 1000),
      ir: List<int>.filled(n, 1000),
    );

/// 一組「核心 + 定長窗」的測試台，接線方式與 K2SerialAdapter._onPacket 相同。
class _Rig {
  _Rig() : core = Max30102K2(config: Max30102Config(resetOnFingerOff: true));

  final Max30102K2 core;
  final K2FixedWindow fw = K2FixedWindow();
  int idx = 0;

  void _forward(K2FeedResult r) {
    fw.feed(
      firstAbs: r.firstAbs,
      newIr: r.newIr,
      newRed: r.newRed,
      computed: r.computed,
      didReset: r.didReset,
      cap: core.config.dataHistorySamples,
      deadSamples: core.config.fingerDeadSamples,
      settleSamples: core.config.settleSamples,
      waveFirstAbs: r.waveFirstAbs,
      newIrWave: r.newIrWave,
    );
  }

  /// 餵 [seconds] 秒有手指的資料。
  void finger(int seconds) {
    final batches = seconds * kFs ~/ kBatch;
    for (int i = 0; i < batches; i++) {
      final b = fingerBatch(idx);
      _forward(core.feedSamples(b.red, b.ir));
      idx += kBatch;
    }
  }

  /// 餵 [seconds] 秒沒手指的資料（足以觸發免洗歸零）。
  void noFinger(int seconds) {
    final batches = seconds * kFs ~/ kBatch;
    for (int i = 0; i < batches; i++) {
      _forward(core.feedSamples(noFingerBatch().red, noFingerBatch().ir));
      idx += kBatch;
    }
  }
}

void main() {
  group('K2FixedWindow', () {
    test('① 凍結後真的不變：再餵 30 秒，view 回傳同一個物件實例', () {
      // 要填滿 30 秒的窗，得量 30 + 開頭 3.4 秒（空轉 + 沉澱）+ 判定段（窗從計入才開始）。
      final rig = _Rig()..finger(38);
      final first = rig.fw.view(30);
      expect(first, isNotNull);
      expect(first!.sealed, isTrue, reason: '餵了 38 秒，30 秒的窗應該已經收滿');
      final rmssd = first.hv?.rmssd;
      final n = first.pts.length;

      rig.finger(30); // 再餵 30 秒

      final second = rig.fw.view(30);
      expect(identical(first, second), isTrue,
          reason: '輸入沒變 → memo 必須回傳同一個實例，這就是「真的凍結」');
      expect(second!.pts.length, n);
      expect(second.hv?.rmssd, rmssd);
      expect(second.ir.length, 30 * kFs);
    });

    test('② 零點 = 空轉 + 沉澱，且窗內沒有早於 base 的拍', () {
      final rig = _Rig()..finger(20);
      final cfg = rig.core.config;
      // 零點落在批次邊界上，不是正好 dead+settle（見 expectedPreSamples 的註解）。
      expect(rig.fw.base, greaterThanOrEqualTo(cfg.fingerDeadSamples));
      expect(rig.fw.base,
          lessThanOrEqualTo(cfg.fingerDeadSamples + cfg.settleSamples + kBatch));
      expect(rig.fw.base, rig.fw.expectedPreSamples);

      final v = rig.fw.view(10)!;
      expect(v.pts.every((p) => p.startAbs >= v.base), isTrue);
      expect(v.pts.every((p) => p.endAbs <= v.base + 10 * kFs), isTrue);
    });

    test('③ 與「何時打開開關」無關', () {
      // A：每一輪都呼叫 view（模擬開關一直開著）
      final a = _Rig();
      for (int s = 0; s < 25; s++) {
        a.finger(1);
        a.fw.view(10);
      }
      // B：餵完 25 秒才第一次呼叫（模擬中途才打開）
      final b = _Rig()..finger(25);

      final va = a.fw.view(10)!;
      final vb = b.fw.view(10)!;
      expect(vb.pts.length, va.pts.length);
      expect(vb.ir.length, va.ir.length);
      expect(vb.hv?.rmssd, va.hv?.rmssd);
      expect(vb.metrics.spectrum?.lf, va.metrics.spectrum?.lf);
    });

    test('④ 切 N 的單調性：短窗是長窗的前綴', () {
      final rig = _Rig()..finger(38);
      final v10 = rig.fw.view(10)!;
      final v20 = rig.fw.view(20)!;
      final v30 = rig.fw.view(30)!;

      expect(v10.pts.length, lessThanOrEqualTo(v20.pts.length));
      expect(v20.pts.length, lessThanOrEqualTo(v30.pts.length));
      for (int i = 0; i < v10.pts.length; i++) {
        expect(v10.pts[i].endAbs, v20.pts[i].endAbs);
      }
      expect(v10.ir, v30.ir.sublist(0, v10.ir.length));
    });

    test('⑤ 手指離開：標記結束但資料留著；再放上才清空重收', () {
      final rig = _Rig()..finger(20);
      final before = rig.fw.filledSamples;
      expect(before, greaterThan(0));

      rig.noFinger(2); // 足以越過去彈跳 → 核心歸零

      expect(rig.fw.ended, isTrue);
      // 去彈跳觀察期間（3 批）核心照收樣本，所以可能多幾筆；重點是「沒有被清掉」。
      expect(rig.fw.filledSamples, greaterThanOrEqualTo(before),
          reason: '資料必須留著，否則來不及存快照');
      expect(rig.fw.view(10), isNotNull);

      rig.idx = 0; // 下一位使用者
      rig.finger(20);

      expect(rig.fw.ended, isFalse);
      expect(rig.fw.base, greaterThan(0), reason: '新一次量測的零點要重新起算');
      expect(rig.fw.base,
          lessThanOrEqualTo(rig.core.config.fingerDeadSamples +
              rig.core.config.settleSamples +
              kBatch));
    });

    test('⑥ 還原的開頭段只影響顯示，不影響計算', () {
      final rig = _Rig()..finger(20);
      final before = rig.fw.view(10)!;

      final pre = rig.fw.expectedPreSamples;
      expect(pre, rig.fw.base, reason: '要還原的就是零點之前那一段'); 
      rig.fw.setPreRoll(
        List<int>.filled(pre, 70000),
        List<int>.filled(pre, 50000),
      );

      final after = rig.fw.view(10)!;
      expect(after.pts.length, before.pts.length);
      expect(after.ir, before.ir, reason: '計算用的切片不含還原段');
      expect(after.hv?.rmssd, before.hv?.rmssd);
      expect(after.chartIr.length, pre + before.chartIr.length);
      expect(after.preMissing, isFalse);

      // 四段區塊：空轉 / 沉澱 / 方向判定 / 正常
      final kinds = after.bands.map((b) => b.kind).toList();
      expect(kinds.contains(K2HeadBand.dead), isTrue);
      expect(kinds.contains(K2HeadBand.settle), isTrue);
      expect(kinds.contains(K2HeadBand.orientWait), isTrue);
      // 流程階段的區塊必須首尾相接且覆蓋整張圖(問題點區塊是疊在上面的,不算)
      final stage = [
        for (final b in after.bands)
          if (b.kind != K2HeadBand.gap && b.kind != K2HeadBand.sqiBad) b,
      ];
      expect(stage.first.from, 0);
      expect(stage.last.to, after.chartIr.length);
      for (int i = 1; i < stage.length; i++) {
        expect(stage[i].from, stage[i - 1].to);
      }
      // 谷標點要跟著平移到圖的座標
      for (final t in after.chartTroughs) {
        expect(t, greaterThanOrEqualTo(pre));
      }
    });

    test('⑦ 問題點:空洞區塊與 confidence 的空洞是同一批,位置對得上谷標點', () {
      // 中間插 3 秒「手指在、但沒有脈搏」的平線 → 那段抓不到谷 → 留下空洞
      final rig = _Rig()..finger(12);
      for (int i = 0; i < 3 * kFs ~/ kBatch; i++) {
        rig._forward(rig.core.feedSamples(
          List<int>.filled(kBatch, 60000),
          List<int>.filled(kBatch, 90000),
        ));
        rig.idx += kBatch;
      }
      rig.finger(10);

      final v = rig.fw.view(15)!;
      final gaps = [
        for (final b in v.bands)
          if (b.kind == K2HeadBand.gap) b,
      ];
      expect(gaps.length, v.metrics.rrGaps, reason: '畫出幾塊 = confidence 數到幾個');
      expect(gaps, isNotEmpty, reason: '3 秒沒脈搏一定會掉拍');
      // 可信度照規則走:異常(空洞 + SQI)≤ 1 且拍數夠才 good
      final m = v.metrics;
      expect(m.anomalies, m.rrGaps + (m.sqiOk ? 0 : 1));
      expect(
        m.confidenceByPulse,
        m.anomalies <= 1 && m.beats >= m.minBeatsNeeded ? 'good' : 'very rough',
      );
      // 空洞兩端都正好落在谷標點上(前一拍終谷、後一拍起谷)
      for (final g in gaps) {
        expect(v.chartTroughs, contains(g.from));
        expect(v.chartTroughs, contains(g.to));
        expect(g.to, greaterThan(g.from));
      }
    });

    test('⑨ 圖上的 IR = 核心 newIrWave,且窗後接 110 筆前後文 → 最後一秒也完整', () {
      const tail = 110;
      final rig = _Rig()..finger(20);
      final v = rig.fw.view(10, tail: tail)!;
      expect(v.sealed, isTrue);
      expect(v.tailLen, tail, reason: '窗收滿而且後面資料夠 → 接滿 110 筆');
      final preLen = v.chartIr.length - v.ir.length - v.tailLen;

      // 後文只是顯示:計算用的切片、拍、數值都不含它
      expect(v.ir.length, 10 * kFs);
      expect(v.pts.every((p) => p.endAbs <= v.base + 10 * kFs), isTrue);

      // 窗內每一筆都有核心給的值,而且等於「事後對整段原始值算」的結果
      final all = <double>[];
      for (int i = 0; i < rig.idx; i += kBatch) {
        all.addAll([for (final x in fingerBatch(i).ir) x.toDouble()]);
      }
      final truth = Max30102Signal.troughLine(
        all,
        trimWindow: Max30102Config.trimWindow,
        baselineWindow: Max30102Signal.baselineWindow(kFs, 0.5),
        lowpassWindow: Max30102Signal.lowpassWindow(kFs, 4.0),
      );
      for (int k = 0; k < 10 * kFs; k++) {
        final got = v.chartWave[preLen + k];
        expect(got, isNotNull, reason: '窗內第 $k 筆還沒有核心的值');
        expect(got!, closeTo(truth[v.base + k], 1e-6), reason: '第 $k 筆');
      }

      // 後文區塊:接在窗後、蓋到圖的最右邊
      final t = v.bands.where((b) => b.kind == K2HeadBand.tail).toList();
      expect(t, hasLength(1));
      expect(t.single.from, preLen + 10 * kFs);
      expect(t.single.to, v.chartIr.length);
    });

    test('⑪ 窗從「計入」開始:判定段只顯示、不計入', () {
      final rig = _Rig()..finger(20);
      final v = rig.fw.view(10)!;
      final release = rig.fw.base + rig.fw.firstBatchLen; // 計入
      expect(rig.fw.firstBatchLen, greaterThan(0));
      expect(v.base, release, reason: '窗的第 0 筆 = 計入那一刻');
      expect(v.pts.every((p) => p.startAbs >= release), isTrue,
          reason: '判定段的拍不進 HRV / 可信度');
      // 判定段在圖上:緊接在還原段之後、窗之前
      final head = v.chartIr.length - v.ir.length - v.tailLen;
      final o = v.bands.where((b) => b.kind == K2HeadBand.orientWait).single;
      expect(o.to, head, reason: '判定段結束 = 窗開始');
      expect(o.to - o.from, rig.fw.firstBatchLen);
    });

    test('⑩ 窗還沒收滿 → 沒有後文(窗的右緣就是「現在」)', () {
      final rig = _Rig()..finger(8);
      final v = rig.fw.view(10, tail: 110)!;
      expect(v.sealed, isFalse);
      expect(v.tailLen, 0);
      expect(v.bands.where((b) => b.kind == K2HeadBand.tail), isEmpty);
    });

    test('⑧ 問題點:乾淨訊號沒有任何問題區塊,可信度 good', () {
      final rig = _Rig()..finger(20);
      final v = rig.fw.view(15)!;
      expect(
        v.bands.where(
          (b) => b.kind == K2HeadBand.gap || b.kind == K2HeadBand.sqiBad,
        ),
        isEmpty,
      );
      expect(v.sqiOkRounds, v.rounds);
      expect(v.metrics.confidenceByPulse, 'good');
    });
  });
}
