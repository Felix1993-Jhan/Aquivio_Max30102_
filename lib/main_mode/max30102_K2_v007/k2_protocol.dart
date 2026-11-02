// ============================================================================
// Max30102Protocol - 0x09 MAX30102 心跳/血氧命令協定 helpers
// ============================================================================
// 規格參考：
//   ai_docs/bootloader/spec/MAX30102_CHEATSHEET.md（上位機速查表，完整協定）
//
// 重點（與既有 0x08 / 0xB0 協定的差異）：
// - 命令號 0x09，4 個 sub-cmd：QUERY_FIFO / WRITE_REG / READ_REG / RESET
// - QUERY_FIFO (0x00) 回應 **變動長度**（7 ~ 151 bytes）：byte[5] = N*6（資料 byte 數）
//   總長 = 6 + N*6 + 1 = 7 + byte[5]
// - 其餘 sub-cmd 回應固定 9 bytes
// - FIFO 原始資料：每組 6 bytes = RED(3) + IR(3)，各 18-bit **低位元組在前**（LE）
// - HR / SpO2 不在此計算（晶片只吐原始值），交給 max30102_algorithm.dart
//
// ⚠️ 協定未定項（cheatsheet §8，待實機最終確認，先照草稿實作）：
//   - WRITE/READ_REG 的 reg 放 byte[5]、value 放 byte[6]
//   - QUERY_FIFO 數量欄送 N*6（byte 數）而非組數 N
// ============================================================================

import 'dart:typed_data';

/// 解碼後的單組原始樣本（RED / IR 各 18-bit）
class Max30102Sample {
  final int red;
  final int ir;
  const Max30102Sample(this.red, this.ir);
}

/// MAX30102 命令號 + sub-cmd + 工具
class Max30102Protocol {
  // ---------------- 通用 ----------------
  /// 表頭前兩個 byte,固定不變。
  static const List<int> kHeaderPrefix = [0x40, 0x71];

  // ── 表頭第 3 個 byte = 板子身分 ──────────────────────────────────────
  /// 主板(K2,出貨中):功能最完整。表頭 40 71 **30**。
  static const int kBoardMain = 0x30;

  /// 擴充板(新):目前只搭載 MAX30102。表頭 40 71 **31**。
  static const int kBoardExpansion = 0x31;

  /// 建封包預設的目標板子。實際運行主要落在擴充板([kBoardExpansion])。
  /// ⚠ 改這個常數 = 改「不指定 board 時打哪塊」。想單獨對某塊送,呼叫時帶 board 參數。
  static const int kDefaultBoard = kBoardExpansion;

  /// 相容用:舊碼若還引用 kHeader,指向預設板子的完整表頭。
  static const List<int> kHeader = [...kHeaderPrefix, kDefaultBoard];

  /// 這一組 MAX30102 命令(0x09)在**兩塊板上完全相同**(含 CS 演算法),
  /// 差別只在表頭第 3 個 byte。接收時兩塊都收(見 _RxState.waitH3),
  /// 由 packet[2] 判斷來源;二選一運行,不會同時在線。

  /// 命令號
  static const int kCmd = 0x09;

  // ---------------- sub-commands ----------------
  static const int kSubQueryFifo = 0x00; // 取累積原始 RED/IR，取完即清空
  static const int kSubWriteReg = 0x01; // 寫一顆晶片暫存器
  static const int kSubReadReg = 0x02; // 讀一顆晶片暫存器
  static const int kSubReset = 0x03; // 軟體復位晶片 → POR 休眠（不可用）
  static const int kSubReInit = 0x04; // 重新初始化成可用狀態（拔插模組後用）

  // ---------------- 晶片暫存器位址（cheatsheet §1 baseline / §7.7）----------------
  static const int kRegFifoConfig = 0x08; // FIFO 設定，baseline 0x1F
  static const int kRegModeConfig = 0x09; // 工作模式，baseline 0x03（SpO2）
  static const int kRegSpo2Config = 0x0A; // 取樣/解析度，baseline 0x27
  static const int kRegLedRed = 0x0C; // 紅光 LED 電流（LED1_PA），baseline 0x24
  static const int kRegLedIr = 0x0D; // 紅外 LED 電流（LED2_PA），baseline 0x24
  static const int kRegPartId = 0xFF; // 驗晶片在線，應讀回 0x15

  /// PART_ID 在線值
  static const int kPartIdValue = 0x15;

  /// LED 電流 baseline（re-init 後晶片回到此值）
  static const int kLedBaseline = 0x24;

  // ---------------- 回應長度 ----------------
  /// 固定 sub-cmd（WRITE/READ/RESET）回應長度
  static const int kFixedLen = 9;

  /// QUERY_FIFO 回應最小長度（N=0：40 71 30 09 00 00 [cs] = 7 bytes）
  static const int kQueryFifoMinLen = 7;

  /// QUERY_FIFO 回應最大長度（N=24：7 + 144 = 151 bytes）
  static const int kQueryFifoMaxLen = 151;

  /// 每組原始資料 byte 數（RED 3 + IR 3）
  static const int kBytesPerSample = 6;

  // ============================================================
  // 封包建構
  // ============================================================

  /// 通用 wrap：[header 前綴(2)] [board(1)] [cmd=0x09] [payload...] [CS]
  /// CS = (0x100 - (sum & 0xFF)) & 0xFF（與 URCommandBuilder / ErrorReportProtocol 一致）。
  /// [board] 決定表頭第 3 個 byte(見 kBoardMain / kBoardExpansion),
  /// 預設 [kDefaultBoard]。CS 由整包現算,換 board 會自動得到對的 CS,不必手動加減。
  static Uint8List _wrap(List<int> payload, {int board = kDefaultBoard}) {
    final body = <int>[...kHeaderPrefix, board, kCmd, ...payload];
    final sum = body.fold<int>(0, (a, b) => a + b);
    final cs = (0x100 - (sum & 0xFF)) & 0xFF;
    body.add(cs);
    return Uint8List.fromList(body);
  }

  /// QUERY_FIFO (0x00)：取累積的原始 RED/IR
  /// TX: 40 71 [board] 09 00 00 00 00 [cs] (9 bytes)
  ///   主板  40 71 30 09 00 00 00 00 16   擴充板 40 71 31 09 00 00 00 00 15(CS −1)
  static Uint8List buildQueryFifo({int board = kDefaultBoard}) =>
      _wrap([kSubQueryFifo, 0x00, 0x00, 0x00], board: board);

  /// WRITE_REG (0x01)：寫一顆晶片暫存器
  /// TX: 40 71 [board] 09 01 [reg] [value] 00 [cs] (9 bytes)
  static Uint8List buildWriteReg(int reg, int value, {int board = kDefaultBoard}) =>
      _wrap([kSubWriteReg, reg & 0xFF, value & 0xFF, 0x00], board: board);

  /// READ_REG (0x02)：讀一顆晶片暫存器
  /// TX: 40 71 [board] 09 02 [reg] 00 00 [cs] (9 bytes)
  /// RX: 40 71 [board] 09 02 [reg] [讀回值] 00 [cs]
  static Uint8List buildReadReg(int reg, {int board = kDefaultBoard}) =>
      _wrap([kSubReadReg, reg & 0xFF, 0x00, 0x00], board: board);

  /// RESET (0x03)：軟體復位晶片 → 回 POR 休眠（LED 關、無模式、不採樣）
  /// ⚠️ reset ≠ 可用，之後要 RE-INIT (0x04) 才恢復運作
  /// TX: 40 71 [board] 09 03 00 00 00 [cs] (9 bytes)
  static Uint8List buildReset({int board = kDefaultBoard}) =>
      _wrap([kSubReset, 0x00, 0x00, 0x00], board: board);

  /// RE-INIT (0x04)：重新初始化成可用狀態（reset + 清 FIFO + 寫所有配置 + 驗 PART_ID）
  /// TX: 40 71 [board] 09 04 00 00 00 [cs] (9 bytes)
  /// RX: 40 71 [board] 09 04 [1/0] 00 00 [cs]  → [5]=1 成功 / 0 失敗
  static Uint8List buildReInit({int board = kDefaultBoard}) =>
      _wrap([kSubReInit, 0x00, 0x00, 0x00], board: board);

  // ============================================================
  // 解析 helpers
  // ============================================================

  static bool verifyCs(Uint8List packet) {
    if (packet.length < 2) return false;
    final sum = packet.fold<int>(0, (a, b) => a + b);
    return (sum & 0xFF) == 0;
  }

  /// 解一組 6 bytes：RED_lo RED_mid RED_hi  IR_lo IR_mid IR_hi（各 18-bit LE）
  static Max30102Sample decodeSample(Uint8List b6, int offset) {
    final red = (b6[offset] |
            (b6[offset + 1] << 8) |
            (b6[offset + 2] << 16)) &
        0x3FFFF;
    final ir = (b6[offset + 3] |
            (b6[offset + 4] << 8) |
            (b6[offset + 5] << 16)) &
        0x3FFFF;
    return Max30102Sample(red, ir);
  }

  /// 解 QUERY_FIFO 回應 → 原始樣本列表（已驗 CS 的封包）
  /// byte[5] = N*6，後接 N 組、每組 6 bytes
  static List<Max30102Sample> decodeFifoResponse(Uint8List packet) {
    if (packet.length < kQueryFifoMinLen) return const [];
    final nbytes = packet[5];
    final result = <Max30102Sample>[];
    // 防呆：避免 nbytes 超過實際封包長度
    final end = (6 + nbytes <= packet.length - 1) ? 6 + nbytes : packet.length - 1;
    for (int i = 6; i + kBytesPerSample <= end; i += kBytesPerSample) {
      result.add(decodeSample(packet, i));
    }
    return result;
  }

  /// READ_REG / WRITE_REG 回應的 (reg, value)
  static ({int reg, int value}) parseReg(Uint8List packet) {
    return (reg: packet[5], value: packet[6]);
  }

  /// 把 bytes 轉 hex 字串
  static String hex(Uint8List bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}

// ============================================================================
// 接收狀態機（處理 0x09 變動長度回應）
// ============================================================================

enum _RxState {
  waitHeader,
  waitH2,
  waitH3,
  waitCmd,
  waitSub,
  waitBody,
}

/// MAX30102 RX 解析器（仿 ErrorReportRxParser）
///
/// 處理：
/// - 0x09 sub=0x00 QUERY_FIFO：byte[5]=N*6，總長 7 + byte[5]（變動 7~151）
/// - 0x09 sub=0x01/0x02/0x03：固定 9 bytes
/// - 不認識的 cmd（例 0x08 / 0xB0）：在這頁不處理，當雜訊丟掉
class Max30102RxParser {
  _RxState _state = _RxState.waitHeader;
  final List<int> _buf = [];

  /// 收到完整封包（已驗 CS）
  void Function(Uint8List packet)? onPacket;

  /// header 之前的雜訊 byte
  void Function(int byte)? onJunkByte;

  /// 解析錯誤
  void Function(String reason, Uint8List partial)? onError;

  void reset() {
    _state = _RxState.waitHeader;
    _buf.clear();
  }

  void feed(Uint8List bytes) {
    for (final b in bytes) {
      _feedByte(b);
    }
  }

  void _feedByte(int b) {
    switch (_state) {
      case _RxState.waitHeader:
        if (b == 0x40) {
          _buf
            ..clear()
            ..add(b);
          _state = _RxState.waitH2;
        } else {
          onJunkByte?.call(b);
        }
        break;

      case _RxState.waitH2:
        if (b == 0x71) {
          _buf.add(b);
          _state = _RxState.waitH3;
        } else {
          _buf.clear();
          _state = _RxState.waitHeader;
          _feedByte(b);
        }
        break;

      case _RxState.waitH3:
        // 板子身分:主板 0x30 或擴充板 0x31 都收(二選一運行)。
        // 來源可由 packet[2] 判讀;拆出的 red/ir 樣本兩塊完全相同。
        if (b == Max30102Protocol.kBoardMain ||
            b == Max30102Protocol.kBoardExpansion) {
          _buf.add(b);
          _state = _RxState.waitCmd;
        } else {
          _buf.clear();
          _state = _RxState.waitHeader;
          _feedByte(b);
        }
        break;

      case _RxState.waitCmd:
        _buf.add(b);
        // 只認 0x09；其餘 cmd（0x08 / 0xB0…）丟掉重新搜尋
        if (b != Max30102Protocol.kCmd) {
          _buf.clear();
          _state = _RxState.waitHeader;
        } else {
          _state = _RxState.waitSub;
        }
        break;

      case _RxState.waitSub:
        _buf.add(b);
        _state = _RxState.waitBody;
        break;

      case _RxState.waitBody:
        _buf.add(b);
        _tryEmitPacket();
        break;
    }
  }

  void _tryEmitPacket() {
    final sub = _buf[4];
    if (sub == Max30102Protocol.kSubQueryFifo) {
      // 變動長度：先收到 byte[5]（N*6）才知道總長
      if (_buf.length < 6) return;
      final total = Max30102Protocol.kQueryFifoMinLen - 1 + _buf[5] + 1; // 6 + N*6 + 1
      if (total > Max30102Protocol.kQueryFifoMaxLen) {
        // N*6 不合理 → 丟首 byte 重新搜尋
        _discardFirstByte();
        return;
      }
      if (_buf.length < total) return;
      _emitOrDiscard(total);
    } else if (sub == Max30102Protocol.kSubWriteReg ||
        sub == Max30102Protocol.kSubReadReg ||
        sub == Max30102Protocol.kSubReset ||
        sub == Max30102Protocol.kSubReInit) {
      if (_buf.length < Max30102Protocol.kFixedLen) return;
      _emitOrDiscard(Max30102Protocol.kFixedLen);
    } else {
      // 不認識的 sub → 嘗試固定 9 bytes，CS 不過就丟首 byte
      if (_buf.length < Max30102Protocol.kFixedLen) return;
      _emitOrDiscard(Max30102Protocol.kFixedLen);
    }
  }

  void _emitOrDiscard(int len) {
    final packet = Uint8List.fromList(_buf.sublist(0, len));
    if (Max30102Protocol.verifyCs(packet)) {
      _consumeAndEmit(packet);
    } else {
      onError?.call('CS verification failed', packet);
      _discardFirstByte();
    }
  }

  void _consumeAndEmit(Uint8List packet) {
    onPacket?.call(packet);
    _buf.removeRange(0, packet.length);
    _state = _RxState.waitHeader;
    if (_buf.isNotEmpty) {
      final remaining = Uint8List.fromList(_buf);
      _buf.clear();
      feed(remaining);
    }
  }

  void _discardFirstByte() {
    if (_buf.isNotEmpty) {
      _buf.removeAt(0);
    }
    _state = _RxState.waitHeader;
    if (_buf.isNotEmpty) {
      final remaining = Uint8List.fromList(_buf);
      _buf.clear();
      feed(remaining);
    }
  }
}
