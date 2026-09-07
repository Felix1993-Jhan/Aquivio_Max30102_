// ============================================================================
// max30102_server 的 API 行為測試
// ============================================================================
// 重點是驗證「兩種進料模式互斥」這條規則:
//   serial 模式下 POST /feed 必須回 409,不能默默吃掉 ——
//   兩條時間軸混進同一個核心,RR 會被算成亂數而且完全不會報錯。
//
// ⚠️ 這裡**不需要真的串口**。原本想用 socat 開虛擬 pty 在 CI 上測,但
//    libserialport 只認實體 UART(它會查 /sys/class/tty/<name>/device,
//    /dev/pts/* 沒有那個節點)→ 開埠必定失敗。
//    互斥規則本身是純邏輯,注入一個假的進料來源就能完整驗證,
//    而且不挑平台、不挑有沒有硬體。
// ============================================================================

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_vitals_metrics.dart';

import '../bin/max30102_server.dart';

/// 假的「主動來源」—— 行為對齊 SerialSource 的關鍵特徵:不接受 HTTP 餵料。
/// 不碰任何 I/O,所以測試環境不需要串口、也不會載入 libserialport。
class _FakeExclusiveSource extends FeedSource {
  bool started = false;
  bool stopped = false;

  @override
  String get name => 'serial';

  @override
  bool get acceptsHttpFeed => false;

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> stop() async => stopped = true;

  @override
  Map<String, dynamic> status() => {'fake': true};
}

/// 一組合法的 QUERY_FIFO 回應封包(1 組樣本)。
/// 40 71 31 09 00 06 | 60 EA 00 (RED=60000) | 50 66 01 (IR=91728) | 0E(checksum)
const List<int> _packet = [64, 113, 49, 9, 0, 6, 96, 234, 0, 80, 102, 1, 14];

void main() {
  const port = 18770; // 挑一個不容易撞到的埠

  late K2Engine engine;
  late ApiServer api;
  late _FakeExclusiveSource fake;

  Uri url(String path) => Uri.parse('http://127.0.0.1:$port$path');

  Future<({int status, Map<String, dynamic> body})> send(
    String method,
    String path, {
    Object? json,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, url(path));
      if (json != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(json)));
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return (
        status: res.statusCode,
        body: jsonDecode(text) as Map<String, dynamic>,
      );
    } finally {
      client.close();
    }
  }

  setUp(() async {
    engine = K2Engine(waveSeconds: 5);
    fake = _FakeExclusiveSource();
    api = ApiServer(
      engine: engine,
      opts: ServerOptions(
        mode: 'serial',
        serialPath: '/dev/null',
        baud: 115200,
        port: port,
        board: 0x31,
        intervalMs: 100,
        waveSeconds: 5,
        resetOnFingerOff: true,
      ),
      initial: fake,
    );
    await api.start();
  });

  tearDown(() async {
    await api.shutdown();
  });

  test('啟動時會 start 進料來源', () {
    expect(fake.started, isTrue);
  });

  test('GET /health 回報目前模式與免洗設定', () async {
    final r = await send('GET', '/health');
    expect(r.status, 200);
    expect(r.body['ok'], isTrue);
    expect(r.body['mode'], 'serial');
    expect(r.body['resetOnFingerOff'], isTrue);
  });

  test('★ 獨佔來源作用中時,POST /feed 必須回 409 而不是默默吃掉', () async {
    final r = await send('POST', '/feed', json: {'bytes': _packet});
    expect(r.status, 409, reason: '兩條時間軸混在一起會讓 RR 算成亂數且不報錯');
    expect(r.body['error'], 'feed rejected');
    expect(engine.totalSamples, 0, reason: '被拒絕的資料絕對不能進到核心');
  });

  test('切回 feed 模式後 /feed 恢復可用,且舊來源有被停掉', () async {
    final m = await send('POST', '/mode', json: {'mode': 'feed'});
    expect(m.status, 200);
    expect(m.body['mode'], 'feed');
    expect(fake.stopped, isTrue, reason: '換來源時舊的一定要釋放');

    final f = await send('POST', '/feed', json: {'bytes': _packet});
    expect(f.status, 200);
    expect(f.body['accepted'], _packet.length);
    expect(engine.totalSamples, greaterThan(0));
  });

  test('切換模式會 reset 核心(不讓兩段資料接在同一條時間軸上)', () async {
    await send('POST', '/mode', json: {'mode': 'feed'});
    for (int i = 0; i < 5; i++) {
      await send('POST', '/feed', json: {'bytes': _packet});
    }
    expect(engine.totalSamples, 5);

    // 再切一次 → 核心與波形都要歸零
    await send('POST', '/mode', json: {'mode': 'feed'});
    expect(engine.totalSamples, 0);
    final w = await send('GET', '/waveform');
    expect(w.body['count'], 0);
    expect(w.body['firstAbs'], 0);
  });

  test('非法 mode 回 400,且不影響目前模式', () async {
    final r = await send('POST', '/mode', json: {'mode': 'banana'});
    expect(r.status, 400);

    final h = await send('GET', '/health');
    expect(h.body['mode'], 'serial', reason: '失敗的切換不該改變現狀');
  });

  test('未知路徑回 404', () async {
    final r = await send('GET', '/nope');
    expect(r.status, 404);
  });

  // ── 晶片控制 ────────────────────────────────────────────────────────
  //
  // 這裡的假來源不是 SerialSource,所以走的是「feed 模式」那條路徑:
  // server 沒有串口 → 把算好的封包交出去,由上層自己送。
  // (serial 模式那條需要真串口,只能在實機上驗。)

  group('晶片控制端點', () {
    setUp(() async {
      // 先切到 feed 模式,模擬「server 沒有串口」的情境
      await send('POST', '/mode', json: {'mode': 'feed'});
    });

    test('沒有串口時 /chip/init 回傳可自行送出的封包', () async {
      final r = await send('POST', '/chip/init');
      expect(r.status, 200);
      expect(r.body['ok'], isTrue);
      expect(r.body['sent'], isFalse, reason: 'server 沒有串口,送不出去');
      // RE-INIT:40 71 31 09 04 00 00 00 11
      expect(r.body['packet'], [64, 113, 49, 9, 4, 0, 0, 0, 17]);
      expect(r.body['note'], isNotNull, reason: '要說明為什麼沒送出去');
      expect(r.body['noteZh'], isNotNull, reason: '中英雙語都要有');
    });

    test('/chip/reset 回傳 RESET 封包', () async {
      final r = await send('POST', '/chip/reset');
      expect(r.status, 200);
      // RESET:40 71 31 09 03 00 00 00 12
      expect(r.body['packet'], [64, 113, 49, 9, 3, 0, 0, 0, 18]);
    });

    test('/chip/reset-init 回傳兩個封包(順序:先 RESET 再 RE-INIT)', () async {
      final r = await send('POST', '/chip/reset-init');
      expect(r.status, 200);
      final packets = r.body['packets'] as List;
      expect(packets, hasLength(2), reason: '復位後一定要接初始化');
      expect(packets[0], [64, 113, 49, 9, 3, 0, 0, 0, 18], reason: 'RESET 在前');
      expect(packets[1], [64, 113, 49, 9, 4, 0, 0, 0, 17], reason: 'RE-INIT 在後');
    });

    test('沒有串口時 GET /chip 回 409,並附上可自行送出的查詢封包', () async {
      final r = await send('GET', '/chip');
      expect(r.status, 409);
      // READ_REG(0xFF):40 71 31 09 02 FF 00 00 14
      expect(r.body['packet'], [64, 113, 49, 9, 2, 255, 0, 0, 20]);
      expect(r.body['hint'], isNotNull);
      expect(r.body['hintZh'], isNotNull);
    });
  });

  test('錯誤回應同時提供英文與中文', () async {
    final r = await send('POST', '/mode', json: {'mode': 'banana'});
    expect(r.status, 400);
    expect(r.body['error'], isNotNull, reason: '英文放主欄位給程式用');
    expect(r.body['errorZh'], isNotNull, reason: '中文放 Zh 後綴欄位');
    expect(r.body['error'], isNot(equals(r.body['errorZh'])),
        reason: '兩個欄位要真的是不同語言,不是同一串複製兩份');
  });

  test('GET /vitals 在沒資料時所有數值為 null(不是 0)', () async {
    final r = await send('GET', '/vitals');
    expect(r.status, 200);
    expect(r.body['bpm'], isNull);
    expect(r.body['spo2'], isNull);
    expect(r.body['hrv'], isNull);
    expect(r.body['fingerPresent'], isFalse);
  });

  // ── strapi 區塊 ────────────────────────────────────────────────────
  //
  // `/vitals` 與 `/stream` 吐的是同一個函式,所以這裡驗過等於兩個端點都驗過。
  //
  // 這一組直接把合成 PPG 餵進 K2Engine(不走 HTTP),原因是要湊滿 HRV 的
  // 暖機拍數需要 30 秒以上的波形 —— 走 HTTP 要打幾百次請求,在行程內餵快得多,
  // 而且驗的是同一條計算鏈。

  group('strapi 區塊', () {
    /// 組一個合法的 QUERY_FIFO 回應封包(擴充板 0x31)。
    List<int> packetOf(List<(int red, int ir)> samples) {
      final b = <int>[0x40, 0x71, 0x31, 0x09, 0x00, samples.length * 6];
      for (final (red, ir) in samples) {
        b.addAll([red & 0xFF, (red >> 8) & 0xFF, (red >> 16) & 0xFF]);
        b.addAll([ir & 0xFF, (ir >> 8) & 0xFF, (ir >> 16) & 0xFF]);
      }
      var sum = 0;
      for (final v in b) {
        sum += v;
      }
      b.add((0x100 - (sum & 0xFF)) & 0xFF);
      return b;
    }

    /// 餵 [seconds] 秒的合成 PPG:70bpm 的脈搏,再疊一個 0.25Hz 的呼吸調變
    /// 讓 RR 有變異(否則每拍間距完全相同,RMSSD 會是 0,測不出東西)。
    /// IR 的 DC 設在 100000,遠高於手指偵測門檻 50000。
    K2Engine feedSynthetic({int seconds = 60}) {
      final e = K2Engine(waveSeconds: 30);
      const fs = 100;
      const f0 = 70 / 60; // 70 bpm
      double phase = 0;
      final buf = <(int, int)>[];
      for (int i = 0; i < fs * seconds; i++) {
        final t = i / fs;
        // 呼吸調變 → RR 隨之起伏(落在 HF 帶)
        final f = f0 * (1 + 0.06 * math.sin(2 * math.pi * 0.25 * t));
        phase += 2 * math.pi * f / fs;
        final s = math.sin(phase);
        buf.add(((60000 + 900 * s).round(), (100000 + 2000 * s).round()));
        if (buf.length == 20) {
          e.feedPacket(packetOf(buf));
          buf.clear();
        }
      }
      return e;
    }

    test('★ 合成 PPG 餵滿後,strapi 區塊真的算得出數值', () {
      final v = feedSynthetic().vitalsJson();
      final s = v['strapi'] as Map<String, dynamic>;

      expect(v['fingerPresent'], isTrue, reason: 'IR DC 100000 遠高於門檻');
      expect(v['hrv'], isNotNull, reason: '60 秒足夠湊滿 HRV 暖機拍數');
      expect(s['mean_hr'], isNotNull);
      expect(s['sdnn'], isNotNull);
      expect(s['rmssd'], isNotNull);
      expect(s['ln_rmssd'], isNotNull);
      expect(s['pns'], isNotNull);
      expect(s['confidence'], isNotNull);
      // 合成訊號是 70bpm,允許演算法有幾 bpm 的誤差
      expect(s['mean_hr'] as double, closeTo(70, 6));
    });

    test('★ strapi 與 hrv 必須同源 —— 兩區的同一個量不可以有兩份計算', () {
      final v = feedSynthetic().vitalsJson();
      final hrv = v['hrv'] as Map<String, dynamic>;
      final s = v['strapi'] as Map<String, dynamic>;

      expect(s['sdnn'], hrv['sdnn'], reason: '各算各的遲早會有一天只改到一邊');
      expect(s['rmssd'], hrv['rmssd']);
      expect(s['mean_hr'], hrv['meanHr']);
      // ln_rmssd 必須真的是 rmssd 的對數,不是另外算的
      expect(s['ln_rmssd'] as double,
          closeTo(math.log(hrv['rmssd'] as double), 1e-9));
    });

    test('★ 30 秒窗照送 lf_hf,可信度另外標明', () {
      final s = feedSynthetic().vitalsJson()['strapi'] as Map<String, dynamic>;

      // 攝影機端(aquivio-vitals)同樣是 30 秒視窗且照樣送。我們送 null
      // 只會讓同一個欄位在兩台裝置上行為不一致,下游分不出
      // 「沒有這個能力」和「刻意保留」。
      expect(s['lf_hf'], isNotNull, reason: '數字照送,誠實靠標註不靠藏');
      expect(s['lf_reliable'], isFalse, reason: '但要講明它不可信');
      expect(s['lf_cycles'] as double, lessThan(4.0),
          reason: '30 秒窗約 1.2 圈,遠低於門檻');
      expect(s['hf_reliable'], isTrue, reason: 'HF 在 30 秒是勉強可用的那一半');
      expect(s['window_sec'], isNotNull);
    });

    test('★ lf/hf 用整合方的單位,我們的 ms² 另外標名', () {
      final s = feedSynthetic().vitalsJson()['strapi'] as Map<String, dynamic>;

      // 同名欄位必須是同一個單位 —— 單位不同的同名欄位比 null 還危險
      expect(s['lf'], closeTo((s['lf_ms2'] as double) * 1.024e-3, 1e-9));
      expect(s['hf'], closeTo((s['hf_ms2'] as double) * 1.024e-3, 1e-9));
      expect(s['vlf_ms2'], isNotNull);
    });

    test('★ 四個 0~100 分數照 aquivio 公式,且都在範圍內', () {
      final v = feedSynthetic().vitalsJson();
      final s = v['strapi'] as Map<String, dynamic>;
      final rmssd = (v['hrv'] as Map<String, dynamic>)['rmssd'] as double;
      final meanHr = (v['hrv'] as Map<String, dynamic>)['meanHr'] as double;

      for (final k in ['pns', 'ans', 'stress', 'activity']) {
        expect(s[k], isNotNull, reason: '$k 應該算得出來');
        expect(s[k] as double, inInclusiveRange(0, 100), reason: '$k 要夾在 0~100');
      }
      // pns 就是 RMSSD 的對數縮放、activity 就是心率 —— 不是別的東西
      expect(s['pns'] as double,
          closeTo(Max30102VitalsMetrics.pnsScore(rmssd)!, 1e-9));
      expect(s['activity'] as double,
          closeTo(Max30102VitalsMetrics.activityScore(meanHr)!, 1e-9));
      // 我們自己那套 z-score 放在不同名字下,不會撞名
      expect(s['pns_max30102'], isNotNull);
      expect(s['pns'], isNot(equals(s['pns_max30102'])));
    });

    test('Parseval:lf_ms2 + hf_ms2 不可能超過 sdnn²', () {
      final v = feedSynthetic().vitalsJson();
      final s = v['strapi'] as Map<String, dynamic>;
      final sdnn = (v['hrv'] as Map<String, dynamic>)['sdnn'] as double;
      final band = (s['lf_ms2'] as double) + (s['hf_ms2'] as double);
      expect(band, lessThanOrEqualTo(sdnn * sdnn * 1.02),
          reason: '三個頻帶加起來等於變異數,LF+HF 只是其中兩段');
    });

    test('沒有資料時 strapi 區塊仍在,欄位為 null 而非缺席', () async {
      final r = await send('GET', '/vitals');
      final s = r.body['strapi'] as Map<String, dynamic>;
      // VitalsResult 宣告的 12 個欄位都要出現(值可以是 null,但 key 不能少,
      // 否則對方的 TypeScript 取用時會是 undefined 而不是 null)
      for (final k in [
        'mean_hr', 'sdnn', 'rmssd', 'ln_rmssd', 'lf_hf', 'sqi',
        'snr_db', 'confidence', 'pns', 'ans', 'stress', 'activity',
      ]) {
        expect(s.containsKey(k), isTrue, reason: '缺少欄位 $k');
      }
      expect(s['mean_hr'], isNull);
      expect(s['sqi'], 0, reason: 'sqi 是 1/0 的數字,沒訊號時是 0');
    });
  });
}
