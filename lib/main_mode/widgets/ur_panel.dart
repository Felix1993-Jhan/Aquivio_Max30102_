// ============================================================================
// UrPanel - STM32 控制面板 Widget
// ============================================================================
// 功能：提供 STM32 串口的控制介面
// - COM 埠選擇與連接
// - 命令模式選擇 (0x01啟動/0x02停止/0x03讀取)
// - ID 選擇 (支援多選和單選)
// - 自訂 Payload 輸入
// - 接收日誌顯示
// - 配色：天空藍主色調
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_firmware_tester_unified/shared/services/serial_port_manager.dart';
import 'package:flutter_firmware_tester_unified/shared/services/localization_service.dart';
import 'package:flutter_firmware_tester_unified/main_mode/services/ur_command_builder.dart';

/// 天空藍色調
class _SkyBlueColors {
  static const Color primary = Color(0xFF87CEEB);
  static const Color light = Color(0xFFE3F2FD);
  static const Color dark = Color(0xFF1976D2);
  static const Color background = Color(0xFFE1F5FE);
  static const Color header = Color(0xFF81D4FA);
}

class UrPanel extends StatefulWidget {
  /// 串口管理器
  final SerialPortManager manager;

  /// 目前選擇的 COM 埠
  final String? selectedPort;

  /// 可用的 COM 埠列表
  final List<String> availablePorts;

  /// HEX 輸入框控制器
  final TextEditingController hexController;

  /// COM 埠選擇變更回調
  final ValueChanged<String?> onPortChanged;

  /// 連接按鈕回調
  final VoidCallback onConnect;

  /// 斷開按鈕回調
  final VoidCallback onDisconnect;

  /// 發送 Payload 回調(payload, 站號 board)
  final void Function(List<int> payload, int board) onSendPayload;

  /// 從輸入框發送回調(帶目前站號 board)
  final void Function(int board) onSendFromInput;

  const UrPanel({
    super.key,
    required this.manager,
    required this.selectedPort,
    required this.availablePorts,
    required this.hexController,
    required this.onPortChanged,
    required this.onConnect,
    required this.onDisconnect,
    required this.onSendPayload,
    required this.onSendFromInput,
  });

  @override
  State<UrPanel> createState() => _UrPanelState();
}

class _UrPanelState extends State<UrPanel> {
  // ==================== ID 對照表 ====================
  /// ID 名稱與數值對照
  static const List<Map<String, dynamic>> idList = [
    {'name': 's0', 'id': 0},
    {'name': 's1', 'id': 1},
    {'name': 's2', 'id': 2},
    {'name': 's3', 'id': 3},
    {'name': 's4', 'id': 4},
    {'name': 's5', 'id': 5},
    {'name': 's6', 'id': 6},
    {'name': 's7', 'id': 7},
    {'name': 's8', 'id': 8},
    {'name': 's9', 'id': 9},
    {'name': 'water', 'id': 10},
    {'name': 'u0', 'id': 11},
    {'name': 'u1', 'id': 12},
    {'name': 'u2', 'id': 13},
    {'name': 'arl', 'id': 14},
    {'name': 'crl', 'id': 15},
    {'name': 'srl', 'id': 16},
    {'name': 'o3', 'id': 17},
    // 以下只在 0x03 讀取模式顯示
    {'name': 'flow', 'id': 18},
    {'name': 'prec', 'id': 19},
    {'name': 'prew', 'id': 20},
    {'name': 'mcutemp', 'id': 21},
    {'name': 'watertemp', 'id': 22},
    {'name': 'bibtemp', 'id': 23},
  ];

  // ==================== 狀態變數 ====================
  /// 站號(Header3):0x30 主板 / 0x31 擴充板。預設擴充板(目前測試都在這塊)。
  int _board = URCommandBuilder.boardExpansion;

  /// 當前選擇的命令模式: 0x01=啟動, 0x02=停止, 0x03=讀取
  int _commandMode = 0x01;

  /// 選中的 ID 集合 (用於 0x01/0x02 多選模式)
  final Set<int> _selectedIds = {};

  /// 單選的 ID (用於 0x03 讀取模式)
  int? _selectedReadId;

  /// 自訂 Payload 輸入區是否展開
  bool _isCustomPayloadExpanded = false;

  @override
  Widget build(BuildContext context) {
    // 監聽語言變更，自動更新 UI
    return ValueListenableBuilder<AppLanguage>(
      valueListenable: LocalizationService().currentLanguageNotifier,
      builder: (context, _, _) {
        return Container(
          color: _SkyBlueColors.background,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 標題列
              _buildHeader(),
              // 串口選擇區
              _buildPortSelector(),
              // 站號(板子)選擇
              _buildBoardSelector(),
              // 命令模式選擇
              _buildCommandModeSelector(),
              // ID 選擇區
              _buildIdSelector(),
              // 命令預覽區
              _buildCommandPreview(),
              // 發送按鈕
              _buildSendButton(),
              // 自訂指令輸入區
              _buildInputSection(),
              // 接收日誌區
              _buildLogSection(),
            ],
          ),
        );
      },
    );
  }

  /// 建構標題列
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: _SkyBlueColors.header,
      child: Row(
        children: [
          Icon(Icons.developer_board, color: _SkyBlueColors.dark),
          const SizedBox(width: 8),
          Text(
            tr('stm32_control'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          // 心跳狀態指示器（持續連接中）
          ValueListenableBuilder<bool>(
            valueListenable: widget.manager.heartbeatOkNotifier,
            builder: (context, heartbeatOk, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: widget.manager.isConnectedNotifier,
                builder: (context, isConnected, _) {
                  if (!isConnected) return const SizedBox.shrink();
                  return Tooltip(
                    message: heartbeatOk ? tr('continuous_connection') : tr('connection_lost'),
                    child: Icon(
                      heartbeatOk ? Icons.link : Icons.link_off,
                      color: heartbeatOk ? Colors.green.shade700 : Colors.red,
                      size: 20,
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(width: 8),
          // 韌體版本顯示
          ValueListenableBuilder<String?>(
            valueListenable: widget.manager.firmwareVersionNotifier,
            builder: (context, version, _) {
              if (version == null) return const SizedBox.shrink();
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue.shade700,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Firmware: $version',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              );
            },
          ),
          const Spacer(),
          // 連接狀態指示器
          ValueListenableBuilder<bool>(
            valueListenable: widget.manager.isConnectedNotifier,
            builder: (context, isConnected, _) {
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isConnected ? Colors.green : Colors.red,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  isConnected ? tr('connected') : tr('disconnected'),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 建構串口選擇區
  Widget _buildPortSelector() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: tr('select_com_port'),
                border: const OutlineInputBorder(),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: widget.availablePorts.contains(widget.selectedPort) ? widget.selectedPort : null,
                  hint: Text(tr('select_com_port')),
                  isExpanded: true,
                  isDense: true,
                  items: widget.availablePorts.toSet().map((port) {
                    return DropdownMenuItem(value: port, child: Text(port));
                  }).toList(),
                  onChanged: widget.onPortChanged,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<bool>(
            valueListenable: widget.manager.isConnectedNotifier,
            builder: (context, isConnected, _) {
              return ElevatedButton(
                onPressed: isConnected ? widget.onDisconnect : widget.onConnect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isConnected ? Colors.red : Colors.green,
                  foregroundColor: Colors.white,
                ),
                child: Text(isConnected ? tr('disconnect') : tr('connect')),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 建構站號(板子)選擇區。切換 Header3 = 0x30 主板 / 0x31 擴充板。
  /// 影響所有送出的指令(含自訂 Payload、Hex 預覽)。
  Widget _buildBoardSelector() {
    Widget btn(String label, int board, String hint) {
      final sel = _board == board;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() => _board = board),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            decoration: BoxDecoration(
              color: sel ? _SkyBlueColors.primary : Colors.white,
              border: Border.all(
                  color: sel ? _SkyBlueColors.primary : Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: sel ? Colors.white : Colors.black87)),
              Text(hint,
                  style: TextStyle(
                      fontSize: 10,
                      color: sel ? Colors.white70 : Colors.grey.shade600)),
            ]),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('站號(Header3)',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Row(children: [
            btn('主板 0x30', URCommandBuilder.boardMain, '機器控制 · 異常偵測'),
            const SizedBox(width: 8),
            btn('擴充板 0x31', URCommandBuilder.boardExpansion, '新功能 · 目前測試'),
          ]),
        ],
      ),
    );
  }

  /// 建構命令模式選擇區
  Widget _buildCommandModeSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('command_mode'), style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              _buildModeButton(tr('mode_start'), 0x01, Colors.green),
              const SizedBox(width: 8),
              _buildModeButton(tr('mode_stop'), 0x02, Colors.red),
              const SizedBox(width: 8),
              _buildModeButton(tr('mode_read'), 0x03, Colors.blue),
            ],
          ),
        ],
      ),
    );
  }

  /// 建構模式按鈕
  Widget _buildModeButton(String label, int mode, Color color) {
    final isSelected = _commandMode == mode;
    return ElevatedButton(
      onPressed: () {
        setState(() {
          _commandMode = mode;
          // 切換模式時清空選擇
          _selectedIds.clear();
          _selectedReadId = null;
        });
      },
      style: ElevatedButton.styleFrom(
        backgroundColor: isSelected ? color : Colors.grey.shade300,
        foregroundColor: isSelected ? Colors.white : Colors.black,
        minimumSize: const Size(100, 36),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  /// 建構 ID 選擇區
  Widget _buildIdSelector() {
    // 根據命令模式決定顯示的 ID 數量
    final maxId = (_commandMode == 0x03) ? 23 : 17;
    final displayList = idList.where((item) => item['id'] <= maxId).toList();

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _commandMode == 0x03 ? tr('id_select_single') : tr('id_select_multi'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              // 0x01/0x02 模式下顯示全選/取消全選按鈕
              if (_commandMode != 0x03) ...[
                TextButton(
                  onPressed: () {
                    setState(() {
                      // 全選 ID 0-17
                      _selectedIds.clear();
                      for (int i = 0; i <= 17; i++) {
                        _selectedIds.add(i);
                      }
                    });
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(50, 28),
                  ),
                  child: Text(tr('select_all'), style: const TextStyle(fontSize: 11)),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectedIds.clear();
                    });
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(50, 28),
                  ),
                  child: Text(tr('cancel'), style: const TextStyle(fontSize: 11)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: displayList.map((item) {
              final id = item['id'] as int;
              final name = item['name'] as String;
              return _buildIdButton(name, id);
            }).toList(),
          ),
        ],
      ),
    );
  }

  /// 建構 ID 按鈕
  Widget _buildIdButton(String name, int id) {
    final bool isSelected;
    if (_commandMode == 0x03) {
      // 讀取模式：單選
      isSelected = _selectedReadId == id;
    } else {
      // 啟動/停止模式：多選
      isSelected = _selectedIds.contains(id);
    }

    return ElevatedButton(
      onPressed: () {
        setState(() {
          if (_commandMode == 0x03) {
            // 讀取模式：單選
            _selectedReadId = isSelected ? null : id;
          } else {
            // 啟動/停止模式：多選切換
            if (isSelected) {
              _selectedIds.remove(id);
            } else {
              _selectedIds.add(id);
            }
          }
        });
      },
      style: ElevatedButton.styleFrom(
        backgroundColor:
            isSelected ? _SkyBlueColors.primary : _SkyBlueColors.light,
        foregroundColor: isSelected ? Colors.white : Colors.black,
        minimumSize: const Size(55, 32),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: Text(name, style: const TextStyle(fontSize: 11)),
    );
  }

  /// 建構命令預覽區
  Widget _buildCommandPreview() {
    final preview = _getCommandPreview();
    if (preview == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade400),
          ),
          child: Text(
            tr('select_id_to_preview'),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _SkyBlueColors.light,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _SkyBlueColors.primary),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('command_preview'),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            SelectableText(
              preview,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: _SkyBlueColors.dark,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 取得命令預覽字串 (含 Header 和 CS)
  String? _getCommandPreview() {
    List<int>? payload;

    if (_commandMode == 0x03) {
      // 讀取模式：單選 ID
      if (_selectedReadId == null) return null;
      payload = [0x03, _selectedReadId!, 0x00, 0x00, 0x00];
    } else {
      // 啟動/停止模式：多選 ID
      if (_selectedIds.isEmpty) return null;

      // 計算 24-bit 值 (低位元、中位元、高位元)
      int bitValue = 0;
      for (final id in _selectedIds) {
        bitValue |= (1 << id);
      }

      final lowByte = bitValue & 0xFF;
      final midByte = (bitValue >> 8) & 0xFF;
      final highByte = (bitValue >> 16) & 0xFF;

      payload = [_commandMode, lowByte, midByte, highByte, 0x00];
    }

    // 加上 Header(第 3 byte = 選定站號)
    final header = [0x40, 0x71, _board];
    final fullCmd = [...header, ...payload];

    // 計算 CS
    int sum = fullCmd.fold(0, (prev, e) => prev + e);
    int cs = (0x100 - (sum & 0xFF)) & 0xFF;
    fullCmd.add(cs);

    // 轉換為 HEX 字串
    return fullCmd
        .map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
  }

  /// 建構發送按鈕
  Widget _buildSendButton() {
    final hasSelection = (_commandMode == 0x03)
        ? _selectedReadId != null
        : _selectedIds.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // 主發送按鈕
          Expanded(
            child: ElevatedButton(
              onPressed: hasSelection ? _sendCommand : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: _SkyBlueColors.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade300,
                minimumSize: const Size(0, 40),
              ),
              child: Text(
                _commandMode == 0x01
                    ? tr('send_start_cmd')
                    : _commandMode == 0x02
                        ? tr('send_stop_cmd')
                        : tr('send_read_cmd'),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 清除流量計按鈕
          ElevatedButton(
            onPressed: _sendClearFlowmeter,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              minimumSize: const Size(80, 40),
            ),
            child: Text(
              tr('clear_flow'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  /// 發送清除流量計指令
  /// 格式: Header + 0x04 + 0x12 + 0x00 + 0x00 + 0x00 + CS
  void _sendClearFlowmeter() {
    // 0x04 = 清除流量計指令, 0x12 = flow ID (18)
    final payload = [0x04, 0x12, 0x00, 0x00, 0x00];
    widget.onSendPayload(payload, _board);
  }

  /// 發送命令
  void _sendCommand() {
    if (_commandMode == 0x03) {
      // 讀取模式：單選 ID
      if (_selectedReadId == null) return;
      // 格式: 0x03 ID 0x00 0x00 0x00
      final payload = [0x03, _selectedReadId!, 0x00, 0x00, 0x00];
      widget.onSendPayload(payload, _board);
    } else {
      // 啟動/停止模式：多選 ID，計算 bit 位置
      if (_selectedIds.isEmpty) return;

      // 計算 24-bit 值 (低位元、中位元、高位元)
      int bitValue = 0;
      for (final id in _selectedIds) {
        bitValue |= (1 << id);
      }

      final lowByte = bitValue & 0xFF;
      final midByte = (bitValue >> 8) & 0xFF;
      final highByte = (bitValue >> 16) & 0xFF;

      // 格式: 命令 低位元 中位元 高位元 0x00
      final payload = [_commandMode, lowByte, midByte, highByte, 0x00];
      widget.onSendPayload(payload, _board);
    }
  }

  /// 建構自訂指令輸入區（可收合）
  Widget _buildInputSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 標題列（可點擊展開/收合）
          InkWell(
            onTap: () {
              setState(() {
                _isCustomPayloadExpanded = !_isCustomPayloadExpanded;
              });
            },
            child: Row(
              children: [
                Icon(
                  _isCustomPayloadExpanded
                      ? Icons.expand_less
                      : Icons.expand_more,
                  size: 20,
                  color: Colors.grey.shade600,
                ),
                const SizedBox(width: 4),
                Text(
                  tr('custom_payload'),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ),
          // 輸入區（展開時顯示）
          if (_isCustomPayloadExpanded) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widget.hexController,
                    decoration: InputDecoration(
                      hintText: tr('hex_example'),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => widget.onSendFromInput(_board),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _SkyBlueColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(tr('send')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 建構日誌顯示區
  Widget _buildLogSection() {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(tr('receive_log'),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 12),
                // 詳細 RX log 開關：開啟後 log 會記錄每一筆原始 chunk、
                // GPIO ACK 解碼、CS 驗證失敗等。預設關閉避免心跳洗版
                FilterChip(
                  avatar: Icon(
                    widget.manager.verboseRawHexRxLog
                        ? Icons.visibility
                        : Icons.visibility_off,
                    size: 16,
                  ),
                  label: Text(tr('verbose_rx_log')),
                  selected: widget.manager.verboseRawHexRxLog,
                  onSelected: (sel) {
                    setState(() {
                      widget.manager.verboseRawHexRxLog = sel;
                    });
                  },
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => widget.manager.clearLog(),
                  style: TextButton.styleFrom(
                    foregroundColor: _SkyBlueColors.dark,
                  ),
                  child: Text(tr('clear')),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: _SkyBlueColors.primary),
                borderRadius: BorderRadius.circular(8),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SizedBox(
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    child: ValueListenableBuilder<String>(
                      valueListenable: widget.manager.logNotifier,
                      builder: (context, log, _) {
                        return SingleChildScrollView(
                          child: SizedBox(
                            width: constraints.maxWidth,
                            child: SelectableText(
                              log,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
