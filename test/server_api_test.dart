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

import 'package:flutter_test/flutter_test.dart';

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

  test('GET /vitals 在沒資料時所有數值為 null(不是 0)', () async {
    final r = await send('GET', '/vitals');
    expect(r.status, 200);
    expect(r.body['bpm'], isNull);
    expect(r.body['spo2'], isNull);
    expect(r.body['hrv'], isNull);
    expect(r.body['fingerPresent'], isFalse);
  });
}
