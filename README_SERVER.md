# MAX30102 K2 無頭伺服器（headless server）

把 MAX30102 K2 計算核心包成 HTTP / WebSocket 服務，供上層 **React + Koa（Node.js）** 透過 localhost 呼叫。

- 進入點：[`bin/max30102_server.dart`](bin/max30102_server.dart)
- 目標平台：Linux AMD64（Windows 也可執行，見下方說明）
- 產出方式：`dart compile exe` → 單一執行檔，**不需要安裝 Dart/Flutter 執行環境**

> 這支 server 只 import 純 Dart 核心（`lib/main_mode/max30102_K2/` 扣掉 `ui/`），
> 完全不碰 Flutter。桌面 App 與 server 共用同一份計算核心，兩者行為一致。

---

## 目錄

1. [快速開始](#快速開始)
2. [兩種進料模式](#兩種進料模式)
3. [API](#api)
4. [啟動參數](#啟動參數)
5. [部署前提](#部署前提)
6. [自行編譯](#自行編譯)
7. [給 Koa 端的整合筆記](#給-koa-端的整合筆記)

---

## 快速開始

### 餵料模式（不接串口，資料由 Koa 推進來）

```bash
./max30102_server --mode feed --port 8770
```

### 串口模式（server 自己開 /dev/ttyUSB0 抓資料）

```bash
./max30102_server --mode serial --serial /dev/ttyUSB0 --baud 115200 --port 8770
```

啟動後：

```bash
curl http://localhost:8770/health
# {"ok":true,"mode":"feed","uptimeMs":1234,"totalSamples":0,"source":{}}
```

---

## 兩種進料模式

| | `serial`（架構①） | `feed`（架構②） |
|---|---|---|
| 資料從哪來 | server 自己開串口，定時送 `QUERY_FIFO` | 上層 `POST /feed` 推原始 MCU bytes |
| 誰控制節奏 | server（`--interval`，預設 100ms） | 上層 |
| `POST /feed` | **回 409 拒絕** | 可用 |
| 適用 | server 直連硬體 | Koa 那邊已經有串口連線，只想借用計算 |

### ⚠️ 兩種模式不能同時餵同一個引擎

串口的時間軸和外部餵料的時間軸混在一起，RR 間距會被算成亂數 —— **而且不會報錯**。
所以：

- `serial` 模式下 `POST /feed` 一律回 **409 Conflict**，不會默默吃掉。
- 切換模式時 server 內部一定會 `k2.reset()`，波形累積也一併清空，乾淨地從新來源重新開始。

### 執行中切換模式

```bash
# 切成串口模式
curl -X POST http://localhost:8770/mode \
  -H 'Content-Type: application/json' \
  -d '{"mode":"serial","serial":"/dev/ttyUSB0","baud":115200}'

# 切回餵料模式
curl -X POST http://localhost:8770/mode \
  -H 'Content-Type: application/json' \
  -d '{"mode":"feed"}'
```

切 `serial` 失敗時（埠不存在、被佔用、沒權限）會回 400 並附上錯誤原因，
同時**自動退回 `feed` 模式**，不會留下半死狀態：

```json
{
  "error": "無法開啟串口 /dev/ttyUSB9(是否被佔用?權限是否在 dialout 群組?)",
  "mode": "feed",
  "note": "切換失敗,已退回 feed 模式"
}
```

---

## API

### `GET /health`

存活探測。

```bash
curl http://localhost:8770/health
```

```json
{
  "ok": true,
  "mode": "serial",
  "uptimeMs": 60123,
  "totalSamples": 6000,
  "source": {
    "serial": "/dev/ttyUSB0", "baud": 115200, "board": "0x31",
    "intervalMs": 100, "open": true, "lastError": null
  }
}
```

`source.open` 與 `source.lastError` 是判斷串口是否還活著的依據 —— USB 被拔掉時
server **不會死**，但這兩個欄位會反映出來。

---

### `GET /vitals`

最新一次計算結果。

```bash
curl http://localhost:8770/vitals
```

```json
{
  "fingerPresent": true,
  "sqiOk": true,
  "settling": false,
  "bpm": 72.5,
  "spo2": 97.3,
  "hrv": {
    "sdnn": 42.1, "rmssd": 38.6, "pnn50": 12.5,
    "sd1": 27.3, "sd2": 53.2,
    "meanRr": 827.6, "meanHr": 72.5,
    "hrvScore": 73.0, "beats": 30
  },
  "totalSamples": 6000
}
```

**欄位為 null 是正常狀態，不是錯誤**：

| 狀態 | 表現 |
|---|---|
| 沒偵測到手指 | `fingerPresent:false`，`bpm`/`spo2`/`hrv` 全 `null` |
| 沉澱中（手指剛放上） | `settling:true`，數值仍全 `null` |
| 拍數不足（暖機 < 9 拍） | `hrv:null`，但 `bpm` 可能已有值 |

⚠️ 手指放上去後，要等 **空轉 1.5 秒 + 沉澱 2 秒 ≈ 3.5 秒** 才會有第一個數值，
再加約 1 秒才有首拍。這是核心的設計（避免手指按下去那一階跳污染 baseline），不是卡住。
UI 請顯示「沉澱中…」，**不要**顯示 0 或上一次的舊值。

---

### `GET /waveform?seconds=10`

近一段原始波形，供畫圖。`seconds` 省略則回傳全部保留的長度（預設保留 30 秒）。

```bash
curl "http://localhost:8770/waveform?seconds=5"
```

```json
{ "firstAbs": 5500, "fs": 100, "count": 500, "ir": [...], "red": [...] }
```

`firstAbs` 是陣列第 0 筆的**絕對樣本位置**。要把波形對齊 HRV 的拍位置就靠它：

```js
陣列索引 = 絕對位置 - firstAbs
```

---

### `POST /feed`

餵原始 MCU 回應封包（含 `40 71 ..` 表頭與 checksum）。**僅 `feed` 模式可用。**

兩種 body 格式都收：

```bash
# 正式用：原始 bytes
curl -X POST http://localhost:8770/feed \
  -H 'Content-Type: application/octet-stream' \
  --data-binary @packet.bin

# 手測方便：JSON 陣列
curl -X POST http://localhost:8770/feed \
  -H 'Content-Type: application/json' \
  -d '{"bytes":[64,113,49,9,0,6,96,234,0,80,102,1,14]}'
```

```json
{ "accepted": 13, "computed": true, "totalSamples": 290 }
```

- `computed` = 這次是否觸發了一輪計算（約每累積 100 筆樣本一次，不是每包都會）
- 封包 checksum 錯誤或不是資料回應 → 核心靜默忽略，`totalSamples` 不會增加

---

### `POST /mode`

切換進料模式，見[上方](#執行中切換模式)。

---

### `WS /stream`

每算出一份新結果就推播一份與 `/vitals` 相同格式的 JSON。連上時會**立刻先收到一份現況**，
不必等下一次計算才有畫面。

```js
const ws = new WebSocket('ws://localhost:8770/stream');
ws.onmessage = (e) => {
  const v = JSON.parse(e.data);
  console.log(v.bpm, v.spo2, v.hrv?.rmssd);
};
```

推播頻率 ≈ 每秒 1 次（跟著核心的 `computeEvery` 走）。

---

## 啟動參數

| 參數 | 環境變數 | 預設 | 說明 |
|---|---|---|---|
| `--mode <serial\|feed>` | `K2_MODE` | `feed` | 啟動時的進料模式 |
| `--serial <path>` | `K2_SERIAL` | `/dev/ttyUSB0` | 串口路徑 |
| `--baud <n>` | `K2_BAUD` | `115200` | 鮑率 |
| `--port <n>` | `K2_PORT` | `8770` | HTTP 監聽埠 |
| `--board <48\|49>` | `K2_BOARD` | `49` | 表頭板子 byte，**十進位**（48=0x30 主板，49=0x31 擴充板）|
| `--interval <ms>` | `K2_INTERVAL` | `100` | 串口輪詢間隔 |
| `--wave-seconds <n>` | `K2_WAVE_SECONDS` | `30` | `/waveform` 保留秒數 |
| `--reset-on-finger-off <true\|false>` | `K2_RESET_ON_FINGER_OFF` | `true` | 免洗模式，見下 |

優先度：命令列參數 > 環境變數 > 預設值。`--key value` 與 `--key=value` 兩種寫法都支援。

`--help` 可印出完整說明。

---

## 免洗模式（`--reset-on-finger-off`，預設開啟）

給「一人一次」的量測情境用：**確認手指離開時，核心連絕對索引一起歸零**，下一位使用者完全從零開始。

```
第一位量測 → totalSamples 累加到 4488
手指離開   → totalSamples 歸 0，波形清空，/vitals 全部回 null
（放著沒人）→ totalSamples 維持 0，空檔不計入時間軸
第二位量測 → totalSamples 又從 0 開始累加
```

`GET /health` 的 `resetOnFingerOff` 欄位會顯示目前狀態。

**Koa 端要注意**：歸零那一刻，你手上所有跟絕對位置有關的東西（`/waveform` 的 `firstAbs`、對齊用的索引）全部失效。判斷方式是 `totalSamples` 突然變小——看到就把自己畫的圖清掉重來。

關掉它（`--reset-on-finger-off false`）會回到核心的通用行為：手指離開只清緩衝，絕對索引繼續累加。

⚠️ 兩種模式的觸發時機相同，都要先通過去彈跳（連續 `fingerOffBatches` 批低於門檻）才算「真的離開」，接觸微抖不會誤觸發。

---

## 部署前提

### 1. 安裝 libserialport

串口模式透過 FFI 呼叫系統的 libserialport，執行機器**必須**裝：

```bash
sudo apt-get install -y libserialport0        # 只執行
sudo apt-get install -y libserialport-dev     # 要編譯的話
```

沒裝的話 server 仍會啟動（feed 模式完全正常），但切 `serial` 會回錯：
`Failed to load dynamic library 'libserialport.so'`。

### 2. 串口權限（沿用 `LINUX_DEPLOYMENT.md` 的做法）

```bash
# 將執行 server 的使用者加入 dialout 群組
sudo usermod -a -G dialout $USER

# 重新登入以套用，或執行：
newgrp dialout

# 驗證
groups | grep dialout
```

沒有這個權限，`openReadWrite()` 會失敗，`/mode` 會回「是否被佔用?權限是否在 dialout 群組?」。

### 3. 找出串口路徑

```bash
ls -l /dev/ttyUSB* /dev/ttyACM*
```

USB 轉串口通常是 `/dev/ttyUSB0`；有些 MCU 直接吃 USB CDC，會是 `/dev/ttyACM0`。

### 4. 常駐執行（systemd 範例）

```ini
# /etc/systemd/system/max30102-server.service
[Unit]
Description=MAX30102 K2 headless server
After=network.target

[Service]
Type=simple
User=aquivio
ExecStart=/opt/max30102/max30102_server --mode serial --serial /dev/ttyUSB0 --port 8770
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now max30102-server
sudo journalctl -u max30102-server -f
```

server 會收 `SIGTERM`，`systemctl stop` 時會先把串口釋放乾淨再退出。

### Windows 上執行

執行檔在 Windows 上一樣跑得動，功能完全相同。兩點差異：

**① 串口模式需要 `serialport.dll`**

Linux 的 `libserialport.so` 由套件管理員裝到系統目錄，全系統共用；Windows 沒有這個機制，
DLL 要自己放到**執行檔旁邊**或 `PATH` 裡。缺少時 `feed` 模式完全正常，切 `serial` 會回
`Failed to load dynamic library 'serialport.dll'`（error 126）。

DLL 不必另外下載 —— 建過 Flutter App 之後，產物裡就有一份：

```
build/windows/x64/runner/Release/serialport.dll
```

把它複製到 `max30102_server.exe` 旁邊即可。

> 為什麼 Flutter App 不用手動放？因為 `flutter_libserialport` 是 **plugin**，Flutter 的
> CMake 在 build 時會自動把 DLL 搬到 App 執行檔旁邊。server 是純 Dart，沒有這道 build
> 步驟，所以要自己準備。兩者用的是**同一個 DLL**。

**② 可能被 Application Control 政策擋住**

企業管控的機器上，未簽署的 DLL / 執行檔可能被 WDAC / AppLocker 擋掉，錯誤訊息是
`An Application Control policy has blocked this file`（error 4551）。這跟 DLL 放哪裡無關
（換路徑沒用，政策認的是檔案本身與載入它的程式）。

遇到這個情況：Windows 上就只能用 `feed` 模式，`serial` 得在 Linux 上跑，
或請 IT 把該檔案加進允許清單。

**③ 沒有 `SIGTERM`**

Windows 在 OS 層面就沒有這個概念，只掛 `SIGINT`（Ctrl+C）。不影響服務運行。

---

## 自行編譯

```bash
flutter pub get
dart compile exe bin/max30102_server.dart -o max30102_server
```

CI 上由 [`.github/workflows/build.yml`](.github/workflows/build.yml) 的 `build-server` job
自動產出，artifact 名稱 `max30102-server-linux-amd64`。

> 若這一步失敗，幾乎都是 server 的 import 圖混進了 `package:flutter` 或 `lib/main_mode/max30102_K2/ui/`。
> server 只能依賴 `dart:*`、`package:libserialport`、以及 K2 純核心。

---

## 給 Koa 端的整合筆記

server 只監聽 HTTP/WS，沒有任何認證機制 —— 它預期跑在**與 Koa 同一台機器**上，
由 Koa 對外轉發。不要把 8770 直接暴露到公網。

典型用法：

```js
// Koa 端
const BASE = 'http://127.0.0.1:8770';

// 1) 開機時決定模式
await fetch(`${BASE}/mode`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ mode: 'serial', serial: '/dev/ttyUSB0' }),
});

// 2) 前端輪詢用
router.get('/api/vitals', async (ctx) => {
  ctx.body = await (await fetch(`${BASE}/vitals`)).json();
});

// 3) 或用 WS 轉推給前端
const ws = new WebSocket('ws://127.0.0.1:8770/stream');
```

健康檢查建議打 `/health` 而不是 `/vitals` —— `/vitals` 在沒手指時所有欄位都是 `null`，
那是正常狀態，不能拿來當「server 掛了」的判斷依據。

CORS 已對所有來源開放（`Access-Control-Allow-Origin: *`），方便開發時前端直連；
正式環境建議還是走 Koa 轉發。
