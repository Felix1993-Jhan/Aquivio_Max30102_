// ============================================================================
// Arduino 連線服務 - 共用定義
// ============================================================================
// 功能：定義 Arduino 連線相關的共用 enum、常數和 Mixin
// 供 Main 和 BodyDoor 模式的 SerialPortManager 使用
// ============================================================================

import 'package:flutter/foundation.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

/// Arduino 連線結果
enum ConnectResult {
  /// 連線成功，模式正確
  success,

  /// 連線成功，但偵測到不同模式的 Arduino
  wrongMode,

  /// 連線失敗（無回應或超時）
  failed,

  /// 無法開啟串口
  portError,
}

/// Arduino 韌體模式（單一模式：Main Board 自動清洗測試）
/// 保留 enum 結構以避免大規模 import 修改，僅剩兩個值
enum ArduinoMode {
  /// Main Board 模式
  main,

  /// 未知模式
  unknown,
}

/// STM32 連線結果
enum Stm32ConnectResult {
  /// 連線成功（收到韌體版本回應）
  success,

  /// 連線失敗（無回應或超時）
  failed,

  /// 無法開啟串口
  portError,
}

// ============================================================================
// Arduino 連線驗證 Mixin
// ============================================================================
// 功能：提供共用的 connectAndVerify() 連線驗證方法
// 使用方式：讓 SerialPortManager 類別 with ArduinoConnectionMixin
// ============================================================================

/// Arduino 連線驗證 Mixin
///
/// 此 Mixin 提供統一的 Arduino 連線驗證邏輯，包括：
/// 1. 開啟串口
/// 2. 等待 Arduino 初始化（bootloader 輸出完成）
/// 3. 發送 connect 指令
/// 4. 輪詢等待回應
/// 5. 根據回應判斷連線結果
///
/// 使用者需要實作以下抽象成員：
/// - connectionPort: 串口物件
/// - connectionReceiveBuffer: 接收緩衝區
/// - heartbeatOkNotifier: 心跳 OK 通知器
/// - wrongModeDetectedNotifier: 錯誤模式偵測通知器
/// - detectedMode: 偵測到的 Arduino 模式（getter 和 setter）
/// - openPort(): 開啟串口
/// - closePort(): 關閉串口
/// - sendStringCommand(): 發送字串指令
/// - startHeartbeatTimer(): 啟動心跳計時器
mixin ArduinoConnectionMixin {
  // ===== 必須由使用者實作的抽象成員 =====

  /// 串口物件
  SerialPort? get connectionPort;

  /// 接收緩衝區
  List<int> get connectionReceiveBuffer;

  /// 心跳 OK 通知器
  ValueNotifier<bool> get heartbeatOkNotifier;

  /// 錯誤模式偵測通知器
  ValueNotifier<bool> get wrongModeDetectedNotifier;

  /// 偵測到的 Arduino 模式
  ArduinoMode get detectedMode;
  set detectedMode(ArduinoMode value);

  /// 開啟串口
  bool openPort(String portName);

  /// 關閉串口
  void closePort();

  /// 發送字串指令
  bool sendStringCommand(String command);

  /// 啟動心跳計時器
  void startHeartbeatTimer();

  // ===== 共用的連線驗證方法 =====

  /// 連線並驗證 Arduino（統一的連線方法）
  ///
  /// 此方法封裝了完整的連線驗證流程：
  /// 1. 開啟串口
  /// 2. 等待 Arduino 初始化（bootloader 輸出完成）
  /// 3. 發送 connect 指令
  /// 4. 輪詢等待回應
  /// 5. 根據回應判斷連線結果
  ///
  /// @param portName COM 埠名稱
  /// @return ConnectResult 連線結果
  Future<ConnectResult> connectAndVerify(String portName) async {
    // 重置偵測到的模式
    detectedMode = ArduinoMode.unknown;

    // 1. 開啟串口
    if (!openPort(portName)) {
      return ConnectResult.portError;
    }

    // 2. 等待 Arduino 初始化（bootloader + setup() 完成）
    //    Arduino 開機時會執行 bootloader（~500ms-1000ms）和 setup()（視韌體而定）
    //    需要足夠時間讓韌體完全啟動才能回應 connect 指令
    await Future.delayed(const Duration(milliseconds: 2000));

    // 3. 清空開機時累積的緩衝區資料（軟體緩衝區 + 硬體緩衝區）
    connectionReceiveBuffer.clear();
    try {
      final available = connectionPort?.bytesAvailable ?? 0;
      if (available > 0) {
        connectionPort?.read(available);  // 清空硬體緩衝區
      }
    } catch (_) {}

    // 4. 發送 connect 指令（最多嘗試 3 次）
    for (int attempt = 0; attempt < 3; attempt++) {
      // 每次嘗試前都清空緩衝區
      connectionReceiveBuffer.clear();
      sendStringCommand('connect');

      // 5. 輪詢等待回應（每次嘗試最多 5 次，每次 200ms = 最多 1 秒）
      for (int i = 0; i < 5; i++) {
        await Future.delayed(const Duration(milliseconds: 200));

        // 檢查是否收到正確模式的回應
        if (heartbeatOkNotifier.value) {
          startHeartbeatTimer();
          return ConnectResult.success;
        }

        // 檢查是否收到錯誤模式的回應
        if (wrongModeDetectedNotifier.value) {
          wrongModeDetectedNotifier.value = false;
          closePort();
          return ConnectResult.wrongMode;
        }
      }

      // 第一次嘗試失敗，等待一下再試一次
      if (attempt == 0) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }

    // 6. 超時，連線失敗
    closePort();
    return ConnectResult.failed;
  }
}
