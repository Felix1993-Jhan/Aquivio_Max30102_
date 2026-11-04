# AQUIVIO MAX30102 Vitals Server

**[中文](#中文) | [English](#english)**

---

## 中文

AQUIVIO K2 指尖感測器（MAX30102）的量測服務：從 MCU 收原始光訊號，算出心率、血氧與 HRV，以 HTTP / WebSocket 提供給站台使用。

| 項目 | 內容 |
|------|------|
| 服務版本 | **0.0.0.9**（定義在 `bin/server_version.dart` 的 `kServerVersion`）|
| 語言 / 產出 | 純 Dart，`dart compile exe` 編成單一執行檔，**不需要安裝 Dart / Flutter 執行環境** |
| 平台 | Linux AMD64（主要）、Windows x64、macOS arm64 |
| 對外介面 | HTTP + WebSocket，預設埠 `8770` |
| 對 MCU | 串口 115200 8N1，表頭 `40 71 31`（擴充板）+ checksum，命令 `0x09` |
| 感測器 | MAX30102，SpO2 模式，100 Hz、18-bit，紅光 + 紅外 |

### 系統定位

```
站台（React + Koa）  ⇄  HTTP / WS  ⇄  本服務  ⇄  串口  ⇄  擴充板 MCU（Nucleo-L432KC）  ⇄  I²C  ⇄  MAX30102
```

晶片只吐原始讀數，**心率與血氧都在本服務算**。同一個 repo 裡另有一支 Flutter 桌面 App，是開發時驗證演算法用的（波形、HRV 圖、快照），不交付；App 與本服務共用同一份計算核心 `lib/main_mode/max30102_K2/`，兩者算出來的數字一致。

### 主要功能

- **心率 / 血氧**：每秒更新一次。手指放上後約 3.5 秒出現第一個數值
- **HRV**：SDNN、RMSSD、pNN50、SD1 / SD2；頻域 LF / HF（Lomb-Scargle）；每筆 RR 分成乾淨 / 漏拍 / 偽拍，**只有乾淨的進計算**
- **`strapi` 區塊**：欄位名與型別照站台的 `VitalsResult` 宣告，可直接取用；`confidence` 分 `good` / `rough` / `very rough`
- **兩種進料模式**：`serial`（本服務自己開串口輪詢）與 `feed`（上層 POST 原始 bytes），兩者互斥，不可混用
- **即時串流**：WS `/stream` 每秒推一次數值，加上 `wave` 區塊（找谷用的帶通線，落後約 1.5 秒）
- **晶片控制**：開 / 關 LED、讀晶片狀態；關燈期間 `fingerPresent` 固定為 `false`
- **免洗模式**：手指離開就全部歸零，下一位從零開始（一人一次的量測情境）
- **LED 方向**：部分 MAX30102 模組把兩顆 LED 裝反，核心可自動判定或強制指定方向

### API

| 方法 | 路徑 | 用途 |
|:---:|------|------|
| GET | `/health` | 存活檢查、版本、目前模式與串口狀態 |
| GET | `/vitals` | 最新的量測數值（含 `hrv`、`strapi`）|
| GET | `/waveform?seconds=10` | 近一段波形（原始 + 截尾平滑）|
| WS | `/stream` | 每算出新結果就推送：`/vitals` 的內容 + `wave` 增量波形 |
| POST | `/mode` | 切換進料模式（`serial` / `feed`）|
| POST | `/feed` | 餵原始 MCU bytes（僅 `feed` 模式）|
| GET | `/chip` | MCU 與晶片在線狀態、LED 電流（僅 `serial` 模式）|
| POST | `/chip/init` | 初始化晶片，開燈 |
| POST | `/chip/reset` | 復位晶片，關燈、停止採樣；之後必須 init |
| POST | `/chip/reset-init` | 復位後等 500 ms 再初始化 |

所有回應都是中英雙語（`error` / `errorZh`、`hint` / `hintZh`）。欄位與判讀方式見 [SERVER_GUIDE](docs/SERVER_GUIDE.zh-TW.md)。

### 快速開始

```bash
# 不接硬體，先確認服務活著
./max30102_server --mode feed --port 8770
curl http://localhost:8770/health

# 接硬體（Linux）
./max30102_server --mode serial --serial /dev/ttyACM0 --port 8770
```

| 參數 | 環境變數 | 預設 | 說明 |
|------|------|------|------|
| `--mode` | `K2_MODE` | `feed` | `serial` / `feed` |
| `--serial` | `K2_SERIAL` | `/dev/ttyUSB0` | 串口路徑（Windows 是 `COM3` 這類）|
| `--baud` | `K2_BAUD` | `115200` | 鮑率 |
| `--port` | `K2_PORT` | `8770` | HTTP 監聽埠 |
| `--board` | `K2_BOARD` | `49` | 表頭板號，十進位（48 = `0x30` 主板，49 = `0x31` 擴充板）|
| `--interval` | `K2_INTERVAL` | `100` | 串口輪詢間隔（ms）|
| `--wave-seconds` | `K2_WAVE_SECONDS` | `30` | `/waveform` 保留秒數 |
| `--reset-on-finger-off` | `K2_RESET_ON_FINGER_OFF` | `true` | 免洗模式 |

`--help` 印出完整說明，`--version` 只印版本號。命令列優先於環境變數。

### 部署注意事項

- **Linux 串口模式要裝 `libserialport-dev`**（不是 `libserialport0`，FFI 要的是無版本號的 `.so`），執行的使用者要在 `dialout` 群組。
- **Windows 串口模式要 `serialport.dll`**，放在執行檔旁邊（見 [packaging/windows/README.txt](packaging/windows/README.txt)）。企業管控的機器可能被 Application Control 擋下（error 4551），這時只能用 `feed` 模式。Windows 沒有 `SIGTERM`，只收 Ctrl+C，不影響運作。
- **服務沒有任何認證**，預期與 Koa 跑在同一台機器上，不要把 8770 對外開放。
- 缺少串口函式庫時服務照樣啟動，`feed` 模式完全正常，只有切 `serial` 會失敗。

完整部署步驟（systemd、防火牆、找串口）見 [SERVER_GUIDE](docs/SERVER_GUIDE.zh-TW.md)。

### 目錄結構

```
bin/
  max30102_server.dart     服務進入點（只能 import 純 Dart）
  server_version.dart      版本號與完整沿革
lib/main_mode/
  max30102_K2/             計算核心（服務與 App 共用；ui/ 子資料夾只給 App）
lib/                       其餘為 Flutter 桌面 App（驗證用）
test/                      單元測試與服務 API 測試
docs/                      對外文件（SERVER_GUIDE 中英、欄位說明）
aidocs/                    演算法技術文件
packaging/                 Windows / macOS 打包說明
.github/workflows/         CI
```

### 建置

```bash
flutter pub get
dart compile exe bin/max30102_server.dart -o max30102_server
```

CI（[build.yml](.github/workflows/build.yml)）產出三種執行檔：

| 產物 | 何時建置 |
|------|------|
| `max30102-server-linux-amd64` | 每次 push（含 feed / serial 冒煙測試與 API 測試）|
| `max30102-server-windows-x64` | 手動 Run workflow，附 `serialport.dll` |
| `max30102-server-macos-arm64` | 手動 Run workflow，附 `libserialport.dylib` |

### 文件

| 要找什麼 | 文件 |
|------|------|
| **整合指南（從這裡開始）** | [SERVER_GUIDE.zh-TW.md](docs/SERVER_GUIDE.zh-TW.md) |
| `/vitals` 每個欄位的意義 | [VITALS_FIELDS.zh-TW.md](docs/VITALS_FIELDS.zh-TW.md) |
| 每個數字怎麼算出來的 | [vitals_metrics_derivation.md](aidocs/vitals_metrics_derivation.md) |
| 找谷的帶通線 | [trough_line.md](aidocs/trough_line.md) |
| `confidence` 的規則 | [confidence.md](aidocs/confidence.md) |
| 完整版本沿革 | [server_version.dart](bin/server_version.dart) |

### 版本

| 版本 | 重點 |
|------|------|
| 0.0.0.9 | 關燈（`/chip/reset`）期間 `fingerPresent` 固定 `false`；晶片指令完成後立刻推送 `/stream`；開燈或啟動後不再短暫誤報有手指 |
| 0.0.0.8 | 找谷 / 畫圖改用 0.7~3.5 Hz 帶通；RR 逐筆分類，只有乾淨的進 HRV；`confidence` 恢復三級 |
| 0.0.0.7 | `confidence` 改看脈搏品質；`wave` 改由核心輸出 |
| 0.0.0.6 | LED 方向自動判定；新增 `channelOrient` |
| 0.0.0.5 | WS `/stream` 加推 `wave` 波形 |
| 0.0.0.4 | SNR 頻帶定義補齊（`snr_db` 數值變動）|
| 0.0.0.3 | `strapi` 區塊的公式、單位與站台對齊 |
| 0.0.0.2 | 新增 `strapi` 區塊 |
| 0.0.0.1 | 最初版：心率 / 血氧 / HRV / 波形 / 晶片控制 |

完整紀錄見 [server_version.dart](bin/server_version.dart)。舊版說明文件在 [docs/old/](docs/old/)。

---

## English

Measurement service for the AQUIVIO K2 fingertip sensor (MAX30102). It takes raw optical readings from the MCU, computes heart rate, SpO2 and HRV, and serves them to the station over HTTP / WebSocket.

| Item | Detail |
|------|------|
| Service version | **0.0.0.9** (`kServerVersion` in `bin/server_version.dart`) |
| Language / output | Pure Dart, compiled with `dart compile exe` into a single executable; **no Dart / Flutter runtime needed** |
| Platforms | Linux AMD64 (primary), Windows x64, macOS arm64 |
| Interface | HTTP + WebSocket, port `8770` by default |
| MCU link | Serial 115200 8N1, header `40 71 31` (expansion board) + checksum, command `0x09` |
| Sensor | MAX30102 in SpO2 mode, 100 Hz, 18-bit, red + infrared |

### System role

```
Station (React + Koa)  ⇄  HTTP / WS  ⇄  this service  ⇄  serial  ⇄  expansion-board MCU (Nucleo-L432KC)  ⇄  I²C  ⇄  MAX30102
```

The chip only outputs raw readings; **heart rate and SpO2 are computed in this service**. The repo also contains a Flutter desktop app used during development to validate the algorithm (waveforms, HRV charts, snapshots). It is not shipped. The app and the service share the same computation core, `lib/main_mode/max30102_K2/`, so they produce the same numbers.

### Features

- **Heart rate / SpO2**: updated once per second. The first value appears about 3.5 s after the finger is placed
- **HRV**: SDNN, RMSSD, pNN50, SD1 / SD2; frequency-domain LF / HF (Lomb-Scargle). Each RR interval is classified as clean / missed beat / artifact, and **only clean intervals are used**
- **`strapi` block**: field names and types follow the station's `VitalsResult` declaration and can be used as-is; `confidence` is `good` / `rough` / `very rough`
- **Two input modes**: `serial` (the service polls the serial port itself) and `feed` (the caller POSTs raw bytes). They are mutually exclusive
- **Live stream**: WS `/stream` pushes values once per second, plus a `wave` block (the band-pass line used for trough detection, about 1.5 s behind)
- **Chip control**: turn the LEDs on / off and read the chip status; `fingerPresent` stays `false` while the LEDs are off
- **Single-session mode**: everything resets when the finger is removed, so the next person starts from zero
- **LED orientation**: some MAX30102 modules have the two LEDs swapped; the core can detect the orientation or use a fixed setting

### API

| Method | Path | Purpose |
|:---:|------|------|
| GET | `/health` | Liveness, version, current mode and serial status |
| GET | `/vitals` | Latest values (including `hrv` and `strapi`) |
| GET | `/waveform?seconds=10` | Recent waveform (raw + trim-smoothed) |
| WS | `/stream` | Pushed on every new result: the `/vitals` content + incremental `wave` |
| POST | `/mode` | Switch input mode (`serial` / `feed`) |
| POST | `/feed` | Push raw MCU bytes (`feed` mode only) |
| GET | `/chip` | MCU and chip status, LED currents (`serial` mode only) |
| POST | `/chip/init` | Initialise the chip and turn the LEDs on |
| POST | `/chip/reset` | Reset the chip: LEDs off, sampling stops; init is required afterwards |
| POST | `/chip/reset-init` | Reset, wait 500 ms, then initialise |

All responses are bilingual (`error` / `errorZh`, `hint` / `hintZh`). Fields and how to read them: [SERVER_GUIDE](docs/SERVER_GUIDE.en.md).

### Quick start

```bash
# No hardware: check the service is alive
./max30102_server --mode feed --port 8770
curl http://localhost:8770/health

# With hardware (Linux)
./max30102_server --mode serial --serial /dev/ttyACM0 --port 8770
```

| Option | Environment variable | Default | Meaning |
|------|------|------|------|
| `--mode` | `K2_MODE` | `feed` | `serial` / `feed` |
| `--serial` | `K2_SERIAL` | `/dev/ttyUSB0` | Serial port path (e.g. `COM3` on Windows) |
| `--baud` | `K2_BAUD` | `115200` | Baud rate |
| `--port` | `K2_PORT` | `8770` | HTTP listen port |
| `--board` | `K2_BOARD` | `49` | Header board byte, decimal (48 = `0x30` main board, 49 = `0x31` expansion board) |
| `--interval` | `K2_INTERVAL` | `100` | Serial polling interval (ms) |
| `--wave-seconds` | `K2_WAVE_SECONDS` | `30` | Seconds of waveform kept for `/waveform` |
| `--reset-on-finger-off` | `K2_RESET_ON_FINGER_OFF` | `true` | Single-session mode |

`--help` prints the full usage and `--version` prints only the version. Command-line options take precedence over environment variables.

### Deployment notes

- **Serial mode on Linux needs `libserialport-dev`** (not `libserialport0`; the FFI binding loads the unversioned `.so`), and the user running the service must be in the `dialout` group.
- **Serial mode on Windows needs `serialport.dll`** next to the executable (see [packaging/windows/README.txt](packaging/windows/README.txt)). On managed machines, Application Control may block it (error 4551); in that case only `feed` mode is available. Windows has no `SIGTERM`, so only Ctrl+C is handled; this does not affect operation.
- **The service has no authentication.** It is meant to run on the same machine as Koa; do not expose port 8770.
- If the serial library is missing, the service still starts and `feed` mode works normally; only switching to `serial` fails.

Full deployment steps (systemd, firewall, finding the port): [SERVER_GUIDE](docs/SERVER_GUIDE.en.md).

### Repository layout

```
bin/
  max30102_server.dart     Service entry point (pure Dart imports only)
  server_version.dart      Version number and full history
lib/main_mode/
  max30102_K2/             Computation core (shared by the service and the app; ui/ is app-only)
lib/                       Everything else is the Flutter desktop app (validation only)
test/                      Unit tests and service API tests
docs/                      Integration docs (SERVER_GUIDE in Chinese and English, field reference)
aidocs/                    Algorithm documentation
packaging/                 Windows / macOS packaging notes
.github/workflows/         CI
```

### Build

```bash
flutter pub get
dart compile exe bin/max30102_server.dart -o max30102_server
```

CI ([build.yml](.github/workflows/build.yml)) produces three executables:

| Artifact | Built when |
|------|------|
| `max30102-server-linux-amd64` | Every push (with feed / serial smoke tests and API tests) |
| `max30102-server-windows-x64` | Manual Run workflow, includes `serialport.dll` |
| `max30102-server-macos-arm64` | Manual Run workflow, includes `libserialport.dylib` |

### Documentation

Some documents are in Chinese only, as noted.

| Topic | Document |
|------|------|
| **Integration guide (start here)** | [SERVER_GUIDE.en.md](docs/SERVER_GUIDE.en.md) |
| Meaning of every `/vitals` field | [VITALS_FIELDS.zh-TW.md](docs/VITALS_FIELDS.zh-TW.md) (Chinese) |
| How each number is derived | [vitals_metrics_derivation.md](aidocs/vitals_metrics_derivation.md) (Chinese) |
| The band-pass trough line | [trough_line.md](aidocs/trough_line.md) (Chinese) |
| `confidence` rules | [confidence.md](aidocs/confidence.md) (Chinese) |
| Full version history | [server_version.dart](bin/server_version.dart) (Chinese) |

### Versions

| Version | Highlights |
|------|------|
| 0.0.0.9 | `fingerPresent` stays `false` while the LEDs are off (`/chip/reset`); `/stream` pushes right after a chip command; no brief false finger detection after the LEDs turn on or the service starts |
| 0.0.0.8 | Trough detection and plotting use a 0.7–3.5 Hz band-pass filter; RR intervals classified individually, only clean ones used for HRV; `confidence` back to three levels |
| 0.0.0.7 | `confidence` based on pulse quality; `wave` produced by the core |
| 0.0.0.6 | Automatic LED orientation detection; new `channelOrient` field |
| 0.0.0.5 | WS `/stream` adds the `wave` waveform |
| 0.0.0.4 | SNR band definitions completed (`snr_db` values change) |
| 0.0.0.3 | `strapi` formulas and units aligned with the station |
| 0.0.0.2 | New `strapi` block |
| 0.0.0.1 | Initial release: heart rate / SpO2 / HRV / waveform / chip control |

Full history: [server_version.dart](bin/server_version.dart) (Chinese). Old documentation: [docs/old/](docs/old/).
