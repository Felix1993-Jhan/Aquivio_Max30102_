// ============================================================================
// resetOnFingerOff（免洗模式）行為測試
// ============================================================================
// 驗證四件事：
//   ① 開啟時：確認手指離開 → didReset=true 且 totalSamples 歸零，之後從 0 重新起算
//   ② 去彈跳仍然有效：批數不足 fingerOffBatches 時不得觸發歸零
//   ③ 不重複觸發：歸零後持續沒手指，不該一直回報 didReset
//   ④ 關閉時（預設）：行為與原本完全一致 —— 絕對索引繼續累加
//
// 全部用 feedSamples 直接餵，不經串口、不經協定封包。
// ============================================================================

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_config.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_core.dart';

const int kFs = Max30102Config.samplingRateHz; // 100
const int kBatch = 24; // 一批樣本數，比照實機一次 QUERY_FIFO 的量

/// 合成一批「有手指」的 PPG：IR 基線 90000（遠高於門檻 50000）+ 正弦搏動。
/// [startIndex] 是這批在整段訊號中的起點，用來維持相位連續。
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

/// 合成一批「沒手指」的資料：IR 低於門檻。
({List<int> red, List<int> ir}) noFingerBatch({int n = kBatch}) => (
      red: List<int>.filled(n, 1000),
      ir: List<int>.filled(n, 1000),
    );

/// 餵 [seconds] 秒的有手指資料；回傳餵完後的樣本索引（供下一段接續相位）。
int feedFinger(Max30102K2 k2, int seconds, {int from = 0}) {
  var idx = from;
  final batches = seconds * kFs ~/ kBatch;
  for (int i = 0; i < batches; i++) {
    final b = fingerBatch(idx);
    k2.feedSamples(b.red, b.ir);
    idx += kBatch;
  }
  return idx;
}

void main() {
  group('resetOnFingerOff = true（免洗模式）', () {
    test('確認手指離開 → didReset 且絕對索引歸零，之後從 0 重新起算', () {
      final k2 = Max30102K2(
        config: Max30102Config(resetOnFingerOff: true),
      );

      // ── ① 先量一段，確認真的有在跑 ──
      feedFinger(k2, 45);
      expect(k2.totalSamples, greaterThan(0), reason: '有手指時應累積樣本');
      expect(k2.bpm, isNotNull, reason: '45 秒 60bpm 合成訊號應算得出心率');
      expect(k2.bpm, closeTo(60, 3), reason: '合成訊號是 60bpm');

      // ── ② 手指離開：餵滿 fingerOffBatches 批 ──
      final off = noFingerBatch();
      var sawReset = false;
      for (int i = 0; i < k2.config.fingerOffBatches; i++) {
        final r = k2.feedSamples(off.red, off.ir);
        if (r.didReset) sawReset = true;
      }
      expect(sawReset, isTrue, reason: '確認離開時應回報 didReset');
      expect(k2.totalSamples, 0, reason: '免洗模式下絕對索引要歸零');
      expect(k2.latest?.fingerPresent, isFalse);

      // ── ③ 新的一次量測，索引從 0 附近重新起算 ──
      final b = fingerBatch(0);
      final r = k2.feedSamples(b.red, b.ir);
      expect(r.firstAbs, lessThan(kBatch),
          reason: '新測試的第一批應該從 0 附近開始，不是接在舊時間軸後面');
      expect(k2.totalSamples, lessThanOrEqualTo(kBatch));
    });

    test('去彈跳仍然有效：批數不足時不得歸零', () {
      final k2 = Max30102K2(
        config: Max30102Config(resetOnFingerOff: true, fingerOffBatches: 3),
      );
      feedFinger(k2, 10);
      final before = k2.totalSamples;
      expect(before, greaterThan(0));

      // 只餵 2 批（< fingerOffBatches=3）→ 單批雜訊不該讓整段重來
      final off = noFingerBatch();
      for (int i = 0; i < 2; i++) {
        final r = k2.feedSamples(off.red, off.ir);
        expect(r.didReset, isFalse, reason: '還沒過去彈跳門檻，不該歸零');
      }
      expect(k2.totalSamples, greaterThan(before),
          reason: '去彈跳期間絕對時間軸照走');
    });

    // ⚠️ 這個案例是端到端測試抓到的：原本只驗「觸發那一批」歸零，
    //    沒有模擬「手指拿開後放著」，結果索引又從 0 一路往上加。
    test('歸零後持續沒手指，索引必須停在 0（空檔不計入時間軸）', () {
      final k2 = Max30102K2(
        config: Max30102Config(resetOnFingerOff: true, fingerOffBatches: 3),
      );
      feedFinger(k2, 10);

      // 拿開手指後放著不動，模擬兩次量測之間的空檔
      final off = noFingerBatch();
      for (int i = 0; i < 100; i++) {
        k2.feedSamples(off.red, off.ir);
      }
      expect(k2.totalSamples, 0,
          reason: '沒人的空檔不屬於任何一次量測，索引不該累加');

      // 下一位使用者放手指 → 從 0 開始，與等了多久無關
      final b = fingerBatch(0);
      final r = k2.feedSamples(b.red, b.ir);
      expect(r.firstAbs, 0);
      expect(k2.totalSamples, kBatch);
    });

    test('兩次量測的 totalSamples 應該一致（真的從零開始）', () {
      final k2 = Max30102K2(
        config: Max30102Config(resetOnFingerOff: true),
      );
      feedFinger(k2, 30);
      final first = k2.totalSamples;

      final off = noFingerBatch();
      for (int i = 0; i < 50; i++) {
        k2.feedSamples(off.red, off.ir);
      }

      feedFinger(k2, 30);
      expect(k2.totalSamples, first,
          reason: '同樣餵 30 秒，第二次的總樣本數應該與第一次完全相同');
    });

    test('不重複觸發：歸零後持續沒手指，didReset 只回報一次', () {
      final k2 = Max30102K2(
        config: Max30102Config(resetOnFingerOff: true, fingerOffBatches: 3),
      );
      feedFinger(k2, 10);

      final off = noFingerBatch();
      var resetCount = 0;
      // 餵遠多於門檻的批數，模擬手指拿開後放著不動
      for (int i = 0; i < 30; i++) {
        if (k2.feedSamples(off.red, off.ir).didReset) resetCount++;
      }
      expect(resetCount, 1, reason: '只有「從有手指變成確認離開」那一次該回報');
    });
  });

  group('resetOnFingerOff = false（預設，交接核心的原行為）', () {
    test('手指離開不歸零，絕對索引繼續累加', () {
      final k2 = Max30102K2(); // 預設 config
      expect(k2.config.resetOnFingerOff, isFalse, reason: '預設必須是關閉');

      feedFinger(k2, 10);
      final before = k2.totalSamples;
      expect(before, greaterThan(0));

      final off = noFingerBatch();
      for (int i = 0; i < 30; i++) {
        final r = k2.feedSamples(off.red, off.ir);
        expect(r.didReset, isFalse, reason: '關閉時不該有任何歸零');
      }
      expect(k2.totalSamples, greaterThan(before),
          reason: '原行為:絕對索引持續累加，不歸零');
    });
  });
}
