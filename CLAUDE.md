# 專案規範

## 撰寫規範

- 所有程式碼註解與修改說明使用**繁體中文**
- commit 訊息使用繁體中文描述修改內容
- 與使用者對話時全程使用**繁體中文**回應（專有名詞、程式碼、變數名稱除外）

---

## 專案概述

**MAX30102 Handover Tester** — Flutter Windows/Linux 桌面應用，MAX30102 心率／血氧演算法**交接展示版**。

本專案是從「Auto-Cleaning Tester」精簡出來的副本，只保留 MAX30102 K2 交接核心與驗證它所需的最小基礎設施。
自動清洗流程、Bootloader/OTA 燒錄、異常檢測、Arduino 控制、以及三份舊版 MAX30102 模組**皆已移除**。

流程：`main.dart → SplashScreen (3 秒) → MainNavigationPage（首頁即 MAX30102 K2 交接頁）`

- 啟動時自動掃描 COM 埠並連線 STM32
- 整個 App 只維護**一條** STM32 串口連線，K2 頁與 UR 面板共用

---

## 目錄結構

```
lib/
├── main.dart                                    # 入口 + 視窗初始化
├── main_mode/
│   ├── main_navigation_page.dart                # 主導航（3 頁）
│   ├── controllers/
│   │   └── serial_controller.dart               # Mixin：STM32 串口連線 / 指令發送
│   ├── services/
│   │   └── ur_command_builder.dart              # STM32 指令建構（header + checksum）
│   ├── widgets/
│   │   ├── ur_panel.dart                        # STM32 手動控制面板（除錯用）
│   │   └── settings_page.dart                   # 設定（語言切換）
│   └── max30102_K2/                             # ★ 交接核心（自足模組）
│       ├── k2_core.dart                         # 控制層：feedData() 進、原始數值出
│       ├── k2_protocol.dart                     # 0x09 命令協定 + FIFO 解碼
│       ├── k2_signal.dart                       # 前處理（濾波 / baseline）
│       ├── k2_algorithm.dart                    # 峰谷偵測 → HR / SpO2
│       ├── k2_beatseries.dart                   # 逐拍序列與生理閘門
│       ├── k2_hrv_calculator.dart               # HRV（RMSSD / SDNN / pNN50…）
│       ├── k2_sqi.dart                          # 訊號品質指標
│       ├── k2_config.dart                       # 可調參數
│       ├── k2_setting_limits.dart               # 參數合法範圍與自動夾制
│       └── ui/                                  # 驗證用 UI（不屬於交接內容）
│           ├── k2_page.dart                     # K2 主畫面
│           ├── k2_serial_adapter.dart           # 串口 ↔ k2_core 的黏合層
│           ├── k2_wave_chart.dart               # 波形圖
│           ├── k2_hrv_chart.dart                # HRV / Poincaré 圖
│           └── k2_snapshot.dart                 # 快照存取（dart:io 直接寫檔）
└── shared/
    ├── language_state.dart                      # globalLanguageNotifier
    ├── services/
    │   ├── serial_port_manager.dart             # 串口管理（文字 + 二進位雙模式）
    │   ├── arduino_connection_service.dart      # 連線握手驗證 + ConnectResult 列舉
    │   ├── port_filter_service.dart             # COM 埠過濾（排除 ST-Link）
    │   └── localization_service.dart            # 多語系（繁中 / 英文）
    └── widgets/
        └── splash_screen.dart                   # 啟動畫面
```

**共 26 個 .dart 檔**（其中 14 個屬於 `max30102_K2/`）。

---

## 導航結構（3 頁）

| Index | 頁面 | 說明 |
|-------|------|------|
| 0 | MAX30102 K2（交接版） | **預設首頁**。自帶 COM 埠選擇與連線按鈕 |
| 1 | STM32 控制 | UR 手動面板，發送任意 payload / 完整 hex 封包 |
| 2 | 設定 | 語言切換（繁中 / English） |

### ⚠️ 串口所有權交接（`_applyStm32Mode()`）

同一個 COM 埠不可能雙開，所以切頁時必須交接 `_urManager` 的所有權：

- **切進 K2 頁**：`stopHeartbeat()` — 每秒一次的心跳 PING 會混進 K2 的資料流，必須停掉
- **切出 K2 頁**：`onRawBytes = null` 解除 K2 的 parser，再 `startHeartbeat()` 恢復

自動連線（`connectAndVerifyStm32`）內部會呼叫 `startHeartbeat()`，所以**首次連線與熱插拔重連之後，若當下停在 K2 頁，都要補一次 `stopHeartbeat()`**。這兩處補償在 `initState` 與 `_checkPortChanges()` 各有一份，改動連線流程時別漏掉。

---

## MAX30102 K2 交接核心

### 設計原則（`k2_core.dart`）

1. **不碰串口、不開 Timer** — 資料何時收、多久算一次由呼叫端決定。軟體收到 MCU 回應就丟進 `feedData()`。
2. **只吐原始值** — 不做 EMA 平滑、不做 hold/凍結、不組 log，那些是呈現層的事。
3. **記憶體有界** — 樣本緩衝與 RR 池共用 `config.dataHistoryMs`（預設 30 秒），永不成長。

### 典型用法

```dart
final k2 = Max30102K2();
final r = k2.feedData(mcuResponseBytes);   // 原封丟進來，驗框/拆包核心自己做
myChartIr.addAll(r.newIr);                 // 想畫圖就自己接
if (r.computed != null) {                  // 約每秒一次才會非 null
  print(r.computed!.bpm);
  print(r.computed!.hrv?.rmssd);
}
```

### 多語系

K2 的 `ui/` 已全面接上 `LocalizationService`（繁中 / English），字串集中在 [localization_service.dart](lib/shared/services/localization_service.dart) 的 `k2_*` 區塊。

⚠️ **兩張圖表是 `CustomPainter` 畫的**，painter 沒有 `BuildContext`，所以 `K2WaveChart` / `Max30102HrvChartView` 會把當下的 `AppLanguage` 當建構參數傳進 painter，**並納入 `shouldRepaint`**。這不是多餘的欄位——切語言時波形資料可能一個位元都沒變（例如停在「等待資料…」畫面），不比對 `lang` 就不會重繪，文字會卡在舊語言。新增 painter 時請沿用這個做法。

日誌裡提到欄位名的地方（`_fieldToLabelKey` / `_switchToLabelKey`）存的是**欄位標籤的翻譯 key** 而非寫死字串，確保日誌講的欄位名與畫面上輸入框的 label 一致。新增可調參數時三處要同步：欄位本身、翻譯 key、對照表。

### 參數安全（`k2_setting_limits.dart`）

所有可調參數都有合法範圍。`enforce()` 會在核心建構時與每輪計算前自動夾回合法區間（例如 `hrMin=0` 會導致除以零崩潰，強制夾為 20）；`check()` 只回報不修改。**新增參數時務必同步補上限制**。

---

## 通訊協定

### STM32 通用（二進位模式）
- 115200 8N1
- `URCommandBuilder.buildCommand(payload)` 自動補 header `[0x40, 0x71, board]` + checksum
- 通用指令：`0x01` ON / `0x02` OFF / `0x03` 讀 ADC / `0x04` 清除 / `0x05` 韌體版本

### 板子身分（header 第 3 byte）
| 值 | 板子 | 用途 |
|----|------|------|
| `0x30` | 主板（K2 出貨中） | UR 面板預設（`URCommandBuilder.header3`）|
| `0x31` | 擴充板 | **MAX30102 預設**（`Max30102Protocol.kDefaultBoard`）|

⚠️ 兩者預設值不同。K2 打的是擴充板 `0x31`，UR 面板打的是主板 `0x30`。

### MAX30102 專用（命令號 `0x09`）
- 4 個 sub-cmd：`QUERY_FIFO(0x00)` / `WRITE_REG` / `READ_REG` / `RESET`
- `QUERY_FIFO` 回應**變動長度**（7 ~ 151 bytes）：`byte[5] = N*6`，總長 = `7 + byte[5]`
- 其餘 sub-cmd 回應固定 9 bytes
- FIFO 原始資料：每組 6 bytes = RED(3) + IR(3)，各 18-bit **低位元組在前（LE）**
- HR / SpO2 不在晶片端計算，晶片只吐原始值

---

## 開發注意事項

- **平台**：Windows + Linux（依賴 `flutter_libserialport` + `window_manager`）
- **SDK**：Flutter ^3.10.4
- **建構**：`flutter build windows --release` / `flutter build linux --release`
- **分析**：`flutter analyze`（目前零 issue）
- **測試**：`flutter test`
- **串口安全**：所有串口操作 try-catch 保護，USB 拔除自動斷線

### 已知問題

- `test/k2_replay_verify_test.dart` **目前失敗**：重放快照的 RR 跨度差 2.52%，超過測試設定的 2.0% 門檻。這是 K2 演算法本身的容差問題，與精簡改造無關，尚未處理。
- **設定檢查訊息的本文仍是繁體中文**：`Max30102SettingLimits.check()` 回傳的 `message` / `applied` 寫在核心層 [k2_setting_limits.dart](lib/main_mode/max30102_K2/k2_setting_limits.dart)，那是交接內容，UI 依設計原則「原封輸出、一個字都不改」。日誌裡的 `↳ UI:` 註解行會跟著語言走，但它引述的核心訊息不會。要翻譯就得動交接核心，需另行決定。
- 從別處複製整個專案資料夾後首次建置，可能因殘留的 plugin symlink 而報 `PathExistsException`。解法：`flutter clean && flutter pub get`。

### 未使用的依賴

`pubspec.yaml` 中的 `file_picker` 與 `shared_preferences` 在精簡後已無任何程式碼使用（原本由 Bootloader/OTA 與舊版 MAX30102 模組使用），刻意保留未移除。

---

## AI 文件索引（aidocs/）

| 文件 | 路徑 | 說明 |
|------|------|------|
| K2 架構 | `aidocs/k2_architecture.html` | **MAX30102 K2 交接核心的完整說明，最重要** |
| MAX30102 運算方式 | `aidocs/max30102_algorithms.md` | 心率 2 種 + 血氧 3 種運算總覽、前處理、SQI、EMA、各自出處 |
| 串口通訊協定 | `aidocs/serial_protocol.md` | STM32 通訊協定、封包格式、ADC 對應表（含已移除功能的協定，僅供參考）|
| BIA 生物阻抗原理 | `aidocs/bia_principle.md` | 導電機制、細胞膜電容、頻率與電流路徑、相位量測、誤差排行、手把式限制 |
| BIA 公式表 | `aidocs/bia_formulas.md` | 全部公式（表格形式）+ AD5940 參數／腳位／隔離元件實查值 |
