// ============================================================================
// URCommandBuilder - UR 指令建構器
// ============================================================================
// 功能：用於建構符合 UR 通訊協議的指令
//
// UR 指令格式：
// +--------+--------+--------+------------------+------+
// | Header1| Header2| Header3|     Payload      |  CS  |
// +--------+--------+--------+------------------+------+
// |  0x40  |  0x71  |  0x30  | (自訂資料內容)   | 校驗 |
// +--------+--------+--------+------------------+------+
//
// CS 校驗碼計算方式：
// CS = 0x100 - (Header1 + Header2 + Header3 + Payload各byte總和) & 0xFF
// ============================================================================

class URCommandBuilder {
  // 固定的指令標頭（Header）
  static const int header1 = 0x40; // '@' 字元 (ASCII 64)
  static const int header2 = 0x71; // 'q' 字元 (ASCII 113)

  // ── Header3 = 板子身分(站號)──────────────────────────────────
  /// 主板(0x30):出貨中的機器控制板(控制零件 + 異常偵測)。
  static const int boardMain = 0x30;

  /// 擴充板(0x31):新功能板。
  static const int boardExpansion = 0x31;

  /// 預設站號。歷史上寫死 0x30;呼叫 [buildCommand] 時可另指定 board。
  static const int header3 = boardMain; // 相容:舊碼引用 header3

  /// 計算校驗碼（Checksum）
  ///
  /// @param bytes 要計算的位元組列表（包含 header 和 payload）
  /// @return 校驗碼值（0x00 - 0xFF 範圍內的整數）
  ///
  /// 計算公式：CS = 0x100 - (所有位元組總和 & 0xFF)
  ///
  /// 範例計算：
  /// 假設 bytes = [0x40, 0x71, 0x30, 0x07, 0x01, 0x00]
  /// sum = 0x40 + 0x71 + 0x30 + 0x07 + 0x01 + 0x00 = 0xE9
  /// CS = 0x100 - (0xE9 & 0xFF) = 0x100 - 0xE9 = 0x17
  static int calculateCS(List<int> bytes) {
    int sum = bytes.fold(0, (prev, e) => prev + e);
    return (0x100 - (sum & 0xFF)) & 0xFF;
  }

  /// 建構完整的 UR 指令
  ///
  /// @param payload 指令的資料部分（不含 header 和 CS）
  /// @return 完整的指令位元組列表（含 header、payload、CS）
  ///
  /// 使用範例：
  /// ```dart
  /// var cmd = URCommandBuilder.buildCommand([0x07, 0x01, 0x00]);
  /// // 結果：[0x40, 0x71, 0x30, 0x07, 0x01, 0x00, 0xB8]
  /// ```
  /// [board] = 站號(Header3),預設主板 0x30。CS 由整包現算,換站號自動得對的 CS。
  static List<int> buildCommand(List<int> payload, {int board = header3}) {
    List<int> cmd = [header1, header2, board, ...payload];
    cmd.add(calculateCS(cmd));
    return cmd;
  }
}