# 串口通訊協定完整參考

本文件完整記錄 Flutter 上位機與 Arduino / STM32 之間的所有通訊細節，供後續基於相同功能快速開發使用。

---

## 目錄

1. [串口基本設定](#串口基本設定)
2. [COM 埠過濾與 ST-Link 排除](#com-埠過濾與-st-link-排除)
3. [Arduino 文字協定](#arduino-文字協定)
4. [STM32 二進位協定](#stm32-二進位協定)
5. [連線狀態機與列舉](#連線狀態機與列舉)
6. [心跳機制](#心跳機制)
7. [自動偵測流程](#自動偵測流程)
8. [ADC 通道對應表](#adc-通道對應表)
9. [錯誤處理模式](#錯誤處理模式)
10. [關鍵程式碼路徑](#關鍵程式碼路徑)

---

## 串口基本設定

兩種裝置共用相同的串口參數：

| 參數 | 值 |
|------|-----|
| Baud Rate | 115200 |
| Data Bits | 8 |
| Parity | None |
| Stop Bits | 1 |
| Flow Control | None |
| RTS | Off |
| DTR | Off |

**依賴套件**：`flutter_libserialport` ^0.6.0

---

## COM 埠過濾與 ST-Link 排除

**實作檔案**：`lib/shared/services/port_filter_service.dart`

### ST-Link 識別

```dart
static const int stLinkVendorId = 0x0483;  // STMicroelectronics USB VID
```

- 透過讀取 USB VID 識別 ST-Link 設備
- 已識別的 ST-Link 埠會快取，避免重複查詢
- 讀取 VID 失敗時保留該埠（fail-open 策略）

### API

| 方法 | 用途 |
|------|------|
| `getAvailablePorts(excludeStLink: true)` | 取得所有可用埠，排除 ST-Link |
| `getAvailablePortsAsync(excludeStLink: true)` | 同上，在 Isolate 中執行避免阻塞 UI |
| `getFilteredPorts(excludePorts: [...], excludeStLink: true)` | 排除 ST-Link + 指定埠（如已連線的 Arduino 埠） |
| `isStLinkPort(portName)` | 檢查特定埠是否為 ST-Link |
| `clearStLinkCache()` | 清除快取 |

---

## Arduino 文字協定

### 概述

Arduino 使用純文字模式通訊，所有指令與回應以換行符 `\n` 結尾。兩種模式（Main Board / Body&Door）共用同一協定格式。

### 發送指令（Flutter → Arduino）

| 指令 | 格式 | 用途 |
|------|------|------|
| 心跳 | `"connect\n"` | 每秒發送，驗證連線 |
| 讀取感測器 | `"<命令名>\n"` | 讀取指定感測器數值 |
| 開啟流量計 | `"flowon\n"` | 開始流量計測（僅 Main Board） |
| 關閉流量計 | `"flowoff\n"` | 停止流量計測（僅 Main Board） |

### 接收回應（Arduino → Flutter）

#### 心跳回應

| 回應 | 模式 | 說明 |
|------|------|------|
| `"connectedmain\n"` | Main Board | 確認連線，Main Board 模式 |
| `"connectedbodydoor\n"` | Body&Door Board | 確認連線，Body&Door 模式 |

判斷邏輯使用 `contains`（大小寫不敏感），所以回應中包含這些字串即可匹配。

#### 數據回應格式

Flutter 端使用 4 種正規表達式依序匹配：

**1. ADC 數值格式**
```
格式：名稱 (腳位): 數值
正規：^(\w+)\s*\([^)]+\):\s*(-?\d+)
範例："SLOT0 (AD09): 1234"
```

**2. MCU 溫度格式**
```
格式：MCU temperature: 溫度值 C
正規：^MCU\s*temperature:\s*(-?\d+\.?\d*)\s*C?
範例："MCU temperature: 25.5 C"
注意：數值乘以 10 轉為整數儲存（25.5 → 255）
```

**3. 流量計數值格式**
```
格式：flowmeter_value: 脈衝數 pulses
正規：flowmeter_value:\s*(\d+)\s*pulses?
範例："flowmeter_value: 1234 pulses"
```

**4. 最終流量格式**（flowoff 後回傳）
```
格式：final_count: 脈衝數 pulses
正規：final_count:\s*(\d+)\s*pulses?
範例："final_count: 1234 pulses"
```

### Main Board Arduino 指令列表

```dart
['s0', 's1', 's2', 's3', 's4', 's5', 's6', 's7', 's8', 's9',
 'water', 'u0', 'u1', 'u2', 'arl', 'crl', 'srl', 'o3']
```

### Body&Door Arduino 指令列表

```dart
['ambientrl', 'coolrl', 'sparklingrl', 'waterpump', 'o3', 'mainuvc',
 'bibtemp', 'flowmeter', 'watertemp', 'leak', 'waterpressure',
 'co2pressure', 'spoutuvc', 'mixuvc', 'flowmeter2',
 'bp24v', 'bp12v', 'bpup', 'bplow']
```

### 文字接收處理流程

```
接收 bytes → 附加到 _receiveBuffer
→ 以 0x0A (\n) 分割
→ 移除 0x0D (\r)
→ UTF-8 解碼（allowMalformed: true）
→ 檢查心跳回應 → 若匹配則處理心跳
→ 否則進入 _parseArduinoResponse() 解析數據
```

---

## STM32 二進位協定

### 概述

STM32 使用二進位封包通訊，僅在 Main Board 模式中使用。透過 `URCommandBuilder` 建構指令。

### 封包格式

```
+----------+----------+----------+------------------+----------+
| Header 1 | Header 2 | Header 3 |     Payload      | Checksum |
+----------+----------+----------+------------------+----------+
|   0x40   |   0x71   |   0x30   |   (N bytes)      |    CS    |
+----------+----------+----------+------------------+----------+
```

**標頭常數**：
```dart
static const int header1 = 0x40;  // '@' (ASCII 64)
static const int header2 = 0x71;  // 'q' (ASCII 113)
static const int header3 = 0x30;  // '0' (ASCII 48)
```

### Checksum 計算

```dart
CS = (0x100 - (所有前面位元組的總和 & 0xFF)) & 0xFF
```

驗證方式：封包所有位元組（含 CS）的總和 & 0xFF 應等於 0。

**範例**：
```
bytes = [0x40, 0x71, 0x30, 0x07, 0x01, 0x00]
sum = 0x40 + 0x71 + 0x30 + 0x07 + 0x01 + 0x00 = 0xE9
CS = 0x100 - 0xE9 = 0x17
完整封包 = [0x40, 0x71, 0x30, 0x07, 0x01, 0x00, 0x17]
```

### 發送指令（Flutter → STM32）

所有指令的 Payload 為 5 bytes：`[指令碼, B1, B2, B3, B4]`

完整封包固定 9 bytes：`[0x40, 0x71, 0x30, 指令碼, B1, B2, B3, B4, CS]`

| 指令碼 | 功能 | Payload 格式 | 說明 |
|--------|------|-------------|------|
| `0x01` | GPIO ON | `[0x01, lowByte, midByte, highByte, 0x00]` | 開啟輸出（MOSFET），24-bit bitmask |
| `0x02` | GPIO OFF | `[0x02, lowByte, midByte, highByte, 0x00]` | 關閉輸出（MOSFET），24-bit bitmask |
| `0x03` | 讀取 ADC | `[0x03, sensorID, 0x00, 0x00, 0x00]` | 讀取指定感測器，ID 0-23 |
| `0x04` | 清除流量計 | `[0x04, 0x12, 0x00, 0x00, 0x00]` | 清除流量計數（ID 18 = 0x12） |
| `0x05` | 韌體版本/PING | `[0x05, 0x00, 0x00, 0x00, 0x00]` | 查詢韌體版本，也用作心跳 |

### GPIO Bitmask 計算

24-bit bitmask 可同時控制多個 GPIO：

```dart
int bitValue = 0;
for (final id in selectedIds) {
  bitValue |= (1 << id);  // id 0-17，每個 bit 對應一個 GPIO
}
final lowByte  = bitValue & 0xFF;         // bit 0-7
final midByte  = (bitValue >> 8) & 0xFF;  // bit 8-15
final highByte = (bitValue >> 16) & 0xFF; // bit 16-23
```

**範例**：開啟 ID 0 和 ID 10
```
bitValue = (1 << 0) | (1 << 10) = 0x000401
lowByte = 0x01, midByte = 0x04, highByte = 0x00
payload = [0x01, 0x01, 0x04, 0x00, 0x00]
```

**關閉全部 GPIO**：
```
payload = [0x02, 0xFF, 0xFF, 0x03, 0x00]  // bitmask = 0x03FFFF (ID 0-17)
```

### 接收回應（STM32 → Flutter）

#### 協定版本自動偵測

支援兩種封包格式，首次收到 0x05 回應時自動偵測：

| 版本 | 韌體版本 | 固定長度 | 格式 |
|------|---------|---------|------|
| 舊協定 | ≤ 0.0.0.6 | 9 bytes | `[Header 3B][Cmd 1B][Data 4B][CS 1B]` |
| 新協定 | ≥ 0.0.0.7 | 6+N bytes | `[Header 3B][Cmd 1B][DataLen 1B][Data NB][CS 1B]` |

**自動偵測邏輯**（僅 0x05 指令，首次接收時）：
1. 嘗試以 9 bytes 舊格式驗證 checksum，若通過且版本值 ≤ 6，確認為舊協定
2. 否則嘗試新格式（byte[4] 為 DataLen），驗證 checksum
3. 偵測結果快取，後續封包直接使用

#### 各指令回應解析

**0x01 GPIO ON 確認**（9 bytes）
```
[0x40, 0x71, 0x30, 0x01, lo, mi, hi, xx, CS]
bitmask = lo | (mi << 8) | (hi << 16)
→ 觸發 onGpioCommandConfirmed(0x01, bitmask)
```

**0x02 GPIO OFF 確認**（9 bytes）
```
[0x40, 0x71, 0x30, 0x02, lo, mi, hi, xx, CS]
bitmask = lo | (mi << 8) | (hi << 16)
→ 觸發 onGpioCommandConfirmed(0x02, bitmask)
```

**0x03 ADC 數值**（9 bytes）
```
[0x40, 0x71, 0x30, 0x03, id, lo, hi, ex, CS]
sensorID = id
value = lo | (hi << 8) | (ex << 16)
→ 觸發 onDataReceived(id, value)
```

**0x05 韌體版本**（舊格式 9 bytes / 新格式 6+N bytes）
```
舊格式：[0x40, 0x71, 0x30, 0x05, v1, v2, v3, v4, CS]
新格式：[0x40, 0x71, 0x30, 0x05, N, v1, v2, v3, v4, ..., CS]
版本字串 = "$v4.$v3.$v2.$v1"
→ 觸發 _handleHeartbeatResponse()
→ 觸發 onFirmwareVersionReceived(versionStr)
→ 首次連線時觸發 onConnectionVerified(true)
```

### HEX 封包組裝流程

```
接收 bytes → 附加到 _hexReceiveBuffer
→ 搜尋標頭 [0x40, 0x71, 0x30]，丟棄標頭前的無效位元組
→ 判斷預期封包長度（_getExpectedPacketLength）
→ 等待足夠位元組
→ 驗證 checksum
→ 通過則解析（_parseUrReadResponse），失敗則丟棄第一個位元組繼續搜尋
```

---

## 連線狀態機與列舉

**實作檔案**：`lib/shared/services/arduino_connection_service.dart`

### 列舉定義

```dart
/// Arduino 連線結果
enum ConnectResult {
  success,    // 連線成功，模式正確
  wrongMode,  // 連線成功，但偵測到不同模式
  failed,     // 無回應 / 逾時
  portError,  // 無法開啟串口
}

/// Arduino 模式
enum ArduinoMode {
  main,       // Main Board 模式
  bodyDoor,   // Body & Door Board 模式
  unknown,    // 未知（用於探測）
}

/// STM32 連線結果
enum Stm32ConnectResult {
  success,    // 收到韌體版本回應
  failed,     // 無回應 / 逾時
  portError,  // 無法開啟串口
}
```

### Arduino 連線驗證流程

**方法**：`connectAndVerify(String portName)` in `ArduinoConnectionMixin`

```
1. 重置 detectedMode = unknown
2. 開啟串口 → 失敗返回 portError
3. 等待 2000ms（Arduino bootloader + setup() 完成）
4. 清除軟體/硬體接收緩衝區
5. 重試迴圈（最多 3 次）：
   a. 清除接收緩衝區
   b. 發送 "connect\n"
   c. 輪詢 5 次，每次 200ms（每次嘗試最長 1 秒）：
      - heartbeatOkNotifier == true → 啟動心跳，返回 success
      - wrongModeDetectedNotifier == true → 重置，關閉，返回 wrongMode
   d. 第一次嘗試失敗後等待 200ms 再重試
6. 全部失敗 → 關閉串口，返回 failed
```

**單埠最大耗時**：約 2000ms (boot) + 3 × (~1000ms poll + 200ms delay) ≈ 5600ms

### STM32 連線驗證流程

**方法**：`connectAndVerifyStm32(String portName)` in `SerialPortManager`

```
1. 開啟串口
2. 等待 300ms（埠穩定）
3. 重置 firmwareVersionNotifier = null
4. 發送韌體版本查詢（0x05 指令作為 PING）
5. 輪詢 10 次，每次 200ms（最長 2 秒）：
   - firmwareVersionNotifier != null → 啟動心跳，返回 success
6. 逾時 → 關閉串口，返回 failed
```

---

## 心跳機制

### 共同參數

| 參數 | 值 |
|------|-----|
| 心跳間隔 | 1 秒（`Timer.periodic`） |
| 活動寬限期 | 800ms（近期有活動則跳過心跳） |
| 失敗閾值 | 連續 3 次無回應即斷線 |
| 讀取輪詢間隔 | 50ms（`Timer.periodic`） |

### Arduino 心跳

```
每秒發送："connect\n"
期望回應：
  - Main Board: "connectedmain"
  - Body&Door: "connectedbodydoor"
```

### STM32 心跳

```
每秒發送：[0x40, 0x71, 0x30, 0x05, 0x00, 0x00, 0x00, 0x00, CS]
期望回應：0x05 韌體版本封包
```

### 心跳失敗處理

```
1. 若 800ms 內有活動 → 跳過心跳，重置失敗計數
2. 若上次心跳尚未回應 → 失敗計數 +1
3. 失敗計數 >= 3：
   → heartbeatOkNotifier = false
   → 觸發 onHeartbeatFailed()
   → 停止心跳
4. 發送心跳時若 write() 拋出例外 → 立即觸發斷線
```

### ValueNotifier 狀態

| Notifier | 型別 | 用途 |
|----------|------|------|
| `logNotifier` | `ValueNotifier<String>` | 串口日誌（最大 10000 字，裁切至 8000） |
| `isConnectedNotifier` | `ValueNotifier<bool>` | 連線狀態 |
| `heartbeatOkNotifier` | `ValueNotifier<bool>` | 心跳健康狀態 |
| `wrongModeDetectedNotifier` | `ValueNotifier<bool>` | 偵測到錯誤模式 |
| `firmwareVersionNotifier` | `ValueNotifier<String?>` | STM32 韌體版本 |

### 回呼函式

| Callback | 用途 |
|----------|------|
| `onDataReceived(int id, int value)` | 收到 ADC 數據 |
| `onGpioCommandConfirmed(int command, int bitMask)` | STM32 GPIO 指令確認 |
| `onFirmwareVersionReceived(String version)` | 收到韌體版本 |
| `onConnectionVerified(bool success)` | STM32 連線驗證完成 |
| `onHeartbeatFailed()` | 心跳失敗（連續 3 次） |

---

## 自動偵測流程

### 模式選擇頁（ModeSelectionPage）

**實作檔案**：`lib/mode_selection_page.dart`

```
1. 啟動後 500ms 開始監控埠口 + 自動偵測
2. 埠口監控：每秒檢查新 COM 埠
   → 偵測到新埠（USB 插入）→ 等待 800ms 驅動初始化 → 觸發重新偵測
3. 自動偵測：
   a. 取得可用埠（排除 ST-Link）
   b. 無埠可用 → 每 3 秒重試
   c. 對每個埠建立臨時 SerialPortManager（expectedMode: unknown）
   d. 呼叫 connectAndVerify(portName)
   e. 根據 detectedMode 導航：
      - ArduinoMode.main → MainNavigationPage
      - ArduinoMode.bodyDoor → BodyDoorNavigationPage
   f. 傳遞 arduinoPort 給目標頁面以便重新連線
4. 使用 Navigator.pushReplacement 避免頁面堆疊
```

### Main Board 自動偵測（Auto Detection Controller）

```
步驟 1：連線
  → 先連 Arduino（掃描所有埠）
  → 再連 STM32（排除已用的 Arduino 埠）

步驟 2：讀取 Idle 值
  → 發送 GPIO 全關 [0x02, 0xFF, 0xFF, 0x03, 0x00]
  → 讀取所有 18 通道（Arduino + STM32）

步驟 3：相鄰短路測試（每個 ID）
  → 開啟單一 GPIO：0x01 + 單 bit bitmask
  → 讀取 Running 狀態（Arduino + STM32）
  → 讀取相鄰腳位檢查短路
  → GPIO 指令使用 Completer 等待 ACK（逾時 100ms，最多重試 5 次）

步驟 4：關閉 GPIO
  → [0x02, 0xFF, 0xFF, 0x03, 0x00]

步驟 5：感測器測試
  → 讀取感測器通道

步驟 6：顯示結果
  → 通過/失敗判定，分類故障清單
```

### Body&Door 自動偵測

```
步驟 1：連線 Arduino（掃描非 ST-Link 埠）
步驟 2：讀取所有 19 通道
  → 逐一發送 Arduino 指令，等待回應（50ms 輪詢）
  → 未收到數據的 ID 進行重試
步驟 3：顯示結果（對照閾值設定）

※ 無 STM32 操作、無 MOSFET/Running 測試，僅 Idle 讀取
```

---

## ADC 通道對應表

### Main Board（24 通道，ID 0-23）

| ID | 名稱 | Arduino 指令 | STM32 操作 | 說明 |
|----|------|-------------|-----------|------|
| 0 | SLOT1 | `s0` | 0x01/0x02/0x03 | 馬達插槽 1 |
| 1 | SLOT2 | `s1` | 0x01/0x02/0x03 | 馬達插槽 2 |
| 2 | SLOT3 | `s2` | 0x01/0x02/0x03 | 馬達插槽 3 |
| 3 | SLOT4 | `s3` | 0x01/0x02/0x03 | 馬達插槽 4 |
| 4 | SLOT5 | `s4` | 0x01/0x02/0x03 | 馬達插槽 5 |
| 5 | SLOT6 | `s5` | 0x01/0x02/0x03 | 馬達插槽 6 |
| 6 | SLOT7 | `s6` | 0x01/0x02/0x03 | 馬達插槽 7 |
| 7 | SLOT8 | `s7` | 0x01/0x02/0x03 | 馬達插槽 8 |
| 8 | SLOT9 | `s8` | 0x01/0x02/0x03 | 馬達插槽 9 |
| 9 | SLOT10 | `s9` | 0x01/0x02/0x03 | 馬達插槽 10 |
| 10 | WATERPUMP | `water` | 0x01/0x02/0x03 | 水泵 |
| 11 | SPOUT UVC | `u0` | 0x01/0x02/0x03 | 出水口 UVC |
| 12 | MIX UVC | `u1` | 0x01/0x02/0x03 | 混合 UVC |
| 13 | MAIN UVC | `u2` | 0x01/0x02/0x03 | 主 UVC |
| 14 | AMBIENT RL | `arl` | 0x01/0x02/0x03 | 環境繼電器 |
| 15 | COOL RL | `crl` | 0x01/0x02/0x03 | 冷卻繼電器 |
| 16 | SPARKLING RL | `srl` | 0x01/0x02/0x03 | 氣泡水繼電器 |
| 17 | O3 | `o3` | 0x01/0x02/0x03 | 臭氧 |
| 18 | FLOW | `flow` | 0x03 (唯讀) | 流量計 |
| 19 | PRESSURE CO2 | `pressureco2` | 0x03 (唯讀) | CO2 壓力 |
| 20 | PRESSURE WATER | `pressurewater` | 0x03 (唯讀) | 水壓 |
| 21 | MCU TEMP | `mcu` / `mcutemp` | 0x03 (唯讀) | MCU 溫度 |
| 22 | WATER TEMP | — | 0x03 (唯讀) | 水溫 |
| 23 | BIB TEMP | — | 0x03 (唯讀) | BIB 溫度 |

> **ID 0-17**：可控制（0x01 ON / 0x02 OFF）+ 可讀取（0x03 Read）
> **ID 18-23**：僅可讀取（0x03 Read）

### Body&Door Board（19 通道，ID 0-18）

| ID | 名稱 | Arduino 指令 | 說明 |
|----|------|-------------|------|
| 0 | AMBIENT RL | `ambientrl` | A0 |
| 1 | COOL RL | `coolrl` | A1 |
| 2 | SPARKLING RL | `sparklingrl` | A2 |
| 3 | WATERPUMP | `waterpump` | A3 |
| 4 | O3 | `o3` | A4 |
| 5 | MAIN UVC | `mainuvc` | A5 |
| 6 | BIB TEMP | `bibtemp` | A6 |
| 7 | FLOWMETER | `flowmeter` | A7 |
| 8 | WATER TEMP | `watertemp` | A8 |
| 9 | LEAK | `leak` | A9 |
| 10 | WATER PRESSURE | `waterpressure` | A10 |
| 11 | CO2 PRESSURE | `co2pressure` | A11 |
| 12 | SPOUT UVC | `spoutuvc` | A12 |
| 13 | MIX UVC | `mixuvc` | A13 |
| 14 | FLOWMETER2 | `flowmeter2` | A14 |
| 15 | BODY POWER 24V | `bp24v` | A15,CH5 |
| 16 | BODY POWER 12V | `bp12v` | A15,CH7 |
| 17 | BODY POWER UP SCREEN | `bpup` | A15,CH6 |
| 18 | BODY POWER LOW SCREEN | `bplow` | A15,CH4 |

> Body&Door 僅透過 Arduino 讀取，無 STM32 GPIO 控制。

---

## 錯誤處理模式

### 串口 I/O 保護

所有 `_port!.write()` 和 `_port!.read()` 均包裹在 try-catch 中：

```dart
try {
  _port!.write(bytes);
} catch (e) {
  _appendLog('寫入錯誤: $e');
  heartbeatOkNotifier.value = false;
  onHeartbeatFailed?.call();
  stopHeartbeat();
}
```

```dart
try {
  final data = _port!.read(bytesAvailable);
} catch (e) {
  _appendLog('讀取錯誤: $e');
  heartbeatOkNotifier.value = false;
  onHeartbeatFailed?.call();
  stopHeartbeat();
  _readTimer?.cancel();  // 停止讀取計時器
}
```

### USB 拔除自動斷線

- 讀取/寫入失敗會自動觸發 `onHeartbeatFailed`
- 心跳連續 3 次失敗會觸發 `forceClose()`
- UI 層監聽 `heartbeatOkNotifier` 更新連線狀態顯示

### GPIO 指令重試機制

自動偵測中的 GPIO 指令（0x01/0x02）使用 Completer 等待 ACK：

```
發送 GPIO 指令 → 等待 100ms → 收到 ACK？
  是 → 繼續
  否 → 重新發送，最多 5 次
```

---

## 關鍵程式碼路徑

| 功能 | 檔案路徑 |
|------|---------|
| **SerialPortManager（統一串口管理）** | `lib/shared/services/serial_port_manager.dart` |
| **URCommandBuilder（STM32 指令建構）** | `lib/main_mode/services/ur_command_builder.dart` |
| **ArduinoConnectionMixin（連線驗證）** | `lib/shared/services/arduino_connection_service.dart` |
| **PortFilterService（埠口過濾）** | `lib/shared/services/port_filter_service.dart` |
| **Main 串口控制 Mixin** | `lib/main_mode/controllers/serial_controller.dart` |
| **BodyDoor 串口控制 Mixin** | `lib/bodydoor_mode/controllers/serial_controller.dart` |
| **Main 自動偵測 Mixin** | `lib/main_mode/controllers/auto_detection_controller.dart` |
| **BodyDoor 自動偵測 Mixin** | `lib/bodydoor_mode/controllers/auto_detection_controller.dart` |
| **Arduino 面板 Widget** | `lib/shared/widgets/arduino_panel.dart` |
| **STM32 面板 Widget** | `lib/main_mode/widgets/ur_panel.dart` |
| **模式選擇頁** | `lib/mode_selection_page.dart` |

---

## 快速開發參考

### 新增一個 Arduino 感測器讀取

1. Arduino 端新增指令處理（回傳格式：`"名稱 (腳位): 數值\n"`）
2. `SerialPortManager` 的 `_arduinoResponseToId`（或 `_arduinoResponseToIdBodyDoor`）新增對應 key → ID
3. `DataStorageService` 確認 ADC 通道數涵蓋新 ID
4. 自動偵測 Controller 的指令列表新增該指令字串

### 新增一個 STM32 GPIO 控制

1. STM32 韌體端新增對應 bit 的 GPIO 處理
2. `UrPanel` 的 `idList` 新增該 ID 的 UI 項目
3. 自動偵測 Controller 新增該 ID 的測試步驟
4. Bitmask 自動涵蓋（只要 ID < 24）

### 新增一個 STM32 指令

1. 定義新指令碼（0x06+）
2. `URCommandBuilder.buildCommand()` 可直接使用（通用封包建構）
3. `SerialPortManager._parseUrReadResponse()` 新增解析分支
4. 新增對應 callback 或 ValueNotifier

### 複製整套串口通訊到新專案

需要的最小檔案集：
```
lib/shared/services/serial_port_manager.dart     # 核心串口管理
lib/shared/services/arduino_connection_service.dart # 連線驗證
lib/shared/services/port_filter_service.dart       # 埠口過濾
lib/main_mode/services/ur_command_builder.dart     # STM32 指令（若需要）
```

依賴：`flutter_libserialport` ^0.6.0
