// ============================================================================
// 串口異常現場紀錄器
// ============================================================================
// 目的：回答「為什麼可以連續送出幾十包卻一個回應都沒有？」
//
// 為什麼不用 PuTTY / 外部監聽工具：
//   ① COM 埠是**獨占**的。我們的 App 握著 COM4 時，PuTTY 根本開不起來。
//      要從外面旁聽得裝 com0com 這類虛擬埠分流驅動（未簽署，這台機器的
//      Application Control 已經擋掉未簽署的 serialport.dll，一樣會被擋）、
//      接硬體邏輯分析儀、或開 Windows USB ETW 追蹤。
//   ② **就算能旁聽也看不到要的東西。** 我們真正需要的是
//      `write()` 實際寫出幾個 byte、以及輸出緩衝區積壓多少 ——
//      那是我們這支程式與驅動之間的事，線路上量不到。
//
// 所以自己錄。只在 App 用，**不屬於 MAX30102 交接核心**。
//
// ⚠️ 記憶體有界：只留最近 [keep] 秒，每次寫入順手裁掉過期的。
//    TX 約 90 B/s（10Hz × 9 bytes）、RX 約 1.5 KB/s（10Hz × 最多 151 bytes），
//    10 秒 ≈ 16 KB，可以放心常駐。
// ============================================================================

import 'dart:io';
import 'dart:typed_data';

/// 一筆紀錄的方向。
enum SerialTraceDir {
  /// 我們送出去的（含 `write()` 的實際回傳值）。
  tx,

  /// 我們收到的。
  rx,

  /// 不是資料，是事件（開啟 / 關閉 / 重開）。
  note,
}

/// 環形緩衝區裡的一筆。
class _Ev {
  _Ev.tx(this.at, this.bytes, this.ret, this.outQ)
      : dir = SerialTraceDir.tx,
        text = null;

  _Ev.rx(this.at, this.bytes)
      : dir = SerialTraceDir.rx,
        ret = null,
        outQ = null,
        text = null;

  _Ev.note(this.at, this.text)
      : dir = SerialTraceDir.note,
        bytes = null,
        ret = null,
        outQ = null;

  final DateTime at;
  final SerialTraceDir dir;
  final Uint8List? bytes;

  /// `write()` 的回傳值。**可能小於要求長度，也可能是負的錯誤碼。**
  final int? ret;

  /// 送出當下輸出緩衝區還積著幾個 byte（`sp_output_waiting`）。
  /// 這個數字一路往上爬 ⇒ 裝置沒有在收，寫入會開始被截斷。
  final int? outQ;

  final String? text;

  /// 要求寫出的長度（TX 才有意義）。
  int get want => bytes?.length ?? 0;

  /// 這一筆 TX 是不是完整寫出去了。
  bool get txOk => ret != null && ret == want;
}

/// 串口收送的現場紀錄。每個 [SerialPortManager] 一份。
class SerialTrace {
  /// 常駐保留多久的歷史（停滯前的現場）。
  static const Duration keep = Duration(seconds: 10);

  /// 觸發後再多錄多久才寫檔（停滯後的現場，含重開恢復那一刻）。
  static const Duration postRoll = Duration(seconds: 1);

  final List<_Ev> _ring = [];

  /// 已經排定寫檔了，不要重複排（50ms 的迴圈會連續觸發）。
  bool _armed = false;

  String _portName = '?';
  int _baud = 0;
  DateTime? _openedAt;

  /// 這次觸發的描述與時刻，寫檔時當表頭用。
  String _reason = '';
  DateTime _trigAt = DateTime.now();

  /// 觸發當下「出事的那個 handle 活了多久」。
  ///
  /// ⚠️ 必須在觸發時就定住，**不能等寫檔時才算**：重開發生在 [postRoll] 的
  ///    1 秒窗內，[_openedAt] 已經被新 handle 蓋掉，到時候算出來的是新 handle
  ///    的 1 秒，不是出事那個的（實測 657.8 秒）—— 那個數字正是判斷
  ///    「是不是固定壽命的閒置計時器」的唯一依據，蓋掉就白做了。
  String _aliveAtTrig = '不明';

  /// 最近一次寫出的檔案路徑（UI 想顯示給使用者看時可用）。
  String? lastDumpPath;

  /// 改寫落地位置。只給測試用 —— 不覆寫就是桌面，測試不該往使用者桌面丟檔案。
  Directory? dumpDirOverride;

  /// 協定層（K2 的輪次）在觸發當下的摘要，寫進報告表頭。
  ///
  /// 為什麼做成回呼而不是欄位：輪次每秒跑 10 次，每輪去組一個字串是白做工。
  /// 回呼只在真的要寫報告時才被叫一次。
  ///
  /// 為什麼需要它：停滯有兩個發現者 —— 協定層（連續 N 輪沒回應，約 0.5 秒）
  /// 與這一層的看門狗（3 秒沒有任何 byte）。協定層觸發時它的統計會寫在
  /// `觸發原因` 裡，但**看門狗先觸發時就沒有**，報告會少掉「對方到底有沒有
  /// 在回應」這個視角。這支補上那個缺口。
  String Function()? protocolProbe;

  void onOpen(String portName, int baud) {
    _portName = portName;
    _baud = baud;
    _openedAt = DateTime.now();
    note('串口開啟 $portName @ $baud');
  }

  /// 記一筆事件（不是資料）。
  void note(String text) => _push(_Ev.note(DateTime.now(), text));

  /// 記一筆送出。[ret] 是 `write()` 的回傳值，[outQ] 是 `bytesToWrite`。
  void tx(List<int> bytes, int ret, int? outQ) =>
      _push(_Ev.tx(DateTime.now(), Uint8List.fromList(bytes), ret, outQ));

  /// 記一筆收到。
  void rx(Uint8List bytes) =>
      _push(_Ev.rx(DateTime.now(), Uint8List.fromList(bytes)));

  void _push(_Ev e) {
    _ring.add(e);
    // 裁掉過期的。_armed 期間不裁，否則觸發前的現場會被新資料擠掉。
    if (_armed) return;
    final cutoff = e.at.subtract(keep);
    int drop = 0;
    while (drop < _ring.length && _ring[drop].at.isBefore(cutoff)) {
      drop++;
    }
    if (drop > 0) _ring.removeRange(0, drop);
  }

  /// 觸發寫檔：先記下現場，再等 [postRoll] 把「之後」也錄進去才落地。
  ///
  /// [onDone] 在檔案寫完後回呼（寫得出來才帶路徑，失敗帶錯誤訊息）。
  void armDump(String reason, {void Function(String msg)? onDone}) {
    if (_armed) return;
    _armed = true;
    _reason = reason;
    _trigAt = DateTime.now();
    _aliveAtTrig = _snapAlive();
    note('⚠️ 觸發現場紀錄');
    Future<void>.delayed(postRoll, () {
      final msg = _writeFile();
      _armed = false;
      // 寫完就把這段現場丟掉，下一次從乾淨的開始。
      _ring.clear();
      onDone?.call(msg);
    });
  }

  /// 立刻落地（給關閉前的收尾用，不等 postRoll）。
  String dumpNow(String reason) {
    _reason = reason;
    _trigAt = DateTime.now();
    _aliveAtTrig = _snapAlive();
    final msg = _writeFile();
    _ring.clear();
    return msg;
  }

  /// 把「現在這個 handle 活了多久」算成字串。見 [_aliveAtTrig] 的警告。
  String _snapAlive() {
    final opened = _openedAt;
    if (opened == null) return '不明';
    final s = _trigAt.difference(opened).inMilliseconds / 1000.0;
    return '${s.toStringAsFixed(1)} 秒';
  }

  // ── 寫檔 ──────────────────────────────────────────────────────────────

  String _writeFile() {
    try {
      final dir = _dumpDir();
      dir.createSync(recursive: true);
      final name = 'stall_${_stamp(_trigAt)}.txt';
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      file.writeAsStringSync(_render());
      lastDumpPath = file.path;
      return '現場已存到 ${file.path}';
    } catch (e) {
      return '現場寫檔失敗: $e';
    }
  }

  /// 桌面底下的資料夾。取不到桌面就退到暫存目錄，不讓寫檔失敗。
  Directory _dumpDir() {
    final override = dumpDirOverride;
    if (override != null) return override;
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    if (home.isNotEmpty) {
      final desktop = Directory(
        '$home${Platform.pathSeparator}Desktop${Platform.pathSeparator}串口異常紀錄',
      );
      // 桌面本身存在就用它（資料夾不存在沒關係，createSync 會建）。
      if (Directory('$home${Platform.pathSeparator}Desktop').existsSync()) {
        return desktop;
      }
    }
    return Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}串口異常紀錄',
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _stamp(DateTime t) =>
      '${t.year}${_two(t.month)}${_two(t.day)}_'
      '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

  /// 相對觸發時刻的秒數，負數 = 之前。
  String _rel(DateTime t) {
    final ms = t.difference(_trigAt).inMicroseconds / 1000000.0;
    final s = ms.toStringAsFixed(3);
    return (ms < 0 ? s : '+$s').padLeft(8);
  }

  static String _hex(Uint8List b, {int max = 32}) {
    final take = b.length > max ? b.sublist(0, max) : b;
    final s = take
        .map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
    return b.length > max ? '$s … (共 ${b.length} bytes)' : s;
  }

  String _render() {
    final sb = StringBuffer();
    final txs = _ring.where((e) => e.dir == SerialTraceDir.tx).toList();
    final rxs = _ring.where((e) => e.dir == SerialTraceDir.rx).toList();

    sb.writeln('=' * 78);
    sb.writeln('串口異常現場');
    sb.writeln('=' * 78);
    sb.writeln('觸發時間        : ${_trigAt.toIso8601String()}');
    sb.writeln('串口 / 鮑率     : $_portName / $_baud');
    sb.writeln('出事的 handle 活了: $_aliveAtTrig');
    sb.writeln('觸發原因        : $_reason');
    sb.writeln();

    // ── 自動判讀：把要看的結論先算出來，不用自己數 ──
    sb.writeln('-' * 78);
    sb.writeln('自動判讀');
    sb.writeln('-' * 78);

    final lastRx = rxs.isEmpty ? null : rxs.last;
    sb.writeln(lastRx == null
        ? '最後一次收到    : 這段期間內完全沒收到過'
        : '最後一次收到    : 觸發前 '
            '${(-lastRx.at.difference(_trigAt).inMilliseconds / 1000).toStringAsFixed(3)}'
            ' 秒（長度 ${lastRx.want}）');

    // ★ 這是這份檔案的重點：送出到底成功了沒有。
    //   write() 走的是 sp_nonblocking_write —— **可以只寫出一部分，也可以回
    //   負的錯誤碼，兩種都不丟例外**。半截封包送到 MCU 會 checksum 不過，
    //   MCU 就「正確地」不回答 —— 看起來像對方故障，其實是我們沒送完。
    final full = txs.where((e) => e.txOk).length;
    final partial =
        txs.where((e) => (e.ret ?? -1) >= 0 && e.ret != e.want).length;
    final neg = txs.where((e) => (e.ret ?? 0) < 0).length;
    sb.writeln('送出統計        : 呼叫 ${txs.length} 次 / '
        '完整寫出 $full 次 / 部分寫出 $partial 次 / 回負數 $neg 次');

    // ★ 無條件輸出的一行結論。
    //   為什麼要有這行：檔尾的「怎麼讀這份檔案」本來就會提到「半截封包」，
    //   所以**拿關鍵字去搜整份檔案一定會誤判**（這是測試抓到的）。
    //   一行結論讓「有沒有問題」只有一個出處，人看一行就夠，要篩一堆檔案
    //   也可以直接搜這行。
    if (txs.isEmpty) {
      sb.writeln('送出端結論      : ⬜ 這段期間內沒有送出任何東西');
    } else if (partial > 0 || neg > 0) {
      sb.writeln('送出端結論      : ⚠️ 送出端有問題 —— 有 ${partial + neg} 次沒把'
          '封包送完。對面收到半截 frame → checksum 不過 → 不回答，'
          '**它沒錯，是我們沒送完**');
    } else {
      sb.writeln('送出端結論      : ✅ 送出端正常（每一包都完整寫出）'
          ' ⇒ 要查的是對面或線路，不是我們的送出');
    }

    // 協定層的視角（有掛才印）。看門狗先觸發時,這是唯一能回答
    // 「對方到底有沒有在回應」的地方。
    final probe = protocolProbe;
    if (probe != null) {
      try {
        sb.writeln('協定層狀況      : ${probe()}');
      } catch (e) {
        sb.writeln('協定層狀況      : 取得失敗($e)');
      }
    }

    final outQs =
        txs.map((e) => e.outQ).whereType<int>().toList(growable: false);
    if (outQs.isEmpty) {
      sb.writeln('輸出緩衝區      : 沒有取樣到');
    } else {
      final lo = outQs.reduce((a, b) => a < b ? a : b);
      final hi = outQs.reduce((a, b) => a > b ? a : b);
      sb.writeln('輸出緩衝區積壓  : 最低 $lo → 最高 $hi bytes'
          '${hi > lo ? '（往上爬 ⇒ 裝置沒有在把資料收走）' : '（平穩）'}');
    }
    sb.writeln();

    // ── 逐筆 ──
    sb.writeln('-' * 78);
    sb.writeln('逐筆（時間相對於觸發時刻，負數 = 觸發之前）');
    sb.writeln('-' * 78);
    sb.writeln('    時間  方向  寫出/要求  outQ  內容');
    for (final e in _ring) {
      switch (e.dir) {
        case SerialTraceDir.note:
          sb.writeln('${_rel(e.at)}  --                     ${e.text}');
        case SerialTraceDir.rx:
          sb.write('${_rel(e.at)}  RX    ${e.want.toString().padLeft(9)}'
              '        ${_hex(e.bytes!)}');
          sb.writeln(identical(e, lastRx) ? '   ← 最後一次收到' : '');
        case SerialTraceDir.tx:
          final ret = e.ret ?? 0;
          final mark = e.txOk
              ? ''
              : (ret < 0
                  ? '   ⚠️ 回負數 $ret（錯誤碼，不是數量）'
                  : '   ⚠️ 只寫出 $ret / ${e.want}');
          sb.writeln('${_rel(e.at)}  TX    '
              '${'$ret/${e.want}'.padLeft(9)}'
              '  ${(e.outQ ?? -1).toString().padLeft(4)}  '
              '${_hex(e.bytes!)}$mark');
      }
    }
    sb.writeln();
    sb.writeln('-' * 78);
    sb.writeln('怎麼讀這份檔案');
    sb.writeln('-' * 78);
    sb.writeln('① 先看「送出統計」。只要 partial 或負數 > 0，問題就在我們的送出端，');
    sb.writeln('   不是 MCU 不回答 —— 我們送的是半截封包，MCU 擋掉是對的。');
    sb.writeln('② 再看「輸出緩衝區積壓」。往上爬代表 USB 裝置沒有把資料收走');
    sb.writeln('   （裝置被電源管理暫停、或 handle 已經壞掉）。');
    sb.writeln('③ 兩個都正常（全部完整寫出、outQ 平穩）才是真的「送出去了但對方沒回」，');
    sb.writeln('   那時候要查的就是 MCU 端或線路。');
    return sb.toString();
  }
}
