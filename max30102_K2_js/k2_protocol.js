// ============================================================================
// Max30102Protocol - 0x09 MAX30102 心跳/血氧命令協定 helpers
// ============================================================================
// 【由 Dart 版 k2_protocol.dart 轉譯,行為完全一致。Uint8List → Uint8Array】
//
// 重點:
// - 命令號 0x09,5 個 sub-cmd:QUERY_FIFO / WRITE_REG / READ_REG / RESET / RE-INIT
// - QUERY_FIFO (0x00) 回應 **變動長度**(7 ~ 151 bytes):byte[5] = N*6,總長 = 7 + byte[5]
// - 其餘 sub-cmd 回應固定 9 bytes
// - FIFO 原始資料:每組 6 bytes = RED(3) + IR(3),各 18-bit **低位元組在前**(LE)
// - 表頭第 3 byte = 板子身分:主板 0x30 / 擴充板 0x31(MAX30102 主要落在 0x31)
// - CS = (0x100 − (sum & 0xFF)) & 0xFF;整包 sum & 0xFF == 0 即通過
// ============================================================================

/// 解碼後的單組原始樣本（RED / IR 各 18-bit）
class Max30102Sample {
  constructor(red, ir) {
    this.red = red;
    this.ir = ir;
  }
}

/// MAX30102 命令號 + sub-cmd + 工具
class Max30102Protocol {
  // ---------------- 通用 ----------------
  /// 表頭前兩個 byte,固定不變。
  static kHeaderPrefix = [0x40, 0x71];

  // ── 表頭第 3 個 byte = 板子身分 ──
  /// 主板(K2,出貨中)。表頭 40 71 30。
  static kBoardMain = 0x30;
  /// 擴充板(新):目前只搭載 MAX30102。表頭 40 71 31。
  static kBoardExpansion = 0x31;
  /// 建封包預設的目標板子。實際運行主要落在擴充板。
  static kDefaultBoard = 0x31; // = kBoardExpansion
  /// 相容用:舊碼若還引用 kHeader,指向預設板子的完整表頭。
  static kHeader = [0x40, 0x71, 0x31];

  /// 命令號
  static kCmd = 0x09;

  // ---------------- sub-commands ----------------
  static kSubQueryFifo = 0x00; // 取累積原始 RED/IR，取完即清空
  static kSubWriteReg = 0x01; // 寫一顆晶片暫存器
  static kSubReadReg = 0x02; // 讀一顆晶片暫存器
  static kSubReset = 0x03; // 軟體復位晶片 → POR 休眠（不可用）
  static kSubReInit = 0x04; // 重新初始化成可用狀態（拔插模組後用）

  // ---------------- 晶片暫存器位址 ----------------
  static kRegFifoConfig = 0x08; // FIFO 設定，baseline 0x1F
  static kRegModeConfig = 0x09; // 工作模式，baseline 0x03（SpO2）
  static kRegSpo2Config = 0x0A; // 取樣/解析度，baseline 0x27
  static kRegLedRed = 0x0C; // 紅光 LED 電流（LED1_PA），baseline 0x24
  static kRegLedIr = 0x0D; // 紅外 LED 電流（LED2_PA），baseline 0x24
  static kRegPartId = 0xFF; // 驗晶片在線，應讀回 0x15

  /// PART_ID 在線值
  static kPartIdValue = 0x15;
  /// LED 電流 baseline（re-init 後晶片回到此值）
  static kLedBaseline = 0x24;

  // ---------------- 回應長度 ----------------
  static kFixedLen = 9; // 固定 sub-cmd（WRITE/READ/RESET）回應長度
  static kQueryFifoMinLen = 7; // QUERY_FIFO 最小長度（N=0）
  static kQueryFifoMaxLen = 151; // QUERY_FIFO 最大長度（N=24）
  static kBytesPerSample = 6; // 每組原始資料 byte 數（RED 3 + IR 3）

  // ============================================================
  // 封包建構
  // ============================================================

  /// 通用 wrap:[header 前綴(2)] [board(1)] [cmd=0x09] [payload...] [CS]
  /// CS 由整包現算,換 board 會自動得到對的 CS,不必手動加減。回傳 Uint8Array。
  static _wrap(payload, board = Max30102Protocol.kDefaultBoard) {
    const body = [...Max30102Protocol.kHeaderPrefix, board, Max30102Protocol.kCmd, ...payload];
    const sum = body.reduce((a, b) => a + b, 0);
    const cs = (0x100 - (sum & 0xFF)) & 0xFF;
    body.push(cs);
    return Uint8Array.from(body);
  }

  /// QUERY_FIFO (0x00):取累積的原始 RED/IR。TX 9 bytes。
  ///   主板 40 71 30 09 00 00 00 00 16   擴充板 40 71 31 09 00 00 00 00 15(CS −1)
  static buildQueryFifo(board = Max30102Protocol.kDefaultBoard) {
    return Max30102Protocol._wrap([Max30102Protocol.kSubQueryFifo, 0x00, 0x00, 0x00], board);
  }

  /// WRITE_REG (0x01):寫一顆晶片暫存器。TX: 40 71 [board] 09 01 [reg] [value] 00 [cs]
  static buildWriteReg(reg, value, board = Max30102Protocol.kDefaultBoard) {
    return Max30102Protocol._wrap(
      [Max30102Protocol.kSubWriteReg, reg & 0xFF, value & 0xFF, 0x00], board);
  }

  /// READ_REG (0x02):讀一顆晶片暫存器。TX: 40 71 [board] 09 02 [reg] 00 00 [cs]
  static buildReadReg(reg, board = Max30102Protocol.kDefaultBoard) {
    return Max30102Protocol._wrap(
      [Max30102Protocol.kSubReadReg, reg & 0xFF, 0x00, 0x00], board);
  }

  /// RESET (0x03):軟體復位晶片 → 回 POR 休眠(之後要 RE-INIT 才恢復)。
  static buildReset(board = Max30102Protocol.kDefaultBoard) {
    return Max30102Protocol._wrap([Max30102Protocol.kSubReset, 0x00, 0x00, 0x00], board);
  }

  /// RE-INIT (0x04):重新初始化成可用狀態。RX [5]=1 成功 / 0 失敗。
  static buildReInit(board = Max30102Protocol.kDefaultBoard) {
    return Max30102Protocol._wrap([Max30102Protocol.kSubReInit, 0x00, 0x00, 0x00], board);
  }

  // ============================================================
  // 解析 helpers
  // ============================================================

  /// 驗 CS:整包 sum & 0xFF == 0 即通過。packet 可為 Uint8Array 或一般陣列。
  static verifyCs(packet) {
    if (packet.length < 2) return false;
    let sum = 0;
    for (let i = 0; i < packet.length; i++) sum += packet[i];
    return (sum & 0xFF) === 0;
  }

  /// 解一組 6 bytes:RED_lo RED_mid RED_hi  IR_lo IR_mid IR_hi（各 18-bit LE）
  static decodeSample(b6, offset) {
    const red = (b6[offset] | (b6[offset + 1] << 8) | (b6[offset + 2] << 16)) & 0x3FFFF;
    const ir = (b6[offset + 3] | (b6[offset + 4] << 8) | (b6[offset + 5] << 16)) & 0x3FFFF;
    return new Max30102Sample(red, ir);
  }

  /// 解 QUERY_FIFO 回應 → 原始樣本列表(已驗 CS 的封包)。byte[5]=N*6。
  static decodeFifoResponse(packet) {
    if (packet.length < Max30102Protocol.kQueryFifoMinLen) return [];
    const nbytes = packet[5];
    const result = [];
    // 防呆:避免 nbytes 超過實際封包長度
    const end = (6 + nbytes <= packet.length - 1) ? 6 + nbytes : packet.length - 1;
    for (let i = 6; i + Max30102Protocol.kBytesPerSample <= end; i += Max30102Protocol.kBytesPerSample) {
      result.push(Max30102Protocol.decodeSample(packet, i));
    }
    return result;
  }

  /// READ_REG / WRITE_REG 回應的 { reg, value }
  static parseReg(packet) {
    return { reg: packet[5], value: packet[6] };
  }

  /// 把 bytes 轉 hex 字串
  static hex(bytes) {
    return Array.from(bytes)
      .map((b) => b.toString(16).padStart(2, '0').toUpperCase())
      .join(' ');
  }
}

// ============================================================================
// 接收狀態機（處理 0x09 變動長度回應）
// ============================================================================

const _RxState = {
  waitHeader: 0,
  waitH2: 1,
  waitH3: 2,
  waitCmd: 3,
  waitSub: 4,
  waitBody: 5,
};

/// MAX30102 RX 解析器（仿 ErrorReportRxParser）
///
/// 處理:
/// - 0x09 sub=0x00 QUERY_FIFO:byte[5]=N*6，總長 7 + byte[5]（變動 7~151）
/// - 0x09 sub=0x01/0x02/0x03/0x04:固定 9 bytes
/// - 不認識的 cmd（例 0x08 / 0xB0）:當雜訊丟掉
///
/// 回呼(直接指派函式即可,可為 null):
///   onPacket(packet:Uint8Array)      收到完整封包（已驗 CS）
///   onJunkByte(byte:number)          header 之前的雜訊 byte
///   onError(reason:string, partial)  解析錯誤
class Max30102RxParser {
  constructor() {
    this._state = _RxState.waitHeader;
    this._buf = [];
    this.onPacket = null;
    this.onJunkByte = null;
    this.onError = null;
  }

  reset() {
    this._state = _RxState.waitHeader;
    this._buf.length = 0;
  }

  feed(bytes) {
    for (const b of bytes) this._feedByte(b);
  }

  _feedByte(b) {
    switch (this._state) {
      case _RxState.waitHeader:
        if (b === 0x40) {
          this._buf.length = 0;
          this._buf.push(b);
          this._state = _RxState.waitH2;
        } else if (this.onJunkByte) {
          this.onJunkByte(b);
        }
        break;

      case _RxState.waitH2:
        if (b === 0x71) {
          this._buf.push(b);
          this._state = _RxState.waitH3;
        } else {
          this._buf.length = 0;
          this._state = _RxState.waitHeader;
          this._feedByte(b);
        }
        break;

      case _RxState.waitH3:
        // 板子身分:主板 0x30 或擴充板 0x31 都收(二選一運行)。
        if (b === Max30102Protocol.kBoardMain || b === Max30102Protocol.kBoardExpansion) {
          this._buf.push(b);
          this._state = _RxState.waitCmd;
        } else {
          this._buf.length = 0;
          this._state = _RxState.waitHeader;
          this._feedByte(b);
        }
        break;

      case _RxState.waitCmd:
        this._buf.push(b);
        // 只認 0x09；其餘 cmd 丟掉重新搜尋
        if (b !== Max30102Protocol.kCmd) {
          this._buf.length = 0;
          this._state = _RxState.waitHeader;
        } else {
          this._state = _RxState.waitSub;
        }
        break;

      case _RxState.waitSub:
        this._buf.push(b);
        this._state = _RxState.waitBody;
        break;

      case _RxState.waitBody:
        this._buf.push(b);
        this._tryEmitPacket();
        break;
    }
  }

  _tryEmitPacket() {
    const sub = this._buf[4];
    if (sub === Max30102Protocol.kSubQueryFifo) {
      // 變動長度:先收到 byte[5]（N*6）才知道總長
      if (this._buf.length < 6) return;
      const total = Max30102Protocol.kQueryFifoMinLen - 1 + this._buf[5] + 1; // 6 + N*6 + 1
      if (total > Max30102Protocol.kQueryFifoMaxLen) {
        this._discardFirstByte();
        return;
      }
      if (this._buf.length < total) return;
      this._emitOrDiscard(total);
    } else if (
      sub === Max30102Protocol.kSubWriteReg ||
      sub === Max30102Protocol.kSubReadReg ||
      sub === Max30102Protocol.kSubReset ||
      sub === Max30102Protocol.kSubReInit
    ) {
      if (this._buf.length < Max30102Protocol.kFixedLen) return;
      this._emitOrDiscard(Max30102Protocol.kFixedLen);
    } else {
      // 不認識的 sub → 嘗試固定 9 bytes，CS 不過就丟首 byte
      if (this._buf.length < Max30102Protocol.kFixedLen) return;
      this._emitOrDiscard(Max30102Protocol.kFixedLen);
    }
  }

  _emitOrDiscard(len) {
    const packet = Uint8Array.from(this._buf.slice(0, len));
    if (Max30102Protocol.verifyCs(packet)) {
      this._consumeAndEmit(packet);
    } else {
      if (this.onError) this.onError('CS verification failed', packet);
      this._discardFirstByte();
    }
  }

  _consumeAndEmit(packet) {
    if (this.onPacket) this.onPacket(packet);
    this._buf.splice(0, packet.length);
    this._state = _RxState.waitHeader;
    if (this._buf.length > 0) {
      const remaining = this._buf.slice();
      this._buf.length = 0;
      this.feed(remaining);
    }
  }

  _discardFirstByte() {
    if (this._buf.length > 0) this._buf.splice(0, 1);
    this._state = _RxState.waitHeader;
    if (this._buf.length > 0) {
      const remaining = this._buf.slice();
      this._buf.length = 0;
      this.feed(remaining);
    }
  }
}

module.exports = { Max30102Sample, Max30102Protocol, Max30102RxParser };
