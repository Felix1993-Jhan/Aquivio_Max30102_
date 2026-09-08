// ============================================================================
// SerialPortManager - 串口管理類別
// ============================================================================
// 功能：負責處理單一串口的所有操作，包括：
// - 開啟/關閉串口連接
// - 發送字串指令（Arduino 用）
// - 發送 16 進制指令（UR 用）
// - 接收並解析串口資料
// - 管理日誌記錄
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:flutter_firmware_tester_unified/shared/services/arduino_connection_service.dart';

class SerialPortManager with ArduinoConnectionMixin {
  // -------------------- 私有成員變數 --------------------

  /// 串口物件，null 表示尚未連接
  SerialPort? _port;

  /// 定時讀取計時器（每 50ms 輪詢讀取串口資料）
  Timer? _readTimer;

  // -------------------- 公開成員變數 --------------------

  /// 串口識別名稱（如 "Arduino" 或 "UR"），用於日誌顯示
  final String name;

  /// 日誌通知器
  /// 使用 ValueNotifier 實現響應式更新，當日誌內容變化時會自動通知 UI 更新
  final ValueNotifier<String> logNotifier = ValueNotifier('');

  /// 連接狀態通知器
  /// 當連接狀態變化時會自動通知 UI 更新連接指示燈
  final ValueNotifier<bool> isConnectedNotifier = ValueNotifier(false);

  /// 接收緩衝區 - 用於累積不完整的位元組資料（文字模式 Arduino 用）
  ///
  /// 為什麼需要緩衝區？
  /// 1. 串口資料可能分多次到達（例如一行文字分成 3 次傳送）
  /// 2. UTF-8 編碼的中文字元占用 3 個 bytes，可能被切斷
  /// 3. 需要等待收到換行符才能確定一行資料完整
  final List<int> _receiveBuffer = [];

  /// HEX 模式接收緩衝區（STM32 用）
  ///
  /// USB Serial 是純粹的位元組串流，封包可能分多次到達。
  /// 例如 35 bytes 的回應可能拆成 20 + 15 bytes 兩次。
  /// 需要緩衝區累積 bytes 直到拼成完整封包。
  final List<int> _hexReceiveBuffer = [];

  /// 已偵測到的 STM32 協定格式
  /// - null: 尚未偵測（首次連接時自動偵測）
  /// - false: 舊版協定（固定 9 bytes，韌體 ≤ 0.0.0.6）
  /// - true: 新版協定（含 DataLen byte，動態長度，韌體 ≥ 0.0.0.7）
  bool? _isNewProtocol;

  /// 是否為文字模式
  /// - true（預設）: Arduino 用，接收的是 UTF-8 文字
  /// - false: UR 用，接收的是原始 16 進制資料
  final bool isTextMode;

  /// 期望的 Arduino 模式（保留欄位以維持 API 相容；目前僅有 Main 模式）
  final ArduinoMode expectedMode;

  /// 數據接收回調（用於儲存數據）
  /// 參數: (int id, int value)
  void Function(int id, int value)? onDataReceived;

  /// GPIO 命令確認回調（STM32 專用）
  /// 當收到 0x01(開啟) 或 0x02(關閉) 命令的回應時觸發
  /// 參數: (int command, int bitMask) - command 為 0x01 或 0x02，bitMask 為受影響的腳位
  void Function(int command, int bitMask)? onGpioCommandConfirmed;

  /// Arduino 純文字行回調（非心跳、非已被識別的 ADC 數據格式）
  /// 用於上層做 ack 確認（例如收到 `cleanrelay_on` mirror 回應）
  /// 參數: 接收到的字串（已 trim、未轉小寫）
  void Function(String line)? onArduinoTextLine;

  /// 原始 RX bytes 回調（在文字/HEX 分流之前觸發）
  /// 用於 Bootloader OTA 測試頁等需要自行解析的場景；參數: 該次讀到的完整 chunk
  /// **注意**：若此 callback 設定後仍想保留既有解析，內建解析仍會繼續執行
  void Function(Uint8List bytes)? onRawBytes;

  /// 詳細 RX log 開關（HEX 模式專用，預設 false）
  /// 開啟後 log 會記錄：
  /// - 每一筆接收到的原始 bytes chunk（含被丟棄的雜訊）
  /// - GPIO ACK (0x01 / 0x02) 封包
  /// - CS 驗證失敗、header 對不上時的丟棄事件
  /// 缺點：STM32 心跳 1Hz 會每秒新增一筆原始 chunk log，因此預設關閉
  bool verboseRawHexRxLog = false;

  /// 韌體版本通知器（格式: "0.0.0.X"）
  final ValueNotifier<String?> firmwareVersionNotifier = ValueNotifier(null);

  /// 韌體版本回調（用於通知版本已接收）
  void Function(String version)? onFirmwareVersionReceived;

  /// STM32 連接驗證回調（收到正確 PING 回應時調用）
  void Function(bool success)? onConnectionVerified;

  /// 當前連接的串口名稱
  String? _currentPortName;

  // -------------------- 心跳機制 --------------------

  /// 心跳定時器（每秒發送一次心跳指令）
  Timer? _heartbeatTimer;

  /// 心跳回應狀態通知器（true = 連接正常，false = 等待回應中）
  @override
  final ValueNotifier<bool> heartbeatOkNotifier = ValueNotifier(false);

  /// 連續心跳失敗計數
  int _heartbeatFailCount = 0;

  /// 心跳失敗閾值（連續幾次失敗後視為斷開）
  static const int _heartbeatFailThreshold = 3;

  /// 是否正在等待心跳回應
  bool _waitingForHeartbeat = false;

  /// PING 輪流打的站號(Header3)。主板與擴充板**二選一在線**,而送出去之前
  /// 無從得知對面是哪一塊 —— 收的那一側兩個都認,送的那一側以前卻寫死 0x30,
  /// 結果擴充板在線時心跳必定連續落空、三次之後誤報「連線已斷開」。
  ///
  /// 交叉輪替解掉這件事,而且**不會誤判斷線**:擴充板在線時 0x30 那次落空
  /// (計數 +1)、下一次 0x31 收到回應就歸零,計數在 0↔1 之間擺盪,永遠到不了
  /// [_heartbeatFailThreshold]。真的兩塊都沒回應才會一路累加到觸發。
  static const List<int> _pingBoards = [0x30, 0x31];

  /// 下一次 PING 要打 [_pingBoards] 的哪一個。
  int _pingBoardIdx = 0;

  /// 取下一個要打的站號並前進索引。
  int _nextPingBoard() {
    final b = _pingBoards[_pingBoardIdx % _pingBoards.length];
    _pingBoardIdx++;
    return b;
  }

  /// 上次活動時間（任何指令發送或接收都會更新）
  DateTime _lastActivityTime = DateTime.now();

  /// 心跳失敗回調（用於通知外部連接可能已斷開）
  void Function()? onHeartbeatFailed;

  /// 偵測到錯誤模式的裝置通知器（保留以維持 Mixin 介面相容；單模式專案永遠為 false）
  @override
  final ValueNotifier<bool> wrongModeDetectedNotifier = ValueNotifier(false);

  /// 最後偵測到的 Arduino 模式
  @override
  ArduinoMode detectedMode = ArduinoMode.unknown;

  // -------------------- 建構函式 --------------------

  /// 建構函式
  /// @param name 串口識別名稱，用於日誌顯示
  /// @param isTextMode 是否為文字模式，預設為 true
  SerialPortManager(this.name, {this.isTextMode = true, this.expectedMode = ArduinoMode.main});

  // -------------------- Getter --------------------

  /// 檢查串口是否已連接
  bool get isConnected => _port != null && isConnectedNotifier.value;

  /// 取得當前連接的串口名稱
  String? get currentPortName => _currentPortName;

  // ============================================================================
  // ArduinoConnectionMixin 實作
  // ============================================================================

  /// 串口物件（供 Mixin 使用）
  @override
  SerialPort? get connectionPort => _port;

  /// 接收緩衝區（供 Mixin 使用）
  @override
  List<int> get connectionReceiveBuffer => _receiveBuffer;

  /// 開啟串口（供 Mixin 使用）
  @override
  bool openPort(String portName) => open(portName);

  /// 關閉串口（供 Mixin 使用）
  @override
  void closePort() => close();

  /// 發送字串指令（供 Mixin 使用）
  @override
  bool sendStringCommand(String command) => sendString(command);

  /// 啟動心跳計時器（供 Mixin 使用）
  @override
  void startHeartbeatTimer() => startHeartbeat();

  // ============================================================================
  // STM32 連線驗證方法
  // ============================================================================

  /// 連線並驗證 STM32（統一的連線方法）
  ///
  /// 此方法封裝了完整的 STM32 連線驗證流程：
  /// 1. 開啟串口
  /// 2. 等待串口穩定
  /// 3. 發送韌體版本查詢指令 (0x05) 作為 PING
  /// 4. 輪詢等待回應
  /// 5. 根據回應判斷連線結果
  ///
  /// @param portName COM 埠名稱
  /// @return Stm32ConnectResult 連線結果
  Future<Stm32ConnectResult> connectAndVerifyStm32(String portName) async {
    // 1. 開啟串口
    if (!open(portName)) {
      return Stm32ConnectResult.portError;
    }

    // 2. 等待串口穩定
    await Future.delayed(const Duration(milliseconds: 300));

    // 3. 重設韌體版本通知器（用於驗證是否收到回應）
    firmwareVersionNotifier.value = null;

    // 4~5. 發送韌體版本查詢指令 (0x05) 作為 PING,輪詢等待回應
    //      (最多 2 秒,每次 200ms = 10 次)
    //
    // ⚠️ 站號每輪輪替(0x30 ↔ 0x31)。這裡與心跳有**同一個**問題:兩塊板二選一
    //    在線,而第一支 PING 送出去之前無從得知對面是哪一塊。以前寫死 0x30,
    //    擴充板在線時就是 2 秒全部落空 → 回 failed,但串口其實是好的。
    //    只修心跳不修這裡的話,自動連線仍然連不上擴充板。
    _pingBoardIdx = 0;
    for (int i = 0; i < 10; i++) {
      try {
        _port!.write(Uint8List.fromList(
          _buildStm32PingCommand(_nextPingBoard()),
        ));
      } catch (e) {
        close();
        return Stm32ConnectResult.portError;
      }

      await Future.delayed(const Duration(milliseconds: 200));

      // 檢查是否收到韌體版本回應
      if (firmwareVersionNotifier.value != null) {
        // 收到韌體版本回應，連線成功，啟動心跳
        startHeartbeat();
        return Stm32ConnectResult.success;
      }
    }

    // 6. 超時，連線失敗
    close();
    return Stm32ConnectResult.failed;
  }

  /// Raw 連線（不送 PING、不啟動心跳）
  ///
  /// 用於 Bootloader OTA 測試頁等需要「純打開 port、自行處理協定」的場景。
  /// 與 [connectAndVerifyStm32] 的差別：
  /// - 不發 0x05 PING（Bootloader 不認此命令）
  /// - 不啟動 [startHeartbeat]（避免每秒送 PING 干擾測試）
  /// - 不檢查 [firmwareVersionNotifier]，純粹依賴 [open] 是否成功
  ///
  /// 上層應透過 [onRawBytes] callback 自行處理收到的資料。
  Future<bool> connectRaw(String portName) async {
    if (!open(portName)) return false;
    _log('🔌 Raw 連線 (no heartbeat): $portName');
    return true;
  }

  // ============================================================================
  // 串口連接操作
  // ============================================================================

  /// 開啟串口連接
  ///
  /// @param portName COM 埠名稱，如 "COM3" (Windows) 或 "/dev/ttyUSB0" (Linux)
  /// @param baudRate 波特率，預設 115200
  /// @return true 表示連接成功，false 表示失敗
  bool open(String portName, {int baudRate = 115200}) {
    close();

    try {
      _port = SerialPort(portName);

      // 先開啟串口
      if (!_port!.openReadWrite()) {
        final error = SerialPort.lastError;
        _log('無法開啟串口 $portName: $error');
        _port = null;
        return false;
      }

      // 設定串口參數: 115200 波特率, 8 資料位元, 無校驗, 1 停止位元
      final config = SerialPortConfig();
      config.baudRate = baudRate;
      config.bits = 8;
      config.parity = SerialPortParity.none;
      config.stopBits = 1;
      config.setFlowControl(SerialPortFlowControl.none);
      // RTS 和 DTR 關閉（與 SSCOM 設定一致）
      config.rts = SerialPortRts.off;
      config.dtr = SerialPortDtr.off;
      _port!.config = config;

      // 記錄當前串口名稱
      _currentPortName = portName;

      isConnectedNotifier.value = true;
      wrongModeDetectedNotifier.value = false;
      heartbeatOkNotifier.value = false;  // 重置心跳狀態，等待收到正確回應

      // 清空硬體串口緩衝區中的殘留數據（如 Arduino 重置時的 bootloader 輸出）
      try {
        final available = _port!.bytesAvailable;
        if (available > 0) {
          _port!.read(available);  // 讀取並丟棄
        }
      } catch (_) {
        // 忽略錯誤
      }

      _log('串口 $portName 已開啟 (115200, 8, N, 1)');
      _startReading();
      return true;
    } catch (e) {
      _log('開啟串口錯誤: $e');
      _port = null;
      return false;
    }
  }

  /// 釋放串口資源（關閉並銷毀串口物件）
  void _disposePort() {
    if (_port == null) return;

    final port = _port!;
    _port = null;  // 先清空引用

    try {
      port.close();
    } catch (e) {
      _log('關閉串口錯誤: $e');
    }

    try {
      port.dispose();
    } catch (e) {
      // dispose 可能會失敗，忽略錯誤
    }
  }

  /// 關閉串口連接
  void close() {
    stopHeartbeat();  // 停止心跳
    _readTimer?.cancel();
    _readTimer = null;

    _disposePort();

    _currentPortName = null;
    _receiveBuffer.clear();  // 清空接收緩衝區，避免殘留數據影響下次連線
    _hexReceiveBuffer.clear();  // 清空 HEX 模式緩衝區
    _isNewProtocol = null;  // 重置協定偵測，下次連接時重新偵測
    // 重置韌體版本，以便下次連接時可以重新觸發驗證
    firmwareVersionNotifier.value = null;
    isConnectedNotifier.value = false;
  }

  /// 強制關閉串口連接（USB 被拔除或心跳失敗時使用）
  void forceClose() {
    stopHeartbeat();  // 停止心跳
    _readTimer?.cancel();
    _readTimer = null;

    _disposePort();
    _log('⚠️ 串口已強制關閉');

    _currentPortName = null;
    _receiveBuffer.clear();
    _hexReceiveBuffer.clear();
    _isNewProtocol = null;
    // 重置韌體版本，以便下次連接時可以重新觸發驗證
    firmwareVersionNotifier.value = null;
    isConnectedNotifier.value = false;
  }

  // ============================================================================
  // 心跳機制（Arduino 和 STM32 共用）
  // ============================================================================

  /// 啟動心跳機制
  /// - Arduino（文字模式）：每秒發送 "connect" 指令
  /// - STM32（HEX 模式）：每秒發送 PING 指令（0x05 查詢韌體版本）
  void startHeartbeat() {
    stopHeartbeat();  // 先停止舊的
    _heartbeatFailCount = 0;
    _waitingForHeartbeat = false;
    heartbeatOkNotifier.value = true;
    _lastActivityTime = DateTime.now();

    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _sendHeartbeat();
    });
  }

  /// 停止心跳機制
  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _waitingForHeartbeat = false;
    _heartbeatFailCount = 0;
    heartbeatOkNotifier.value = false;
  }

  /// 發送心跳指令
  void _sendHeartbeat() {
    if (_port == null || !isConnectedNotifier.value) {
      stopHeartbeat();
      return;
    }

    // 如果最近 800ms 內有活動，跳過這次心跳（避免干擾正常通訊）
    final now = DateTime.now();
    if (now.difference(_lastActivityTime).inMilliseconds < 800) {
      // 有活動表示連接正常
      _heartbeatFailCount = 0;
      heartbeatOkNotifier.value = true;
      _waitingForHeartbeat = false;
      return;
    }

    // 如果上次心跳還在等待回應
    if (_waitingForHeartbeat) {
      _heartbeatFailCount++;
      if (_heartbeatFailCount >= _heartbeatFailThreshold) {
        // 站號要印出來 —— 心跳送出本身不寫日誌(避免每秒洗版),所以失敗時若不
        // 講清楚打了哪些站號,日誌看起來就是「剛連上就莫名其妙斷了」,很難查。
        final tried = _pingBoards
            .map((b) => '0x${b.toRadixString(16).toUpperCase()}')
            .join(' / ');
        _log('⚠️ 心跳失敗 $_heartbeatFailCount 次(站號 $tried 輪流試過都沒回應)，'
            '連接可能已斷開或連接錯誤');
        heartbeatOkNotifier.value = false;
        onHeartbeatFailed?.call();
        stopHeartbeat();
        return;
      }
    }

    // 發送心跳指令
    try {
      if (isTextMode) {
        // Arduino: 發送 "connect" 心跳指令（Arduino 會回傳各自韌體識別字串）
        final data = Uint8List.fromList('connect\n'.codeUnits);
        _port!.write(data);
      } else {
        // STM32: 發送 PING 指令（0x05 查詢韌體版本）
        // 指令格式: 40 71 [board] 05 00 00 00 00 [CS]
        // 站號每次輪替(0x30 ↔ 0x31),理由見 _pingBoards。
        final pingCommand = _buildStm32PingCommand(_nextPingBoard());
        _port!.write(Uint8List.fromList(pingCommand));
      }
      _waitingForHeartbeat = true;
      // 心跳指令不記錄日誌，避免干擾
    } catch (e) {
      // write 拋出異常代表串口已無法通訊（USB 拔除等）
      // 立即觸發斷線，不再等待計數
      _log('⚠️ 心跳發送異常: $e，立即觸發斷線處理');
      heartbeatOkNotifier.value = false;
      onHeartbeatFailed?.call();
      stopHeartbeat();
    }
  }

  /// 建構 STM32 PING 指令（查詢韌體版本）
  /// 格式: Header(40 71 [board]) + 命令(05) + Data(00 00 00 00) + CS
  ///
  /// [board] = 站號(Header3),`0x30` 主板 / `0x31` 擴充板。**不要再寫死** ——
  /// 兩塊板二選一在線,寫死哪一邊都會在另一邊在線時無聲落空(見 [_pingBoards])。
  /// CS 由整包現算,換站號自動得到對的 CS。
  List<int> _buildStm32PingCommand(int board) {
    final header = [0x40, 0x71, board];
    const payload = [0x05, 0x00, 0x00, 0x00, 0x00];
    final command = [...header, ...payload];

    // 計算 checksum
    final sum = command.fold(0, (int prev, int e) => prev + e);
    final cs = (0x100 - (sum & 0xFF)) & 0xFF;

    return [...command, cs];
  }

  /// 處理心跳回應
  /// - Arduino: 當收到 "connected" 時調用
  /// - STM32: 當收到韌體版本回應（0x05）時調用
  void _handleHeartbeatResponse() {
    _waitingForHeartbeat = false;
    _heartbeatFailCount = 0;
    heartbeatOkNotifier.value = true;
    _lastActivityTime = DateTime.now();
  }

  /// 更新活動時間（任何指令發送或接收時調用）
  void _updateActivityTime() {
    _lastActivityTime = DateTime.now();
    // 有活動時重置失敗計數
    if (_heartbeatFailCount > 0) {
      _heartbeatFailCount = 0;
      heartbeatOkNotifier.value = true;
    }
  }

  // ============================================================================
  // 資料發送方法
  // ============================================================================

  /// 發送字串指令（Arduino 用）
  ///
  /// @param command 要發送的指令字串，如 "flowon"、"s0" 等
  /// @return true 表示發送成功，false 表示失敗
  bool sendString(String command) {
    if (_port == null) {
      _log('串口未開啟');
      return false;
    }

    try {
      final data = Uint8List.fromList('$command\n'.codeUnits);
      _port!.write(data);
      _log('發送: $command');
      return true;
    } catch (e) {
      _log('⚠️ 發送錯誤: $e，觸發斷線處理');
      heartbeatOkNotifier.value = false;
      onHeartbeatFailed?.call();
      stopHeartbeat();
      return false;
    }
  }

  /// 發送 16 進制指令（UR 用）
  ///
  /// @param bytes 要發送的位元組列表
  /// @return true 表示發送成功，false 表示失敗
  bool sendHex(List<int> bytes) {
    if (_port == null) {
      _log('串口未開啟');
      return false;
    }

    try {
      final data = Uint8List.fromList(bytes);
      _port!.write(data);

      final hexStr = bytes
          .map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
      _log('發送HEX: $hexStr');
      return true;
    } catch (e) {
      _log('⚠️ 發送HEX錯誤: $e，觸發斷線處理');
      heartbeatOkNotifier.value = false;
      onHeartbeatFailed?.call();
      stopHeartbeat();
      return false;
    }
  }

  // ============================================================================
  // 資料接收方法
  // ============================================================================

  /// 開始讀取串口資料（使用 Timer.periodic 輪詢）
  void _startReading() {
    _readTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_port == null) {
        _readTimer?.cancel();
        _readTimer = null;
        return;
      }

      try {
        final available = _port!.bytesAvailable;

        if (available > 0) {
          final data = _port!.read(available);

          if (data.isNotEmpty) {
            _processReceivedData(data);
          }
        }
      } catch (e) {
        // 讀取錯誤（USB 拔除等）
        _log('讀取錯誤: $e');
        _log('⚠️ 讀取異常，觸發斷線處理');
        heartbeatOkNotifier.value = false;
        onHeartbeatFailed?.call();
        stopHeartbeat();
        _readTimer?.cancel();
        _readTimer = null;
      }
    });
  }

  /// 處理接收到的串口資料
  void _processReceivedData(Uint8List data) {
    if (data.isEmpty) return;

    // 原始 bytes callback（在任何分流前觸發；Bootloader OTA 頁透過此 callback 自行解析）
    onRawBytes?.call(data);

    if (isTextMode) {
      // 文字模式處理（Arduino）
      _receiveBuffer.addAll(data);

      while (_receiveBuffer.contains(0x0A)) {
        int newlineIndex = _receiveBuffer.indexOf(0x0A);
        List<int> lineBytes = _receiveBuffer.sublist(0, newlineIndex);
        _receiveBuffer.removeRange(0, newlineIndex + 1);
        lineBytes.removeWhere((b) => b == 0x0D);

        if (lineBytes.isNotEmpty) {
          String line =
              utf8.decode(lineBytes, allowMalformed: true).trim();
          if (line.isNotEmpty) {
            final lineLower = line.toLowerCase();

            // 檢查是否為心跳回應（使用 contains 以容忍額外字元）
            // 根據 expectedMode 判斷哪個回應為「正確模式」或「錯誤模式」
            if (lineLower.contains('connectedmain')) {
              detectedMode = ArduinoMode.main;
              _handleHeartbeatResponse();
              continue;
            }

            _log('接收: $line');
            _updateActivityTime();  // 更新活動時間
            // 廣播純文字行（供上層 ack 確認等用途）
            onArduinoTextLine?.call(line);
            // 解析 Arduino 回應並儲存數據
            _parseArduinoResponse(line);
          }
        }
      }
    } else {
      // HEX 模式處理（STM32）— 累積到緩衝區再組裝封包
      if (verboseRawHexRxLog) {
        final hex = data
            .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
            .join(' ');
        _log('RX RAW (${data.length}B): $hex');
      }
      _hexReceiveBuffer.addAll(data);
      _processHexBuffer();
    }
  }

  /// 檢查字串是否全部為可列印的 ASCII 字元
  bool _isPrintable(String s) {
    return s.runes.every((r) => r >= 32 && r < 127);
  }

  // ============================================================================
  // HEX 模式封包組裝（STM32 動態長度支援）
  // ============================================================================
  //
  // 支援兩種封包格式：
  //
  // 舊版（韌體 ≤ 0.0.0.6）— 固定 9 bytes：
  //   [Header 3B] [Cmd 1B] [Data 4B] [CS 1B]
  //
  // 新版（韌體 ≥ 0.0.0.7）— 動態長度（僅 0x05 指令）：
  //   [Header 3B] [Cmd 1B] [DataLen 1B] [Data N bytes] [CS 1B]
  //   總長度 = 5 + N + 1 = 6 + N
  //
  // 自動偵測邏輯：首次收到 0x05 回應時，**純以 CS 驗證判別**：
  // - 先試 9-byte CS（前 8 bytes sum → CS），匹配 → 鎖定為舊版（之後 0x05 都當 9 bytes）
  // - 9-byte CS 不匹配 → 取 byte[4] 為 DataLen，試新版 (6+N) CS，匹配 → 鎖定新版
  // - 兩種都不匹配 → 封包無效（return -1，呼叫端會丟棄此 header byte 繼續搜尋）
  //
  // **不再用版本號當判別依據**，因為 0.0.0.7+ 之後韌體有新舊兩種封包長度共存。
  // 純 CS 驗證理論上有 1/256 機率新版封包前 9 bytes 巧合通過 9-byte CS，
  // 屬可接受風險（一次連線僅判別一次，後續封包都依鎖定格式收）。
  // ============================================================================

  /// 處理 HEX 模式緩衝區中的封包
  ///
  /// 從緩衝區中搜尋完整封包，驗證後交給 _parseUrReadResponse 解析。
  /// 支援封包跨越多次讀取的情況（USB Serial 位元組串流特性）。
  void _processHexBuffer() {
    while (_hexReceiveBuffer.length >= 9) {
      // 1. 搜尋封包 header [0x40, 0x71, 0x30]
      final headerIdx = _findHexHeader();
      if (headerIdx < 0) {
        // 找不到 header，保留最後 2 bytes（可能是不完整的 header 開頭）
        if (_hexReceiveBuffer.length > 2) {
          _hexReceiveBuffer.removeRange(0, _hexReceiveBuffer.length - 2);
        }
        return;
      }

      // 丟棄 header 之前的垃圾 bytes
      if (headerIdx > 0) {
        if (verboseRawHexRxLog) {
          final discarded = _hexReceiveBuffer
              .sublist(0, headerIdx)
              .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
              .join(' ');
          _log('⚠️ 丟棄 header 前雜訊 ($headerIdx B): $discarded');
        }
        _hexReceiveBuffer.removeRange(0, headerIdx);
      }

      // 2. 判斷期望的封包長度
      final expectedLen = _getExpectedPacketLength();
      if (expectedLen == null) return;  // 資料不足，等待下次讀取
      if (expectedLen < 0) {
        // 無效封包（新舊格式 CS 都不匹配），跳過此 header byte 繼續搜尋
        _hexReceiveBuffer.removeAt(0);
        continue;
      }

      // 3. 等待封包完整到達
      if (_hexReceiveBuffer.length < expectedLen) return;

      // 4. 取出封包並驗證 checksum
      final packet = Uint8List.fromList(
        _hexReceiveBuffer.sublist(0, expectedLen),
      );
      if (!_verifyChecksum(packet)) {
        // CS 驗證失敗，跳過此 header
        if (verboseRawHexRxLog) {
          final hex = packet
              .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
              .join(' ');
          _log('⚠️ CS 驗證失敗，跳過 ($expectedLen B): $hex');
        }
        _hexReceiveBuffer.removeAt(0);
        continue;
      }

      // 5. 消耗已處理的 bytes
      _hexReceiveBuffer.removeRange(0, expectedLen);

      // 6. 解析封包
      final isHeartbeat = _parseUrReadResponse(packet);

      // 7. 非心跳回應記錄日誌
      if (!isHeartbeat) {
        _logHexPacket(packet);
      }
    }
  }

  /// 在緩衝區中搜尋 STM32 封包 header [0x40, 0x71, board]
  /// board = 0x30(主板) 或 0x31(擴充板);返回 header 起始位置,找不到返回 -1。
  int _findHexHeader() {
    for (int i = 0; i <= _hexReceiveBuffer.length - 3; i++) {
      if (_hexReceiveBuffer[i] == 0x40 &&
          _hexReceiveBuffer[i + 1] == 0x71 &&
          (_hexReceiveBuffer[i + 2] == 0x30 ||
              _hexReceiveBuffer[i + 2] == 0x31)) {
        return i;
      }
    }
    return -1;
  }

  /// 根據命令碼和協定版本判斷封包的期望長度
  ///
  /// 返回值：
  /// - 正整數: 期望的封包長度
  /// - null: 資料不足以判斷，需等待更多 bytes
  /// - -1: 無效封包（新舊格式都不匹配）
  int? _getExpectedPacketLength() {
    // 至少需要 5 bytes（header 3 + cmd 1 + 第一個 data/len byte 1）
    if (_hexReceiveBuffer.length < 5) return null;

    final cmd = _hexReceiveBuffer[3];

    // 非 0x05 命令（GPIO、ADC 等）：固定 9 bytes
    if (cmd != 0x05) return 9;

    // ---- 以下為 0x05（ping/韌體版本）命令的處理 ----

    // 已確認新版協定：使用 DataLen byte 計算長度
    if (_isNewProtocol == true) {
      final n = _hexReceiveBuffer[4];
      return 6 + n; // header(3) + cmd(1) + len(1) + data(n) + cs(1)
    }

    // 已確認舊版協定：固定 9 bytes
    if (_isNewProtocol == false) return 9;

    // ---- 尚未偵測：自動偵測協定格式 ----

    // 需要至少 9 bytes 才能嘗試舊版格式
    if (_hexReceiveBuffer.length < 9) return null;

    // 嘗試 9-byte CS 驗證（舊版格式）
    final sum9 = _hexReceiveBuffer
        .sublist(0, 8)
        .fold(0, (int prev, int e) => prev + e);
    final expectedCs9 = (0x100 - (sum9 & 0xFF)) & 0xFF;

    if (_hexReceiveBuffer[8] == expectedCs9) {
      // 9-byte CS 匹配 → 直接鎖定為舊版協定（不再依版本號判別）
      _isNewProtocol = false;
      final v1 = _hexReceiveBuffer[4];
      final v2 = _hexReceiveBuffer[5];
      final v3 = _hexReceiveBuffer[6];
      final v4 = _hexReceiveBuffer[7];
      _log('🔍 偵測到舊版 STM32 協定（固定 9 bytes，版本 $v4.$v3.$v2.$v1）');
      return 9;
    }

    // 嘗試新版格式：byte[4] 作為 DataLen
    final n = _hexReceiveBuffer[4];
    final newLen = 6 + n;

    // 資料不足，等待更多 bytes
    if (_hexReceiveBuffer.length < newLen) return null;

    // 驗證新版格式的 CS
    final sumNew = _hexReceiveBuffer
        .sublist(0, newLen - 1)
        .fold(0, (int prev, int e) => prev + e);
    final expectedCsNew = (0x100 - (sumNew & 0xFF)) & 0xFF;

    if (_hexReceiveBuffer[newLen - 1] == expectedCsNew) {
      // 新版格式 CS 匹配 → 確認為新版協定
      _isNewProtocol = true;
      _log('🔍 偵測到新版 STM32 協定（動態長度，DataLen=$n）');
      return newLen;
    }

    // 兩種格式都不匹配 → 無效封包
    return -1;
  }

  /// 驗證封包的 checksum
  /// CS = (0x100 - (前 N-1 bytes 總和 & 0xFF)) & 0xFF
  bool _verifyChecksum(Uint8List data) {
    if (data.length < 2) return false;
    final sum = data
        .sublist(0, data.length - 1)
        .fold(0, (int prev, int e) => prev + e);
    final expectedCs = (0x100 - (sum & 0xFF)) & 0xFF;
    return data.last == expectedCs;
  }

  /// 記錄 HEX 封包日誌
  void _logHexPacket(Uint8List packet) {
    String hexStr = packet
        .map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');

    String text = String.fromCharCodes(packet)
        .replaceAll('\r', '')
        .replaceAll('\n', ' ')
        .trim();

    if (text.isNotEmpty && _isPrintable(text)) {
      _log('接收: $hexStr ($text)');
    } else {
      _log('接收: $hexStr');
    }
  }

  // ============================================================================
  // Arduino 回應解析
  // ============================================================================

  /// Arduino 回應名稱與 ID 對照表（Main Board 用）
  /// 根據 Main Board Arduino 實際回傳的格式來對應
  static const Map<String, int> _arduinoResponseToId = {
    // SLOT0~SLOT9 對應 ID 0-9
    'slot0': 0, 'slot1': 1, 'slot2': 2, 'slot3': 3, 'slot4': 4,
    'slot5': 5, 'slot6': 6, 'slot7': 7, 'slot8': 8, 'slot9': 9,
    // WATER 對應 ID 10
    'water': 10,
    // UVC 燈對應 ID 11-13 (u0=SpoutUVC, u1=MixUVC, u2=MainUVC)
    'spoutuvc': 11, 'mixuvc': 12, 'mainuvc': 13,
    // 繼電器對應 ID 14-16
    'ambientrl': 14, 'coolrl': 15, 'sparking': 16,
    // O3 對應 ID 17
    'o3': 17,
    // 流量計對應 ID 18
    'flow': 18,
    // 壓力計對應 ID 19-20
    'pressureco2': 19, 'pressurewater': 20,
    // 溫度對應 ID 21-23
    'mcu': 21, 'mcutemp': 21,
  };

  /// Arduino 回應名稱→ID 映射表（Main Board 唯一）
  Map<String, int> get _activeResponseToId => _arduinoResponseToId;

  /// 解析 Arduino 回應
  /// 支援 Arduino 實際回傳的格式:
  /// - "SLOT0 (AD09): 1234"
  /// - "WATER (AD12): 1234"
  /// - "MainUVC (AD15): 1234"
  /// - "MCU 溫度: 25.5 °C"
  /// - "流量計數值: 1234 pulses"
  void _parseArduinoResponse(String line) {
    // 格式1: "名稱 (ADxx): 數值" - 例如 "SLOT0 (AD09): 1234"
    final adcPattern = RegExp(r'^(\w+)\s*\([^)]+\):\s*(-?\d+)');
    final adcMatch = adcPattern.firstMatch(line);
    if (adcMatch != null) {
      final name = adcMatch.group(1)!.toLowerCase();
      final valueStr = adcMatch.group(2)!;
      final value = int.tryParse(valueStr);
      if (value != null) {
        final id = _activeResponseToId[name];
        if (id != null) {
          onDataReceived?.call(id, value);
          return;
        }
      }
    }

    // 格式2: "MCU 溫度: 25.5 °C" - 溫度格式（浮點數轉整數，乘以10保留一位小數）
    final tempPattern = RegExp(r'^MCU\s*溫度:\s*(-?\d+\.?\d*)\s*°?C?', caseSensitive: false);
    final tempMatch = tempPattern.firstMatch(line);
    if (tempMatch != null) {
      final tempStr = tempMatch.group(1)!;
      final tempFloat = double.tryParse(tempStr);
      if (tempFloat != null) {
        // 將溫度乘以10轉為整數保存（例如 25.5 -> 255）
        final value = (tempFloat * 10).round();
        onDataReceived?.call(21, value);  // ID 21 = mcutemp
        return;
      }
    }

    // 格式3: "流量計數值: 1234 pulses" - 流量計格式
    final flowPattern = RegExp(r'流量計數值:\s*(\d+)\s*pulses?', caseSensitive: false);
    final flowMatch = flowPattern.firstMatch(line);
    if (flowMatch != null) {
      final valueStr = flowMatch.group(1)!;
      final value = int.tryParse(valueStr);
      if (value != null) {
        onDataReceived?.call(18, value);  // ID 18 = flow
        return;
      }
    }

    // 格式4: "最終計數值: 1234 pulses" - flowoff 回傳
    final finalFlowPattern = RegExp(r'最終計數值:\s*(\d+)\s*pulses?', caseSensitive: false);
    final finalFlowMatch = finalFlowPattern.firstMatch(line);
    if (finalFlowMatch != null) {
      final valueStr = finalFlowMatch.group(1)!;
      final value = int.tryParse(valueStr);
      if (value != null) {
        onDataReceived?.call(18, value);  // ID 18 = flow
        return;
      }
    }
  }

  /// 解析 UR 讀取命令回應
  ///
  /// 支援兩種封包格式：
  /// - 舊版（9 bytes）: [Header 3B] [Cmd 1B] [Data 4B] [CS 1B]
  /// - 新版（6+N bytes）: [Header 3B] [Cmd 1B] [DataLen 1B] [Data NB] [CS 1B]
  ///
  /// 封包在進入此方法前已由 _processHexBuffer 完成 header 搜尋和 CS 驗證。
  /// 返回值: true 表示為心跳回應（0x05），不需記錄日誌；false 表示其他回應
  bool _parseUrReadResponse(Uint8List data) {
    // 最小封包長度檢查
    if (data.length < 9) return false;

    // 檢查 Header: 0x40 0x71 [board];board = 0x30(主板) 或 0x31(擴充板)
    if (data[0] != 0x40 ||
        data[1] != 0x71 ||
        (data[2] != 0x30 && data[2] != 0x31)) {
      return false;
    }

    // 動態驗證 checksum（封包最後一個 byte）
    final sum = data.sublist(0, data.length - 1).fold(0, (int prev, int e) => prev + e);
    final expectedCs = (0x100 - (sum & 0xFF)) & 0xFF;
    if (data.last != expectedCs) return false;

    final command = data[3];

    // GPIO 開啟命令回應 (0x01) — 固定 9 bytes
    if (command == 0x01 && data.length == 9) {
      final lowByte = data[4];
      final midByte = data[5];
      final highByte = data[6];
      final bitMask = lowByte | (midByte << 8) | (highByte << 16);
      _updateActivityTime();
      if (verboseRawHexRxLog) {
        _log('✓ GPIO ON ack: bitmask=0x${bitMask.toRadixString(16).toUpperCase().padLeft(6, '0')}');
      }
      onGpioCommandConfirmed?.call(0x01, bitMask);
      // 返回 false → 由 _processHexBuffer 透過 _logHexPacket 另外印 raw hex
      return false;
    }
    // GPIO 關閉命令回應 (0x02) — 固定 9 bytes
    else if (command == 0x02 && data.length == 9) {
      final lowByte = data[4];
      final midByte = data[5];
      final highByte = data[6];
      final bitMask = lowByte | (midByte << 8) | (highByte << 16);
      _updateActivityTime();
      if (verboseRawHexRxLog) {
        _log('✓ GPIO OFF ack: bitmask=0x${bitMask.toRadixString(16).toUpperCase().padLeft(6, '0')}');
      }
      onGpioCommandConfirmed?.call(0x02, bitMask);
      return false;
    }
    // 讀取命令回應 (0x03) — 固定 9 bytes
    else if (command == 0x03 && data.length == 9) {
      final id = data[4];
      final value = data[5] | (data[6] << 8) | (data[7] << 16);
      final result = _formatReadResult(id, value);
      _log(result);
      _updateActivityTime();  // 收到回應表示連線正常
      onDataReceived?.call(id, value);
      return false;  // 不是心跳回應
    }
    // 韌體版本回應 (0x05) - 也作為心跳回應
    // 舊版格式（9 bytes）: 40 71 30 05 [v1] [v2] [v3] [v4] CS
    // 新版格式（6+N bytes）: 40 71 30 05 [N] [v1] [v2] [v3] [v4] [extra...] CS
    else if (command == 0x05) {
      int v1, v2, v3, v4;

      if (data.length == 9) {
        // 舊版格式：版本在 data[4..7]
        v1 = data[4];  // 最低位元
        v2 = data[5];
        v3 = data[6];
        v4 = data[7];  // 最高位元
      } else {
        // 新版格式：data[4] = DataLen，版本在 data[5..8]
        // 額外資料（data[9] ~ data[data.length-2]）暫時忽略
        v1 = data[5];
        v2 = data[6];
        v3 = data[7];
        v4 = data[8];
      }

      final versionStr = '$v4.$v3.$v2.$v1';

      // 處理心跳回應（STM32 的心跳使用 0x05 指令）
      _handleHeartbeatResponse();

      // 只有在版本變化或首次收到時才記錄日誌和觸發回調（避免心跳干擾）
      if (firmwareVersionNotifier.value != versionStr) {
        _log('📦 韌體版本: $versionStr');
        firmwareVersionNotifier.value = versionStr;
        onFirmwareVersionReceived?.call(versionStr);
        // 只在首次收到韌體版本時觸發連接驗證（之後的心跳回應不再觸發）
        onConnectionVerified?.call(true);
      }
      return true;  // 是心跳回應，不需額外記錄日誌
    }

    return false;
  }

  /// ID 資訊對照表：圖標、名稱、是否為溫度
  static const Map<int, Map<String, dynamic>> _idInfoMap = {
    // s0~s9: 小顆馬達 (SLOT)
    0: {'icon': '⚙️', 'name': 'SLOT1', 'isTemp': false},
    1: {'icon': '⚙️', 'name': 'SLOT2', 'isTemp': false},
    2: {'icon': '⚙️', 'name': 'SLOT3', 'isTemp': false},
    3: {'icon': '⚙️', 'name': 'SLOT4', 'isTemp': false},
    4: {'icon': '⚙️', 'name': 'SLOT5', 'isTemp': false},
    5: {'icon': '⚙️', 'name': 'SLOT6', 'isTemp': false},
    6: {'icon': '⚙️', 'name': 'SLOT7', 'isTemp': false},
    7: {'icon': '⚙️', 'name': 'SLOT8', 'isTemp': false},
    8: {'icon': '⚙️', 'name': 'SLOT9', 'isTemp': false},
    9: {'icon': '⚙️', 'name': 'SLOT10', 'isTemp': false},
    // water: 水泵
    10: {'icon': '💧', 'name': 'WATERPUMP', 'isTemp': false},
    // u0~u2: 紫外殺菌燈 (u0=SpoutUVC, u1=MixUVC, u2=MainUVC)
    11: {'icon': '💡', 'name': 'SpoutUVC', 'isTemp': false},
    12: {'icon': '💡', 'name': 'MixUVC', 'isTemp': false},
    13: {'icon': '💡', 'name': 'MainUVC', 'isTemp': false},
    // relay
    14: {'icon': '🔌', 'name': 'AmbientRL', 'isTemp': false},
    15: {'icon': '🔌', 'name': 'CoolRL', 'isTemp': false},
    16: {'icon': '🔌', 'name': 'SparklRL', 'isTemp': false},
    // o3: 臭氧
    17: {'icon': '🌀', 'name': 'O3', 'isTemp': false},
    // flow: 流量計
    18: {'icon': '🌊', 'name': 'Flow', 'isTemp': false},
    // 壓力計
    19: {'icon': '📊', 'name': 'PressureCO2', 'isTemp': false},
    20: {'icon': '📊', 'name': 'PressureWater', 'isTemp': false},
    // 溫度感測器 (Arduino 只有 MCUtemp)
    21: {'icon': '🌡️', 'name': 'MCUtemp', 'isTemp': true},
    // 以下為 STM32 專用（Arduino 沒有）
    22: {'icon': '🌡️', 'name': 'WATERtemp', 'isTemp': true},
    23: {'icon': '🌡️', 'name': 'BIBtemp', 'isTemp': true},
  };

  /// 根據 ID 取得格式化的讀取結果字串
  String _formatReadResult(int id, int value) {
    final info = _idInfoMap[id];
    if (info == null) {
      return '❓ ID$id, ADC= $value';
    }

    final icon = info['icon'] as String;
    final name = info['name'] as String;
    final isTemp = info['isTemp'] as bool;

    if (isTemp) {
      return '$icon $name, 量測溫度= $value';
    } else {
      return '$icon $name, ADC= $value';
    }
  }

  // ============================================================================
  // 日誌管理方法
  // ============================================================================

  /// 記錄日誌訊息
  void _log(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    logNotifier.value = '[$timestamp] $message\n${logNotifier.value}';

    if (logNotifier.value.length > 10000) {
      logNotifier.value = logNotifier.value.substring(0, 8000);
    }
  }

  /// 清除所有日誌
  void clearLog() {
    logNotifier.value = '';
  }

  /// 釋放資源
  void dispose() {
    close();
    logNotifier.dispose();
    isConnectedNotifier.dispose();
    firmwareVersionNotifier.dispose();
    wrongModeDetectedNotifier.dispose();
  }
}