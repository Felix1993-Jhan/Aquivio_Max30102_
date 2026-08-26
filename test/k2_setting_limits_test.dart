// ============================================================================
// 設定監督(k2_setting_limits)測試
// ----------------------------------------------------------------------------
// 驗兩件事:
//   ① 每條限制真的會把壞值夾回來(而且不是夾成另一個壞值)
//   ② check() 絕對不改原本的 config —— 它只是報告
// ============================================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_config.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_core.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_setting_limits.dart';

void main() {
  test('預設值本身完全合法 → enforce 不該改任何東西', () {
    final c = Max30102Config();
    final issues = Max30102SettingLimits.enforce(c);
    expect(issues, isEmpty, reason: '出廠預設值不該觸發任何夾值:\n'
        '${Max30102SettingLimits.format(issues)}');
  });

  test('hrMin=0 會讓 bandLowHz=0 → 除以零;必須被夾住', () {
    final c = Max30102Config(hrMin: 0);
    Max30102SettingLimits.enforce(c);
    expect(c.hrMin, greaterThanOrEqualTo(Max30102SettingLimits.hrLo));
    expect(c.bandLowHz, greaterThan(0), reason: 'bandLowHz 為 0 會讓 fs/0 丟例外');
  });

  test('hrMin / hrMax 寫反 → 夾完必須 hrMax > hrMin', () {
    final c = Max30102Config(hrMin: 240, hrMax: 30);
    final issues = Max30102SettingLimits.enforce(c);
    expect(c.hrMax, greaterThan(c.hrMin),
        reason: '寫反時 RR 上限會小於下限 → 所有拍被剔光');
    expect(issues.any((e) => e.field == 'hrMax'), isTrue);
    // 夾完的組合必須真的能用:RR 下限 < RR 上限
    expect(60000 / c.hrMax, lessThan(60000 / c.hrMin));
  });

  test('各項超出範圍都會被夾回合法區間', () {
    final c = Max30102Config(
      fingerThreshold: 999999, // > 18-bit
      promRatio: -1, // ≤0
      ledCurrentRed: 300, // > 8-bit
      ledCurrentIr: -5,
      fingerDeadMs: 99999, // > 2s
      dataHistoryMs: 1000, // 湊不到 9 拍
      fingerOffBatches: 0, // 沒有去彈跳
      spo2SmoothFactor: 5, // EMA 發散
      hrSmoothFactor: -2,
    );
    final issues = Max30102SettingLimits.enforce(c);
    // ignore: avoid_print
    print(Max30102SettingLimits.format(issues));

    expect(c.fingerThreshold,
        inInclusiveRange(Max30102SettingLimits.fingerThresholdMin,
            Max30102SettingLimits.fingerThresholdMax));
    expect(c.promRatio, greaterThanOrEqualTo(Max30102SettingLimits.promRatioMin));
    expect(c.ledCurrentRed, inInclusiveRange(0, 255));
    expect(c.ledCurrentIr, inInclusiveRange(0, 255));
    expect(c.fingerDeadMs,
        inInclusiveRange(0, Max30102SettingLimits.fingerDeadMsMax));
    expect(c.dataHistoryMs,
        greaterThanOrEqualTo(Max30102SettingLimits.dataHistoryMsMin));
    expect(c.fingerOffBatches, greaterThanOrEqualTo(1));
    expect(c.spo2SmoothFactor, inInclusiveRange(0.0, 1.0));
    expect(c.hrSmoothFactor, inInclusiveRange(0.0, 1.0));
  });

  test('computeEvery 不得大於固定的 computeWindow(否則會整段樣本沒被分析)', () {
    final c = Max30102Config(computeEvery: 9999);
    Max30102SettingLimits.enforce(c);
    expect(c.computeEvery,
        lessThanOrEqualTo(Max30102Config.computeWindow));
    expect(c.computeEvery,
        greaterThanOrEqualTo(Max30102Config.minComputeEvery));
  });

  test('check() 只回報、絕不修改原本的 config', () {
    final c = Max30102Config(hrMin: 0, hrMax: 0, promRatio: -1);
    final before = (c.hrMin, c.hrMax, c.promRatio);
    final issues = Max30102SettingLimits.check(c);

    expect((c.hrMin, c.hrMax, c.promRatio), before,
        reason: 'check() 不該動到任何值');
    expect(issues.where((e) => e.severity == ConfigSeverity.error), isNotEmpty);
    // ignore: avoid_print
    print(Max30102SettingLimits.format(issues));
  });

  test('核心建構時會自動 enforce → 拿壞設定建核心也不會崩', () {
    final k2 = Max30102K2(config: Max30102Config(hrMin: 0, hrMax: 0));
    expect(k2.config.bandLowHz, greaterThan(0));
    expect(k2.config.hrMax, greaterThan(k2.config.hrMin));

    // 真的餵資料進去不該丟例外(以前 hrMin=0 會在 (fs/0).round() 崩掉)
    expect(() {
      for (int i = 0; i < 60; i++) {
        k2.feedSamples(
          List<int>.filled(10, 70000),
          List<int>.filled(10, 90000),
        );
      }
    }, returnsNormally);
  });

  test('運行中把設定改壞,下一輪計算會自己夾回來', () {
    final k2 = Max30102K2();
    k2.config.hrMin = 0; // 軟體亂改
    expect(() {
      for (int i = 0; i < 60; i++) {
        k2.feedSamples(
          List<int>.filled(10, 70000),
          List<int>.filled(10, 90000),
        );
      }
    }, returnsNormally);
    expect(k2.config.hrMin, greaterThanOrEqualTo(Max30102SettingLimits.hrLo),
        reason: '_compute() 每輪都會 enforce');
  });
}
