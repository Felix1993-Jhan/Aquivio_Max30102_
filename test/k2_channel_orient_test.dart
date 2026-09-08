// ============================================================================
// 通道方向自動判定（RED / IR 誰是誰）
// ============================================================================
// 背景：市面上有 MAX30102 模組把兩顆 LED 晶粒裝反（實測 8 片裡 7 片如此）。
// datasheet 規定 0x0C = LED1 = 紅光、FIFO 順序 RED 在前，我們的解碼完全照規格，
// 但那種模組送出來的兩路就是對調的。
//
// 判定靠 AC/DC 比值（= 血氧的 R），**不能靠讀數大小** —— DC 高低只反映
// 「LED 多亮」，實測兩片健康板的方向還相反。
//
// 這裡驗五件事：
//   ① 正接的訊號 → 判定 normal，血氧照給
//   ② 反接的訊號 → 判定 swapped，且輸出的 newIr/newRed 已經轉正
//   ③ 判定完成前不輸出樣本（與沉澱期同一個原則）
//   ④ 手指離開 → 方向歸零，下一位重新判定
//   ⑤ 模糊帶（R 接近 1）不判定，且不給血氧
// ============================================================================

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_config.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_core.dart';

const int kFs = Max30102Config.samplingRateHz; // 100
const int kBatch = 24;

/// 合成一批 PPG。
///
/// [irAcRatio] / [redAcRatio] 是各自的 AC/DC 比例 —— 決定 R 的就是這兩個數字。
/// 健康手指上紅外的相對脈動比紅光大（R ≈ 0.4~0.6），所以預設 IR 給比較大的。
///
/// [swapHardware] = true 模擬「晶粒裝反的模組」：把兩路的內容互換再送出去，
/// 就像那些板子實際做的事。
({List<int> red, List<int> ir}) batch(
  int startIndex, {
  double bpm = 60,
  int n = kBatch,
  double irAcRatio = 0.06,
  double redAcRatio = 0.025,
  bool swapHardware = false,
}) {
  const irDc = 120000.0;
  const redDc = 90000.0;
  final a = <int>[]; // 第 1 槽（datasheet 說是 RED）
  final b = <int>[]; // 第 2 槽（datasheet 說是 IR）
  for (int k = 0; k < n; k++) {
    final ph = 2 * pi * (bpm / 60.0) * ((startIndex + k) / kFs);
    final s = sin(ph);
    final irV = (irDc * (1 + irAcRatio * s)).round();
    final redV = (redDc * (1 + redAcRatio * s)).round();
    // 正常模組：第 1 槽是紅光。裝反的模組：第 1 槽變成紅外。
    a.add(swapHardware ? irV : redV);
    b.add(swapHardware ? redV : irV);
  }
  return (red: a, ir: b);
}

/// 餵 [seconds] 秒，回傳最後一次 feedSamples 的結果與累計吐出的樣本數。
({K2FeedResult last, int emitted, int idx}) feed(
  Max30102K2 k2,
  int seconds, {
  int from = 0,
  bool swapHardware = false,
  double irAcRatio = 0.06,
  double redAcRatio = 0.025,
}) {
  var idx = from;
  var emitted = 0;
  late K2FeedResult r;
  for (int i = 0; i < seconds * kFs ~/ kBatch; i++) {
    final s = batch(idx,
        swapHardware: swapHardware,
        irAcRatio: irAcRatio,
        redAcRatio: redAcRatio);
    r = k2.feedSamples(s.red, s.ir);
    emitted += r.newIr.length;
    idx += kBatch;
  }
  return (last: r, emitted: emitted, idx: idx);
}

void main() {
  test('★ 正接的模組 → 判定 normal，血氧照給', () {
    final k2 = Max30102K2();
    feed(k2, 12);

    expect(k2.channelOrient, K2ChannelOrient.normal);
    expect(k2.spo2, isNotNull, reason: '方向確定後血氧才給');
    expect(k2.spo2!, greaterThan(Max30102Config.spo2Min.toDouble()));
  });

  test('★ 晶粒裝反的模組 → 判定 swapped，且輸出已經轉正', () {
    final k2 = Max30102K2();
    final r = feed(k2, 12, swapHardware: true);

    expect(k2.channelOrient, K2ChannelOrient.swapped,
        reason: '硬體把兩路對調了，核心要自己認出來');
    expect(k2.spo2, isNotNull);
    expect(k2.spo2!, greaterThan(Max30102Config.spo2Min.toDouble()),
        reason: '轉正之後血氧要落在生理範圍內（沒轉正會是負的）');

    // 輸出必須是「實際的光源」，不是線上的槽位順序。
    // 合成訊號的紅外 DC 是 120000、紅光是 90000。
    final irMean = r.last.newIr.reduce((p, c) => p + c) / r.last.newIr.length;
    final redMean = r.last.newRed.reduce((p, c) => p + c) / r.last.newRed.length;
    expect(irMean, closeTo(120000, 12000),
        reason: 'newIr 要吐真正的紅外，不能是線上的第 2 槽');
    expect(redMean, closeTo(90000, 9000));
  });

  test('★ 判定完成前不輸出樣本 —— 與沉澱期同一個原則', () {
    final k2 = Max30102K2();
    // 只餵到「沉澱剛過、還沒湊滿票數」的長度。
    // 空轉期 1.5s + 沉澱 2s ≈ 3.5s，R 要第 3 顆谷才有 → 4.5s 才第一票。
    final r = feed(k2, 4);
    expect(r.emitted, 0, reason: '方向未定就送出去，等於送出貼錯標籤的資料');
    expect(k2.channelOrient, K2ChannelOrient.unknown);
    expect(k2.spo2, isNull, reason: '方向沒確定就沒有可信的血氧');
  });

  test('★ 鎖定那一刻把壓著的樣本一次吐出，不是丟掉', () {
    final k2 = Max30102K2();
    final r = feed(k2, 12);
    expect(r.emitted, greaterThan(kFs * 5),
        reason: '沉澱期 + 判定期壓下來的那幾秒要補吐，不能無聲消失');
  });

  test('★ 手指離開 → 方向歸零，下一位重新判定', () {
    final k2 = Max30102K2(config: Max30102Config(resetOnFingerOff: true));
    feed(k2, 12);
    expect(k2.channelOrient, K2ChannelOrient.normal);

    // 沒手指：連續幾批低於門檻（fingerOffBatches = 3）
    for (int i = 0; i < 5; i++) {
      k2.feedSamples(List<int>.filled(kBatch, 1000), List<int>.filled(kBatch, 1000));
    }
    expect(k2.channelOrient, K2ChannelOrient.unknown,
        reason: '方向是「這一次量測」的狀態，不是設備常數');
  });

  test('模糊帶（R 接近 1）→ 不判定、不給血氧', () {
    final k2 = Max30102K2();
    // 兩路的 AC/DC 幾乎一樣 → R ≈ 1 → 分不出「真缺氧」與「接反」
    feed(k2, 12, irAcRatio: 0.04, redAcRatio: 0.04);

    expect(k2.spo2, isNull,
        reason: '分不出來就不猜 —— 不能把危險值自動改寫成正常值');
  });

  test('逾時逃生口：一直判不出來也要放行波形（但血氧仍不給）', () {
    final k2 = Max30102K2();
    // 模糊帶 + 餵超過 orientTimeoutMs
    final secs = 4 + Max30102Config.orientTimeoutMs ~/ 1000 + 2;
    final r = feed(k2, secs, irAcRatio: 0.04, redAcRatio: 0.04);

    expect(r.emitted, greaterThan(0),
        reason: '訊號差的人不該連波形都看不到');
    expect(k2.spo2, isNull, reason: '方向沒驗證過，血氧照樣不給');
  });
}
