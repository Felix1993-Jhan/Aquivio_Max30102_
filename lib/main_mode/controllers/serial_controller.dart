// ============================================================================
// 串口控制器 Mixin（STM32 / UR 專用）
// ============================================================================
// 功能說明：
// 將 STM32（UR 板）的串口操作邏輯從導航頁抽出，提供自動掃描連線、
// 斷線、以及帶 header + checksum 的指令發送。
//
// 精簡說明：
// 交接展示版只保留 STM32 一條連線（K2 交接頁與 UR 手動面板共用），
// 原本的 Arduino 連線 / 流量讀取 / 硬體狀態記錄已全部移除。
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_firmware_tester_unified/shared/services/serial_port_manager.dart';
import 'package:flutter_firmware_tester_unified/shared/services/port_filter_service.dart';
// Stm32ConnectResult 列舉定義在此檔（與 Arduino 的 ConnectResult 同檔，沿用既有結構）
import 'package:flutter_firmware_tester_unified/shared/services/arduino_connection_service.dart';
import 'package:flutter_firmware_tester_unified/shared/services/localization_service.dart';
import '../services/ur_command_builder.dart';

/// 串口控制器 Mixin（僅 STM32）
mixin SerialController<T extends StatefulWidget> on State<T> {
  // ===== 必須由使用者實作的抽象成員 =====

  /// STM32（UR 板）串口管理器
  SerialPortManager get urManager;

  /// 目前選定的 STM32 COM 埠
  String? get selectedUrPort;
  set selectedUrPort(String? value);

  /// 顯示提示訊息（由導航頁決定呈現方式）
  void showSnackBarMessage(String message);

  // ==================== STM32 操作 ====================

  /// 連接 STM32（自動掃描所有 COM 埠尋找正確的 STM32）
  ///
  /// 會自動排除 ST-Link VCP，逐一嘗試每個埠口直到握手成功。
  /// 已選定的埠口會被排在最前面優先嘗試。
  Future<void> connectUr() async {
    final filteredPorts = PortFilterService.getFilteredPorts(
      excludeStLink: true,
    );

    if (filteredPorts.isEmpty) {
      showSnackBarMessage(tr('no_com_port'));
      return;
    }

    showSnackBarMessage(tr('stm32_verifying'));

    // 建立要嘗試的埠口列表（優先嘗試已選擇的埠口）
    final List<String> portsToScan = [];
    if (selectedUrPort != null && filteredPorts.contains(selectedUrPort)) {
      portsToScan.add(selectedUrPort!);
      portsToScan.addAll(filteredPorts.where((p) => p != selectedUrPort));
    } else {
      portsToScan.addAll(filteredPorts);
    }

    // 逐一嘗試每個 COM 埠
    for (final port in portsToScan) {
      if (!mounted) return;

      // 更新下拉選單顯示目前正在測試的埠口
      selectedUrPort = port;
      setState(() {});

      final result = await urManager.connectAndVerifyStm32(port);

      if (!mounted) return;

      if (result == Stm32ConnectResult.success) {
        setState(() {});
        showSnackBarMessage(tr('stm32_connected'));
        return; // 連線成功，結束掃描
      }
    }

    // 所有埠口都嘗試完畢仍然失敗，清除選擇狀態
    selectedUrPort = null;
    setState(() {});
    showSnackBarMessage(tr('stm32_connect_failed'));
  }

  /// 斷開 STM32 連接
  void disconnectUr() {
    urManager.close();
    if (mounted) setState(() {});
    showSnackBarMessage(tr('stm32_disconnected'));
  }

  /// 發送指令到 STM32（自動補上 header 與 checksum）
  void sendUrCommand(List<int> payload,
      {int board = URCommandBuilder.header3}) {
    if (!urManager.isConnected) {
      showSnackBarMessage(tr('connect_stm32_first'));
      return;
    }
    final cmd = URCommandBuilder.buildCommand(payload, board: board);
    urManager.sendHex(cmd);
  }
}
