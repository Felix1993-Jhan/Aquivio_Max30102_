// ============================================================================
// K2 輪次（一問一答交易）測試
// ============================================================================
// 舊版是「送出去就不管了」的盲送計時器，現在每一輪有頭有尾：
//   送出 → 等最長 roundTimeoutMs → 這輪算成功或延遲 → 再開新的一輪。
//
// 測五件事，其中 ① 是最重要的回歸測試：
//   ① **探測期不可以計輪次** —— 探測期同時問 0x31 與 0x30，兩塊板二選一在線，
//      其中一塊本來就不會回。這裡算進去的話每一輪都會被誤判成延遲，
//      然後連續 5 輪就去重開串口 —— 一開始量測就無限重開。
//      （這與心跳 0x30↔0x31 交叉輪替是同一個坑，CLAUDE.md 有記。）
//   ② 鎖定板子後完全沒有回應 → 延遲輪數累積
//   ③ 連續到門檻 → 請求串口層重開，並且重新起算（不是每輪都喊）
//   ④ 有回應 → 算成功，連續延遲計數歸零
//   ⑤ stop() 之後不可以再有任何輪次被計入
//
// 用 fake_async 控制時間，不真的等 150ms。串口管理層用子類別攔下
// requestReadRecovery 來觀察（它是公開方法，正是為了這個介面而存在）。
// ============================================================================

import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/k2_protocol.dart';
import 'package:flutter_firmware_tester_unified/main_mode/max30102_K2/ui/k2_serial_adapter.dart';
import 'package:flutter_firmware_tester_unified/shared/services/serial_port_manager.dart';

/// 攔下重開請求，其餘行為照舊（沒開串口，所以 sendHex 會回 false —— 不影響
/// 輪次邏輯，輪次要驗的是「有沒有在逾時內收到回應」）。
class _SpyManager extends SerialPortManager {
  _SpyManager() : super('TEST', isTextMode: false);

  final List<String> recoveries = [];

  @override
  void requestReadRecovery(String reason) => recoveries.add(reason);
}

/// 造一包合法的 QUERY_FIFO 回應：40 71 31 09 00 [N*6] [資料…] [CS]
Uint8List fifoReply(int groups) {
  final b = <int>[0x40, 0x71, 0x31, 0x09, 0x00, groups * 6];
  for (int i = 0; i < groups; i++) {
    b.addAll([0x10, 0x20, 0x02]); // RED 18-bit，低位元組在前
    b.addAll([0x30, 0x40, 0x02]); // IR
  }
  var sum = 0;
  for (final v in b) {
    sum += v;
  }
  b.add((0x100 - (sum & 0xFF)) & 0xFF);
  return Uint8List.fromList(b);
}

({_SpyManager mgr, K2SerialAdapter ad}) _rig() {
  final mgr = _SpyManager();
  return (mgr: mgr, ad: K2SerialAdapter(manager: mgr));
}

/// 開始量測並讓板子鎖定在擴充板。
///
/// ⚠️ 不可以在 start() 之前設 `activeBoard` —— `start()` 裡有
///    `activeBoard = null`（每次量測重新探測，可能換板子插）。寫在前面會被清掉，
///    整段跑在探測期而不計輪次。要鎖定就餵一包 0x31 的回應，
///    [K2SerialAdapter._onPacket] 收到就會自動鎖 —— 這也是實機的路徑。
void _startLocked(({_SpyManager mgr, K2SerialAdapter ad}) r, FakeAsync async) {
  r.ad.start();
  async.elapse(const Duration(milliseconds: 20));
  r.mgr.onRawBytes!(fifoReply(10));
  expect(r.ad.activeBoard, Max30102Protocol.kBoardExpansion,
      reason: '收到 0x31 的回應就該鎖定擴充板');
  // 探測期不建 Completer，所以這一包只負責鎖板子，不算任何一輪。
  expect(r.ad.roundsOk, 0);
  expect(r.ad.roundsLate, 0);
}

void main() {
  group('K2 輪次', () {
    test('① 探測期不計輪次（否則一開始量測就會無限重開串口）', () {
      fakeAsync((async) {
        final r = _rig(); // 不餵任何回應 → 板子永遠鎖不到 → 一直在探測期
        r.ad.start();
        async.elapse(const Duration(seconds: 2));

        expect(r.ad.activeBoard, isNull, reason: '沒有人回應,應該還在探測');
        expect(r.ad.roundsOk, 0);
        expect(r.ad.roundsLate, 0,
            reason: '探測期有一塊板本來就不會回,算進去就是誤判');
        expect(r.mgr.recoveries, isEmpty,
            reason: '探測期絕對不可以去重開串口');
        r.ad.stop();
      });
    });

    test('② 鎖定板子後完全沒有回應 → 延遲輪數累積', () {
      fakeAsync((async) {
        final r = _rig();
        _startLocked(r, async);
        // 鎖定後每輪 = 150ms 逾時（比 100ms 節奏長，節奏由逾時決定）
        async.elapse(const Duration(milliseconds: 800));

        expect(r.ad.roundsOk, 0, reason: '鎖定之後一包都沒再回');
        expect(r.ad.roundsLate, greaterThanOrEqualTo(3));
        r.ad.stop();
      });
    });

    test('③ 連續到門檻 → 請求重開一次，然後重新起算', () {
      fakeAsync((async) {
        final r = _rig();
        _startLocked(r, async);
        async.elapse(const Duration(milliseconds: 1000));

        expect(r.ad.roundsLate, greaterThanOrEqualTo(5));
        expect(r.mgr.recoveries.length, 1,
            reason: '到門檻才喊一次,不是每輪都喊');
        expect(r.mgr.recoveries.first, contains('連續 5 輪'));
        expect(r.mgr.recoveries.first, contains('150ms'),
            reason: '原因要寫清楚等了多久,給看日誌的人判斷用');

        // 重新起算後再累積 5 輪 → 第二次
        async.elapse(const Duration(milliseconds: 1000));
        expect(r.mgr.recoveries.length, 2, reason: '重新起算後會再觸發');
        r.ad.stop();
      });
    });

    test('④ 有回應 → 算成功，連續延遲歸零', () {
      fakeAsync((async) {
        final r = _rig();
        _startLocked(r, async);

        // 送出後 20ms 就回應（實測正常延遲 11~20ms）
        for (int i = 0; i < 6; i++) {
          async.elapse(const Duration(milliseconds: 20));
          r.mgr.onRawBytes!(fifoReply(10));
          async.elapse(const Duration(milliseconds: 80)); // 補足 100ms 節奏
        }

        expect(r.ad.roundsOk, greaterThanOrEqualTo(5));
        expect(r.ad.roundsLate, 0, reason: '每輪都在 150ms 內回了');
        expect(r.mgr.recoveries, isEmpty, reason: '通訊正常,不該重開');
        expect(r.ad.roundSuccessRate, 1.0);
        r.ad.stop();
      });
    });

    test('⑤ stop() 之後不可以再有任何輪次被計入', () {
      fakeAsync((async) {
        final r = _rig();
        _startLocked(r, async);
        async.elapse(const Duration(milliseconds: 800));
        final lateAtStop = r.ad.roundsLate;
        expect(lateAtStop, greaterThan(0), reason: '先確定真的有在跑');

        r.ad.stop();
        expect(r.ad.measuring, isFalse);

        // 停了之後再放很久,統計一個字都不該動
        async.elapse(const Duration(seconds: 3));
        expect(r.ad.roundsLate, lateAtStop,
            reason: '停止後還在累積,代表迴圈沒退出');
        expect(r.ad.roundsOk, 0);
      });
    });
  });
}
