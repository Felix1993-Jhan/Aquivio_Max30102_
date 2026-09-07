# MAX30102 量測服務 — 使用說明

> **目前版本 `0.0.0.4`** — 用 `./max30102_server --version` 或 `/health` 的 `version` 欄位確認手上是哪一版。
> 版本沿革記在 `bin/server_version.dart`。


> 這份文件是給**串接方（React + Koa）**看的。
> 你不需要懂 Dart，也不需要編譯任何東西——拿到執行檔就能用。
>
> English version: [SERVER_GUIDE.en.md](SERVER_GUIDE.en.md)

---

## 這是什麼

一支常駐的 HTTP / WebSocket 服務，負責把 MAX30102 感測器的原始訊號，
換算成**心率、血氧、HRV（心跳變異度）**。

```
MAX30102 感測器 ──> 這支服務 ──> 你的 Koa ──> React 前端
                    (算數值)      (轉發)      (畫面)
```

它**只做運算**，不存資料庫、不管畫面、不做登入。
要保留歷史紀錄是你們那邊的事——它手上永遠只有「最近 30 秒」。

---

## 你會拿到什麼

| 檔案 | 說明 |
|---|---|
| `max30102_server` | Linux x86-64 執行檔，**不需要安裝任何執行環境** |
| 這份文件 | |

---

## 三分鐘上手

```bash
# 1. 給執行權限
chmod +x max30102_server

# 2. 啟動（先用不接硬體的模式確認它活著）
./max30102_server --mode feed --port 8770 &

# 3. 確認
curl http://localhost:8770/health
```

看到這樣就成功了：

```json
{"ok":true,"mode":"feed","uptimeMs":1204,"totalSamples":0,"resetOnFingerOff":true,"source":{}}
```

> 它沒有畫面，啟動後就靜靜待著等你呼叫，這是正常的。

---

## ★ 開始量測前，先確認硬體有沒有正常啟動

整條鏈路有三段，**任何一段斷掉，畫面上看起來都一樣**（數值全 `null`）：

```
MAX30102 晶片  ←I2C→  MCU (STM32)  ←串口→  這支服務
     ①                    ②                  ③
```

| 斷在哪 | 症狀 | 怎麼查 |
|---|---|---|
| ③ 串口 | 服務連不上裝置 | `/health` 的 `source.open` 是 `false`、`lastError` 有訊息 |
| ② MCU | 串口開著但沒人回話 | [`/chip`](#chip) 的 `mcu.online` 是 `false` |
| ① 晶片 | MCU 正常但讀不到感測器 | [`/chip`](#chip) 的 `chip.online` 是 `false` |

### 目前的確認步驟

```bash
# 1. 串口有沒有開起來
curl http://localhost:8770/health
#    → 確認 "open": true

# 2. 把手指放上感測器，等 5 秒後看
curl http://localhost:8770/vitals
#    → "fingerPresent": true 代表①②③整條都通
#    → 再等一下 "bpm" 出現數字，代表運算也正常
```

**第 2 步是目前唯一的端到端驗證**——手指放上去有反應，就表示晶片、MCU、串口
三段都是好的。

### ⚠️ 目前的限制（重要）

**服務啟動時不會自動初始化 MAX30102。**

如果晶片處於未初始化（休眠）狀態，服務會一直去問、一直收到空資料，
而且**不會報任何錯**——`/health` 顯示一切正常，`/vitals` 全是 `null`，
看起來就跟「沒人放手指」一模一樣。

遇到「怎麼放手指都沒反應」時，用這兩支查與修：

```bash
# 硬體到底哪一段有問題？
curl http://localhost:8770/chip

# 初始化晶片
curl -X POST http://localhost:8770/chip/init
```

`serial` 模式下服務**連上串口時會自動 init 一次**，所以多數情況不必手動處理。

---

## 兩種進料模式，選一個

**資料要怎麼進到服務裡**有兩種做法，開機時決定，也可以中途切換。

| | `serial` | `feed` |
|---|---|---|
| 誰開串口 | **服務自己開** | **你們自己開** |
| 資料怎麼進去 | 服務每 100ms 自己去問感測器 | 你們 `POST /feed` 把原始 bytes 丟進來 |
| 你們要做的事 | 什麼都不用做，直接讀 `/vitals` | 開串口、送查詢指令、轉發 bytes |
| 適合 | 服務跟硬體在同一台機器 | 你們已經有串口邏輯，只想借用運算 |

### 大多數情況建議用 `serial`

```bash
./max30102_server --mode serial --serial /dev/ttyUSB0 --port 8770
```

這樣你們完全不用碰硬體，只要讀 `/vitals` 就好。

**前置條件（只有 serial 模式需要）：**

```bash
# ① 安裝串口函式庫（一定要 -dev，見下方說明）
sudo apt-get install -y libserialport-dev

# ② 給串口權限（做完要重新登入才生效）
sudo usermod -a -G dialout $USER

# ③ 找出感測器接在哪個裝置
ls -l /dev/ttyUSB* /dev/ttyACM*
```

#### ⚠️ 為什麼一定要 `-dev` 而不是 `libserialport0`

服務透過 FFI 呼叫 `dlopen("libserialport.so")` —— **無版本號**的檔名。
Linux 套件慣例是這樣分的：

| 套件 | 提供的檔案 |
|---|---|
| `libserialport0`（runtime） | `libserialport.so.0`、`libserialport.so.0.1.1` |
| `libserialport-dev` | **`libserialport.so`（無版本號的 symlink）** ← 需要的是這個 |

只裝 `libserialport0` 會得到：

```
Failed to load dynamic library 'libserialport.so': cannot open shared object file
```

不想裝 `-dev` 的話，這兩條路等效：

```bash
# ① 自己補 symlink
sudo ln -s libserialport.so.0.1.1 /usr/lib/x86_64-linux-gnu/libserialport.so

# ② 用環境變數直接指路（不必動系統目錄，適合容器）
export LIBSERIALPORT_PATH=/usr/lib/x86_64-linux-gnu/libserialport.so.0.1.1
./max30102_server --mode serial --serial /dev/ttyUSB0
```

### ⚠️ 同一個串口不能兩個程式同時開

如果桌面版測試工具（Flutter App）正連著同一個裝置，這裡就開不起來。
一次只能有一個程式持有串口。

---

## API

服務起在 `http://localhost:8770`（埠號可用 `--port` 改）。以下路徑都接在後面，
例如 `http://localhost:8770/vitals`。所有回應都是 JSON。

<a id="api-overview"></a>
### API 一覽

| 端點 | 方法 | 用途 | 主要回傳欄位 |
|---|---|---|---|
| [`/health`](#health) | GET | 服務活著嗎、目前模式、串口狀態 | `ok` `version` `mode` `source` |
| [`/vitals`](#vitals) | GET | **★ 最常用** — 心率、血氧、HRV | `bpm` `spo2` `hrv` `fingerPresent` `settling` [`strapi`](#strapi) |
| [`/waveform`](#waveform) | GET | 近 N 秒波形（原始 + 平滑兩組） | `ir` `red` `irTrim` `redTrim` `firstAbs` |
| [`/stream`](#stream) | WS | **★ 建議用** — 即時推播，約每秒一次 | 同 `/vitals` |
| [`/feed`](#feed) | POST | 餵原始資料（**僅 feed 模式**） | `accepted` `computed` `totalSamples` |
| [`/mode`](#mode) | POST | 切換 serial / feed 模式 | `mode` `source` |
| [`/chip`](#chip) | GET | MCU 與 MAX30102 在線狀態（僅 serial 模式） | `mcu` `chip` `inSync` |
| [`/chip/init`](#chip-init) | POST | 初始化晶片（RE-INIT） | `ok` `sent` |
| [`/chip/reset`](#chip-init) | POST | 復位晶片（⚠️ 之後會進入休眠） | `ok` `sent` `warning` |
| [`/chip/reset-init`](#chip-init) | POST | 復位後立刻初始化（完整重來） | `ok` `sent` |

#### 📝 所有回應都是中英雙語

錯誤與提示類欄位一律成對出現：**英文放主欄位、中文加 `Zh` 後綴**。

```json
{
  "error":    "mode must be \"serial\" or \"feed\"",
  "errorZh":  "mode 必須是 \"serial\" 或 \"feed\""
}
```

適用於 `error` / `reason` / `hint` / `note` / `warning`。
前端依使用者語言取其中一個即可，主欄位名稱與過去完全相同。

#### ⚠️ 晶片控制端點在兩種模式下的差別

晶片控制（init / reset）是**直接對 MAX30102 下指令**，跟進料模式無關。
但**誰能把指令送出去**在兩種模式下不一樣：

| 模式 | server 有串口嗎 | 行為 |
|---|---|---|
| `serial` | ✅ 有 | server **直接送出**並等 MCU 回應確認 |
| `feed` | ❌ 沒有 | server 只能把**算好的封包**給你，**由你們自己寫進串口** |

`feed` 模式的定義就是「你們自己開串口、server 只負責算」，所以 server 手上
根本沒有那條線。回應會長這樣：

```json
// serial 模式：server 已經送出去了
{ "ok": true, "sent": true, "confirmed": true }

// feed 模式：請你們自己送這個封包
{ "ok": true, "sent": false,
  "packet": [64, 113, 49, 9, 4, 0, 0, 0, 17],
  "note": "feed 模式下 server 沒有串口，請自行送出這個封包" }
```

Koa 端兩種模式共用同一段程式碼，只多一個判斷：

```js
const r = await fetch(`${K2}/chip/init`, { method: 'POST' }).then(r => r.json());
if (!r.sent) mySerialPort.write(Buffer.from(r.packet));   // 只有 feed 模式要做
```

這樣**你們完全不用碰協定細節**——表頭、checksum 都由 server 算好。
（checksum 算錯的封包會被 MCU 靜默丟棄，不會有錯誤訊息，很難查。）

實際封包內容（board = 0x31 擴充板）：

| 指令 | hex | JSON bytes |
|---|---|---|
| RE-INIT | `40 71 31 09 04 00 00 00 11` | `[64,113,49,9,4,0,0,0,17]` |
| RESET | `40 71 31 09 03 00 00 00 12` | `[64,113,49,9,3,0,0,0,18]` |
| READ_REG(0xFF) | `40 71 31 09 02 FF 00 00 14` | `[64,113,49,9,2,255,0,0,20]` |

⚠️ **`/chip/reset` 之後晶片會進入休眠、停止採樣**，必須再呼叫 `/chip/init`
才會恢復。一般情況請直接用 `/chip/init`，或用 `/chip/reset-init`
（它把兩步包成一個動作，不會忘記）。

### ⚠️ 安全性：這個服務沒有任何存取控制

- **監聽在 `0.0.0.0:8770`（所有網卡）**，不是只有本機
- **沒有認證機制**——任何連得到這個埠的人都能讀取量測資料、切換模式

部署時請自行擋住外部存取，兩種做法擇一：

```bash
# ① 防火牆（推薦）
sudo ufw deny 8770

# ② 或用 iptables
sudo iptables -A INPUT -p tcp --dport 8770 ! -s 127.0.0.1 -j DROP
```

正常用法是 **Koa 與服務跑在同一台機器**，由 Koa 打 `127.0.0.1:8770` 再轉發給前端，
8770 這個埠完全不需要對外開放。

<a id="health"></a>
### `GET /health` — 存活檢查

```bash
curl http://localhost:8770/health
```

```json
{
  "ok": true,
  "version": "0.0.0.4",
  "mode": "serial",
  "uptimeMs": 60123,
  "totalSamples": 6000,
  "resetOnFingerOff": true,
  "source": {
    "serial": "/dev/ttyUSB0", "baud": 115200,
    "open": true, "lastError": null
  }
}
```

**健康檢查請打這支，不要打 `/vitals`。** `/vitals` 在沒人量測時所有數值都是
`null`，那是正常狀態，不能當成「服務掛了」。

`source.open` 和 `source.lastError` 可以看出串口是否還活著——
USB 被拔掉時服務**不會死**，但這兩個欄位會反映出來。

---

<a id="vitals"></a>
### `GET /vitals` — 目前的量測數值 ★ 最常用

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
  "totalSamples": 6000,
  "strapi": { "…見下方「strapi 區塊」…" }
}
```

> ⚠️ **`GET /vitals` 與 WebSocket `/stream` 吐的是同一份資料。**
> WS 一接上先推一份現況，之後每算完一次推一份（約每秒）。
> 所以底下講的欄位在兩個端點都一樣。

| 欄位 | 意義 |
|---|---|
| `fingerPresent` | 有沒有偵測到手指 |
| `settling` | **沉澱中**——手指剛放上，還在等訊號穩定 |
| `sqiOk` | 這一輪訊號品質是否過關 |
| `bpm` | 心率（最近 6 拍的**中位數**，反應快） |
| `spo2` | 血氧（%） |
| `hrv` | 心跳變異度，見下表 |
| `totalSamples` | 累計收到的樣本數（100 筆 = 1 秒） |
| `strapi` | 整合方介面形狀的區塊，見 [`strapi` 區塊](#strapi) |

HRV 各項（單位 ms）：

| 欄位 | 意義 |
|---|---|
| `sdnn` | 整體變異度 |
| `rmssd` | 相鄰心跳的變異，副交感神經指標 |
| `pnn50` | 相鄰差超過 50ms 的比例（%） |
| `sd1` / `sd2` | Poincaré 圖的短軸 / 長軸 |
| `meanRr` / `meanHr` | 平均心跳間隔 / 平均心率 |
| `hrvScore` | 親切分數 = `ln(rmssd) × 20`，上限 150（跟自己比用） |
| `beats` | 這段統計用了幾拍 |

---

<a id="strapi"></a>
### `strapi` 區塊 — 整合方介面形狀

`/vitals` 回應裡的 `strapi` 物件，**形狀完全等於** `aquivio-station` 的
`VitalsResult`，可以直接取用不必轉換：

```ts
const v: VitalsResult = (await res.json()).strapi;
```

```json
"strapi": {
  "mean_hr": 70.41,
  "sdnn": 36.81,
  "rmssd": 40.19,
  "ln_rmssd": 3.694,
  "lf_hf": 0.5347,
  "sqi": 1,
  "snr_db": 8.89,
  "confidence": "good",
  "pns": 66.90,
  "ans": 27.42,
  "stress": 30.83,
  "activity": 13.02,

  "lf": 0.4240,
  "hf": 0.7931,
  "lf_ms2": 414.08,
  "hf_ms2": 774.49,
  "vlf_ms2": 166.16,
  "lf_reliable": false,
  "hf_reliable": true,
  "lf_cycles": 1.125,
  "hf_cycles": 4.218,
  "window_sec": 28.12,
  "confidence_video": "good",

  "pns_max30102": -0.352,
  "sns_max30102": 1.138,
  "ans_max30102": 1.490,
  "stress_max30102": 12.01,
  "confidence_max30102": "good"
}
```

上排是 `VitalsResult` 宣告的 12 個欄位（**一個都不會缺，沒有值就是 `null`**）；
下排是額外附帶的，靠介面的 `[key: string]: unknown` 塞進去。

#### 公式與單位都對齊 `aquivio-vitals`

`pns` / `ans` / `stress` / `activity` / `confidence` 逐字對應
`aquivio-vitals` 的 `core.py::derived_scores()` 與 `hrv_confidence()`：

```
pns      = clip((log10(rmssd) − log10(10)) / (log10(80) − log10(10)), 0, 1) × 100
ans      = clip(0.5 + log2(lf_hf) / 4,                                 0, 1) × 100
stress   = clip(0.6 × (100−pns)/100 + 0.4 × ans/100,                   0, 1) × 100
activity = clip((mean_hr − 60) / 80,                                   0, 1) × 100
confidence: snr_db ≥ 6 → good、≥ 1 → rough、其餘 very rough
```

**實測比對**（同一份真機快照，兩邊各自跑自己的程式）：

| | aquivio-vitals | 本服務 |
|---|---|---|
| `rmssd` / `sdnn` / `mean_hr` | 40.1948 / 36.8067 / 70.4125 | **完全相同** |
| `pns` / `activity` | 66.9003 / 13.0156 | **完全相同** |
| `lf_hf` | 0.6342 | 0.5347（−16%） |
| `ans` / `stress` | 33.57 / 33.29 | 27.42 / 30.83 |

時域完全一致；頻域有差是因為**估計器不同**，見下。


#### 欄位後綴:這個數字是照誰的標準算的

同一個生理量,兩套演算法會給出**尺度完全不同**的數字。後綴就是用來分辨的：

| 後綴 | 依照 | 例(同一次量測) |
|---|---|---|
| 無後綴 / `_video` | **aquivio-vitals**(攝影機那套) | `pns` 66.9（0~100 分）|
| `_max30102` | **我們自己的**（Kubios z-score / Baevsky / 拍數）| `pns_max30102` −0.35（z-score，0 = 常模平均）|

`confidence` 是你們 `VitalsResult` 宣告的欄位，名字不能動，所以另外給一個
`confidence_video` 的明確別名（**同一個值**），要哪個名字都拿得到。

⚠️ **兩套不可互比。** 66.9 和 −0.35 是同一個人、同一批 RR，只是問法不同。

#### 為什麼不直接把外層欄位改名

因為有些**根本不是同一個量**，改名等於送錯值：

| 我們的 | 他們的 | 差在哪 |
|---|---|---|
| `sqiOk` | `sqi` | 布林 vs 數字 1/0，型別不同 |
| `bpm` | `mean_hr` | 最近 6 拍**中位** vs 全窗**平均**，同一次量測差 1~3 bpm |

所以兩區並存。`sdnn` 之類重複的欄位是**同一份 `HrvStats` 導出的**，
不是各算一次——測試有釘死這條（`strapi.sdnn` 必須等於 `hrv.sdnn`）。

#### `lf` / `hf` 的單位

`aquivio-vitals` 的 `freq_domain()` 是：RR（秒）→ cubic spline 內插到 4 Hz
→ `welch(fs=4, nfft=4096)` → **直接加總 PSD bin（沒乘 df）**。

所以他們的值 = 頻帶功率(s²) ÷ df，其中 `df = fs/nfft = 4/4096`。
與我們的 ms² 差一個 `1.024e-3` 的換算因子。

| 欄位 | 單位 |
|---|---|
| `lf` / `hf` | **他們的慣例**（可直接與攝影機端比較） |
| `lf_ms2` / `hf_ms2` / `vlf_ms2` | **ms²**，我們的原始值 |

同名不同單位比缺欄位更危險，所以兩者分開命名。`lf_hf` 是比值，
縮放會約分掉，兩邊可直接互比。

#### 頻域估計器不同（差約 15%）

| | aquivio-vitals | 本服務 |
|---|---|---|
| 時間軸 | `cumsum(rr)` 把 RR 首尾相接 | RR 的**實際絕對位置** |
| 重取樣 | cubic spline 內插到 4 Hz | **不重取樣** |
| 估計 | Welch（分段平均） | Lomb-Scargle（最小平方擬合） |

我們選 Lomb-Scargle 的理由是它假設較少、也**較接近已知真值**。用振幅
已知的合成訊號（真值可以直接算出來）驗證：

| 合成訊號 | 真實 `lf_hf` | aquivio-vitals | 本服務 |
|---|---|---|---|
| LF25 / HF25 | 1.000 | 0.9774（−2.3%） | **0.9813（−1.9%）** |
| LF35 / HF18 | 3.781 | 4.0901（+8.2%） | **3.8708（+2.4%）** |
| LF15 / HF30 | 0.250 | 0.2208（−11.7%） | **0.2329（−6.8%）** |
| LF30 / HF20 | 2.250 | 2.4419（+8.5%） | **2.2460（−0.2%）** |

四組都比較接近真值。差異來源是 Welch 的分段平均會壓縮動態範圍，
而內插會製造原本不存在的資料點。

⚠️ **RR 序列有斷層時（訊號品質不佳被濾掉的拍）兩者都會退化**，
誰比較接近真值取決於斷層的分布，沒有一般性結論。

#### 30 秒視窗下 `lf_hf` 的可信度

LF 頻帶下緣 0.04 Hz 週期就有 25 秒，**30 秒只裝得下約 1.1 個週期**
（見 `lf_cycles`）。實測（同一段錄製切成不同窗長，對 5 分鐘基準）：

| 窗長 | 偏差中位數 | 落在 ±20% 內 |
|---|---|---|
| 30 秒 | **42%** | 6 / 28 |
| 2 分鐘 | **26%** | 1 / 7 |

而且它是**持續漂移**而非上下抖動——單一段 5 分鐘錄製裡，2 分鐘窗的偏差
從 −39% 單調爬到 +63%。所以拉長量測時間也解決不了。

**數值仍然照送**（攝影機端同樣是 30 秒視窗，見他們的 `docs/VITALS.md`：
*"The window is 30s (not 60s) across the station and the SDK"*），
可信度另以 `lf_reliable` / `lf_cycles` / `hf_cycles` / `window_sec` 標明。
**誠實靠標註，不靠藏數字。**

HF 不受影響：下緣 0.15 Hz 週期只有 6.7 秒，30 秒約有 4.2 個週期，
`hf_reliable` 通常是 `true`。

#### 建議：需要「放鬆／恢復」訊號時用 `rmssd`

`LF/HF` 裡機制真正站得住的那一半是 **HF（副交感）**，而 `rmssd` 與 HF 的
相關性通常 **> 0.9**（RMSSD 是一階差分，本質上就是高通濾波器），
而且**在 30 秒視窗下經過文獻驗證**。

注意 `pns` 本身就是 `rmssd` 的對數縮放，所以兩者帶的是同一份資訊。

所以如果你要的是「放鬆／恢復程度」的訊號，用 `rmssd` 或 `ln_rmssd`，
今天就能用。給不了的是交感那一半——而那一半 LF 本來就沒有真的量到。

#### 額外欄位

| 欄位 | 意義 |
|---|---|
| `lf` / `hf` | 兩個頻帶的功率，**單位同 aquivio-vitals**。比值會把資訊丟掉——`lf_hf` 變大可能是 LF 漲、也可能是 HF 掉，看絕對值才分得出來 |
| `lf_ms2` / `hf_ms2` / `vlf_ms2` | 同樣三個頻帶，但**單位是 ms²**（我們的原始值）。三者相加 ≈ `sdnn²` |
| `lf_reliable` / `hf_reliable` | 該頻帶在這段窗長下可不可信 |
| `lf_cycles` / `hf_cycles` | 該頻帶下緣在這段窗裡走了幾個完整週期。**< 4 就不可信** |
| `window_sec` | 這些數值實際涵蓋幾秒（30 秒視窗實測約 28~29） |

以下是我們自己的判讀，**與上面的 0~100 分數尺度不同、不可互比**。
它們有常模依據（Kubios 風格的 z-score），適合需要統計解讀時參考：

| 欄位 | 意義 |
|---|---|
| `pns_max30102` | 副交感指數（z-score：平均 RR + RMSSD + SD1） |
| `sns_max30102` | 交感指數（z-score：平均心率 + Baevsky 壓力指數 + SD2） |
| `ans_max30102` | 時域版自律平衡 = `sns_z − pns_z` |
| `stress_max30102` | √(Baevsky 壓力指數)，靜息常態約 7~12 |
| `confidence_max30102` | 依拍數 + SQI 判定的可信度（上面的 `confidence` 是依 SNR） |

> ⚠️ 這些 z-score 沒有用 Kubios 的常模資料庫校準，用的是文獻上健康成年人的
> 參考值。**方向可信，絕對值不會與 Kubios 對齊。**

> 各欄位的完整算法、常模來源與限制，見 `docs/VITALS_FIELDS.zh-TW.md`。

---

<a id="waveform"></a>
### `GET /waveform?seconds=5` — 原始波形（畫圖用）

```json
{
  "firstAbs": 5500, "fs": 100, "count": 500,
  "ir":      [90325, 89699, ...],
  "red":     [60112, 59980, ...],
  "irTrim":  [89982.4, 89759.4, ...],
  "redTrim": [60043.1, 59961.7, ...]
}
```

- `fs: 100` — 取樣率 100Hz，所以 500 筆 = 5 秒
- `firstAbs` — 陣列第 0 筆的絕對位置（見下方「免洗歸零」）
- `ir` / `red` — 感測器**原始**讀值
- `irTrim` / `redTrim` — **截尾平滑後**的值，**要畫乾淨的線就用這組**

四個陣列**逐筆對應、長度相同**（都等於 `count`）。

原始值與平滑值兩組都給，是刻意的：平滑會讓線好看，但也會抹掉一部分真實變化。
要顯示就用 `irTrim`，要做進一步分析就用 `ir`，由你們決定，不必自己再算一次
（平滑是運算核心做的，跟心率／HRV 用的是同一套處理）。

**不要拿這支當即時輪詢。** 30 秒的波形是 3000 筆 × 2 個陣列，約 40KB JSON。
數值請走 WebSocket，波形只在要重畫圖時才拉，而且 `seconds` 給小一點。

---

<a id="stream"></a>
### `WS /stream` — 即時推播 ★ 建議用這個

服務每算出一次結果就主動推一份（約每秒一次），格式與 `/vitals` 完全相同。
**連上的瞬間會先收到一份現況**，不必等下一次計算。

```js
const ws = new WebSocket('ws://localhost:8770/stream');
ws.on('message', (raw) => {
  const v = JSON.parse(raw);
  console.log(v.bpm, v.spo2, v.hrv?.rmssd);
});
```

---

<a id="mode"></a>
### `POST /mode` — 切換進料模式

```bash
curl -X POST http://localhost:8770/mode \
  -H 'Content-Type: application/json' \
  -d '{"mode":"serial","serial":"/dev/ttyUSB0","baud":115200}'
```

```bash
curl -X POST http://localhost:8770/mode \
  -H 'Content-Type: application/json' -d '{"mode":"feed"}'
```

切換時服務內部會把運算核心整個重置，乾淨地從新來源開始。

切 `serial` 失敗（裝置不存在、被佔用、沒權限）會回 **400** 並附上原因，
同時**自動退回 `feed` 模式**，不會卡在半死狀態：

```json
{
  "error": "無法開啟串口 /dev/ttyUSB9(是否被佔用?權限是否在 dialout 群組?)",
  "mode": "feed",
  "note": "切換失敗,已退回 feed 模式"
}
```

---

<a id="feed"></a>
### `POST /feed` — 餵原始資料（只有 `feed` 模式能用）

如果你們自己開串口，把讀到的原始封包原封丟進來：

```bash
curl -X POST http://localhost:8770/feed \
  -H 'Content-Type: application/octet-stream' --data-binary @packet.bin
```

也接受 JSON 陣列（方便手動測試）：

```bash
curl -X POST http://localhost:8770/feed \
  -H 'Content-Type: application/json' \
  -d '{"bytes":[64,113,49,9,0,6,96,234,0,80,102,1,14]}'
```

⚠️ **`serial` 模式下這支會回 409 拒絕**，這是刻意的：
兩個來源同時餵資料會讓兩條時間軸混在一起，心跳間隔會被算成亂數，
而且**不會有任何錯誤訊息**。與其默默算錯，不如明確擋下來。

---

<a id="chip"></a>
### `GET /chip` — MCU 與晶片在線狀態

**只有 `serial` 模式可用**（feed 模式下服務沒有串口，會回 409 並附上你可自行送出的封包）。

```bash
curl http://localhost:8770/chip
```

```json
{
  "mcu":  { "online": true },
  "chip": { "online": true, "partId": "0x15", "ledRed": 36, "ledIr": 36 },
  "expected": { "partId": "0x15", "ledRed": 36, "ledIr": 36 },
  "inSync": true
}
```

**一次查詢就能分辨三種狀況**，這是 `/health` 做不到的（它只知道串口開著）：

| 回應 | 意思 |
|---|---|
| `mcu.online: false` | MCU 沒回話——韌體沒跑、或線沒接好 |
| `mcu.online: true`、`chip.online: false` | MCU 正常，但讀不到 MAX30102（晶片沒接好或壞了）|
| 兩個都 `true` | 硬體鏈路完整，沒數值就純粹是沒放手指 |

`inSync` 表示晶片實際的 LED 電流與服務的設定是否一致。
不一致代表晶片可能被復位回原廠值——呼叫 `/chip/init` 可讓兩邊回到一致。

> ⚠️ 這支只做查詢**不會自動修復**。init 會讓晶片重啟，若剛好有人在量測中途，
> 那次量測就毀了。看到 `inSync: false` 請自行決定何時修。

---

#### 回應欄位對照

| 欄位 | 型別 | 說明 |
|---|---|---|
| `mcu.online` | bool | MCU（STM32）有沒有回話 |
| `mcu.error` / `mcu.errorZh` | string | MCU 無回應時的原因（英 / 中） |
| `chip.online` | bool | MAX30102 是否在線（PART_ID == `0x15`） |
| `chip.partId` | string | 實際讀到的 PART_ID，例如 `"0x15"` |
| `chip.ledRed` / `chip.ledIr` | int | 晶片上**實際**的 LED 電流 |
| `expected.partId` | string | 應該要是 `"0x15"` |
| `expected.ledRed` / `expected.ledIr` | int | 本服務**設定**的 LED 電流 |
| `inSync` | bool | 晶片實際設定與服務設定是否一致 |
| `hint` / `hintZh` | string | 該檢查什麼（英 / 中） |

#### 狀況判讀

| `mcu.online` | `chip.online` | `inSync` | 意思 | 該做什麼 |
|---|---|---|---|---|
| `true` | `true` | `true` | **一切正常**。沒數值就只是沒放手指 | 無 |
| `true` | `true` | `false` | 晶片在線，但 LED 電流與設定不符（可能被復位回原廠值） | `POST /chip/init` |
| `true` | `false` | `false` | **MCU 正常，但讀不到 MAX30102** —— 晶片沒接好或已損壞 | 檢查感測器接線 |
| `false` | `false` | `false` | **MCU 沒有回應** —— 串口是通的，但另一端沒人回話 | 檢查韌體是否運行、接線 |

> 💡 `mcu.online: false` 與 `/health` 的 `source.open: false` 是**不同的兩件事**：
> `open: false` 是連串口都打不開（裝置不存在／被佔用／無權限）；
> `mcu.online: false` 是串口開著、但另一端沒有人回話。

#### 異常時的回應範例

MCU 沒回應：

```json
{
  "mcu":  { "online": false,
            "error": "no reply from MCU (timeout 1000ms)",
            "errorZh": "MCU 沒有回應(逾時 1000ms)" },
  "chip": { "online": false },
  "inSync": false,
  "hint": "no reply from the MCU. The serial port itself is fine ...",
  "hintZh": "MCU 沒有回應。串口是通的 ..."
}
```

晶片讀不到：

```json
{
  "mcu":  { "online": true },
  "chip": { "online": false, "partId": "0x00", "ledRed": 0, "ledIr": 0 },
  "inSync": false,
  "hint": "PART_ID is not 0x15 — the chip is not connected or is faulty",
  "hintZh": "PART_ID 不是 0x15 —— 晶片沒接好或已損壞"
}
```

---

<a id="chip-init"></a>
### `POST /chip/init` · `/chip/reset` · `/chip/reset-init` — 晶片控制

```bash
curl -X POST http://localhost:8770/chip/init
```

| 端點 | 動作 | 什麼時候用 |
|---|---|---|
| `/chip/init` | RE-INIT | **最常用**——晶片沒反應時先試這個 |
| `/chip/reset` | RESET | ⚠️ 只想讓晶片休眠時。**之後必須 init** |
| `/chip/reset-init` | RESET → 等 500ms → RE-INIT | **完整重來**，最乾淨的復原手段 |

`serial` 模式下會**等 MCU 回覆確認**，不是送出去就當成功：

```json
{ "ok": true, "sent": true, "confirmed": true, "action": "init" }
```

失敗會說明原因：

```json
{ "ok": false, "sent": true, "action": "init",
  "error": "MCU reported init failure (is the chip connected?)",
  "errorZh": "MCU 回報初始化失敗(晶片是否接好?)" }
```

`feed` 模式下服務沒有串口，改成把封包交給你（見[上方說明](#api-overview)）。

> 💡 `serial` 模式**連上串口時會自動 init 一次**。韌體開機本來就會 init，
> 這是額外的保險——服務可能在韌體跑了很久之後才連上，期間晶片狀態
> 可能已被別的東西改過。

---

## 讀懂數值：三件必須知道的事

### ① `null` 不是錯誤，是「還不知道」

| 狀況 | 表現 |
|---|---|
| 沒手指 | `fingerPresent:false`，數值全 `null` |
| 沉澱中 | `settling:true`，數值仍全 `null` |
| 拍數不夠（少於 9 拍） | `hrv:null`，但 `bpm` 可能已有值 |

**請不要把 `null` 顯示成 `0`**，那會讓使用者以為心跳停了。
畫面應該顯示「量測中…」之類的提示。

### ② 手指放上去後要等約 3.5 秒才有第一個數字

這是刻意的設計。手指按下去的那一瞬間訊號會有一段劇烈變化，
如果收進去會污染基準線，導致後面整段心率都算錯。
所以服務會先丟棄 1.5 秒，再累積 2 秒才開始輸出。

**這不是卡住**，`settling: true` 就是在告訴你「我在等，別急」。

### ③ ★ 手指離開時，一切歸零（免洗模式）

這個服務預設為「一人一次」的量測情境：
**確認手指離開後，累計樣本數會歸零，下一位使用者完全從頭開始。**

```
第一位量測 → totalSamples 累加到 4488
手指離開   → totalSamples 歸 0，數值全部回 null
（沒人的空檔）→ totalSamples 維持 0
第二位量測 → totalSamples 又從 0 開始
```

**你們需要處理的**：`/waveform` 回傳的 `firstAbs` 是絕對位置，
歸零那一刻它會失效。判斷方式很簡單——**`totalSamples` 突然變小**，
看到就把畫面上累積的波形清掉重畫。

如果你們的情境不需要這個（例如長時間連續監測），啟動時加上：

```bash
./max30102_server --reset-on-finger-off false
```

#### ⚠️ 「停止餵資料」不等於「手指離開」

歸零的觸發條件是**收到「手指不在」的訊號**（連續三批紅外值低於門檻），
而不是「沒收到訊號」。

```
手指離開，但資料仍持續進來 → 服務看到低訊號 → 三批後歸零   ✅
單純停止呼叫 /feed          → 服務什麼都沒收到 → 狀態原封保留 ❌
```

`serial` 模式不用擔心——服務自己持續輪詢，手指一離開就偵測得到。

但如果你們用 `feed` 模式而且是**間歇性餵資料**（例如量測結束就停止推送），
請在停止時主動重置一次，否則下一位使用者會接續上一位的狀態：

```bash
curl -X POST http://localhost:8770/mode -H 'Content-Type: application/json' -d '{"mode":"feed"}'
```

---

## Koa 整合範例

```js
const Router = require('@koa/router');
const WebSocket = require('ws');

const K2 = 'http://127.0.0.1:8770';
const router = new Router();

// ── 給前端輪詢用 ──
router.get('/api/vitals', async (ctx) => {
  const res = await fetch(`${K2}/vitals`);
  ctx.body = await res.json();
});

router.get('/api/waveform', async (ctx) => {
  const sec = ctx.query.seconds || 5;
  const res = await fetch(`${K2}/waveform?seconds=${sec}`);
  ctx.body = await res.json();
});

// ── 健康檢查 ──
router.get('/api/health', async (ctx) => {
  try {
    const res = await fetch(`${K2}/health`);
    ctx.body = await res.json();
  } catch (e) {
    ctx.status = 503;
    ctx.body = { ok: false, error: '量測服務未回應' };
  }
});

// ── 開機時切到串口模式 ──
async function initDevice(path = '/dev/ttyUSB0') {
  const res = await fetch(`${K2}/mode`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mode: 'serial', serial: path }),
  });
  const body = await res.json();
  if (!res.ok) console.error('切換串口失敗：', body.error);
  return body;
}

// ── 即時推播：訂閱後轉發給前端 ──
function subscribe(onVitals) {
  const ws = new WebSocket(`ws://127.0.0.1:8770/stream`);
  ws.on('message', (raw) => onVitals(JSON.parse(raw)));
  ws.on('close', () => setTimeout(() => subscribe(onVitals), 3000)); // 自動重連
  return ws;
}
```

---

## 常駐執行（systemd）

```ini
# /etc/systemd/system/max30102.service
[Unit]
Description=MAX30102 量測服務
After=network.target

[Service]
Type=simple
User=你的使用者名稱
ExecStart=/opt/max30102/max30102_server --mode serial --serial /dev/ttyUSB0 --port 8770
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now max30102
sudo journalctl -u max30102 -f     # 看即時 log
```

`systemctl stop` 時服務會先把串口好好釋放再退出。

---

## 啟動參數

| 參數 | 預設 | 說明 |
|---|---|---|
| `--mode <serial\|feed>` | `feed` | 進料模式 |
| `--serial <路徑>` | `/dev/ttyUSB0` | 串口裝置 |
| `--baud <n>` | `115200` | 鮑率 |
| `--port <n>` | `8770` | HTTP 監聽埠 |
| `--interval <ms>` | `100` | 串口輪詢間隔 |
| `--wave-seconds <n>` | `30` | `/waveform` 保留秒數 |
| `--reset-on-finger-off <true\|false>` | `true` | 免洗模式 |

也支援環境變數：`K2_MODE`、`K2_SERIAL`、`K2_PORT`、`K2_BAUD`、
`K2_INTERVAL`、`K2_WAVE_SECONDS`、`K2_RESET_ON_FINGER_OFF`。

`--help` 可印出完整說明。

---

## 疑難排解

| 症狀 | 原因與處理 |
|---|---|
| `Failed to load dynamic library 'libserialport.so'` | 裝成 `libserialport0` 了 → 改裝 `libserialport-dev`（見「安裝串口函式庫」）|
| `無法開啟串口 ...(是否被佔用?權限是否在 dialout 群組?)` | ① 別的程式正開著同一個埠 ② 沒有 dialout 權限，`sudo usermod -a -G dialout $USER` 後**重新登入** |
| `/vitals` 一直全是 `null` | 手指沒放好，或 `/health` 的 `source.open` 是 `false`（串口沒開成功） |
| 數值卡在 `settling: true` | 正常，等 3.5 秒。若一直如此，代表訊號品質不足（手指壓太緊/太鬆） |
| `POST /feed` 回 409 | 目前是 `serial` 模式。先 `POST /mode {"mode":"feed"}` |
| `totalSamples` 突然變 0 | 正常，手指離開觸發免洗歸零。請清掉前端累積的波形 |
| USB 拔掉後服務沒反應 | 服務不會死。`/health` 的 `source.lastError` 會顯示原因，插回去後 `POST /mode` 重新切一次 |

---

## 附錄：還沒有硬體時怎麼開發

用 `feed` 模式配合合成資料，就能在沒有感測器的情況下把整條鏈路跑通：

```js
// 合成一個 100Hz、72bpm 的假心跳封包（24 組樣本）
function fakePacket(startIndex, bpm = 72) {
  const body = [0x40, 0x71, 0x31, 0x09, 0x00, 24 * 6];
  for (let k = 0; k < 24; k++) {
    const ph = 2 * Math.PI * (bpm / 60) * ((startIndex + k) / 100);
    const ir  = 90000 + Math.round(3000 * Math.sin(ph));
    const red = 60000 + Math.round(1500 * Math.sin(ph));
    body.push(red & 0xFF, (red >> 8) & 0xFF, (red >> 16) & 0x03);
    body.push(ir  & 0xFF, (ir  >> 8) & 0xFF, (ir  >> 16) & 0x03);
  }
  const sum = body.reduce((a, b) => a + b, 0);
  body.push((0x100 - (sum & 0xFF)) & 0xFF);   // checksum
  return body;
}

// 每 240ms 餵一包（24 筆 @100Hz），約 4 秒後就會有心率
let idx = 0;
setInterval(async () => {
  await fetch('http://127.0.0.1:8770/feed', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ bytes: fakePacket(idx) }),
  });
  idx += 24;
}, 240);
```

餵 45 秒的話，`/vitals` 會回報 `bpm` 約等於 72——可以拿來驗證整條鏈路是否正確。

> 注意：合成訊號的血氧值是固定的（因為紅光/紅外振幅比是寫死的），
> 那個數字沒有生理意義，只用來確認資料有流通。
