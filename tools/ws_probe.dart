// ============================================================================
// ws_probe.dart — 連上 server 的 WS /stream,把每一筆推播印出來
// ============================================================================
// 用途:
//   `/stream` 是 WebSocket(`ws://`),瀏覽器網址列打不開,而 Chrome 的
//   DevTools Console 又有貼上保護。這支腳本讓你不必碰瀏覽器。
//
//   它也是**上層(React / Koa)的參考實作** —— 接法、以及那條「firstAbs
//   接不上就重來」的規則,跟正式串接要做的事完全一樣。
//
// 用法:
//   dart run tools/ws_probe.dart                       # 預設 localhost:8770
//   dart run tools/ws_probe.dart --port 8770
//   dart run tools/ws_probe.dart --full                # 印完整 JSON
//
// 純 Dart,不需要任何套件。
// ============================================================================

import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  String argOf(String name, String fallback) {
    final i = args.indexOf(name);
    return (i >= 0 && i + 1 < args.length) ? args[i + 1] : fallback;
  }

  final host = argOf('--host', 'localhost');
  final port = argOf('--port', '8770');
  final full = args.contains('--full');
  final url = 'ws://$host:$port/stream';

  stdout.writeln('連線中… $url');
  final WebSocket ws;
  try {
    ws = await WebSocket.connect(url);
  } catch (e) {
    stderr.writeln('連不上:$e');
    stderr.writeln('確認 server 有在跑:'
        'max30102_server.exe --mode feed --port $port');
    exit(1);
  }
  stdout.writeln('已連上,Ctrl+C 結束\n');

  // ⚠️ 這是串接方**必須**實作的那條規則:每一批都要檢查接不接得上。
  //    接不上的原因有三種(手指離開歸零 / 沉澱期丟樣本 / 太久沒收被裁掉),
  //    但處理方式只有一種:清空重畫,不要跨過缺口硬接。
  int? next;

  ws.listen((raw) {
    final d = jsonDecode(raw as String) as Map<String, dynamic>;
    if (full) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(d));
      return;
    }

    final w = (d['wave'] as Map).cast<String, dynamic>();
    final rw = (d['raw_wave'] as Map?)?.cast<String, dynamic>();
    final first = w['firstAbs'] as int;
    final count = w['count'] as int;

    final gap = (next != null && first != next) ? '  ⚠️ 接不上(要清空重畫)' : '';
    next = first + count;

    String head(Map<String, dynamic>? blk) {
      final l = (blk?['irTrim'] as List?) ?? const [];
      if (l.isEmpty) return '—';
      return l.take(3).map((e) => (e as num).toStringAsFixed(1)).join(', ');
    }

    String n(Object? v, [int d = 1]) =>
        v == null ? '—' : (v as num).toStringAsFixed(d);

    stdout.writeln(
      'orient=${(d['channelOrient'] ?? '—').toString().padRight(8)}'
      ' finger=${(d['fingerPresent'] == true ? 'Y' : 'n')}'
      ' sqi=${(d['sqiOk'] == true ? 'Y' : 'n')}'
      '  bpm=${n(d['bpm']).padLeft(5)}'
      '  spo2=${n(d['spo2']).padLeft(5)}'
      '  | first=${first.toString().padLeft(6)} n=${count.toString().padLeft(4)}'
      '  wave[${head(w)}]'
      '  raw[${head(rw)}]$gap',
    );
  }, onDone: () {
    stdout.writeln('\n連線關閉');
    exit(0);
  }, onError: (Object e) {
    stderr.writeln('錯誤:$e');
    exit(1);
  });
}
