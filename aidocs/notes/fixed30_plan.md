# MAX30102 server 固定 30 秒量測模式 / Fixed 30-second measurement mode

> 加入版本：0.0.1-fixed30s（規劃中，尚未實作）／最後修改：0.0.1-fixed30s（2026-11-20）
>
> 狀態：暫定方案，待與 Mark 討論。中文版最後一節「內部對照」不給軟體。

- [中文版](#zh)
- [English](#en)

---

<a id="zh"></a>

# 中文版

# MAX30102 server 固定 30 秒量測模式（規劃中，尚未實作）

> **說明**：這是暫定的做法，細節可能還會調整。我們稍後會跟 Mark 討論，有變動會再通知你。

## 1. 跟現在差在哪

| 項目 | 現在（即時模式） | 新的（固定 30 秒模式） |
|---|---|---|
| 計算時機 | 每秒算一次，數值一直在變 | 收滿 30 秒後**一次算完** |
| 量測期間的數值 | 每秒更新 | **全部是 `null`** |
| 波形 | 每秒推送 | 每秒推送（不變） |
| 心率 `bpm` | 最近 6 拍的中位數 | **整段 30 秒 HRV 的平均心率**（與 `mean_hr` 同一個值） |

## 2. 啟動方式

- **指令不用改**：不帶參數啟動，預設就是固定 30 秒模式。
- 要用即時模式，才加上 `--calc realtime`。
- 版本號：`0.0.1-fixed30s`，可從 `--version` 或 `GET /health` 查到。

## 3. 一次量測的流程

```
放上手指                                   phase = waiting
  │ 約 3 秒準備（不送波形）
  ▼
開始送波形，倒數 30 秒                       phase = measuring
  │ 每秒一包：波形 + 剩餘秒數，結果欄位全部 null
  ▼
倒數到 0，再等約 1.5 秒
  │
  ▼
算出結果，立刻推送                          phase = done
    這一包開始帶 confidence 與所有數值
```

- 從**開始收到波形**算起，大約 **31.5～32.5 秒**會收到結果。
- 判斷「結果到了」的方式：**`phase` 第一次變成 `done`**，也就是 `confidence` 第一次不是 `null` 的那一包。請以這一包為準，不要用自己的計時器決定。

## 4. 手指中途離開

| 手指離開的時間點 | server 的處理 |
|---|---|
| 倒數未滿 28 秒 | **這次作廢**，`phase` 變成 `aborted`、`abortReason` 為 `fingerRemoved`。**保持這個狀態，直到收到 init**；這段期間手指放回去也不會開始新的倒數。 |
| 倒數滿 28 秒（剩 2 秒以內） | **照常計算**，用已收到的資料（約 26 秒）算出結果並推送，`phase` 變成 `done`。 |
| 結果已經送出之後 | 不算中止，`phase` 維持 `done`，結果保留。 |

**收到 `aborted` 時，軟體要做兩件事：**
1. 提示使用者把手指放好。
2. 送 `POST /chip/init`，重新開始量測。

⚠️ 軟體如果不處理 `aborted`，使用者把手指放回去也不會有任何反應，看起來會像當機。

另外，手指短暫滑動不會觸發中止。server 要連續幾批都偵測不到手指才算離開。

## 5. 結果保存到什麼時候

結果送出後會一直保留，WS 每秒推送與 `GET /vitals` 都會帶著同一份結果，直到以下任一件事發生：

| 事件 | 結果 |
|---|---|
| 手指離開 | **保留** |
| `POST /chip/reset`（關燈） | **保留** |
| `POST /chip/init` 成功 | **清除** |
| 關閉 server | 清除 |
| 沒下 init，手指拿開再放上 | **保留**；不會開始新的量測，必須送 init |

## 6. ⚠️ init 的重要性

**init = 清除上一次的結果（或中止狀態），開始新的量測。** 每次開始量測前，不論是第一次、重新量測，還是收到 `aborted` 之後，都要先送 `POST /chip/init`。

照你們目前的流程：
- 結束時：reset
- 離開畫面時：關 server
- 新量測時：開 server 並 init
- 重新量測時：init

這樣是正確的，不需要更動。只需要再加上「收到 `aborted` 時 init」這一項。

## 7. WS `/stream` 格式

只有一條 WS，**每秒一包，每一包都是同一個完整格式**，沒有分不同種類的封包。連上之後會先立刻收到一包現況。

每一包都包含：

| 內容 | 欄位 |
|---|---|
| 波形 | `wave`、`raw_wave`（每包只帶「上一包之後」新增的那一段） |
| 狀態 | `phase`、`abortReason`、`calcMode`、`fingerPresent` |
| 時間 | `remainingSec` |
| 計算結果 | `bpm`、`spo2`、`hrv`、`strapi`（含 `confidence`） |

**新增的欄位：**

| key | 型別 | 內容 |
|---|---|---|
| `phase` | 字串 | `waiting`（等手指或準備中）/ `measuring`（倒數中）/ `done`（已出結果）/ `aborted`（中途離開，等待 init） |
| `remainingSec` | 整數或 `null` | 倒數剩餘秒數（無條件進位，30 → 1）；只有 `measuring` 時有值 |
| `abortReason` | 字串或 `null` | 目前只有 `fingerRemoved`；只有 `aborted` 時有值 |
| `calcMode` | 字串 | `fixed30` / `realtime`，表示 server 是用哪種模式啟動的 |

結果出來之前，`bpm`、`spo2`、`hrv`、`strapi`（含 `confidence`）一律是 `null`。結果出來之後，**每一包都會重複帶同一份結果**，直到收到 init；軟體只需要處理 `phase` 第一次變成 `done` 的那一包。

`GET /vitals` 拿到的內容與 WS 相同，只是不含波形。

**範例：**

倒數中：
```json
{ "phase": "measuring", "remainingSec": 12, "abortReason": null, "calcMode": "fixed30",
  "fingerPresent": true, "bpm": null, "spo2": null, "hrv": null, "strapi": null, "wave": {...} }
```

中途離開：
```json
{ "phase": "aborted", "remainingSec": null, "abortReason": "fingerRemoved", "calcMode": "fixed30",
  "fingerPresent": false, "bpm": null, "spo2": null, "hrv": null, "strapi": null }
```

已出結果：
```json
{ "phase": "done", "remainingSec": null, "abortReason": null, "calcMode": "fixed30",
  "fingerPresent": true, "bpm": 72.4, "spo2": 97, "hrv": {...}, "strapi": { "confidence": "good", ... } }
```

## （內部對照，不給軟體）

- **起算點**：倒數從「開始輸出」那一刻算起，跟即時版開始收谷是同一個時間點，約放上手指後 2.9 秒。倒數到 0 後多收 154 筆，作為右緣的前後文。
- **倒數期間只算線**：只算帶通線來推波形；找谷、HRV、SpO2、SQI 都不算。WS 改成由計時器每秒推送，結果算出來時另外立刻推一次。
- **第 28 秒後提早結束**：從手指離開判定的那一筆往回，在截尾平均的 IR 上找平台邊緣 L，只收 `L − 154` 之前的谷，跟正常結束是同一條右緣規則。抬手指時 IR 的實際形狀要上機確認。
- **`aborted` 期間**：資料不進量測、不倒數，等 init。
- **程式架構**：兩套控制層分放在 `realtime/` 與 `fixed30/`，共用的演算檔不動。
- **還沒定的**：「一次算」用哪種算法（整段一個門檻，或分段門檻＋分段 SQI），見 [bad_beat_discussion.md](bad_beat_discussion.md) §6.5。
- **先記著**：「軟體收到結果後下 reset，當作流程結束」。

---

<a id="en"></a>

# English

# MAX30102 server — Fixed 30-second measurement mode (planned, not yet implemented)

> **Note:** This is a tentative plan, and some details may still change. We will discuss it with Mark shortly and will let you know of any changes.

## 1. What changes

| Item | Now (real-time mode) | New (fixed 30-second mode) |
|---|---|---|
| When values are computed | Every second; values keep changing | **Once**, after 30 seconds of data have been collected |
| Values during the measurement | Updated every second | **All `null`** |
| Waveform | Pushed every second | Pushed every second (unchanged) |
| Heart rate `bpm` | Median of the last 6 beats | **Mean heart rate from HRV over the whole 30 s** (same value as `mean_hr`) |

## 2. How to start the server

- **No change to your launch command.** Starting without any flag runs the fixed 30-second mode by default.
- Add `--calc realtime` only if you want the real-time mode.
- Version: `0.0.1-fixed30s`, shown by `--version` and `GET /health`.

## 3. Flow of one measurement

```
Finger placed                                       phase = waiting
  │ approx. 3 s preparation (no waveform sent)
  ▼
Waveform starts, 30-second countdown                phase = measuring
  │ one packet per second: waveform + remaining seconds; all result fields null
  ▼
Countdown reaches 0, then approx. 1.5 s more
  │
  ▼
Results computed and pushed immediately             phase = done
    from this packet on, confidence and all values are filled in
```

- You will receive the results approx. **31.5–32.5 seconds after the waveform starts arriving**.
- How to tell the results have arrived: **the first packet where `phase` becomes `done`** (the same packet where `confidence` is first not `null`). Please rely on this packet, not on your own timer.

## 4. Finger removed during the measurement

| When the finger is removed | What the server does |
|---|---|
| Before 28 s of the countdown | **The measurement is discarded.** `phase` becomes `aborted` and `abortReason` is `fingerRemoved`. **This state stays until init is received.** Placing the finger again during this time does not start a new countdown. |
| After 28 s of the countdown (2 s or less remaining) | **Computes as normal** with the data collected so far (approx. 26 s), pushes the results, and `phase` becomes `done`. |
| After the results have been sent | Not treated as an abort. `phase` stays `done` and the results are kept. |

**When you receive `aborted`, the software should:**
1. Ask the user to place their finger properly.
2. Send `POST /chip/init` to start a new measurement.

⚠️ If the software does not handle `aborted`, nothing will happen when the user places their finger again. It will look as if the system has frozen.

A brief finger slip does not trigger an abort. The server only treats the finger as removed after several consecutive batches without a finger.

## 5. How long results are kept

Once sent, the results are kept. Every WS push and every `GET /vitals` carries the same results until one of the following happens:

| Event | Results |
|---|---|
| Finger removed | **Kept** |
| `POST /chip/reset` (LEDs off) | **Kept** |
| `POST /chip/init` succeeds | **Cleared** |
| Server shut down | Cleared |
| No init sent, and a finger is placed again | **Kept**. No new measurement starts until init is sent. |

## 6. ⚠️ Why init matters

**init = clear the previous results (or the aborted state) and start a new measurement.** Always send `POST /chip/init` before starting a measurement: the first one, a retry, or after receiving `aborted`.

Your current flow is correct and needs no change:
- At the end of a measurement: reset.
- When leaving the page: shut down the server.
- For a new measurement: start the server and init.
- For a retry: init.

The only addition is: **send init when you receive `aborted`.**

## 7. WS `/stream` format

There is only one WS. **It sends one packet per second, and every packet has the same full format.** There are no different packet types. Right after connecting, you immediately receive one packet with the current state.

Each packet contains:

| Content | Fields |
|---|---|
| Waveform | `wave`, `raw_wave` (each packet carries only the new segment since the previous packet) |
| Status | `phase`, `abortReason`, `calcMode`, `fingerPresent` |
| Time | `remainingSec` |
| Results | `bpm`, `spo2`, `hrv`, `strapi` (including `confidence`) |

**New fields:**

| Key | Type | Meaning |
|---|---|---|
| `phase` | string | `waiting` (waiting for a finger, or preparing) / `measuring` (counting down) / `done` (results available) / `aborted` (finger removed, waiting for init) |
| `remainingSec` | integer or `null` | Seconds left in the countdown, rounded up (30 → 1). Only has a value during `measuring`. |
| `abortReason` | string or `null` | Currently only `fingerRemoved`. Only has a value during `aborted`. |
| `calcMode` | string | `fixed30` / `realtime`: the mode the server was started in. |

Until the results are available, `bpm`, `spo2`, `hrv` and `strapi` (including `confidence`) are always `null`. Once available, **every packet repeats the same results** until init is received. You only need to handle the first packet where `phase` becomes `done`.

`GET /vitals` returns the same content as the WS, without the waveform.

**Examples:**

Counting down:
```json
{ "phase": "measuring", "remainingSec": 12, "abortReason": null, "calcMode": "fixed30",
  "fingerPresent": true, "bpm": null, "spo2": null, "hrv": null, "strapi": null, "wave": {...} }
```

Finger removed:
```json
{ "phase": "aborted", "remainingSec": null, "abortReason": "fingerRemoved", "calcMode": "fixed30",
  "fingerPresent": false, "bpm": null, "spo2": null, "hrv": null, "strapi": null }
```

Results available:
```json
{ "phase": "done", "remainingSec": null, "abortReason": null, "calcMode": "fixed30",
  "fingerPresent": true, "bpm": 72.4, "spo2": 97, "hrv": {...}, "strapi": { "confidence": "good", ... } }
```

---

## 文件修改紀錄

| 版本 | 日期 | 改了什麼 |
|---|---|---|
| 0.0.1-fixed30s | 2026-11-20 | 第 5 節：出結果後沒下 init、手指拿開再放上 → 結果保留，不會開始新量測（原寫「新倒數開始時清除」） |
| 0.0.1-fixed30s（規劃中） | 2026-11-20 | 建立：固定 30 秒模式的對外說明草案（中英） |
