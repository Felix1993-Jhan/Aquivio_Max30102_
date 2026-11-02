// ============================================================================
// K2FeedResult.newIrWave —— 核心輸出的「畫圖用 IR」
// ============================================================================
// 背景:截尾平滑與帶通都要用到 i 之後的資料。
// 舊做法(newIrTrim)每批一到就算,批尾 4 筆的右側是截斷的,交出去就凍住;
// server 拿它減 baseline 送給站台,站台照著畫,每 0.1 秒左右一個小缺口。
//
// newIrWave = 核心找谷用的那條線(Max30102Signal.troughLine:截尾 → 0.7~3.5 Hz 帶通,
// v0.0.0.8),對整段緩衝算,等離最新資料 154 筆(截尾 4 + 150)才給。
// 帶通是 IIR,沒有「等滿就完全相同」這回事:壓 150 筆時誤差約 1.4%(相對振幅),
// 所以 ①②③ 驗的是「誤差 < 振幅的 2%」,不是 v0.0.0.7 時的 1e-6。
//
// 這裡驗:
//   ① 每一筆都與「事後對整段算」幾乎相同 —— 包含量測一開始那幾筆(左邊有沉澱期當前後文)
//   ② 裝反的模組:輸出的是真正的 IR
//   ③ 與批次大小無關(10 筆 / 24 筆一批,同一個位置的值幾乎相同)
//   ④ 首尾相接,而且最新的 154 筆一定壓著不送
//   ⑤ 手指離開 → 下一位從自己的零點重新開始,不帶上一位的游標
//   ⑥ newIrWaveTrim = 同一段的截尾值(帶 DC)
//   ⑦ 線與谷是同一條:核心收的谷落在 newIrWave 的最低點
//   ⑧ 收的谷一定離最新資料 ≥ 154 筆(線定下來才收)
// ============================================================================

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_config.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_core.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_signal.dart';

const int kFs = Max30102Config.samplingRateHz; // 100
// 截尾半窗 4 + 線定下來要等的 150(Max30102Config.troughGuardSamples)
const int kHold = Max30102Config.trimWindow ~/ 2 + Max30102Config.troughGuardSamples;

/// 帶通是 IIR:核心交出的值與「事後整段算」允許的誤差 = 振幅的 2%(壓 150 筆實測約 1.4%)。
const double kTol = 0.02;

/// 指標 0(自動判定):這裡用 feedSamples 模擬「線上槽位」,靠核心判定方向轉正。
/// 指標 1 / 2 的 newIrWave 在 k2_channel_orient_test 的 ⑥ 另外驗。
Max30102Config _autoCfg() => Max30102Config(
      resetOnFingerOff: true,
      channelMode: Max30102Config.channelModeAuto,
    );

/// 合成 [seconds] 秒的 PPG(真實的 IR / RED,尚未依模組接法排列)。
///
/// 脈搏 72bpm + 呼吸漂移 + 固定種子的雜訊 + 每 0.37 秒一個尖刺 ——
/// 尖刺是為了讓截尾平滑真的有事做(只有平滑正弦的話,截斷與否差異很小,測不出來)。
({List<int> ir, List<int> red}) synth(int seconds, {int seed = 7}) {
  final rnd = Random(seed);
  final ir = <int>[];
  final red = <int>[];
  for (int i = 0; i < seconds * kFs; i++) {
    final t = i / kFs;
    final s = sin(2 * pi * 1.2 * t);
    final drift = 1500 * sin(2 * pi * 0.2 * t);
    final spike = (i % 37 == 0) ? 900 : 0;
    ir.add((120000 + 4000 * s + drift + spike + rnd.nextInt(200)).round());
    red.add((90000 + 1200 * s + drift * 0.6 + rnd.nextInt(120)).round());
  }
  return (ir: ir, red: red);
}

/// 照「線上順序」餵進核心,收集所有輸出。[swapped] = 模擬 LED 裝反的模組。
({
  Max30102K2 k2,
  List<int> waveAbs,
  List<double> wave,
  List<double> waveTrim,
  List<({int first, int len, int total})> calls,
}) run(
  ({List<int> ir, List<int> red}) sig, {
  int batch = 10,
  bool swapped = false,
}) {
  final k2 = Max30102K2(config: _autoCfg());
  final waveAbs = <int>[];
  final wave = <double>[];
  final waveTrim = <double>[];
  final calls = <({int first, int len, int total})>[];
  for (int i = 0; i + batch <= sig.ir.length; i += batch) {
    final ir = sig.ir.sublist(i, i + batch);
    final red = sig.red.sublist(i, i + batch);
    // feedSamples(第 1 槽, 第 2 槽);正常模組第 1 槽是紅光,裝反的是紅外
    final r = swapped ? k2.feedSamples(ir, red) : k2.feedSamples(red, ir);
    for (int k = 0; k < r.newIrWave.length; k++) {
      waveAbs.add(r.waveFirstAbs + k);
      wave.add(r.newIrWave[k]);
      waveTrim.add(r.newIrWaveTrim[k]);
    }
    calls.add((
      first: r.waveFirstAbs,
      len: r.newIrWave.length,
      total: k2.totalSamples,
    ));
  }
  return (k2: k2, waveAbs: waveAbs, wave: wave, waveTrim: waveTrim, calls: calls);
}

/// 「事後對整段算」的正確答案。核心的絕對位置從第 0 筆起算(空轉期也計時),
/// 所以陣列索引就是絕對位置。
///
/// 從空轉期之後才開始算 —— 核心的緩衝就是從那裡開始收的(空轉期的樣本直接丟掉)。
/// IIR 的值受左邊所有資料影響,左邊多算一段空轉期,開頭那幾筆就會跟核心對不上。
List<double> offline(List<int> ir) {
  final dead = Max30102Config().fingerDeadSamples;
  final line = Max30102Signal.troughLine(
    [for (final v in ir.sublist(dead)) v.toDouble()],
    trimWindow: Max30102Config.trimWindow,
    fs: kFs,
    lowHz: Max30102Config.beatBandLowHz,
    highHz: Max30102Config.beatBandHighHz,
  );
  return [...List<double>.filled(dead, double.nan), ...line];
}

/// 振幅參考:|正確答案| 的最大值(誤差用它的百分比來量)。
double amplitude(List<double> truth) =>
    truth.where((v) => !v.isNaN).fold<double>(0, (m, v) => max(m, v.abs()));

void main() {
  group('newIrWave', () {
    final sig = synth(20);
    final truth = offline(sig.ir);
    final amp = amplitude(truth);

    test('① 每一筆都與「事後對整段算」幾乎相同,包含量測一開始那幾筆', () {
      final r = run(sig);
      expect(r.wave, isNotEmpty);
      var maxErr = 0.0;
      for (int k = 0; k < r.wave.length; k++) {
        final err = (r.wave[k] - truth[r.waveAbs[k]]).abs();
        if (err > maxErr) maxErr = err;
      }
      expect(maxErr, lessThan(kTol * amp),
          reason: '離最新資料 154 筆才給,左邊有沉澱期當前後文 → 誤差在振幅的 2% 內'
              '(實際 ${(100 * maxErr / amp).toStringAsFixed(2)}%)');
    });

    test('② 裝反的模組:輸出的是真正的 IR,不是線上那一槽', () {
      final r = run(sig, swapped: true);
      expect(r.k2.channelOrient, K2ChannelOrient.swapped);
      expect(r.wave, isNotEmpty);
      var maxErr = 0.0;
      for (int k = 0; k < r.wave.length; k++) {
        final err = (r.wave[k] - truth[r.waveAbs[k]]).abs();
        if (err > maxErr) maxErr = err;
      }
      expect(maxErr, lessThan(kTol * amp));
    });

    test('③ 與批次大小無關:同一個位置的值幾乎相同', () {
      final a = run(sig, batch: 10);
      final b = run(sig, batch: 24);
      final byAbs = {for (int k = 0; k < a.wave.length; k++) a.waveAbs[k]: a.wave[k]};
      var shared = 0;
      for (int k = 0; k < b.wave.length; k++) {
        final v = byAbs[b.waveAbs[k]];
        if (v == null) continue;
        shared++;
        // 批次大小不同 → 交出那一刻右邊多了 0~23 筆,IIR 的值跟著有一點差
        expect(b.wave[k], closeTo(v, kTol * amp), reason: 'abs ${b.waveAbs[k]}');
      }
      expect(shared, greaterThan(1000));
    });

    test('④ 首尾相接,且最新的 154 筆一定壓著不送', () {
      final r = run(sig);
      int? next;
      for (final c in r.calls) {
        if (c.len == 0) continue;
        if (next != null) {
          expect(c.first, next, reason: '接續處不可以有洞,也不可以重疊');
        }
        next = c.first + c.len;
        expect(next, lessThanOrEqualTo(c.total - kHold),
            reason: '沒有完整前後文的樣本不可以送出去 —— 送了就凍住,修不回來');
      }
      // 第一筆就是原始樣本開始輸出的那一筆(不晚於、也不早於)
      expect(r.waveAbs.first, greaterThanOrEqualTo(
          r.k2.config.fingerDeadSamples + r.k2.config.settleSamples - 10));
    });

    test('⑤ 手指離開 → 下一位從自己的零點重新開始,不帶上一位的游標', () {
      final k2 = Max30102K2(config: _autoCfg());
      void feedAll(({List<int> ir, List<int> red}) s) {
        for (int i = 0; i + 10 <= s.ir.length; i += 10) {
          k2.feedSamples(s.red.sublist(i, i + 10), s.ir.sublist(i, i + 10));
        }
      }

      feedAll(synth(12));
      // 手指離開 1 秒(IR 掉到門檻以下)
      for (int i = 0; i < 10; i++) {
        k2.feedSamples(List.filled(10, 1000), List.filled(10, 1000));
      }
      expect(k2.totalSamples, 0, reason: '免洗模式:已經歸零');

      // 下一位:收集第二次量測的輸出,必須與「只量第二次」完全相同
      final s2 = synth(12, seed: 99);
      final got = <int, double>{};
      for (int i = 0; i + 10 <= s2.ir.length; i += 10) {
        final r = k2.feedSamples(s2.red.sublist(i, i + 10), s2.ir.sublist(i, i + 10));
        for (int k = 0; k < r.newIrWave.length; k++) {
          got[r.waveFirstAbs + k] = r.newIrWave[k];
        }
      }
      final fresh = run(s2);
      expect(got.length, fresh.wave.length, reason: '第二位的輸出量要與全新的一樣');
      for (int k = 0; k < fresh.wave.length; k++) {
        expect(got[fresh.waveAbs[k]], closeTo(fresh.wave[k], 1e-6));
      }
    });

    test('⑥ newIrWaveTrim = 同一段的截尾值(帶 DC,完整)', () {
      final r = run(sig);
      final trim = Max30102Signal.slidingTrimmedMean(
        [for (final v in sig.ir) v.toDouble()],
        Max30102Config.trimWindow,
      );
      for (int k = 0; k < r.waveTrim.length; k++) {
        expect(r.waveTrim[k], closeTo(trim[r.waveAbs[k]], 1e-6));
      }
    });

    test('對照:舊的 newIrTrim 批尾確實是截斷的(這正是改用 newIrWave 的原因)', () {
      final k2 = Max30102K2(config: _autoCfg());
      final trim = Max30102Signal.slidingTrimmedMean(
        [for (final v in sig.ir) v.toDouble()],
        Max30102Config.trimWindow,
      );
      var tailErr = 0.0, headErr = 0.0;
      for (int i = 0; i + 10 <= sig.ir.length; i += 10) {
        final r = k2.feedSamples(sig.red.sublist(i, i + 10), sig.ir.sublist(i, i + 10));
        for (int k = 0; k < r.newIrTrim.length; k++) {
          final e = (r.newIrTrim[k] - trim[r.firstAbs + k]).abs();
          final fromEnd = r.newIrTrim.length - 1 - k;
          if (fromEnd < 4) {
            if (e > tailErr) tailErr = e;
          } else if (r.newIrTrim.length <= 10) {
            if (e > headErr) headErr = e;
          }
        }
      }
      expect(headErr, lessThan(1e-6), reason: '批內前段是完整的');
      expect(tailErr, greaterThan(50), reason: '批尾 4 筆右側截斷,誤差明顯');
    });

    test('⑦ 線與谷是同一條:核心收的谷落在 newIrWave 的最低點(±1 筆)', () {
      final k2 = Max30102K2(config: _autoCfg());
      final wave = <int, double>{};
      for (int i = 0; i + 10 <= sig.ir.length; i += 10) {
        final r = k2.feedSamples(sig.red.sublist(i, i + 10), sig.ir.sublist(i, i + 10));
        for (int k = 0; k < r.newIrWave.length; k++) {
          wave[r.waveFirstAbs + k] = r.newIrWave[k];
        }
      }
      final troughs = k2.latest!.troughAbs;
      var checked = 0;
      for (final t in troughs) {
        final near = [for (int d = -3; d <= 3; d++) wave[t + d]];
        if (near.any((v) => v == null)) continue;
        var best = 0;
        for (int d = 1; d < near.length; d++) {
          if (near[d]! < near[best]!) best = d;
        }
        expect((best - 3).abs(), lessThanOrEqualTo(1),
            reason: '谷 $t:畫出來的線最低點在 ${t + best - 3},找谷的線與畫的線不是同一條');
        checked++;
      }
      expect(checked, greaterThan(10));
    });

    test('⑧ 收的谷一定離最新資料 ≥ 154 筆(線定下來才收,收了不再改)', () {
      final k2 = Max30102K2(config: _autoCfg());
      var rounds = 0;
      for (int i = 0; i + 10 <= sig.ir.length; i += 10) {
        final r = k2.feedSamples(sig.red.sublist(i, i + 10), sig.ir.sublist(i, i + 10));
        final c = r.computed;
        if (c == null || c.troughAbs.isEmpty) continue;
        expect(c.troughAbs.last, lessThan(k2.totalSamples - kHold),
            reason: '最新的谷還在線沒定下來的那段裡');
        rounds++;
      }
      expect(rounds, greaterThan(5));
    });
  });
}
