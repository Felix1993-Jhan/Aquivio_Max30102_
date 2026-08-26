// ============================================================================
// MainNavigationPage — MAX30102 K2 交接測試主畫面
// ============================================================================
// 功能：
// - 3 個頁面：MAX30102 K2（交接版，預設首頁）/ STM32 控制面板 / 設定
// - 啟動時自動掃描 COM 埠並連線 STM32
// - 使用 SerialController mixin 提供 STM32 串口操作
//
// 串口共用原則：
//   整個 App 只維護「一條」STM32 連線（_urManager）。K2 頁與 UR 面板共用它，
//   同一個 COM 埠不可能雙開，所以切頁時必須交接 onRawBytes 與心跳的所有權。
// ============================================================================

import 'dart:async';
import 'package:flutter/material.dart';

import 'package:flutter_firmware_tester_unified/shared/services/port_filter_service.dart';
import 'package:flutter_firmware_tester_unified/shared/services/serial_port_manager.dart';
import 'package:flutter_firmware_tester_unified/shared/services/localization_service.dart';

import 'controllers/serial_controller.dart';
import 'services/ur_command_builder.dart';
import 'max30102_K2/ui/k2_page.dart';
import 'widgets/settings_page.dart';
import 'widgets/ur_panel.dart';

/// 分頁索引常數（避免魔術數字散落在切頁邏輯裡）
class _Pages {
  static const int k2 = 0;
  static const int urPanel = 1;
  static const int settings = 2;
}

class MainNavigationPage extends StatefulWidget {
  const MainNavigationPage({super.key});

  @override
  State<MainNavigationPage> createState() => _MainNavigationPageState();
}

class _MainNavigationPageState extends State<MainNavigationPage>
    with SerialController {
  // ==================== 串口管理器 ====================
  final SerialPortManager _urManager =
      SerialPortManager('UR', isTextMode: false);

  // ==================== State ====================
  String? _selectedUrPort;
  List<String> _availablePorts = [];

  int _selectedPageIndex = _Pages.k2;

  /// 目前 STM32 連線是否處於「診斷模式」（K2 頁）
  /// 診斷模式：暫停 _urManager 心跳，由 K2 adapter 接管 onRawBytes 解析
  /// 控制模式：恢復心跳、清掉診斷 parser
  bool _stm32DiagnosticMode = false;

  /// COM 埠監控
  Timer? _portMonitorTimer;
  List<String> _lastDetectedPorts = [];

  /// 訊息計時器
  Timer? _messageTimer;
  final ValueNotifier<String> _statusMessage = ValueNotifier('');

  /// HEX 輸入控制器（UR Panel）
  final TextEditingController _hexController = TextEditingController();

  // ==================== SerialController 抽象成員實作 ====================
  @override
  SerialPortManager get urManager => _urManager;
  @override
  String? get selectedUrPort => _selectedUrPort;
  @override
  set selectedUrPort(String? v) => _selectedUrPort = v;

  @override
  void showSnackBarMessage(String message) {
    _statusMessage.value = message;
    _messageTimer?.cancel();
    _messageTimer = Timer(const Duration(seconds: 3), () {
      _statusMessage.value = '';
    });
  }

  // ==================== 生命週期 ====================
  @override
  void initState() {
    super.initState();

    _refreshAvailablePorts();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 啟動 COM 埠監控
      _startPortMonitor();

      // 自動連線 STM32
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      await connectUr();

      // 首頁就是 K2（診斷頁）：connectAndVerifyStm32 內部會 startHeartbeat，
      // 這裡必須補一次 stopHeartbeat，否則每秒 PING 會混進 K2 的資料流。
      if (mounted && _stm32DiagnosticMode && _urManager.isConnected) {
        _urManager.stopHeartbeat();
      }
    });
  }

  @override
  void dispose() {
    _portMonitorTimer?.cancel();
    _messageTimer?.cancel();
    _urManager.close();
    _urManager.dispose();
    _hexController.dispose();
    _statusMessage.dispose();
    super.dispose();
  }

  // ==================== COM 埠管理 ====================
  void _refreshAvailablePorts() {
    try {
      _availablePorts = PortFilterService.getFilteredPorts(excludeStLink: true);
    } catch (_) {
      _availablePorts = [];
    }
  }

  void _startPortMonitor() {
    _lastDetectedPorts = List.from(_availablePorts);
    _portMonitorTimer?.cancel();
    _portMonitorTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _checkPortChanges();
    });
  }

  Future<void> _checkPortChanges() async {
    if (!mounted) return;
    List<String> current;
    try {
      current =
          await PortFilterService.getAvailablePortsAsync(excludeStLink: true);
    } catch (_) {
      return;
    }

    final added = current.where((p) => !_lastDetectedPorts.contains(p)).toList();
    _lastDetectedPorts = List.from(current);

    if (mounted) {
      setState(() {
        _availablePorts = current;
      });
    }

    // 新插入裝置 → 嘗試自動連線
    if (added.isNotEmpty && !_urManager.isConnected) {
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted && !_urManager.isConnected) {
        await connectUr();
        // 自動重連後若仍在 K2 頁，補一次 stopHeartbeat
        // 避免 connectAndVerifyStm32 內部 startHeartbeat 把心跳重新喚醒
        if (mounted && _stm32DiagnosticMode && _urManager.isConnected) {
          _urManager.stopHeartbeat();
        }
      }
    }
  }

  // ==================== UI 建構 ====================
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppLanguage>(
      valueListenable: LocalizationService().currentLanguageNotifier,
      builder: (context, _, _) {
        return Scaffold(
          appBar: _buildAppBar(),
          drawer: _buildDrawer(),
          body: _buildBody(),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Row(
        children: [
          Text(_pageTitle()),
          const SizedBox(width: 16),
          ValueListenableBuilder<String>(
            valueListenable: _statusMessage,
            builder: (_, msg, _) {
              if (msg.isEmpty) return const SizedBox.shrink();
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  msg,
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              );
            },
          ),
        ],
      ),
      backgroundColor: Colors.teal,
      foregroundColor: Colors.white,
      actions: [
        _buildHeartbeatBadge('STM32', _urManager),
        const SizedBox(width: 12),
      ],
    );
  }

  Widget _buildHeartbeatBadge(String label, SerialPortManager mgr) {
    return ValueListenableBuilder<bool>(
      valueListenable: mgr.heartbeatOkNotifier,
      builder: (_, ok, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: mgr.isConnectedNotifier,
          builder: (_, connected, _) {
            final color = connected
                ? (ok ? Colors.greenAccent : Colors.amberAccent)
                : Colors.red.shade300;
            return Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    connected
                        ? (ok ? Icons.check_circle : Icons.warning_amber)
                        : Icons.cancel,
                    size: 14,
                    color: color,
                  ),
                  const SizedBox(width: 4),
                  Text(label,
                      style: TextStyle(
                          fontSize: 12,
                          color: color,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: Colors.teal),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  tr('drawer_title'),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  tr('drawer_subtitle'),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          _drawerItem(_Pages.k2, Icons.monitor_heart, tr('page_k2')),
          _drawerItem(_Pages.urPanel, Icons.bolt, tr('stm32_control')),
          _drawerItem(_Pages.settings, Icons.settings, tr('page_settings')),
        ],
      ),
    );
  }

  Widget _drawerItem(int index, IconData icon, String label) {
    final selected = _selectedPageIndex == index;
    return ListTile(
      leading: Icon(icon, color: selected ? Colors.teal : null),
      title: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.teal : null,
          fontWeight: selected ? FontWeight.bold : null,
        ),
      ),
      selected: selected,
      onTap: () {
        setState(() => _selectedPageIndex = index);
        Navigator.of(context).pop();
      },
    );
  }

  String _pageTitle() {
    switch (_selectedPageIndex) {
      case _Pages.k2:
        return tr('page_k2');
      case _Pages.urPanel:
        return tr('stm32_control');
      case _Pages.settings:
        return tr('page_settings');
      default:
        return tr('app_title');
    }
  }

  /// 依目前分頁套用 STM32 連線模式（只在模式切換時動作，避免每次 rebuild 重置心跳）
  /// K2 頁：自己接管 onRawBytes、自己輪詢，心跳必須停掉不可干擾
  /// 其餘頁：清掉診斷 parser、恢復心跳
  void _applyStm32Mode() {
    final diagnostic = _selectedPageIndex == _Pages.k2;
    if (diagnostic == _stm32DiagnosticMode) return;
    _stm32DiagnosticMode = diagnostic;
    if (diagnostic) {
      // 暫停控制心跳，避免每秒 PING 干擾 K2 的資料流
      _urManager.stopHeartbeat();
    } else {
      // 回到控制頁：解除 K2 的 parser、恢復心跳
      _urManager.onRawBytes = null;
      if (_urManager.isConnected) {
        _urManager.startHeartbeat();
      }
    }
  }

  Widget _buildBody() {
    _applyStm32Mode();
    switch (_selectedPageIndex) {
      case _Pages.urPanel:
        return _buildUrPanel();
      case _Pages.settings:
        return const SettingsPage();
      case _Pages.k2:
      default:
        return _buildK2Page();
    }
  }

  /// K2（交接版）驗證頁：**共用同一條串口**（_urManager），不另開連線。
  Widget _buildK2Page() {
    return K2Page(
      key: const ValueKey('max30102_k2'),
      manager: _urManager,
      availablePorts: _availablePorts,
    );
  }

  Widget _buildUrPanel() {
    return UrPanel(
      manager: _urManager,
      selectedPort: _selectedUrPort,
      availablePorts: _availablePorts,
      hexController: _hexController,
      onPortChanged: (p) => setState(() => _selectedUrPort = p),
      onConnect: () => connectUr(),
      onDisconnect: disconnectUr,
      onSendPayload: (payload, board) => sendUrCommand(payload, board: board),
      onSendFromInput: _sendUrFromInput,
    );
  }

  void _sendUrFromInput([int board = URCommandBuilder.header3]) {
    final text = _hexController.text.trim();
    if (text.isEmpty) {
      showSnackBarMessage(tr('enter_payload'));
      return;
    }
    final hex = text.replaceAll(RegExp(r'[\s,]+'), '');
    if (hex.length % 2 != 0) {
      showSnackBarMessage(tr('hex_length_error'));
      return;
    }
    try {
      final bytes = <int>[];
      for (int i = 0; i < hex.length; i += 2) {
        bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      // 智慧偵測：輸入以 40 71 開頭（完整封包）→ 原封送出（尊重你自己算的 CS）；
      //   否則當 payload → 自動補 [40 71 board] + CS。
      final isFullPacket =
          bytes.length >= 3 && bytes[0] == 0x40 && bytes[1] == 0x71;
      if (isFullPacket) {
        if (!_urManager.isConnected) {
          showSnackBarMessage(tr('connect_stm32_first'));
          return;
        }
        _urManager.sendHex(bytes); // 完整封包，原封送
      } else {
        sendUrCommand(bytes, board: board);
      }
    } catch (e) {
      showSnackBarMessage(trParams('parse_error', {'error': e.toString()}));
    }
  }
}
