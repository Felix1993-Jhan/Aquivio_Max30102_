// ============================================================================
// 固定 30 秒模式(0.0.1-fixed30s)
// ============================================================================
// 核心 [Max30102K2Fixed30] 的狀態機與一次計算,以及 server 端 [K2EngineFixed30]
// 對外 JSON 的規則(結果前全 null、結果保留到 init、關燈固定 fingerPresent false)。
// 合成 PPG:70 bpm + 0.25 Hz 呼吸調變(讓 RR 有變異),IR DC 100000。
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/fixed30/k2_core_fixed30.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_config.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_hrv_calculator.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_vitals_metrics.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/realtime/k2_core.dart'
    show K2ChannelOrient;
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/ui/k2_serial_adapter.dart';
import 'package:flutter_firmware_tester_unified/shared/services/serial_port_manager.dart';

import '../bin/max30102_server.dart';

/// 合成訊號產生器:每次 [next] 給一批 (red, ir)。[finger] = false 時 IR 掉到門檻以下。
class _Ppg {
  /// [redAc]:紅光脈動振幅(DC 60000)。預設 900 → R = (900/60000)/(2000/100000) = 0.75。
  /// [swap]:兩路對調送進去(模擬「假設的方向是錯的」)。
  _Ppg({this.redAc = 900, this.swap = false});
  final int redAc;
  final bool swap;

  static const fs = 100;
  double _phase = 0;
  int _i = 0;

  ({List<int> red, List<int> ir}) next(int n, {bool finger = true}) {
    final red = <int>[], ir = <int>[];
    for (int k = 0; k < n; k++) {
      final t = _i++ / fs;
      final f = 70 / 60 * (1 + 0.06 * math.sin(2 * math.pi * 0.25 * t));
      _phase += 2 * math.pi * f / fs;
      final s = math.sin(_phase);
      if (finger) {
        red.add((60000 + redAc * s).round());
        ir.add((100000 + 2000 * s).round());
      } else {
        red.add(5000);
        ir.add(8000);
      }
    }
    return swap ? (red: ir, ir: red) : (red: red, ir: ir);
  }
}

/// 假時鐘(ms)。倒數用真實時鐘計時(0.0.1-fixed30s 之後),測試瞬間餵完資料,
/// 所以每餵一批 10 筆就讓時間前進 100ms(= 100 Hz 準時到達)。
int _nowMs = 0;
int _clock() => _nowMs;

/// 餵 [seconds] 秒(每批 10 筆,時鐘每批 +100ms)。回傳這段期間 computed 非 null 的次數。
int _feed(Max30102K2Fixed30 k, _Ppg g, double seconds, {bool finger = true}) {
  int computed = 0;
  for (int i = 0; i < (seconds * 10).round(); i++) {
    final b = g.next(10, finger: finger);
    if (k.feedSamples(b.red, b.ir).computed != null) computed++;
    _nowMs += 100;
  }
  return computed;
}

/// 組合法的 QUERY_FIFO 回應封包(擴充板 0x31),依預設通道指標排槽位(同 server_api_test)。
List<int> _packetOf(List<int> red, List<int> ir) {
  const swapped =
      Max30102Config.channelModeDefault == Max30102Config.channelModeSwapped;
  final b = <int>[0x40, 0x71, 0x31, 0x09, 0x00, red.length * 6];
  for (int i = 0; i < red.length; i++) {
    final (s1, s2) = swapped ? (ir[i], red[i]) : (red[i], ir[i]);
    b.addAll([s1 & 0xFF, (s1 >> 8) & 0xFF, (s1 >> 16) & 0xFF]);
    b.addAll([s2 & 0xFF, (s2 >> 8) & 0xFF, (s2 >> 16) & 0xFF]);
  }
  var sum = 0;
  for (final v in b) {
    sum += v;
  }
  b.add((0x100 - (sum & 0xFF)) & 0xFF);
  return b;
}

void _feedEngine(VitalsEngine e, _Ppg g, double seconds, {bool finger = true}) {
  for (int i = 0; i < (seconds * 10).round(); i++) {
    final b = g.next(10, finger: finger);
    e.feedPacket(_packetOf(b.red, b.ir));
    _nowMs += 100;
  }
}

void main() {
  group('核心狀態機', () {
    test('沒手指 → waiting;放上手指 → 空轉/沉澱仍是 waiting 且 settling', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      _feed(k, g, 1, finger: false);
      expect(k.phase, K2Phase.waiting);
      expect(k.fingerPresent, isFalse);
      _feed(k, g, 1); // 空轉期中
      expect(k.phase, K2Phase.waiting);
      expect(k.fingerPresent, isTrue);
      expect(k.settling, isTrue);
      expect(k.remainingSec, isNull);
    });

    test('★ 沉澱完開始倒數:measuring、剩餘秒數遞減、結果前 result 為 null', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      _feed(k, g, 4); // 空轉 1.5 + 沉澱 2.0 → 已進入倒數
      expect(k.phase, K2Phase.measuring);
      expect(k.settling, isFalse);
      final r0 = k.remainingSec!;
      expect(r0, inInclusiveRange(29, 30));
      _feed(k, g, 10);
      expect(k.remainingSec!, inInclusiveRange(r0 - 11, r0 - 9));
      expect(k.result, isNull, reason: '倒數期間不算任何數值');
    });

    test('★ 30 秒 + 右緣 154 筆到齊才算一次;bpm = HRV 平均心率', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      final n = _feed(k, g, 36);
      expect(n, 1, reason: '整次量測只算一次');
      expect(k.phase, K2Phase.done);
      final r = k.result!;
      expect(r.windowEndAbs - r.windowStartAbs, Max30102K2Fixed30.windowSamples);
      // 開始倒數 = 空轉 150 + 沉澱 settleSamples
      expect(r.windowStartAbs, 150 + Max30102Config().settleSamples);
      expect(r.liftAbs, isNull);
      final c = r.compute;
      expect(c.hrv, isNotNull);
      expect(c.bpm, c.hrv!.meanHr);
      expect(c.bpm!, closeTo(70, 3));
      // 收的谷都在計算窗內
      for (final t in c.troughAbs) {
        expect(t, inInclusiveRange(r.windowStartAbs, r.windowEndAbs - 1));
      }
    });

    test('出結果後手指不離開 → 不會自動開始下一次量測', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      _feed(k, g, 36);
      final r = k.result;
      expect(_feed(k, g, 40), 0);
      expect(k.phase, K2Phase.done);
      expect(identical(k.result, r), isTrue);
    });

    test('★ done 鎖到 reset():手指拿開再放上也不會開始新量測', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      _feed(k, g, 36);
      final r = k.result;
      _feed(k, g, 1, finger: false);
      expect(k.fingerPresent, isFalse);
      expect(_feed(k, g, 40), 0, reason: '沒有 init 就不會再算');
      expect(k.phase, K2Phase.done);
      expect(k.fingerPresent, isTrue, reason: '手指偵測照常,反映實際狀況');
      expect(identical(k.result, r), isTrue, reason: '結果原封保留');

      k.reset(); // = server 收到 init
      expect(k.phase, K2Phase.waiting);
      expect(k.result, isNull);
      _feed(k, g, 4);
      expect(k.phase, K2Phase.measuring);
    });

    test('★ 倒數未滿 28 秒手指離開 → aborted,手指放回去也不重量,直到 reset()', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      _feed(k, g, 15);
      _feed(k, g, 0.5, finger: false);
      expect(k.phase, K2Phase.aborted);
      expect(k.abortReason, K2AbortReason.fingerRemoved);
      expect(k.result, isNull);

      _feed(k, g, 10); // 手指放回去
      expect(k.phase, K2Phase.aborted);
      expect(k.fingerPresent, isTrue, reason: '中止期間手指偵測照常,反映實際狀況');

      k.reset(); // = server 收到 init
      expect(k.phase, K2Phase.waiting);
      expect(k.abortReason, isNull);
      _feed(k, g, 4);
      expect(k.phase, K2Phase.measuring);
    });

    test('空轉 / 沉澱中離開不算中止(倒數還沒開始)', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      _feed(k, g, 2);
      _feed(k, g, 0.5, finger: false);
      expect(k.phase, K2Phase.waiting);
    });

    test('★ 倒數滿 28 秒後離開 → 照算;計算窗止於 L − 154', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      _feed(k, g, 3.5 + 29); // 倒數約 29 秒
      expect(k.phase, K2Phase.measuring);
      final n = _feed(k, g, 0.5, finger: false);
      expect(n, 1);
      expect(k.phase, K2Phase.done);
      final r = k.result!;
      expect(r.liftAbs, isNotNull);
      expect(r.windowEndAbs, lessThanOrEqualTo(r.liftAbs! - Max30102K2Fixed30.hold));
      expect(r.windowEndAbs - r.windowStartAbs, greaterThan(2600));
      expect(r.compute.hrv, isNotNull);
    });

    test('dropMeasurement(關燈):倒數中 → 回到 waiting;已有結果則保留', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      _feed(k, g, 10);
      k.dropMeasurement();
      expect(k.phase, K2Phase.waiting);
      expect(k.fingerPresent, isFalse);

      final k2 = Max30102K2Fixed30(clockMs: _clock);
      _feed(k2, _Ppg(), 36);
      k2.dropMeasurement();
      expect(k2.phase, K2Phase.done);
      expect(k2.result, isNotNull);
    });
  });

  // 倒數 30 秒 / 滿 28 秒看真實時鐘,不數樣本(0.0.1-fixed30s 之後)。
  // 實機曾發生:樣本到達不足 100 筆/秒,碼表 30 秒時倒數還剩 3~4 秒。
  group('倒數用真實時鐘', () {
    /// 每 100ms 到 [perBatch] 筆(9 = 只有 90 筆/秒)。
    int feedRate(Max30102K2Fixed30 k, _Ppg g, double seconds, int perBatch,
        {bool finger = true}) {
      int computed = 0;
      for (int i = 0; i < (seconds * 10).round(); i++) {
        final b = g.next(perBatch, finger: finger);
        if (k.feedSamples(b.red, b.ir).computed != null) computed++;
        _nowMs += 100;
      }
      return computed;
    }

    test('★ 樣本只有 90 筆/秒:碼表 30 秒就結束倒數,計算窗 ≈ 2700 筆', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      feedRate(k, g, 4, 10); // 空轉 + 沉澱(照筆數)→ 倒數已開始約 0.6 秒
      expect(k.phase, K2Phase.measuring);
      feedRate(k, g, 29, 9); // 倒數經過約 29.6 秒
      expect(k.phase, K2Phase.measuring);
      expect(k.remainingSec, 1);
      expect(feedRate(k, g, 3, 9), 1, reason: '30 秒到 + 右緣 154 筆 → 算一次');
      expect(k.phase, K2Phase.done);
      final r = k.result!;
      expect(r.liftAbs, isNull);
      expect(r.windowEndAbs - r.windowStartAbs, inInclusiveRange(2650, 2760),
          reason: '舊寫法(數 3000 筆)要等到碼表約 33 秒');
      expect(r.compute.hrv, isNotNull);
    });

    test('★ 90 筆/秒、碼表 28.6 秒拿掉(只收到約 2570 筆)→ 判定為提早結束,照算', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      feedRate(k, g, 4, 10);
      feedRate(k, g, 28, 9); // 倒數經過約 28.6 秒
      expect(k.phase, K2Phase.measuring);
      expect(feedRate(k, g, 0.5, 9, finger: false), 1);
      expect(k.phase, K2Phase.done, reason: '舊寫法數不到 2800 筆 → 會被判成 aborted');
      final r = k.result!;
      expect(r.liftAbs, isNotNull);
      expect(r.windowEndAbs, lessThanOrEqualTo(r.liftAbs! - Max30102K2Fixed30.hold));
      expect(r.compute.hrv, isNotNull);
    });

    test('碼表未滿 28 秒拿掉 → aborted', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      feedRate(k, g, 4, 10);
      feedRate(k, g, 27, 10); // 倒數經過約 27.6 秒,確認離開還要 3 批 = 0.3 秒 → 27.9 秒
      feedRate(k, g, 0.5, 10, finger: false);
      expect(k.phase, K2Phase.aborted);
      expect(k.result, isNull);
    });

    test('30 秒已到、還在等右緣時拿掉 → 走提早結束,窗終點不超過 30 秒那一點', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      _feed(k, g, 4);
      _feed(k, g, 29.5); // 倒數經過約 30.1 秒:窗終點已定,右緣才收 1 批
      expect(k.phase, K2Phase.measuring);
      expect(k.remainingSec, 0);
      expect(_feed(k, g, 0.5, finger: false), 1);
      expect(k.phase, K2Phase.done);
      final r = k.result!;
      expect(r.liftAbs, isNotNull);
      expect(r.windowEndAbs - r.windowStartAbs, lessThanOrEqualTo(3000));
    });

    test('沒有新資料時,剩餘秒數照樣跟著時鐘走', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      _feed(k, _Ppg(), 4); // 倒數經過約 0.6 秒
      expect(k.remainingSec, 30);
      _nowMs += 10000;
      expect(k.remainingSec, 20);
    });

    test('時鐘不動、資料一直灌(積壓)→ 收滿 maxWindowSamples 就當作窗滿,緩衝有界', () {
      final k = Max30102K2Fixed30(clockMs: _clock);
      final g = _Ppg();
      _feed(k, g, 4);
      int n = 0;
      for (int i = 0; i < 400 && k.phase == K2Phase.measuring; i++) {
        final b = g.next(10); // 時鐘不前進
        if (k.feedSamples(b.red, b.ir).computed != null) n++;
      }
      expect(n, 1);
      final r = k.result!;
      expect(r.windowEndAbs - r.windowStartAbs,
          inInclusiveRange(Max30102K2Fixed30.maxWindowSamples - 60,
              Max30102K2Fixed30.maxWindowSamples + 10));
    });
  });

  group('血氧的通道方向驗證(預設指標 1 = 假設對調)', () {
    K2Fixed30Result run(_Ppg g) {
      final k = Max30102K2Fixed30(clockMs: _clock);
      _feed(k, g, 36);
      expect(k.phase, K2Phase.done);
      return k.result!;
    }

    test('R < 0.9:假設對 → 照給,方向 swapped', () {
      final r = run(_Ppg());
      expect(r.compute.spo2, isNotNull);
      expect(r.compute.orient, K2ChannelOrient.swapped);
    });

    test('★ R > 1.3:假設錯 → 兩路換回來重算,與正確方向的血氧相同,方向 normal', () {
      final ok = run(_Ppg()).compute;
      final r = run(_Ppg(swap: true)).compute;
      expect(r.orient, K2ChannelOrient.normal);
      expect(r.spo2, isNotNull);
      expect(r.spo2!, closeTo(ok.spo2!, 0.5));
      expect(r.hrv!.meanHr, closeTo(ok.hrv!.meanHr, 1), reason: '心率不受方向影響');
    });

    test('模糊帶(R ≈ 1.1)→ 不給血氧', () {
      // 紅光振幅 1320 → R = (1320/60000)/(2000/100000) = 1.1
      final r = run(_Ppg(redAc: 1320)).compute;
      expect(r.spo2, isNull);
      expect(r.hrv, isNotNull, reason: '心率 / HRV 照常');
    });
  });

  group('cleanShare 頭尾', () {
    // 10 筆首尾相接的 RR,每筆 80 筆(800 ms),涵蓋 abs 1000~1800
    final pts = <HrvRrPoint>[
      for (int i = 0; i < 10; i++)
        (rr: 800.0, startAbs: 1000 + i * 80, endAbs: 1080 + i * 80),
    ];

    test('不傳窗 → 行為與即時模式相同(頭尾不算)', () {
      expect(Max30102VitalsMetrics.cleanShare(pts), 1.0);
    });

    test('★ 窗尾空 400 筆(4 秒 = 5 拍)→ 扣 5 拍', () {
      expect(
        Max30102VitalsMetrics.cleanShare(pts, spanStart: 1000, spanEnd: 2200),
        10 / 15,
      );
    });

    test('不到一拍的頭尾空白不扣(無條件捨去)', () {
      expect(
        Max30102VitalsMetrics.cleanShare(pts, spanStart: 950, spanEnd: 1870),
        1.0,
      );
    });
  });

  group('classify 基準:整段中位數(固定模式)vs 局部 ±4(即時模式)', () {
    // 頭端連 3 顆壞拍(1050),後面 12 顆正常(約 800)
    final rr = <double>[1050, 1050, 1050, 800, 790, 815, 780, 825, 805, 770, 830, 795, 810, 785, 820];
    final pts = <HrvRrPoint>[];
    int t = 0;
    for (final r in rr) {
      final s = t;
      t += (r / 10).round();
      pts.add((rr: r, startAbs: s, endAbs: t));
    }

    test('局部 ±4:最頭兩筆可比的太少、被壞拍翻盤 → 漏網成乾淨(即時模式行為不變)', () {
      final k = Max30102HrvCalculator.classify(pts);
      // 第 0 筆只看 5 筆(3 壞)、第 1 筆看 6 筆(3 壞)→ 中位數被帶偏;第 2 筆看 7 筆就判得出
      expect(k.sublist(0, 2), everyElement(HrvRrKind.clean));
      expect(k[2], isNot(HrvRrKind.clean));
    });

    test('★ 整段中位數:3 顆壞拍被剔除,其餘全乾淨', () {
      final k = Max30102HrvCalculator.classify(pts, wholeSeries: true);
      expect(k.sublist(0, 3), everyElement(isNot(HrvRrKind.clean)));
      expect(k.sublist(3), everyElement(HrvRrKind.clean));
    });

    test('整段中位數:30 拍內心率漂移 30% 仍全部乾淨', () {
      final drift = <HrvRrPoint>[];
      int a = 0;
      for (int i = 0; i < 30; i++) {
        final r = 900 - 270 * i / 29; // 900 → 630
        final s = a;
        a += (r / 10).round();
        drift.add((rr: r, startAbs: s, endAbs: a));
      }
      expect(
        Max30102HrvCalculator.classify(drift, wholeSeries: true),
        everyElement(HrvRrKind.clean),
      );
    });
  });

  group('server feed 模式的 /chip/*(固定模式)', () {
    const port = 18773;
    late K2EngineFixed30 e;
    late ApiServer api;

    Future<Map<String, dynamic>> post(String path) async {
      final c = HttpClient();
      try {
        final req = await c.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
        final res = await req.close();
        return jsonDecode(await res.transform(utf8.decoder).join())
            as Map<String, dynamic>;
      } finally {
        c.close();
      }
    }

    setUp(() async {
      e = K2EngineFixed30(clockMs: _clock);
      api = ApiServer(
        engine: e,
        opts: ServerOptions(
          mode: 'feed',
          serialPath: '/dev/null',
          baud: 115200,
          port: port,
          board: 0x31,
          intervalMs: 100,
          waveSeconds: 30,
          resetOnFingerOff: true,
        ),
        initial: HttpFeedSource(),
      );
      await api.start();
    });
    tearDown(() => api.shutdown());

    test('★ /chip/reset:休眠、結果保留;/chip/init:醒來、結果清除', () async {
      _feedEngine(e, _Ppg(), 36);
      expect(e.vitalsJson()['phase'], 'done');

      final r = await post('/chip/reset');
      expect(r['sent'], isFalse, reason: 'feed 模式照舊只回封包,由上層送');
      expect(e.chipAsleep, isTrue);
      expect(e.vitalsJson()['phase'], 'done');
      expect(e.vitalsJson()['strapi'], isNotNull);

      await post('/chip/init');
      expect(e.chipAsleep, isFalse);
      expect(e.vitalsJson()['phase'], 'waiting');
      expect(e.vitalsJson()['strapi'], isNull);
    });

    test('/chip/reset-init:等同 init(醒來、清除)', () async {
      _feedEngine(e, _Ppg(), 36);
      await post('/chip/reset-init');
      expect(e.chipAsleep, isFalse);
      expect(e.vitalsJson()['phase'], 'waiting');
    });
  });

  group('server K2EngineFixed30', () {
    late K2EngineFixed30 e;
    setUp(() => e = K2EngineFixed30(clockMs: _clock));
    tearDown(() => e.dispose());

    test('★ 倒數中:結果欄位全 null、sqiOk false、有 phase / remainingSec', () {
      final g = _Ppg();
      _feedEngine(e, g, 10);
      final v = e.vitalsJson();
      expect(v['calcMode'], 'fixed30');
      expect(v['phase'], 'measuring');
      expect(v['remainingSec'], isA<int>());
      expect(v['abortReason'], isNull);
      expect(v['fingerPresent'], isTrue);
      expect(v['sqiOk'], isFalse);
      for (final key in ['bpm', 'spo2', 'hrv', 'strapi']) {
        expect(v[key], isNull, reason: '$key 在結果出來前必須是 null');
      }
      // 原有欄位都還在
      for (final key in ['settling', 'channelOrient', 'totalSamples']) {
        expect(v.containsKey(key), isTrue, reason: '原有欄位 $key 要保留');
      }
    });

    test('★ 出結果後:phase done、strapi 有 confidence、bpm = hrv.meanHr', () {
      _feedEngine(e, _Ppg(), 36);
      final v = e.vitalsJson();
      expect(v['phase'], 'done');
      expect(v['remainingSec'], isNull);
      expect((v['strapi'] as Map)['confidence'], isNotNull);
      expect(v['bpm'], (v['hrv'] as Map)['meanHr']);
    });

    test('★ 只 reset 關燈 → 結果保留、fingerPresent false;init → 全清', () {
      final g = _Ppg();
      _feedEngine(e, g, 36);
      e.chipAsleep = true;
      e.afterChipCommand(initialized: false);
      var v = e.vitalsJson();
      expect(v['phase'], 'done');
      expect(v['strapi'], isNotNull);
      expect(v['fingerPresent'], isFalse);

      e.chipAsleep = false;
      e.afterChipCommand(initialized: true);
      v = e.vitalsJson();
      expect(v['phase'], 'waiting');
      expect(v['strapi'], isNull);
      expect(v['bpm'], isNull);
    });

    test('中途離開 → aborted + fingerRemoved', () {
      final g = _Ppg();
      _feedEngine(e, g, 10);
      _feedEngine(e, g, 0.5, finger: false);
      final v = e.vitalsJson();
      expect(v['phase'], 'aborted');
      expect(v['abortReason'], 'fingerRemoved');
    });

    test('倒數期間 WS 也會推送(計時器每秒一次)', () async {
      final got = <Map<String, dynamic>>[];
      final sub = e.vitalsStream.listen(got.add);
      _feedEngine(e, _Ppg(), 10);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await sub.cancel();
      expect(got, isNotEmpty);
      expect(got.last['phase'], 'measuring');
    });
  });

  test('即時模式的輸出多了 calcMode,其餘不變', () async {
    final e = K2Engine();
    expect(e.vitalsJson()['calcMode'], 'realtime');
    expect(e.vitalsJson().containsKey('phase'), isFalse);
    await e.dispose();
  });

  // App 在 done 那一刻凍結固定核心吃的那段資料(fixedBuf),快照存它。
  // 驗證:拿凍結的資料直接呼叫 computeBuffer(),結果要與核心當時算的**完全相同**。
  group('App 凍結的固定版資料 → computeBuffer() 重放一致', () {
    /// 開始輪詢,逐包餵 [seconds] 秒。回傳收包入口(done 後 stop() 會卸載,先留著)。
    void feedAd(void Function(Uint8List) feed, _Ppg g, double seconds,
        FakeAsync async, {bool finger = true}) {
      for (int i = 0; i < (seconds * 10).round(); i++) {
        final b = g.next(10, finger: finger);
        feed(Uint8List.fromList(_packetOf(b.red, b.ir)));
        async.flushMicrotasks();
        _nowMs += 100;
      }
    }

    void expectSame(K2SerialAdapter ad) {
      final r = ad.fixedResult!;
      final buf = ad.fixedBuf!;
      final re = Max30102K2Fixed30.computeBuffer(
        red: buf.red,
        ir: buf.ir,
        bufStartAbs: buf.bufStartAbs,
        windowStartAbs: r.windowStartAbs,
        windowEndAbs: r.windowEndAbs,
        liftAbs: r.liftAbs,
        config: ad.coreFixed.config,
      );
      expect(re.compute.troughAbs, r.compute.troughAbs);
      expect(re.compute.rr, r.compute.rr);
      expect(re.compute.bpm, r.compute.bpm);
      expect(re.compute.hrv?.rmssd, r.compute.hrv?.rmssd);
      expect(re.compute.spo2, r.compute.spo2);
      expect(re.compute.orient, r.compute.orient);
      expect(re.compute.sqiOk, r.compute.sqiOk);
      // 快照裡寫的就是這一份
      final snap = ad.buildSnapshot(full: true)['fixed30'] as Map<String, dynamic>;
      expect(snap['bufStartAbs'], buf.bufStartAbs);
      expect(snap['bufIr'], buf.ir);
    }

    test('正常結束(滿 30 秒):長度 = 沉澱 + 30 秒 + 右緣', () {
      fakeAsync((async) {
        final ad = K2SerialAdapter(
            manager: SerialPortManager('TEST', isTextMode: false),
            coreFixed: Max30102K2Fixed30(clockMs: _clock));
        ad.start();
        final feed = ad.manager.onRawBytes!;
        feedAd(feed, _Ppg(), 36, async);
        expect(ad.coreFixed.phase, K2Phase.done);
        expect(ad.fixedResult!.liftAbs, isNull);
        expect(ad.fixedBuf!.ir.length,
            ad.coreFixed.config.settleSamples + 3000 + Max30102K2Fixed30.hold);
        expectSame(ad);
        ad.stop();
        async.elapse(const Duration(seconds: 1));
      });
    });

    test('★ 提早結束(≥ 28 秒手指離開):畫面保留(同正常結束),凍結資料止於 L', () {
      fakeAsync((async) {
        final ad = K2SerialAdapter(
            manager: SerialPortManager('TEST', isTextMode: false),
            coreFixed: Max30102K2Fixed30(clockMs: _clock));
        ad.start();
        final feed = ad.manager.onRawBytes!;
        final g = _Ppg();
        feedAd(feed, g, 3.5 + 29, async);
        // 手指離開:餵到 done 為止 —— 實機在 done 那一包就 stop(),之後不會再收到封包
        for (int i = 0; i < 5 && ad.coreFixed.phase != K2Phase.done; i++) {
          feedAd(feed, g, 0.1, async, finger: false);
        }
        expect(ad.coreFixed.phase, K2Phase.done);
        final r = ad.fixedResult!;
        expect(r.liftAbs, isNotNull);
        // 即時核心在同一批歸零(手指離開),但這一批不清畫面、不覆蓋 latest
        expect(ad.core.totalSamples, 0, reason: '即時核心內部照樣歸零');
        expect(ad.waveIr, isNotEmpty, reason: '上方波形要保留');
        expect(ad.displayTroughs(), isNotEmpty, reason: '谷標(讀 latest)要保留');
        expect(ad.fixedBuf!.bufStartAbs + ad.fixedBuf!.ir.length, r.liftAbs);
        expectSame(ad);
        ad.stop();
        async.elapse(const Duration(seconds: 1));
      });
    });

    test('reset()(= 開始量測 init 成功 / 清空)清掉凍結資料', () {
      fakeAsync((async) {
        final ad = K2SerialAdapter(
            manager: SerialPortManager('TEST', isTextMode: false),
            coreFixed: Max30102K2Fixed30(clockMs: _clock));
        ad.start();
        feedAd(ad.manager.onRawBytes!, _Ppg(), 36, async);
        expect(ad.fixedBuf, isNotNull);
        ad.reset();
        expect(ad.fixedBuf, isNull);
        ad.stop();
        async.elapse(const Duration(seconds: 1));
      });
    });
  });
}
