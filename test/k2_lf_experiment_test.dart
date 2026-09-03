// ============================================================================
// K2LfExperiment 的驗證測試
// ============================================================================
// 這個錄製器有兩個「安靜地壞掉」的風險,兩個都必須有測試釘著:
//
//   ① 去重 —— 相鄰兩輪的 rrPoints 高度重疊(核心視窗只滑動一點)。
//      漏了去重就會把同一拍收很多次,RR 序列被灌水,頻譜整個歪掉而且不報錯。
//
//   ② 核心歸零 —— 免洗模式下手指一離開,絕對索引歸零。硬接兩段時間軸
//      會算出一個看起來正常、實際上沒有意義的數字。必須中止,不是接下去。
// ============================================================================

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_hrv_calculator.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/ui/k2_lf_experiment.dart';

const int fs = 100;

/// 合成一整段 RR(帶絕對位置),平均 850ms + 0.1Hz 振盪。
List<HrvRrPoint> series(double seconds, {int fromAbs = 0}) {
  final pts = <HrvRrPoint>[];
  int abs = fromAbs;
  double t = 0;
  while (t < seconds) {
    final rr = 850 + 40 * math.sin(2 * math.pi * 0.1 * t);
    final n = (rr / 1000 * fs).round();
    pts.add((rr: n * 1000.0 / fs, startAbs: abs, endAbs: abs + n));
    abs += n;
    t = (abs - fromAbs) / fs;
  }
  return pts;
}

/// 模擬核心的行為:在 [totalSamples] 這一刻,核心手上的 rrPoints 是
/// 「終谷落在最近 30 秒內」的那些拍。
List<HrvRrPoint> coreWindowAt(List<HrvRrPoint> all, int totalSamples) {
  final lo = totalSamples - 30 * fs;
  return [
    for (final p in all)
      if (p.endAbs > lo && p.endAbs <= totalSamples) p,
  ];
}

/// 把整段錄製「播放」給實驗器,每 [stepMs] 毫秒餵一輪(模擬核心每秒算一次)。
///
/// [fromSec] 是餵料的起始時刻 —— 實驗如果從第 N 秒才開始錄,餵進去的
/// `totalSamples` 也必須從 N 秒起算(現實中核心的計數器只會遞增)。
void playback(
  K2LfExperiment exp,
  List<HrvRrPoint> all, {
  int seconds = 120,
  int fromSec = 0,
  int stepMs = 1000,
}) {
  final step = stepMs * fs ~/ 1000;
  for (int t = fromSec * fs + step; t <= seconds * fs; t += step) {
    exp.feed(coreWindowAt(all, t), t);
  }
}

void main() {
  test('★ 去重:相鄰輪次高度重疊,但每一拍只能收一次', () {
    final all = series(120);
    final exp = K2LfExperiment()..start(0);
    playback(exp, all);

    // 錄製期間核心視窗滑過的拍數 = 整段的拍數(扣掉最後不足一輪的)
    expect(exp.collectedBeats, lessThanOrEqualTo(all.length),
        reason: '收到的拍數不可能超過實際存在的拍數 —— 超過就是重複收了');
    expect(exp.collectedBeats, greaterThan(all.length * 0.9),
        reason: '也不該漏掉太多');

    // 終谷必須嚴格遞增(有重複就會違反)
    final r = exp.result!;
    expect(r.totalBeats, exp.collectedBeats + 1);
  });

  test('★ 核心歸零 → 中止並標明原因,不把兩段時間軸接起來', () {
    final all = series(120);
    final exp = K2LfExperiment()..start(0);

    // 先正常餵 40 秒
    playback(exp, all, seconds: 40);
    expect(exp.running, isTrue);
    expect(exp.collectedBeats, greaterThan(30));

    // 免洗模式歸零:totalSamples 突然倒退回小數字
    final fresh = series(10);
    exp.feed(coreWindowAt(fresh, 5 * fs), 5 * fs);

    expect(exp.running, isFalse, reason: '偵測到歸零必須停下來');
    expect(exp.abortReason, 'reset');
    expect(exp.result, isNull, reason: '中止的實驗不該產出結果');
  });

  test('錄滿 2 分鐘 → 產出基準 + 10 個滑動窗', () {
    final all = series(125); // 多錄一點,確保餵得滿 120 秒
    final exp = K2LfExperiment()..start(0);
    playback(exp, all, seconds: 125);

    expect(exp.running, isFalse);
    expect(exp.abortReason, isNull);

    final r = exp.result!;
    // s = 0,10,...,90 → 10 個窗
    expect(r.windows, hasLength(10));
    expect(r.windows.first.startSec, 0);
    expect(r.windows.last.endSec, 120);

    // 基準是 2 分鐘 → LF 可用;每個 30 秒窗 → LF 不可用
    expect(r.baseline.lfUsable, isTrue);
    for (final w in r.windows) {
      expect(w.spec.lfUsable, isFalse,
          reason: '30 秒窗的 LF 一律不可信 —— 這正是實驗要證明的事');
      expect(w.spec.spanSeconds, closeTo(30, 2));
    }
  });

  test('偏差統計算得出來', () {
    final all = series(125);
    final exp = K2LfExperiment()..start(0);
    playback(exp, all, seconds: 125);
    final r = exp.result!;

    expect(r.medianAbsDevPct, isNotNull);
    expect(r.minAbsDevPct!, lessThanOrEqualTo(r.medianAbsDevPct!));
    expect(r.medianAbsDevPct!, lessThanOrEqualTo(r.maxAbsDevPct!));
    expect(r.windowsWithin20pct, inInclusiveRange(0, r.windows.length));
  });

  test('取消 → 停止且不產結果', () {
    final all = series(120);
    final exp = K2LfExperiment()..start(0);
    playback(exp, all, seconds: 30);
    exp.cancel();
    expect(exp.running, isFalse);
    expect(exp.abortReason, 'cancelled');
    expect(exp.result, isNull);
  });

  test('未開始時 feed 不會有任何作用', () {
    final exp = K2LfExperiment();
    exp.feed(series(30), 30 * fs);
    expect(exp.collectedBeats, 0);
    expect(exp.running, isFalse);
  });

  test('clear 回到乾淨狀態', () {
    final all = series(125);
    final exp = K2LfExperiment()..start(0);
    playback(exp, all, seconds: 125);
    expect(exp.result, isNotNull);

    exp.clear();
    expect(exp.result, isNull);
    expect(exp.collectedBeats, 0);
    expect(exp.elapsedSeconds, 0);
    expect(exp.abortReason, isNull);
  });

  group('歷次結果', () {
    /// 跑完一整段錄製,回傳實驗器。[fromSec] 讓多次錄製接在同一條時間軸上
    /// (現實中核心的 totalSamples 只會遞增)。
    void runOnce(K2LfExperiment exp, int fromSec) {
      exp.start(fromSec * fs);
      playback(exp, series(fromSec + 125, fromAbs: 0),
          seconds: fromSec + 125, fromSec: fromSec);
    }

    test('★ clear() 不能洗掉歷史 —— 「再測一次」的用意就是要留著前幾次', () {
      final exp = K2LfExperiment();
      runOnce(exp, 0);
      expect(exp.history, hasLength(1));

      exp.clear();
      expect(exp.result, isNull, reason: '當次結果要清掉');
      expect(exp.history, hasLength(1), reason: '但歷史必須留著');

      runOnce(exp, 130);
      expect(exp.history, hasLength(2));
      expect(exp.history[0].index, 1);
      expect(exp.history[1].index, 2);
    });

    test('clearHistory 才是整批丟掉', () {
      final exp = K2LfExperiment();
      runOnce(exp, 0);
      exp.clearHistory();
      expect(exp.history, isEmpty);
    });

    test('中止的錄製不進歷史', () {
      final exp = K2LfExperiment()..start(0);
      playback(exp, series(125), seconds: 40);
      exp.cancel();
      expect(exp.history, isEmpty, reason: '沒錄完就沒有結果,不該留下記錄');
    });

    test('跨次範圍:少於 2 次時 medianDevRange 仍算得出來,空的時候回 null', () {
      final exp = K2LfExperiment();
      expect(exp.baselineRange, isNull);
      expect(exp.medianDevRange, isNull);

      runOnce(exp, 0);
      final b = exp.baselineRange!;
      expect(b.$1, closeTo(b.$2, 1e-9), reason: '只有一次 → 最小=最大');

      runOnce(exp, 130);
      final b2 = exp.baselineRange!;
      expect(b2.$1, lessThanOrEqualTo(b2.$2));
    });
  });

  test('★ 錄製開始前的舊拍不會被收進來', () {
    // 機器已經跑了 60 秒(核心視窗裡有一堆舊拍),這時才按下開始錄製。
    final all = series(180);
    final exp = K2LfExperiment()..start(60 * fs);
    playback(exp, all, seconds: 120, fromSec: 60);

    expect(exp.points, isNotEmpty);
    for (final p in exp.points) {
      expect(p.startAbs, greaterThanOrEqualTo(60 * fs),
          reason: '按下開始之前的拍屬於上一段,不該混進這次錄製');
    }
    // 從 60 秒錄到 120 秒 = 只錄了 60 秒 → 還沒錄滿
    expect(exp.elapsedSeconds, closeTo(60, 2));
    expect(exp.running, isTrue, reason: '只過了 60 秒,還沒錄滿 120');
  });
}
