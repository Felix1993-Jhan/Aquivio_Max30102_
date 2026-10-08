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
//
// 全部用 feedSamples 直接餵核心，再把 K2FeedResult 轉交給 K2FixedWindow，
// 不經串口、不經協定封包、不開 widget。
// ============================================================================

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_config.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_core.dart';
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
      // 要填滿 30 秒的窗，得量 30 + 開頭那 3.4 秒（空轉 + 沉澱不輸出）。
      final rig = _Rig()..finger(35);
      final first = rig.fw.view(30);
      expect(first, isNotNull);
      expect(first!.sealed, isTrue, reason: '餵了 35 秒，30 秒的窗應該已經收滿');
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
      expect(v.pts.every((p) => p.startAbs >= rig.fw.base), isTrue);
      expect(v.pts.every((p) => p.endAbs <= rig.fw.base + 10 * kFs), isTrue);
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
      final rig = _Rig()..finger(35);
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
      expect(after.chartIr.length, pre + before.ir.length);
      expect(after.preMissing, isFalse);

      // 四段區塊：空轉 / 沉澱 / 方向判定 / 正常
      final kinds = after.bands.map((b) => b.kind).toList();
      expect(kinds.contains(K2HeadBand.dead), isTrue);
      expect(kinds.contains(K2HeadBand.settle), isTrue);
      expect(kinds.contains(K2HeadBand.orientWait), isTrue);
      // 區塊必須首尾相接且覆蓋整張圖
      expect(after.bands.first.from, 0);
      expect(after.bands.last.to, after.chartIr.length);
      for (int i = 1; i < after.bands.length; i++) {
        expect(after.bands[i].from, after.bands[i - 1].to);
      }
      // 谷標點要跟著平移到圖的座標
      for (final t in after.chartTroughs) {
        expect(t, greaterThanOrEqualTo(pre));
      }
    });
  });
}
