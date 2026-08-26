// ============================================================================
// PortFilterService - COM 埠過濾服務
// ============================================================================
// 功能：過濾可用的 COM 埠，排除特定裝置
// - 排除 ST-Link VCP 埠口（透過 VID 識別）
// - 排除已被其他裝置使用的埠口
// ============================================================================

import 'dart:isolate';
import 'package:flutter_libserialport/flutter_libserialport.dart';

/// COM 埠過濾服務
class PortFilterService {
  /// ST-Link 的 USB Vendor ID (STMicroelectronics)
  static const int stLinkVendorId = 0x0483;

  /// 快取已知的 ST-Link 埠口（避免每次都查詢 VendorID）
  static final Set<String> _cachedStLinkPorts = {};

  /// 取得所有可用的 COM 埠（同步版本）
  ///
  /// [excludeStLink] 是否排除 ST-Link VCP 埠口，預設為 true
  /// 注意：此方法會阻塞 UI，建議在需要即時結果時使用
  static List<String> getAvailablePorts({bool excludeStLink = true}) {
    // 使用 toSet() 去除重複埠口名稱，避免 DropdownButton 斷言錯誤
    final allPorts = SerialPort.availablePorts.toSet().toList();

    if (!excludeStLink) {
      return allPorts;
    }

    return allPorts.where((portName) {
      // 先檢查快取
      if (_cachedStLinkPorts.contains(portName)) {
        return false;
      }

      try {
        final port = SerialPort(portName);
        final vendorId = port.vendorId;
        port.dispose();

        // 排除 ST-Link 設備（VID = 0x0483）並加入快取
        if (vendorId == stLinkVendorId) {
          _cachedStLinkPorts.add(portName);
          return false;
        }
        return true;
      } catch (_) {
        // 無法讀取 VID，保留此埠口
        return true;
      }
    }).toList();
  }

  /// 取得所有可用的 COM 埠（非同步版本，不阻塞 UI）
  ///
  /// [excludeStLink] 是否排除 ST-Link VCP 埠口，預設為 true
  /// 此方法在背景執行緒執行，適合用於定時監控
  static Future<List<String>> getAvailablePortsAsync({bool excludeStLink = true}) async {
    return Isolate.run(() {
      // 使用 toSet() 去除重複埠口名稱
      final allPorts = SerialPort.availablePorts.toSet().toList();

      if (!excludeStLink) {
        return allPorts;
      }

      return allPorts.where((portName) {
        try {
          final port = SerialPort(portName);
          final vendorId = port.vendorId;
          port.dispose();

          // 排除 ST-Link 設備（VID = 0x0483）
          if (vendorId == stLinkVendorId) {
            return false;
          }
          return true;
        } catch (_) {
          // 無法讀取 VID，保留此埠口
          return true;
        }
      }).toList();
    });
  }

  /// 清除 ST-Link 埠口快取
  /// 當埠口配置改變時呼叫
  static void clearStLinkCache() {
    _cachedStLinkPorts.clear();
  }

  /// 取得過濾後的 COM 埠（排除指定的埠口和 ST-Link）
  ///
  /// [excludePorts] 要排除的埠口列表
  /// [excludeStLink] 是否排除 ST-Link VCP 埠口，預設為 true
  static List<String> getFilteredPorts({
    List<String> excludePorts = const [],
    bool excludeStLink = true,
  }) {
    final basePorts = getAvailablePorts(excludeStLink: excludeStLink);
    return basePorts.where((p) => !excludePorts.contains(p)).toList();
  }

  /// 檢查指定埠口是否為 ST-Link VCP
  ///
  /// [portName] COM 埠名稱
  static bool isStLinkPort(String portName) {
    // 先檢查快取
    if (_cachedStLinkPorts.contains(portName)) {
      return true;
    }

    try {
      final port = SerialPort(portName);
      final vendorId = port.vendorId;
      port.dispose();

      if (vendorId == stLinkVendorId) {
        _cachedStLinkPorts.add(portName);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 取得埠口的 Vendor ID（用於除錯）
  ///
  /// [portName] COM 埠名稱
  /// 回傳 Vendor ID，若無法讀取則回傳 null
  static int? getVendorId(String portName) {
    try {
      final port = SerialPort(portName);
      final vendorId = port.vendorId;
      port.dispose();
      return vendorId;
    } catch (_) {
      return null;
    }
  }
}
