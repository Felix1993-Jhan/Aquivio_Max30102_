// ============================================================================
// SerialTrace（串口異常現場紀錄）測試
// ============================================================================
// 這份紀錄存在的理由只有一個：回答「為什麼連續送出幾十包卻一個回應都沒有」。
// 所以測的就是那個答案能不能被看出來：
//   ① 半截封包要被標出來 —— 這是最可能的真相，漏掉等於整個工具白做
//   ② write() 回負數要被講明是錯誤碼，不是數量
//   ③ 輸出緩衝區積壓往上爬要被指出來（裝置沒在收資料的直接證據）
//   ④ 全部正常時不可以亂喊狼來了
//   ⑤ 環形緩衝區要有界（常駐的東西不可以無限長大）
//
// 落地位置一律用 dumpDirOverride 改到暫存目錄 —— 跑測試不該往使用者桌面丟檔案。
// ============================================================================

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_firmware_tester_unified/shared/services/serial_trace.dart';

/// 一包 QUERY_FIFO：40 71 31 09 00 00 00 00 CS
final List<int> kQuery = [0x40, 0x71, 0x31, 0x09, 0x00, 0x00, 0x00, 0x00, 0xAB];

/// 建一個落地到暫存目錄的紀錄器。
({SerialTrace trace, Directory dir}) _rig(String tag) {
  final dir = Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}trace_test_$tag'
    '_${DateTime.now().microsecondsSinceEpoch}',
  );
  final t = SerialTrace()..dumpDirOverride = dir;
  t.onOpen('COM_TEST', 115200);
  return (trace: t, dir: dir);
}

String _dump(SerialTrace t) {
  final msg = t.dumpNow('測試觸發');
  expect(msg, contains('現場已存到'), reason: '寫檔要成功,否則後面都沒意義');
  return File(t.lastDumpPath!).readAsStringSync();
}

void main() {
  group('SerialTrace', () {
    test('① 半截封包要被標出來,並且說清楚 MCU 不回答是對的', () {
      final r = _rig('partial');
      // 收得到 → 然後送出只寫出 4 / 9（驅動輸出緩衝區塞住）
      r.trace.rx(Uint8List.fromList([0x40, 0x71, 0x31, 0x09, 0x00, 0x06]));
      r.trace.tx(kQuery, 4, 5);
      r.trace.tx(kQuery, 4, 10);

      final text = _dump(r.trace);
      addTearDown(() => r.dir.deleteSync(recursive: true));

      expect(text, contains('部分寫出 2 次'));
      expect(text, contains('完整寫出 0 次'));
      expect(text, contains('只寫出 4 / 9'), reason: '逐筆那行要看得到實際值');
      expect(text, contains('送出端結論      : ⚠️ 送出端有問題'));
      expect(text, contains('它沒錯，是我們沒送完'),
          reason: '要講出「MCU 不回答是正確的」,否則還是會去怪 MCU');
    });

    test('② write() 回負數要被講明是錯誤碼而不是數量', () {
      final r = _rig('neg');
      r.trace.tx(kQuery, -1, 0);

      final text = _dump(r.trace);
      addTearDown(() => r.dir.deleteSync(recursive: true));

      expect(text, contains('回負數 1 次'));
      expect(text, contains('錯誤碼'));
      expect(text, contains('不是數量'));
    });

    test('③ 輸出緩衝區積壓往上爬要被指出來', () {
      final r = _rig('outq');
      for (int i = 0; i < 5; i++) {
        r.trace.tx(kQuery, 9, i * 100); // 0 → 400,一路往上
      }

      final text = _dump(r.trace);
      addTearDown(() => r.dir.deleteSync(recursive: true));

      expect(text, contains('最低 0 → 最高 400'));
      expect(text, contains('裝置沒有在把資料收走'));
    });

    test('④ 全部正常時不可以亂喊狼來了', () {
      final r = _rig('clean');
      for (int i = 0; i < 5; i++) {
        r.trace.tx(kQuery, 9, 0); // 完整寫出、緩衝區平穩
        r.trace.rx(Uint8List.fromList(List<int>.filled(151, 0x11)));
      }

      final text = _dump(r.trace);
      addTearDown(() => r.dir.deleteSync(recursive: true));

      expect(text, contains('完整寫出 5 次'));
      expect(text, contains('部分寫出 0 次'));
      expect(text, contains('回負數 0 次'));
      expect(text, contains('（平穩）'));
      // ⚠️ 不可以搜「半截封包」:檔尾的閱讀說明本來就會提到它,整份檔案一定命中。
      //    結論只有「送出端結論」這一行,要篩就篩它。
      expect(text, contains('送出端結論      : ✅ 送出端正常'));
      expect(text.contains('⚠️ 送出端有問題'), isFalse,
          reason: '一切正常卻說送出端有問題,會把人帶去查錯的方向');
      // 長封包要截斷顯示,不然整份檔案會被 hex 淹掉
      expect(text, contains('共 151 bytes'));
      expect(text, contains('← 最後一次收到'));
    });

    test('⑤ 環形緩衝區有界:超過保留時間的要被裁掉', () {
      final r = _rig('ring');
      // 直接塞遠超過 keep 的量,驗證不會無限長大。
      // （真實是按時間裁,這裡用「大量寫入後檔案不該無限大」當代理指標）
      for (int i = 0; i < 20000; i++) {
        r.trace.tx(kQuery, 9, 0);
      }

      final text = _dump(r.trace);
      addTearDown(() => r.dir.deleteSync(recursive: true));

      // 20000 筆若全留,檔案會是好幾 MB;裁過之後應該遠小於那個量級。
      expect(text.length, lessThan(2 * 1024 * 1024),
          reason: '常駐的環形緩衝區不可以無限長大');
    });
  });
}
