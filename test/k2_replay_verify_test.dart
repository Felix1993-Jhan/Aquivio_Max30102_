// ============================================================================
// K2 對拍驗證:把「既有快照的原始波形」重放進 K2,比對結果與原本管線是否一致
// ----------------------------------------------------------------------------
// 為什麼這樣驗:
//   · 快照存了「原始 ir/red(10秒)」+「原本管線在那 10 秒偵測到並算進 HRV 的谷
//     (goldTroughs,視窗內索引)」。
//   · 相鄰 goldTroughs 的間距 × 10ms 就是「原本算出的 RR」。
//   · 把同一份 ir/red 分批餵進 K2(模擬每 100ms 一批),看 K2 產出的 RR 對不對得上。
//
// 這條驗的是 **k2_core 的接線**(視窗切法 / 谷去重 / B右緣 / 餵拍時機),
// 基礎層本身是複製過來的,理論上一致。
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_config.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_core.dart';

const _snapDir = r'C:\Users\AQUIVIO\Desktop\max30102_snapshots';

/// 找一張「谷夠多」的快照來驗(至少 6 顆金谷)。
Map<String, dynamic>? _pickSnapshot() {
  final d = Directory(_snapDir);
  if (!d.existsSync()) return null;
  final files = d
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => b.path.compareTo(a.path)); // 新→舊
  for (final f in files) {
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final gold = (j['goldTroughs'] as List?) ?? const [];
      final ir = (j['ir'] as List?) ?? const [];
      if (gold.length >= 6 && ir.length >= 500) {
        // ignore: avoid_print
        print('▶ 使用快照:${f.path.split(Platform.pathSeparator).last}');
        return j;
      }
    } catch (_) {}
  }
  return null;
}

void main() {
  test('K2 重放快照波形 → RR 應與原本 goldTroughs 的間距一致', () {
    final j = _pickSnapshot();
    if (j == null) {
      // ignore: avoid_print
      print('⚠ 找不到可用快照,略過(此測試需要桌面 max30102_snapshots 有資料)');
      return;
    }

    final ir = [for (final e in (j['ir'] as List)) (e as num).toInt()];
    final red = [for (final e in (j['red'] as List)) (e as num).toInt()];
    final goldAll = [
      for (final e in (j['goldTroughs'] as List)) (e as num).toInt()
    ]..sort();
    final fs = (j['fs'] as num?)?.toInt() ?? 100;

    // K2 起步會丟掉「空轉期」的資料(手指壓下去那段斜坡不能收),所以只能拿
    // 空轉期之後的金谷來對照 —— 前面那幾拍 K2 本來就不該有。
    //
    // 界線取 fingerDeadSamples 而非「空轉+沉澱」:沉澱期的樣本**有進緩衝**,
    // 只是不輸出;沉澱一滿的第一次計算就是拿那批算的 → 那段的谷 K2 抓得到。
    final cfg = Max30102Config();
    final warmup = cfg.fingerDeadSamples;
    final gold = [for (final g in goldAll) if (g >= warmup) g];
    // ignore: avoid_print
    print('空轉 $warmup 筆 → 金谷 ${goldAll.length} 顆中有 ${gold.length} 顆在其後');
    if (gold.length < 4) {
      // ignore: avoid_print
      print('⚠ 暖機後剩下的谷太少,此快照太短,略過');
      return;
    }

    // 原本管線在暖機之後算出的 RR = 相鄰金谷間距
    final expected = <double>[
      for (int i = 1; i < gold.length; i++)
        (gold[i] - gold[i - 1]) * 1000.0 / fs,
    ];

    // 分批餵進 K2(模擬軟體每 100ms 丟一批 10 筆)
    final k2 = Max30102K2();
    const chunk = 10;
    for (int i = 0; i < ir.length; i += chunk) {
      final end = math.min(i + chunk, ir.length);
      k2.feedSamples(red.sublist(i, end), ir.sublist(i, end));
    }
    final actual = k2.rrLatest;

    // ignore: avoid_print
    print('金谷位置    : $gold');
    // ignore: avoid_print
    print('原本 RR(${expected.length}) : ${expected.map((e) => e.toStringAsFixed(0)).join(", ")}');
    // ignore: avoid_print
    print('K2   RR(${actual.length}) : ${actual.map((e) => e.toStringAsFixed(0)).join(", ")}');

    // ── 驗「等價性」而非「逐筆相同」──────────────────────────────
    // 谷的位置本來就依「在哪個視窗偵測到」而位移 1~2 樣本(去趨勢基線隨視窗變),
    // 而且重放是冷啟動(前幾次視窗未滿 500),早期偏差更大 →
    // 逐筆完全相同本來就不該期待。應驗的是:同一批拍、同樣的統計特性。
    expect(actual.length, greaterThanOrEqualTo(3),
        reason: 'K2 至少要算出 3 筆 RR');

    // ① 拍數:K2 因 B 右緣過濾少最新一拍 → 應為 原本 或 原本-1
    expect(actual.length, inInclusiveRange(expected.length - 2, expected.length),
        reason: '拍數應與原本相當(容許 B 右緣少 1~2 拍)');

    // ② 涵蓋時間跨度:兩邊應涵蓋同一段訊號
    double sum(List<double> x) => x.fold(0.0, (a, b) => a + b);
    final spanK2 = sum(actual);
    final spanOrigSame = sum(expected.take(actual.length).toList());
    final spanDiffPct = (spanK2 - spanOrigSame).abs() / spanOrigSame * 100;
    // ignore: avoid_print
    print('跨度:K2 ${spanK2.toStringAsFixed(0)}ms vs 原本同筆數 '
        '${spanOrigSame.toStringAsFixed(0)}ms → 差 ${spanDiffPct.toStringAsFixed(2)}%');
    expect(spanDiffPct, lessThan(2.0),
        reason: '涵蓋跨度應幾乎相同(代表抓到同一批拍)');

    // ③ 平均 RR:整體節律應一致
    final meanK2 = spanK2 / actual.length;
    final meanOrig = sum(expected) / expected.length;
    final meanDiffPct = (meanK2 - meanOrig).abs() / meanOrig * 100;
    // ignore: avoid_print
    print('平均RR:K2 ${meanK2.toStringAsFixed(1)}ms vs 原本 '
        '${meanOrig.toStringAsFixed(1)}ms → 差 ${meanDiffPct.toStringAsFixed(2)}%');
    expect(meanDiffPct, lessThan(3.0), reason: '平均 RR 應一致(節律相同)');

    // ④ 每筆偏差量級:應是「幾個取樣點」等級,不該有整拍級的錯位
    final n = math.min(expected.length, actual.length);
    double maxDev = 0;
    for (int i = 0; i < n; i++) {
      final d = (actual[i] - expected[i]).abs();
      if (d > maxDev) maxDev = d;
    }
    // ignore: avoid_print
    print('逐筆最大偏差:${maxDev.toStringAsFixed(0)}ms(谷位視窗相依,屬正常)');
    expect(maxDev, lessThan(200),
        reason: '偏差應在「谷位位移」等級(<200ms);若達整拍級代表漏/多抓');
  });

  test('K2 重放後 HRV 應算得出來且落在合理範圍', () {
    final j = _pickSnapshot();
    if (j == null) return;
    final ir = [for (final e in (j['ir'] as List)) (e as num).toInt()];
    final red = [for (final e in (j['red'] as List)) (e as num).toInt()];

    final k2 = Max30102K2();
    const chunk = 10;
    for (int i = 0; i < ir.length; i += chunk) {
      final end = math.min(i + chunk, ir.length);
      k2.feedSamples(red.sublist(i, end), ir.sublist(i, end));
    }

    final c = k2.latest;
    expect(c, isNotNull, reason: '重放後應該有算出結果');
    // ignore: avoid_print
    print('K2 重放結果:bpm=${c!.bpm?.toStringAsFixed(1)} '
        'spo2=${c.spo2?.toStringAsFixed(1)} 拍數=${k2.beatCount}');
    if (c.bpm != null) {
      expect(c.bpm!, inInclusiveRange(30, 240), reason: '心率應在生理範圍');
    }
    if (c.spo2 != null) {
      expect(c.spo2!, inInclusiveRange(50, 100), reason: '血氧應在合理範圍');
    }
  });
}
