# MAX30102 生理數值算法推導速查

**每一個輸出的數字是怎麼算出來的：公式、輸入、出處。**

排序方式是**資料流的順序**，不是 API 欄位順序 —— 從封包裡的 18-bit 數字開始，一路推到送出去的 28 個 key。第 N 階段只會用到第 0～N−1 階段產出的量（唯一例外是 `snr_db`，見 §9.6）。

同一個概念若有兩種算法，**時域那一種永遠先講**。

---

## 這份文件不寫什麼

| 不寫 | 去哪裡 |
|---|---|
| UART 封包格式、0x09 命令、FIFO 時序 | [serial_protocol.md](serial_protocol.md) |
| Server API、部署、啟動參數、疑難排解 | [docs/SERVER_GUIDE.zh-TW.md](../docs/SERVER_GUIDE.zh-TW.md) |
| 每個欄位對整合方意味什麼、交涉紀錄 | [docs/VITALS_FIELDS.zh-TW.md](../docs/VITALS_FIELDS.zh-TW.md) |
| 已退場的算法、曾經訂錯的門檻 | [vitals_metrics_history.md](vitals_metrics_history.md) |
| 參數怎麼調（`k2_config.dart` 每個旋鈕） | 尚未有專文；夾制範圍見 `k2_setting_limits.dart` |
| 生理學／臨床解讀 | 刻意不寫 —— 這是算法速查，開始寫解讀就會膨脹成綜述 |

---

## 版本對應

| | |
|---|---|
| 對應 commit | `6371c42`（2026-09-09） |
| server 版本 | `0.0.0.6`（`bin/server_version.dart`） |
| 撰寫日期 | 2026-09-29 |

⚠️ **本文只標檔名與函式名，不標行號。** 行號一改就腐化 —— `max30102_algorithms.md` 整份的路徑全部失效就是前例。

---

## 速查表 A：算法

出處代號見[附錄 C](#附錄-c出處清單)。「依賴」欄填的是上游的階段編號。

| # | 名稱 | JSON key | 公式 | 單位 | 依賴 | 出處 |
|---|---|---|---|---|---|---|
| 0.1 | 原始 RED / IR | — | `(b0 \| b1<<8 \| b2<<16) & 0x3FFFF` | counts | — | CHEATSHEET |
| 1.1 | 手指偵測 | `fingerPresent` | `mean(IR) ≥ 50000` | bool | 0.1 | 自訂 |
| 1.3 | 通道方向 | `channelOrient` | `R < 0.9` 正常 / `R > 1.3` 相反 | 列舉 | 4.2 | 自訂 |
| 2.1 | 截尾滑動平均 | — | `(Σ − min − max) / (cnt − 2)` | counts | 0.1 | 自訂 |
| 2.3 | 去趨勢 | — | `trim − MA(trim, 200)` | counts | 2.1 | 自訂 |
| 3.1 | 谷偵測 | — | `prominence ≥ 0.5 × p70(prominence)` | 索引 | 2.3 | scipy |
| 4.1 | 逐拍 AC / DC | — | `AC = pv − B點`、`DC = pv` | counts | 3.1 | Maxim |
| 4.2 | R | `spo2Ratio` | `median( (AC/DC)red ÷ (AC/DC)ir )` | 無單位 | 4.1 | Maxim |
| 4.3 | SpO2 | `spo2` | `−45.06R² + 30.354R + 94.845` | % | 4.2 | SparkFun |
| 5.1 | SQI | `sqi` | `cv < 0.35 ∧ spike < 5.0 ∧ kept ≥ 2` | 1 / 0 | 3.2 | 自訂 |
| 6.1 | RR | `hrv.rr` | `Δabs × 1000 / fs` | ms | 3.1 | — |
| 6.5 | 心率 | `bpm` | `60000 / median(最近 6 筆 RR)` | bpm | 6.1 | 自訂 |
| 7.1 | clean → NN | — | `\|rr − med\| ≤ max(2.5 × 1.4826 × MAD, 0.5 × med)` | ms | 6.1 | robust |
| 7.2 | 平均心率 | `mean_hr` | `60000 / meanRr` | bpm | 7.1 | — |
| 7.3 | SDNN | `sdnn` | `√( Σ(NN − mean)² / (N−1) )` | ms | 7.1 | TF1996 |
| 7.4 | RMSSD | `rmssd` | `√( Σ ΔNN² / pairs )`（只累加時間相鄰對） | ms | 7.1 | TF1996 |
| 7.4 | ln(RMSSD) | `ln_rmssd` | `ln(RMSSD)` | ln(ms) | 7.4 | — |
| 7.5 | pNN50 | — | `nn50 / pairs × 100`（絕對 50 ms） | % | 7.4 | TF1996 |
| 7.6 | SD1 / SD2 | — | `RMSSD/√2` ／ `√(2·SDNN² − SD1²)` | ms | 7.3, 7.4 | Poincaré |
| 7.7 | hrvScore | `hrv.hrvScore` | `clamp( ln(RMSSD) × 20, 0, 150 )` | 分 | 7.4 | EliteHRV |
| 7.8 | 早搏標記 | — | `median\|ΔNN\| + 4.0 × MAD` 自適應門檻 | 標記 | 7.1 | 自訂 |
| 8.2 | Lomb-Scargle | — | 見 §8.2 | ms²/Hz | 7.1 | Lomb/Scargle |
| 8.4 | VLF / LF / HF | `vlf_ms2` `lf_ms2` `hf_ms2` | `k · Σ P(f)·df` 於各頻帶 | ms² | 8.2 | TF1996 |
| 8.4 | LF / HF（他們單位） | `lf` `hf` | `ms² × 1.024e-3` | — | 8.4 | aquivio |
| 8.5 | lfNu / hfNu | — | `lf / (lf + hf) × 100` | % | 8.4 | TF1996 |
| 8.5 | LF/HF 比 | `lf_hf` | `lf ÷ hf` | 無單位 | 8.4 | TF1996 |
| 8.6 | 週期數 | `lf_cycles` `hf_cycles` | `span × 0.04` ／ `span × 0.15` | 圈 | 8.2 | 自訂 |
| 8.6 | 可用旗標 | `lf_reliable` `hf_reliable` | 圈數 `≥ 4` | bool | 8.6 | 自訂 |
| 9.1 | 副交感（z） | `pns_z` | `[ z(meanRr) + z(RMSSD) + z(SD1) ] / 3` | z | 7.2/7.4/7.6 | Kubios 風格 |
| 9.1 | 副交感（0~100） | `pns` | `clamp( (log₁₀RMSSD − 1) / (log₁₀80 − 1) ) × 100` | 0~100 | 7.4 | aquivio |
| 9.2 | 自律平衡（z） | `ans_time_domain` | `sns_z − pns_z` | z | 9.1, 9.4 | 自訂 |
| 9.2 | 自律平衡（0~100） | `ans` | `clamp( 0.5 + log₂(LF/HF) / 4 ) × 100` | 0~100 | 8.5 | aquivio |
| 9.3 | 壓力（Baevsky） | `stress_baevsky` | `√( AMo / (2 · Mo · MxDMn) )` | ≈7~12 | 7.1 | Baevsky |
| 9.3 | 壓力（0~100） | `stress` | `0.6(100−pns)/100 + 0.4·ans/100` ×100 | 0~100 | 9.1, 9.2 | aquivio |
| 9.4 | 交感（z） | `sns_z` | `[ z(meanHr) + z(√SI) − z(SD2) ] / 3` | z | 7.2/9.3/7.6 | Kubios 風格 |
| 9.5 | 活動量 | `activity` | `clamp( (meanHr − 60) / 80 ) × 100` | 0~100 | 7.2 | aquivio |
| 9.6 | 訊噪比 | `snr_db` | `10·log₁₀(sig / noise)` | dB | **0.1** | aquivio |
| 9.7 | 可信度（拍數） | `confidence_by_beats` | `≥20 → good`、`≥13 → rough` | 字串 | 7.1 | 自訂 |
| 9.7 | 可信度（SNR） | `confidence` `confidence_video` | `≥6 dB → good`、`≥1 dB → rough` | 字串 | 9.6 | aquivio |

---

## 速查表 B：可信度與視窗需求

`✓` 可用｜`△` 可用但偏差大或很薄｜`✗` 不可用｜`⚠` 會給出看似正常的錯誤值

| # | 指標 | 域 | 最少樣本 | 10 秒 | 30 秒 | 5 分鐘 | 硬閘門 |
|---|---|---|---|---|---|---|---|
| 4.3 | `spo2` | 光學 | 3 顆谷 | ✓ | ✓ | ✓ | — |
| 6.5 | `bpm` | 時域 | 2 拍 | ✓ | ✓ | ✓ | — |
| 7.2 | `mean_hr` | 時域 | 9 拍 | ✓ 1% | ✓ | ✓ | — |
| 7.3 | `sdnn` | 時域 | 9 拍 | △ 18% | ✓ | ✓ | — |
| 7.4 | `rmssd` / `ln_rmssd` | 時域 | 9 拍 | ✓ 9% / 2% | ✓ | ✓ | — |
| 7.5 | pNN50 | 時域 | 9 拍 | △ | ✓ | ✓ | — |
| 7.6 | SD1 / SD2 | 時域 | 9 拍 | ✓ 9% / △ 22% | ✓ | ✓ | — |
| 7.7 | `hrvScore` | 時域 | 9 拍 | ✓ | ✓ | ✓ | — |
| 8.4 | `vlf_ms2` | 頻域 | 8 拍 | ✗ | ✗ | △ | — |
| 8.4 | `lf` / `lf_ms2` | 頻域 | 8 拍 | ✗ | ✗ | ✓ | — |
| 8.4 | `hf` / `hf_ms2` | 頻域 | 8 拍 | ✗ | △ 剛好 4.2 圈 | ✓ | — |
| 8.5 | `lf_hf` | 頻域 | 8 拍 | ✗ | ✗ | ✓ | — |
| 9.1 | `pns` / `pns_z` | 時域 | 9 拍 | ✓ 6% | ✓ | ✓ | — |
| 9.2 | `ans_time_domain` | 時域 | 9 拍 | ✓ 5% | ✓ | ✓ | — |
| 9.2 | `ans` | 頻域 | 8 拍 | **⚠ 77 倍** | ✗ | ✓ | — |
| 9.3 | `stress_baevsky` | 時域 | 5 拍 | △ 2%（但統計很薄） | △ | ✓ | — |
| 9.3 | `stress` | 混合 | 8 拍 | **⚠ 1.6 倍** | ✗ | ✓ | — |
| 9.4 | `sns_z` | 時域 | 9 拍 | ✓ 1% | ✓ | ✓ | — |
| 9.5 | `activity` | 時域 | 9 拍 | ✓ 7% | ✓ | ✓ | — |
| 9.6 | `snr_db` | 頻域 | 5 秒波形 | ✓ | ✓ | ✓ | — |
| 5.1 | `sqi` | 工程 | 2 拍 | ✓ | ✓ | ✓ | **是** |
| 1.1 | `fingerPresent` | 光學 | 1 批 | ✓ | ✓ | ✓ | **是** |
| 1.2 | `settled` | 工程 | 200 筆 | ✓ | ✓ | ✓ | **是** |
| 1.3 | `channelOrient` | 光學 | 2 票 | ✓ | ✓ | ✓ | **是**（未定不給血氧） |
| 9.7 | `confidence_by_beats` | 時域 | 9 拍 | ✓（會誠實回報 `very rough`） | ✓ | ✓ | — |
| 9.7 | `confidence` | 頻域 | 5 秒波形 | **⚠ 只看 SNR，10 秒照樣回 `good`** | ✓ | ✓ | — |

百分比是實測值（同一份 30 秒快照切前 10 秒對照整段，工具見 §附錄 B）。

---

## 符號與慣例

```
fs        取樣率 = 100 Hz（Max30102Config.samplingRateHz，韌體設定）
N         樣本數 / 間距數
med       中位數
MAD       median( |x − med(x)| )
p70       第 70 百分位
clamp(x,a,b)  把 x 夾在 [a,b]
Σ         求和
counts    ADC 原始計數（18-bit，0 ~ 262143），無物理單位
```

**RR 與 NN 的用詞紀律：**

- **RR** = 谷與谷之間的原始間距，還沒過 `clean()`
- **NN** = 過了 `clean()` 的 RR（normal-to-normal）

**兩套尺度的稱呼：**

- **整合方尺度** = 0~100 的那組（`pns` `ans` `stress` `activity`）
- **z / Baevsky 尺度** = 我們自己的那組（`pns_z` `sns_z` `ans_time_domain` `stress_baevsky`）

不用「新／舊」「我們的／他們的」—— 交接時會歧義。

**狀態標記：** `現行` ／ `降級為閘門` ／ `已退場`（退場的只留一行，細節在 [vitals_metrics_history.md](vitals_metrics_history.md)）

---
---

# 第 1 部｜從 ADC 到一個拍

## 階段 0｜原始 RED / IR

**輸入 ←** UART 回應封包（`0x09` / `QUERY_FIFO`）　**輸出 →** `red[]`、`ir[]`（18-bit counts）

### 0.1 18-bit 重組

每組 6 bytes = RED(3) + IR(3)，各 18-bit，**低位元組在前**：

```
RED = (b[o]   | b[o+1]<<8 | b[o+2]<<16) & 0x3FFFF
IR  = (b[o+3] | b[o+4]<<8 | b[o+5]<<16) & 0x3FFFF
值域 0 ~ 262143
```

- **出處**：`MAX30102_CHEATSHEET.md §7.4`（⚠️ **在母專案 `ai_docs/bootloader/spec/`，本 repo 沒有這個檔**）；架構分工與 libdriver/max30102 一致
- **實作**：`k2_protocol.dart` → `decodeFifoResponse`

### 0.2 為什麼一切單位都是 counts

晶片吐的是 ADC 計數，沒有物理單位。這件事不是缺陷，而是後面所有公式能成立的前提：

```
R = (AC/DC)red ÷ (AC/DC)ir
```

AC 與 DC 都是 counts，相除之後**量綱消失** → R 是無單位的純數 → 才能套用 SparkFun/Maxim 用別的硬體擬合出來的係數。

同理，LED 電流改變會讓 AC 與 DC **同時**縮放，所以：

| 對 LED 電流 | 哪些東西 |
|---|---|
| **穩健**（比值，縮放抵銷） | 谷偵測的 prominence 門檻、SQI 的 cv 與 spike、RR → HRV 整條線 |
| **會受影響** | `fingerThreshold`（與 IR DC 同單位，換模組必須重調）、**SpO2**（改變紅光/紅外的電流**比例**會讓 R 系統性偏移，而公式照舊算 → 血氧穩定地偏掉幾個百分點，看起來完全正常）、**ADC 飽和**（18-bit 上限 262143，削平波峰 → AC 失真） |

所以調 LED 電流比較接近「重新校正硬體」，不是「調一個參數」。

---

## 階段 1｜控制層閘門（還沒開始算）

**輸入 ←** `ir[]`　**輸出 →** 許可（`fingerPresent`、`settled`、`channelOrient`），不是數值

### 1.1 手指偵測

```
fingerPresent(批) = mean(這批 IR) >= fingerThreshold   // 預設 50000
離開判定 = 連續 fingerOffBatches(3) 批低於門檻          // 去彈跳，約 300 ms
```

- **陷阱**：50000 是**經驗門檻，模組相依**。它與 IR DC 同單位，換模組或改 LED 電流就要重校。
- **實作**：`k2_core.dart` → `feedSamples`

### 1.2 空轉期與沉澱期 —— 為什麼第一個數字要等

```
空轉期  fingerDeadSamples = fingerDeadMs × fs / 1000 = 1500 × 100/1000 = 150 筆（1.5 秒）
沉澱期  settleSamples     = round(fs / bandLowHz)    = round(100 / 0.5) = 200 筆（2.0 秒）
```

| 階段 | 做什麼 | 為什麼 |
|---|---|---|
| 空轉期 | 偵測到手指後**完全不收** 1.5 秒 | `fingerThreshold` 是手指「壓到一半」就跨過的，IR 還會從 5 萬爬到 9 萬。那段斜坡幅度是脈搏的數十倍，進了緩衝會①去趨勢炸出巨大假暫態②找谷門檻被墊高③生出的假 RR 污染 ±40% 閘門的中位數，**真拍反被判成太短剔除**，序列鎖死在 2 倍週期 |
| 沉澱期 | 累積滿 200 筆前不輸出、不計算 | 去趨勢是「原始值 − baseline」，baseline 需要這麼寬的資料才成形。綁在 baseline 寬度上而不是寫死 200 |
| 沉澱期滿 | 把累積的 200 筆**一次全吐** | 所以波形的絕對索引會在這裡出現一次斷層（`firstAbs` 從 0 跳到 140），這不是 bug |

**時序：** 偵測到手指 → 1.5 s → 2.0 s → **約 3.5 秒後才有第一筆數值**；加上 §1.3 的方向判定，實測約 5.5 秒。

### 1.3 通道方向判定（RED / IR 誰是誰）

市面上有 MAX30102 模組**把兩顆 LED 晶粒裝反**（本專案實測 8 片中 7 片）。datasheet 規定 `0x0C` = LED1 = 紅光、FIFO 順序 RED 在前，我們的解碼完全照規格 —— 錯的是模組。

**不能靠讀數大小判斷：** DC 高低只反映「LED 多亮、光路耦合多好」，每片都不同，實測兩片健康板的方向還相反。有識別資訊的只有 **AC/DC 比值**，也就是 §4.2 的 R —— 除以 DC 正好把硬體差異消掉。

```
R < orientRatioNormal (0.9)   → 目前假設正確
R > orientRatioSwapped (1.3)  → 目前假設相反
0.9 <= R <= 1.3               → 不判定（這一輪不投票，也不給血氧）
連續 orientVotesToLatch (2) 票一致 → 鎖定
逾時 orientTimeoutMs (10 s)        → 退回 datasheet 預設方向，但 _orientByVote = false
```

| 門檻 | 換算血氧 | 為什麼 |
|---|---|---|
| 決策邊界 `R = 1` | 約 80% | 那裡 R 與 1/R 相等，兩個方向的解釋一樣合理 |
| 0.9 | 約 87% | 不能再往下壓：`R = 0.7` 已經是血氧 94%，那是正常讀數 |
| 1.3 | 約 55% | 中間那段**刻意不判定** —— 那正好是「真的缺氧」與「通道接反」分不開的區域。分不出來就不猜：寧可不給血氧，也不要把危險值自動改寫成正常值 |

實測值離模糊帶都很遠：正常板 0.46、對調板 2.35（對調後 0.42）。

- **陷阱**：方向只在「呼叫演算法時」與「組輸出時」套用，**緩衝永遠存線上收到的原始槽位**。這樣下游（波形圖、快照、`/waveform`、WS `wave`）全部自動拿到實際光源。方向掛在**這一次量測**上，手指離開就歸零。
- **心率不受影響**：兩路的脈搏是同一個（實測相關 0.995），谷照樣找得到。
- **實作**：`k2_core.dart` → `_voteOrient`；對外說法見 [SERVER_GUIDE.zh-TW.md](../docs/SERVER_GUIDE.zh-TW.md) 的「已知硬體問題」

---

## 階段 2｜前處理

**輸入 ←** `red[]`、`ir[]`　**輸出 →** `neg[]`（去趨勢、平滑、取負）

### 2.1 截尾滑動平均（去突波）

```
half = win ÷ 2（整數除法）
lo = max(0, c−half)、hi = min(n−1, c+half)、cnt = hi−lo+1
cnt <= 2 : out[c] = Σa[i] / cnt
cnt >  2 : out[c] = (Σa[i] − min − max) / (cnt − 2)
win = trimWindow = 9（固定）
```

- **中心對稱＝零相位**：視窗以 c 為中心，前後對稱 → 群延遲為 0 → **谷的位置不會位移**。這對 §6.1 的 RR 精度是必要的（偶數窗會有半樣本相位偏移）。
- 只丟 1 個最大 + 1 個最小 → 單點尖刺殺得掉；連續 2 筆以上的突波只擋一部分。
- **出處**：自訂（概念同 trimmed mean）
- **實作**：`k2_signal.dart` → `slidingTrimmedMean`

### 2.2 置中移動平均（baseline）

前綴和 O(N)，同樣置中：

```
half = window ÷ 2
out[i] = (prefix[hi+1] − prefix[lo]) / (hi − lo + 1)，lo = max(0,i−half), hi = min(n−1,i+half)
```

### 2.3 去趨勢 → 平滑 → 取負

| 步 | 運算 | 為什麼 |
|---|---|---|
| ① | `trim = slidingTrimmedMean(raw, 9)` | 殺尖刺型假谷 |
| ② | `baseline = MA(trim, hpWin)` | 呼吸漂移 |
| ③ | `detrend = trim − baseline` | **高通**（減掉長視窗平均） |
| ④ | `smoothed = MA(detrend, lpWin)` | **低通**，輕度平滑 |
| ⑤ | `neg = −smoothed` | PPG 的**谷**才是供血點；取負之後谷變成峰，才能用 §3.1 的找峰 |

視窗寬度由心率換算 —— **Hz 只是 bpm 的另一種單位**：

```
bandLowHz  = max(hrMin, 1) / 60 = 30/60  = 0.5 Hz
bandHighHz = max(hrMax, 1) / 60 = 240/60 = 4.0 Hz
hpWin = clamp(round(fs / bandLowHz), 1, n)        = 200 筆
lpWin = clamp(round(fs / (2 × bandHighHz)), 1, n) = 13 筆
```

- **陷阱**：這**不是頻域濾波器**，是時域移動平均的視窗寬度換算。全鏈沒有任何 FFT（唯一的 FFT 在 §9.6）。
- **陷阱**：`hrMin` 被設成 0 會讓這裡除以零，所以取 `max(hrMin, 1)`。

### 2.4 整窗 DC / AC

```
DC = mean(v)
AC = sqrt( Σ(v[i] − DC)² / n )      // rms
```

核心本身不用這組（SpO2 走的是逐拍版 §4.1），但**保留給軟體端**：`fingerThreshold` 就是與 IR DC 同單位，沒有這組數字就沒辦法替不同感測器調門檻。

---

## 階段 3｜谷偵測與逐拍

**輸入 ←** `neg[]`　**輸出 →** 谷索引、谷間距、`beatsOk`

### 3.1 顯著度（prominence）找峰

**prominence 的定義**（不是絕對高度）：一個峰的顯著度 = 峰值 減去「往左右各走到遇見更高的峰之前，途中的最低谷」之中**較高**的那一個。

```
① 候選局部極大：s[i] >= s[i−1] 且 s[i] > s[i+1]
② 向左掃到 s[i] > peak 為止，途中最小值 = leftMin；向右同理 = rightMin
③ prom = peak − max(leftMin, rightMin)
④ 門檻 minProm = promRatio × percentile(prom, 70)      // promRatio = 0.5
⑤ 保留 prom >= minProm，按 prom 由大到小貪婪選取
⑥ 與已選任一點距離 < distance 則丟棄
   distance = minDist = clamp(floor(60 × fs / hrMax)) = floor(6000/240) = 25 筆（250 ms）
```

- **為什麼用顯著度而不是絕對深度**：門檻跟著訊號自身的尺度走，不必為每片模組重訂。
- **陷阱**：`promRatio` 設 0 或負數 → 門檻歸零 → 雜訊全被當成谷 → 心率暴衝。
- **陷阱**：調低 `hrMax` 會拉大 `minDist`，快心跳可能被當成同一拍漏抓。
- **出處**：概念來自 `scipy.signal.find_peaks(prominence=…)`，Dart 自寫
- **實作**：`k2_signal.dart` → `findProminentPeaks`

谷少於 3 顆 → 該輪回空。

### 3.2 谷間距 → 生理閘門 → 離群剔除（窗層）

```
intervals[k] = troughs[k] − troughs[k−1]           // 單位：樣本
medInt = median(intervals)
kept = { d : hrMin <= 60·fs/d <= hrMax  且  0.5·medInt <= d <= 1.5·medInt }
beatsOk = kept.length >= 2 且 median(kept) 落在 [60·fs/hrMax, 60·fs/hrMin] = [25, 200] 筆
```

`[0.5, 1.5] × medInt` 同時擋掉漏拍（約 2 倍）與多抓（約 0.5 倍）。

- **陷阱**：這一層**不再算心率**。`beatsOk` 只當 SpO2 的閘門與空結果判斷；顯示用的心率走 §6.5 的 NN 序列版。這裡曾經是心率的來源，見[歷史文件 §6](vitals_metrics_history.md#6-心率)。

---

## 階段 4｜R 與 SpO2

**輸入 ←** 谷索引 + 截尾後的 `red`/`ir`　**輸出 →** `R`、`spo2`

### 4.1 逐拍 B 點 AC / DC

在相鄰兩谷 `[a, b]` 之間：

```
pk   = argmax x[i]，i 在 [a,b]
pv   = x[pk]                                        // 峰值
base = x[a] + (x[b] − x[a]) × (pk − a) / (b − a)    // B 點：兩谷對峰值位置的線性內插
AC   = pv − base
DC   = pv
```

**B 點法自動扣掉「這一拍之內的基線斜率」**（呼吸、漂移），這是它比整窗 RMS 好的地方。

- **陷阱**：AC/DC 吃的是**截尾後**的訊號（`irTrim`/`redTrim`），不是去趨勢後的訊號。去趨勢訊號只用來找谷的位置。
- **實作**：`k2_algorithm.dart` → `_acDcBeat`

### 4.2 R（比值）

```
每一拍：r = (AC_red / DC_red) ÷ (AC_ir / DC_ir)
跳過：b − a < 3
納入條件：DC_ir > 0、DC_red > 0、AC_ir > 0，且 0.1 < r < 3.0
R = median(所有納入的 r)          // = HrSpo2Result.spo2Ratio
```

用中位數而非平均：一次體動不會把整窗的 R 拉走。

### 4.3 SpO2

```
SpO2 = −45.06 · R² + 30.354 · R + 94.845        （%）
spo2Valid = beatsOk 且 70 <= SpO2 <= 100
```

- **出處**：SparkFun / Maxim 應用註記的擬合式（**未校正的通用經驗式**，要絕對準度必須拿真血氧機校正）
- **輸出閘門**（`k2_core.dart`）：
  ```
  spo2 = (R > 0 且 _orientByVote) ? SpO2 : null
  ```
  方向必須是**投票判定出來的**才給血氧 —— 兩路標反時 R 是倒數，算出來是生理上不可能的值（實測對調板 R = 2.35 → 血氧 −83%）。
- **⚠️ 待決事項**：`spo2Valid` 算了但核心**沒有採用**。也就是拍不可信、或值超出 70~100 時照樣輸出。收緊會讓血氧更常 null，目前先不動。
- 另兩代 SpO2 算法（整窗 RMS 版、線性 `110 − 25R`）已退場，見[歷史文件 §4](vitals_metrics_history.md#4-血氧)。

### 4.4 EMA 平滑在哪一層

**核心不套用 EMA。** `spo2SmoothFactor`(0.7) / `hrSmoothFactor`(0.8) 只是提供給呈現層的建議值：

```
顯示值ₙ = k × 顯示值ₙ₋₁ + (1 − k) × 原始值ₙ
```

套用前要知道核心**已經做過一層平滑，但不是 EMA**：心率是最近 6 拍 RR 的中位數（約 5 秒）、血氧是視窗內逐拍 R 的中位數。用中位數是刻意的 —— 中位數抗離群，EMA 會把離群值按權重吃進去再慢慢吐出來。再疊一層 EMA 是**加總延遲**。

- **出處**：仿 CAVEDU GitBook 的 `ESpO2 = 0.7·舊 + 0.3·新`

---

## 階段 5｜SQI（硬閘門）

**輸入 ←** `neg[]` + `kept`　**輸出 →** `sqiOk`

```
cv（間距離散）：
    kept.length < 2 或 mean <= 0 → cv = 1
    否則 cv = sqrt( Σ(d − mean)² / N ) / mean        // 母體標準差，分母 N
spike（突波比）：
    ampMax = max(neg)                                // 整窗單一最大值
    spike  = p70 > 0 ? ampMax / p70 : 99.0           // p70 = neg 正值的第 70 百分位
sqiOk = cv < 0.35 且 spike < 5.0 且 kept.length >= 2
```

兩個零件互補：**cv 管「間距規律度」、spike 管「振幅有無暴衝」**，一個被遮住還有另一個接。

- **⚠️ 它是硬閘門，不是燈號。** `sqiOk = false` 的那一輪，該輪的谷**不會進 NN 序列**（`k2_beatseries.feed` 的「SQI差」分支）→ 間接擋住心率與 HRV。舊文件寫「只作燈號，不擋顯示」是**錯的**，那句話描述的是已不存在的舊實作。
- **給不出連續分數**：三個零件裡只有 spike 被核心導出，`cv` 與 `keptCount` 只活在 `Max30102Sqi` 內部。要連續值得先改交接核心。
- 門檻 0.35 / 5.0 / 2 是**觀測式初值**，不是文獻值。
- **實作**：`k2_sqi.dart` → `Max30102Sqi.from`

---
---

# 第 2 部｜從拍到 HRV

## 階段 6｜NN 序列與心率

**輸入 ←** 谷的絕對位置　**輸出 →** `rr[]`（ms）、`bpm`

### 6.0 進序列之前：三道過濾

谷從演算視窗送進序列之前，`k2_core` 會先做三件事：

| 做法 | 規則 | 為什麼 |
|---|---|---|
| 丟掉最右一顆谷 | 每輪 `troughs` 的最後一顆不送 | 視窗邊緣的顯著度還沒穩，延遲一拍再收 |
| 擋掉左緣 context 區 | 起步階段只收 `t >= hpWin/2 = 100` 的谷 | baseline 是**置中**移動平均，陣列開頭那 100 筆取不到左半邊，baseline 是偏的，在那裡找到的谷不是真的脈搏。那段資料仍留在緩衝裡**當後面樣本的 baseline context**，不是丟棄 |
| 去重 | `abs <= _lastFedAbs + 12` 就跳過 | 視窗滑動時同一顆谷可能位移 1~2 樣本（12 筆 = 120 ms） |

「起步階段」的判斷條件是 `take == _ir.length`（視窗吃掉整個緩衝 ⇔ 視窗左緣 = 緩衝左緣）。緩衝滿了之後谷是先從**右緣**進來、在中段被餵過才移到左緣，這時再擋沒有意義。

### 6.1 RR

```
RR = (abs − lastTroughAbs) × 1000 / fs        （ms）
```

- **為什麼用絕對位置而不是窗內索引**：演算視窗每輪都在滑動，窗內索引每輪意義都不同。用「從量測開始累計的絕對樣本索引」才能跨輪接起來。**這是整條鏈最容易出 bug 的一點** —— 索引一錯，RR 會變成一個看起來合理但完全錯誤的數字，而且不會報錯。
- 絕對索引上限 `0xFFFFFFFF`（約 497 天 @100 Hz）。**移植規格：至少要 32-bit**，16-bit 只撐 11 分鐘，量測途中翻掉會讓已存的拍相減出負值。

### 6.2 SQI 閘門

`sqiOk = false` 的那一輪：該顆谷**記一筆「SQI差」但不進池**，基準仍往前推進。

### 6.3 生理閘門

```
rrMinMs = 60000 / hrMax = 60000/240 = 250 ms
rrMaxMs = 60000 / hrMin = 60000/30  = 2000 ms
rr < 250  → 剔除，且**基準不推進**（advance = false）
rr > 2000 → 剔除，基準照常推進（resync）
```

**短側不推進基準**是刻意的：過短多半是偽谷／多抓，若推進基準會把下一段真間期切成假短 NN、灌爆 RMSSD。長側多半是真的漏拍，不推進會連環量爆、整段被砍。

### 6.4 誤拍過濾（±40%）

```
med = median(最近 9 筆 RR)        // 含 search-back 補回的拍；不足 3 拍 → 全收
接受條件：|rr − med| / med <= 0.40
不接受 → 剔除「誤拍>40%」；且 rr < med 時基準不推進
```

- 2026-07 由 30% 放寬到 40%：以「近 9 拍當前節律」為主要基準，只擋明顯離群，中等真變異留下。漏拍改由 search-back 回補，clean 的全域離群降級為對照開關。

### 6.5 心率（現行）

```
take   = min(rr.length, 6)
med    = median(最後 take 筆 RR)
bpm    = 60000 / med
不足 2 拍 → null（由呼叫端凍結）
```

- **為什麼用「拍數」而不是「時間窗」**：時間窗版會在 SQI 差的空窗期整段滑過去 → 掉 null。拍數版只要序列有 2 拍就一定算得出。
- **陷阱**：`bpm` 吃的是 `_rr`（**未過 `clean()`** 的原始序列），而 `mean_hr`（§7.2）吃的是 clean 後的 NN。兩者不是同一個東西 —— `bpm` 是「最近約 5 秒」，`mean_hr` 是「整個視窗的平均」。欄位層面的說明見 [VITALS_FIELDS.zh-TW.md §1](../docs/VITALS_FIELDS.zh-TW.md)。
- **實作**：`k2_beatseries.dart` → `hrRecent(6)`
- 前兩代心率算法已退場／降級，見[歷史文件 §6](vitals_metrics_history.md#6-心率)。

### 6.6 search-back 補漏拍（預設關）

```
觸發：rr > 1.6 × median(最近 9 筆乾淨拍)，且序列已有 >= 9 拍
做法：在 [prevAbs, curAbs] 這段用放寬門檻（relax = clamp(promRatio × 0.4, 0.05, 0.5) = 0.2）重找谷
     base = MA(seg, 200)、neg = base − seg、minDist = med × 0.5 × fs/1000
     只收 margin < k < n − margin，margin = med × 0.4 × fs/1000
驗證：插入後每段 RR 都要落在 [0.6, 1.5] × med，任一段不合 → **整批不採用**
上限：maxRecover = round(gap / med) − 1，抓到更多 = 誤抓（重搏切跡／波肩）→ 整批不採用
```

原則是**寧缺勿假**。補回的拍全部標 `recovered: true`。預設 `searchBackEnabled = false`。

---

## 階段 7｜HRV 時域

**輸入 ←** `rr[]` + 起訖谷絕對位置　**輸出 →** 8 個時域量

這是最常查的一節。

### 7.1 clean：MAD 穩健離群濾除（RR → NN）

```
拍數 < 4 → 全收
med    = median(rr)
MAD    = median( |rr − med| )
MAD <= 0 → 全收（資料幾乎全等，避免除不出門檻而全砍）
thresh = max( madK × madScale × MAD , minRelThresh × med )
       = max( 2.5 × 1.4826 × MAD , 0.5 × med )
保留 |rr − med| <= thresh
```

**1.4826 是什麼**：常態分佈下 MAD 與標準差的一致化常數（σ ≈ 1.4826 × MAD）。少了它，「2.5 × MAD」其實只等於約 1.69σ —— 連完全正常的資料都會被砍掉約 9%，而且**心跳越穩 → MAD 越小 → 門檻越緊 → 砍越兇**，自打嘴巴。

**下限 `0.5 × med` 不可省**：RR 有 10 ms 量化，安靜時 MAD 只有 1~2 格，純 MAD 門檻會塌到 ±25 ms，把正常的心率漂移（收 30 秒時 RR 從 780 爬到 900）整段砍掉。0.5 的意思是「保留 [0.5×, 1.5×] 中位數以內的拍，超出才視為漏拍（約 2 倍）／切拍（約 0.5 倍）」。

- **副作用（下游關鍵）**：clean 會**壓縮**清單，被抽掉的地方左右兩筆的谷位置就對不上 → §7.4 的 RMSSD 自動略過那種跨洞相減。
- **暖機門檻**：乾淨拍 `pts.length + 1 < minBeatsForHrv (9)` → **整個 HRV 回 null**，連帶 §9 的 `pns_z`/`sns_z`/`ans_time_domain` 與 `confidence_by_beats` 全部 null。
- **出處**：robust statistics 慣例
- **實作**：`k2_hrv_calculator.dart` → `clean`、`stats`

### 7.2 meanRr / mean_hr

```
meanRr = Σ NN / N          （ms，N = 間距數）
mean_hr = 60000 / meanRr   （bpm）
```

- **陷阱**：`60000 / mean(NN)` **不等於** `mean(60000 / NN)`（Jensen 不等式）。我們用的是前者。
- 與 §6.5 的 `bpm` 是兩個東西。

### 7.3 SDNN

```
SDNN = sqrt( Σ(NN − meanRr)² / (N − 1) )     （ms）
```

- **樣本標準差（N−1）**，不是母體。這個選擇要與 §8.3 的歸一化同源，否則 `VLF+LF+HF` 對不上 `SDNN²`。
- 反映**整體變異**，包含慢成分 → 視窗越短系統性越低（10 秒實測偏 18%）。
- **出處**：Task Force 1996

### 7.4 RMSSD / ln_rmssd

```
只累加「時間相鄰對」：pts[i].startAbs == pts[i−1].endAbs
RMSSD = sqrt( Σ_相鄰對 (NN_i − NN_{i−1})² / pairs )    （ms）
pairs = 0 → RMSSD = 0
ln_rmssd = ln(RMSSD)                                   （RMSSD <= 0 → null）
```

- **「只累加時間相鄰對」是本節最重要的實作細節**：被 §7.1 剔除、或被 SQI 擋掉而產生的斷點**不得跨接**。跨洞相減會把兩段不連續的時間硬當成相鄰拍，RMSSD 直接虛高。
- 透明化欄位：`pairs`（實際用到的連續對數）與 `totalPairs`（全部相鄰對），兩者差值 = 被打出來的洞數。
- **取 ln 的理由**：RMSSD 是對數常態分佈，取 ln 之後才適合做線性運算與比較。
- **出處**：Task Force 1996

### 7.5 pNN50

```
nn50  = #{ i : 時間相鄰 且 |NN_i − NN_{i−1}| > 50 ms }
pNN50 = nn50 / pairs × 100                （%）
```

- 門檻是**絕對 50 ms**，不是相對比例。副交感（迷走）指標，與 RMSSD 同一組相鄰對、同一個分母。
- **出處**：Task Force 1996

### 7.6 SD1 / SD2（Poincaré）

```
SD1 = sqrt(0.5) × RMSSD = RMSSD / sqrt(2)
SD2 = sqrt( 2·SDNN² − SD1² )        // 2·SDNN² − SD1² <= 0 時回 0
```

- **⚠️ SD1 = RMSSD/√2 是恆等式**，不是獨立資訊。這件事在 §9.1 會再咬一次。
- SD2 跟著 SDNN 走 → 同樣反映慢成分 → 短視窗一樣偏（10 秒實測偏 22%）。

### 7.7 hrvScore

```
hrvScore = clamp( ln(RMSSD) × 20 , 0 , 150 )      （RMSSD <= 0 → 0）
```

- **自訂刻度，不是文獻指標**，只供「跟自己比」。出處：Elite HRV 風格。
- 上限原本是 100，實測會撞到（深慢呼吸下 RMSSD 真的量得到 130~230 ms，分數卡在 100 分不出「很好」與「極高」），放寬到 150（對應 RMSSD 約 1808 ms，等於不再設限）。
- **⚠️ 超過 100 時不再是「滿分 100」的語意**，呈現層若有進度條要自己處理溢出。

### 7.8 ectopics（疑似早搏）—— 只標記，不移除

簽章是「短 → 代償長 → 回歸」：

```
四拍都要時間相鄰
M    = median( NN[lo..hi) )                    // 局部中位數，window = 10
dabs = { |NN_j − NN_{j−1}| : 時間相鄰 }        // 逐拍差樣本，不足 3 筆 → 跳過
thr  = median(dabs) + ectopicK × MAD(dabs)     // ectopicK = 4.0
判定 = (d1 < −thr) 且 (d2 > thr)
       且 |NN_{i−1} − M| <= 0.20·M 且 |NN_{i+2} − M| <= 0.20·M
```

- **為什麼用自適應門檻而不是固定百分比**：高 HRV 的人門檻自動放寬（不誤剔真正的呼吸性竇性心律不整，**不製造假雪茄**）；心跳加速是持續變短不回頭 → 不觸發。
- **A 階段只標記、不從池移除** → 不影響任何 HRV 數字。
- **實作**：`k2_hrv_calculator.dart` → `ectopics`

### 7.9 時域小結

| 量 | 公式 | 單位 | 最少拍 | 10 秒 |
|---|---|---|---|---|
| `mean_hr` | `60000 / mean(NN)` | bpm | 9 | ✓ 1% |
| `sdnn` | `sqrt(Σ(NN−mean)²/(N−1))` | ms | 9 | △ 18% |
| `rmssd` | `sqrt(ΣΔNN²/pairs)` 只相鄰 | ms | 9 | ✓ 9% |
| `ln_rmssd` | `ln(RMSSD)` | ln(ms) | 9 | ✓ 2% |
| pNN50 | `nn50/pairs×100` | % | 9 | △ |
| SD1 | `RMSSD/√2` | ms | 9 | ✓ 9% |
| SD2 | `√(2SDNN²−SD1²)` | ms | 9 | △ 22% |
| `hrvScore` | `clamp(ln(RMSSD)×20,0,150)` | 分 | 9 | ✓ |

**規律：指標反映的東西越慢，就越需要長視窗。** `rmssd`/`sd1`/`pNN50` 看逐拍之間的快速變化，10 秒完全夠；`sdnn`/`sd2` 看幾十秒級的擺盪，10 秒就不夠。這條規律在 §8 會走到極端。

---

## 階段 8｜HRV 頻域（Lomb-Scargle）

**輸入 ←** NN（不等間隔）　**輸出 →** `vlf` `lf` `hf`、`lfNu` `hfNu`、`lf_hf`、可信度證據

### 8.1 為什麼不是 FFT

RR 序列本來就**不等間隔**（每一拍的時間戳由心跳決定），而且 SQI 差與誤拍過濾會在序列上留下**洞**。FFT 兩個前提都不成立。

Lomb-Scargle 是為這種資料設計的：它直接對每個頻率做最小平方擬合，不需要重取樣、不需要內插，洞多洞少都能算（只是洞越多估計越差）。

完整理由見 [VITALS_FIELDS.zh-TW.md 附錄 A](../docs/VITALS_FIELDS.zh-TW.md)。

### 8.2 週期圖

```
前置：拍數 < 8 → null
時間軸：t_i = pts[i].endAbs / fs − t0，t0 = pts.first.endAbs / fs
        （每一筆 NN 掛在它「終谷」發生的時刻上；以第一筆為原點讓三角函數精度較好）
span   = (pts.last.endAbs − pts.first.startAbs) / fs        // span <= 0 → null
去均值：dx_i = NN_i − mean(NN)                              // Lomb-Scargle 的前提
變異數：variance = Σ dx² / (N − 1)                          // variance <= 0 → null

單頻功率（先解出時間位移 τ 讓 cos/sin 兩項正交，再各自最小平方擬合）：
    tan(2ωτ) = Σ sin(2ωt) / Σ cos(2ωt)
    A = Σ dx·cos(ω(t−τ))、B = Σ dx·sin(ω(t−τ))
    C = Σ cos²(ω(t−τ))、D = Σ sin²(ω(t−τ))
    P(f) = ½ · ( A²/C + B²/D )              // C 或 D 塌到 0（取樣點落在節點上）→ 不計
```

- **出處**：Lomb 1976 / Scargle 1982
- 掃描格點：`f = 0.003, 0.005, … , 0.40`，**固定格距 `df = 0.002 Hz`**
- **為什麼 df 是固定值而不是 1/T**：兩種窗長要用同一個格點才能公平比較。用 1/T 的話長窗天生格子多，比的就不只是窗長了。
- **實作**：`k2_vitals_metrics.dart` → `spectrum`、`_lombAt`

### 8.3 歸一化：讓 Σ(P·df) = 變異數

```
rawIntegral = Σ P(f) · df                    // <= 0 → null
k           = variance / rawIntegral
band(lo,hi) = k · Σ_{lo <= f < hi} P(f) · df
```

這一步是「為什麼我們的 ms² 能對帳」的關鍵：歸一化之後 **VLF + LF + HF ≈ SDNN²**（Parseval），數字可以直接拿去跟畫面上的 SDNN 比對。它也讓不同窗長的功率值落在同一個尺度上（否則長窗的絕對值天生比較大，比出來的差異一半是尺度造成的）。

### 8.4 頻帶

| 頻帶 | 範圍 (Hz) | JSON key | 生理意義 |
|---|---|---|---|
| VLF | 0.003 ~ 0.04 | `vlf_ms2` | **30 秒窗完全測不到**，算出來只是讓總功率合得起來 |
| LF | 0.04 ~ 0.15 | `lf_ms2` / `lf` | 壓力反射（Mayer wave）為主，交感副交感混合 |
| HF | 0.15 ~ 0.40 | `hf_ms2` / `hf` | 呼吸性竇性心律不整（RSA），迷走神經主導 |

- **出處**：Task Force 1996

**兩套單位**：

```
lf_ms2 / hf_ms2 / vlf_ms2 = 我們的原始值（ms²）
lf / hf                   = ms² × 1.024e-3      // 整合方單位
```

換算的由來：他們的 `hrv.py freq_domain()` 是 `rr(秒) → CubicSpline 內插到 4 Hz → welch(fs=4, nfft=4096)`，然後 `lf = pxx[...].sum()` —— **直接加總 bin，沒乘 df**。所以 `df = 4/4096 = 0.0009766`，`他們 = 我們(ms²) ÷ 1e6 × (1/df) = 我們 × 1.024e-3`。

- **⚠️ 這是單位與正規化慣例的換算，不是重寫 Welch。** 兩個估計器（Welch vs Lomb-Scargle）對同一段訊號的估計本來就會有差（實測約 15%），這裡只保證數量級與語意一致。`lf_hf` 是比值，縮放約分掉，不受影響。

### 8.5 比值

```
lfNu = lf / (lf + hf) × 100        （%，分母**不含 VLF**）
hfNu = hf / (lf + hf) × 100
lf_hf = lf ÷ hf                    （hf = 0 → 0）
totalPower = vlf + lf + hf
```

### 8.6 可信度證據（不是生理量）

```
spanSeconds = (last.endAbs − first.startAbs) / fs        → window_sec
lfCycles    = span × 0.04                                → lf_cycles
hfCycles    = span × 0.15                                → hf_cycles
lfBins      = (0.15 − 0.04) × span                       // LF 跨越幾個解析格（Δf = 1/T）
lf_reliable = lfCycles >= minBandCycles (4.0)
hf_reliable = hfCycles >= minBandCycles (4.0)
```

**門檻由「需要多久」決定，不可以拿手上的資料去反推。** 一個頻帶要估得準，至少要在它**最低的那個頻率**上看到 4 個完整週期 —— 低於這個數，週期圖在該頻帶只剩兩三個獨立自由度，估計值的變異數會跟估計值本身同一個量級。4 是工程判斷，但它是**從頻率導出的**。

| 頻帶 | 下緣 | 一個週期 | 需要 4 圈 | 國際標準 |
|---|---|---|---|---|
| **LF** | 0.04 Hz | 25 秒 | **100 秒** | Task Force 1996 要求 **300 秒** |
| **HF** | 0.15 Hz | 6.7 秒 | **26.7 秒** | — |

產品的 30 秒視窗實際跨度約 27~29 秒：**HF 剛好在線上**（偶爾落到 false，那不是 bug），**LF 只有 1.1~1.2 圈，一定是 false**。

### 8.7 ⚠️ 10 秒的頻域是壞的

頻率解析度 `Δf = 1/T`。T = 10 秒 → Δf = 0.1 Hz，而整條 LF 頻帶只有 0.11 Hz 寬 → **塌成一格，且與「0 Hz（趨勢）」分不開**。

實測（同一份 30 秒快照，10 秒視窗每 2 秒滑一次，工具見附錄 B）：

```
LF     35 ~ 414 ms²     12 倍
HF    232 ~ 1111 ms²     4.8 倍
LF/HF 0.05 ~ 0.55        11 倍
```

同一個人、同一次量測、手指沒離開，只是起點差 2 秒。相對地 `mean_hr` 全程都在 69 上下。

**數字照送，不藏。** 可信度靠 `lf_reliable` / `lf_cycles` 標明 —— 誠實靠標註，不靠藏數字。攝影機端（aquivio-vitals）同樣是 30 秒視窗，也照樣送，我們送 null 而他們送數字只會讓同一個欄位在兩台裝置上行為不一致。完整實測資料見 [VITALS_FIELDS.zh-TW.md 附錄 B](../docs/VITALS_FIELDS.zh-TW.md)。

---
---

# 第 3 部｜衍生分數與輸出

## 9.0 兩套尺度，先看這裡

**同一批 NN，兩套完全不同的尺度，而且兩套都會送出去。**

```
                 整合方尺度                    z / Baevsky 尺度
                 （0~100 分）                  （z-score / 開根號）
                 送給 aquivio                  我們自己判讀用
  ───────────────────────────────────────────────────────────────
  副交感          pns         66.9            pns_z          −0.35
  交感            （沒有這個欄位）              sns_z          +1.75
  自律平衡        ans         25.2            ans_time_domain +2.13
  壓力            stress      31.8            stress_baevsky   4.1
  可信度          confidence  good            confidence_by_beats  very rough
```

上面那一行是**同一次量測**的實際數字。`pns = 66.9` 與 `pns_z = −0.35` 講的是同一件事（這個人的副交感活性剛好落在常模平均），但 **−0.35 若被當成 0~100 讀，會變成「恢復力幾乎為零」—— 完全相反的結論。**

| | 整合方尺度 | z / Baevsky 尺度 |
|---|---|---|
| 來源 | 逐字對應 aquivio-vitals 的 `core.py::derived_scores()` | Kubios 風格的 z-score + Baevsky |
| 範圍 | 0~100，恆為正 | 以 0 為常模平均，**可為負** |
| 用途 | 與攝影機端數值可互換；下游 LLM prompt 的門檻是照這個尺度寫的 | 有常模依據，適合我們自己判讀 |
| 性質 | 他們自己標明「heuristic (consumer-device style), not clinical」 | 常模常數是**文獻上健康成年人的近似值，不是 Kubios 的資料庫** → 方向可信，絕對值不會跟 Kubios 對齊 |

**整合方那四個分數沒有引入任何新資訊**，只是既有指標的重新縮放：

```
pns      就是 RMSSD
ans      就是 LF/HF
stress   就是前兩者的線性組合
activity 就是心率
```

下面四組成對指標，**時域版一律先講**。這裡講過的混用風險，後面不再重複。

### 四個整合方分數都會「撞邊」

`pns` / `ans` / `stress` / `activity` 全是 `clamp(…, 0, 1) × 100` 算出來的。撞到量表端點時畫面上會出現 `0.0` 或 `100.0` —— **看起來像極端生理讀數，其實是「這個值已經沒有解析度」**。

| 分數 | 撞底 | 撞頂 |
|---|---|---|
| `pns` | RMSSD ≤ 10 ms | RMSSD ≥ 80 ms |
| `ans` | LF/HF ≤ 0.25 | LF/HF ≥ 4.0 |
| `activity` | mean_hr ≤ 60 bpm | mean_hr ≥ 140 bpm |
| `stress` | 自己不會撞（但 `ans` 撞底時它的 40% 恆為 0） | 同左 |

驗證 UI 會在撞邊的值後面標 `⤓`（底）/ `⤒`（頂）並灰化，底下附一行說明是哪個輸入越界（`k2_page.dart` → `_railMark`）。**送出去的 JSON 沒有這個資訊** —— 下游只會看到 `0` 或 `100`。

### 常模常數（z 尺度那組全部的門檻）

```
z(v, mean, sd) = (v − mean) / sd

            平均      SD      單位
meanRr      926.0     90.0    ms
rmssd        42.0     15.0    ms
sd1          29.7     11.0    ms   （= RMSSD/√2）
meanHr       64.8      6.5    bpm
√SI          10.0      3.0    —
sd2         100.0     30.0    ms
```

---

## 9.1 PNS（副交感）

> ⚠️ 兩個值都會送出，尺度不同，不可互比。

### 9.1.a 時域 z 版　`pns_z`

- **一句話**：副交感（休息與消化）活性，Kubios 風格的 PNS index
- **公式**：`pns_z = [ z(meanRr) + z(RMSSD) + z(SD1) ] / 3`
- **輸入**：§7.2 meanRr、§7.4 RMSSD、§7.6 SD1
- **單位與典型值**：z-score；0 = 常模平均，可為負
- **出處**：Kubios 風格（常模是文獻近似值，非 Kubios 資料庫）
- **陷阱**：**SD1 = RMSSD/√2 是恆等式**，所以這三項其實只有兩份獨立資訊 —— SD1 那一項等於把 RMSSD 加權兩次。這是 Kubios 自己的定義，照做即可，但別誤以為它是三個獨立證據
- **實作**：`k2_vitals_metrics.dart` → `pns`

### 9.1.b 整合方 0~100 版　`pns`

- **一句話**：整合方畫面上叫 **Recovery**，就是 RMSSD 的對數縮放
- **公式**：`pns = clamp( (log₁₀RMSSD − 1.0) / (log₁₀80 − 1.0) , 0, 1 ) × 100`
- **輸入**：§7.4 RMSSD（null 或 ≤ 0 → null）
- **單位與典型值**：0~100 分；錨點 `RMSSD 10 ms → 0 分`、`80 ms → 100 分`
- **出處**：aquivio-vitals `core.py::derived_scores()`
- **陷阱**：超出兩端直接夾住 —— `RMSSD ≤ 10 ms → 0.0`、`RMSSD ≥ 80 ms → 100.0`。高變異的人（深慢呼吸）會卡在 100
- **實作**：`k2_vitals_metrics.dart` → `pnsScore`

### 9.1.c 並排

| | `pns_z`（時域 z） | `pns`（整合方 0~100） |
|---|---|---|
| 公式 | 三項 z-score 平均 | RMSSD 的對數縮放 |
| 尺度 | 0 = 常模平均，可為負 | 0~100，恆為正 |
| 典型值 | −0.35 | 66.9 |
| 需要多長視窗 | 9 拍（10 秒可用，實測誤差 6%） | 同左 |
| 出處 | Kubios 風格 | aquivio core.py |
| 送給誰 | 我們自己 | 整合方 |

### 9.1.d 該看哪一個

自己判讀看 `pns_z`（有常模依據）；對整合方報表、跟攝影機端比較看 `pns`。**兩者 10 秒都可用。**

---

## 9.2 ANS（自律神經平衡）

> ⚠️ 兩個值都會送出，**定義完全不同的兩條路徑**，不可互比、不可存進同一張表。

### 9.2.a 時域版　`ans_time_domain`

- **一句話**：交感減副交感，全時域，不碰 LF
- **公式**：`ans_time_domain = sns_z − pns_z`
- **輸入**：§9.4 sns_z、§9.1.a pns_z
- **單位與典型值**：z-score 差；**正值偏交感（緊張）、負值偏副交感（放鬆）**
- **出處**：自訂（Kubios 式成分的差）
- **陷阱**：與整合方的 `ans` 數值不可比較。它的價值在於 **10~30 秒就算得出來，而 LF/HF 不行**（實測 10 秒 2.03 vs 整段 2.13，誤差 5%）
- **實作**：`k2_vitals_metrics.dart` → `ansTimeDomain`

### 9.2.b 整合方 0~100 版　`ans`

- **一句話**：就是 LF/HF 取 log2 後縮放
- **公式**：`ans = clamp( 0.5 + log₂(LF/HF) / 4 , 0, 1 ) × 100`
- **輸入**：§8.5 `lf_hf`（null 或 ≤ 0 → null）
- **單位與典型值**：0~100；錨點 `LF/HF 0.25 → 0`、`1.0 → 50`（中性）、`4.0 → 100`。**越大越偏交感**
- **出處**：aquivio-vitals `core.py::derived_scores()`
- **陷阱**：**短視窗下這個數字會撞夾制邊界。** LF 被低估 → LF/HF 掉到 0.25 以下 → 一律夾成 0，連偏多少都看不出來。實測 10 秒 0.3 vs 整段 25.2（**77 倍**），滑動視窗中出現過剛好 `0.0`
- **陷阱**：**看到 `ans = 0.0` 先檢查 LF/HF 是不是只差一點就掉出量表。** 實測一次 30 秒量測 `LF/HF = 0.2285`（下緣是 0.25，只低 8%）就夾成 0.0 —— 下游會把它讀成「極度偏副交感」，但它其實是「這個數字已經沒有解析度」
- **實作**：`k2_vitals_metrics.dart` → `ansScore`

### 9.2.c 並排

| | `ans_time_domain`（時域） | `ans`（整合方，頻域） |
|---|---|---|
| 公式 | `sns_z − pns_z` | `clamp(0.5 + log₂(LF/HF)/4) × 100` |
| 尺度 | z-score 差，可為負 | 0~100 |
| 典型值（同一次量測） | **+2.13（偏交感）** | **25.2（偏副交感）** |
| 需要多長視窗 | 9 拍 → **10 秒可用** | LF 要 100 秒 → **10 秒、30 秒都不可用** |
| 出處 | 自訂 | aquivio core.py |
| 送給誰 | 我們自己 | 整合方 |

**注意典型值那一列：同一份資料，兩者講相反的故事。** 這不是 bug —— 它們量的不是同一件事，而且 `ans` 在 30 秒視窗下本來就不可信（`lf_reliable = false`）。**不要試圖用映射讓兩者數字接近**，那等於把其中一個的判讀扭成另一個。

### 9.2.d 該看哪一個

短視窗（< 100 秒）只能看 `ans_time_domain`。要用它填整合方的 `ans` 欄位必須先跟整合方講清楚定義換了，而且下游門檻（`deepseek.ts` 的 `LF/HF > 1.5` 之類）要重新校準。

---

## 9.3 STRESS（壓力）

> ⚠️ 兩個值都會送出，**這兩個根本不是同一個指標**（一個是 Baevsky 壓力指數，一個是前面兩個分數的加權混合）。

### 9.3.a Baevsky 版　`stress_baevsky`

- **一句話**：Baevsky 壓力指數（SI）開根號，**純時域**
- **公式**：
  ```
  前置：RR 數 < 5 → null
  直方圖 bin = 50 ms，以 0 為原點：格號 = floor(RR / 50)
  Mo    = (眾數格號 + 0.5) × 50 / 1000        （秒，該格中心）
  AMo   = 眾數格的筆數 / 總筆數 × 100          （%）
  MxDMn = (max RR − min RR) / 1000            （秒；= 0 → null）
  SI    = AMo / (2 × Mo × MxDMn)
  stress_baevsky = sqrt(SI)                    // Kubios 慣例，取平方根讓分布接近常態
  ```
- **輸入**：§7.1 NN（純值）
- **單位與典型值**：無單位；**靜息常態約 7~12**
- **出處**：Baevsky 壓力指數；開根號是 Kubios 慣例
- **陷阱**：**短視窗下這個數字很薄**，而且不是普通的「樣本少所以有雜訊」—— SI 剛好由兩個對小樣本最敏感的統計量組成：`AMo` 是「最高那格佔多少」（35 個樣本分到 8~10 格，哪格最高幾乎隨機），`MxDMn` 是全距（只由兩個極端值決定，多收一拍就可能整個變）
- **實作**：`k2_vitals_metrics.dart` → `stressIndex`
- **直覺**：心跳被壓得又快又規律 → 直方圖又高又窄 → AMo 大、MxDMn 小 → SI 衝高

### 9.3.b 整合方 0~100 版　`stress`

- **一句話**：`pns` 與 `ans` 的加權混合，**不是 Baevsky 壓力指數**
- **公式**：`stress = clamp( 0.6 × (100 − pns)/100 + 0.4 × ans/100 , 0, 1 ) × 100`
- **輸入**：§9.1.b `pns`、§9.2.b `ans`（**任一為 null 就 null**，與他們的 `if pns and ans` 一致）
- **單位與典型值**：0~100
- **出處**：aquivio-vitals `core.py::derived_scores()`
- **陷阱**：**它有 40% 來自 `ans`，所以 `ans` 在短視窗垮掉時它跟著垮**（實測 10 秒 19.4 vs 整段 31.8）。要在短視窗用，只能把權重改成全部吃 `pns`
- **陷阱**：它自己**不會撞夾制邊界**（`0.6x + 0.4y` 的加權本來就落在 0~1），但 `ans` 撞底時它的那 40% 恆為 0。實測畫面 `pns 93.7` + `ans 0.0` → `stress 3.8`，那個 3.8 完全由 `pns` 決定
- **實作**：`k2_vitals_metrics.dart` → `stressScore`

### 9.3.c 並排

| | `stress_baevsky` | `stress`（整合方） |
|---|---|---|
| 公式 | `√(AMo/(2·Mo·MxDMn))` | `0.6(100−pns)/100 + 0.4·ans/100` |
| 尺度 | 靜息約 7~12 | 0~100 |
| 典型值 | 4.1 | 31.8 |
| 需要多長視窗 | 5 拍（但 30 秒下就很薄） | 受 `ans` 拖累 → **短視窗不可用** |
| 出處 | Baevsky / Kubios | aquivio core.py |
| 送給誰 | 我們自己 | 整合方 |

### 9.3.d 該看哪一個

兩個都要保留：`stress_baevsky` 是真正的壓力指數但統計很薄；`stress` 是下游 prompt 認得的尺度但短視窗會壞。**短視窗要給壓力欄位，得先改 `stress` 的公式。**

---

## 9.4 SNS（交感，z 尺度）　`sns_z`

- **一句話**：交感活性指數，**全時域，不碰 LF**
- **公式**：
  ```
  zHr  = z(meanHr; 64.8, 6.5)
  zSd2 = −z(SD2; 100, 30)                    // 取負號：SD2 越小越偏交感
  si 有值 → sns_z = [ zHr + z(√SI; 10, 3) + zSd2 ] / 3
  si 為 null → sns_z = [ zHr + zSd2 ] / 2
  ```
- **輸入**：§7.2 meanHr、§9.3.a √SI、§7.6 SD2
- **單位**：z-score
- **出處**：Kubios 風格
- **陷阱**：整合方介面**沒有這個欄位**，但 §9.2.a 的 `ans_time_domain` 由它導出
- **實作**：`k2_vitals_metrics.dart` → `sns`

## 9.5 ACTIVITY　`activity`

- **一句話**：心率超出靜息基準多少
- **公式**：`activity = clamp( (meanHr − 60) / 80 , 0, 1 ) × 100`
- **輸入**：§7.2 `mean_hr`
- **單位**：0~100
- **出處**：aquivio-vitals `core.py::derived_scores()`
- **陷阱**：沒有別的資訊，就是心率換個尺度
- **陷阱**：量表是 `60 bpm → 0 分`、`140 bpm → 100 分`，**靜息心率低於 60 的人這一欄恆為 0.0**（實測 `mean_hr = 59` → `activity = 0.0`）。那不是壞掉，是夾制的底 —— 這個量表只表達「超出靜息多少」
- **驗證 UI 另外顯示一個 50 bpm 起算的版本**（`活動量(50起算)`，**不送出**）。固定 60 bpm 當靜息對心率 50 幾的人（坐著量更常見）等於整欄報廢；50 起算至少分得出高低。⚠️ 那只是換基準，不是更好的指標 —— 真正對的做法是用**這個人自己的**靜息心率當起點，但一次性量測拿不到那個基準。**要改送出去的 `activity` 必須先跟整合方談**，那個公式是逐字對應他們的 `core.py`，改了就不能互換
- **實作**：`k2_vitals_metrics.dart` → `activityScore`

## 9.6 SNR　`snr_db`

> ⚠️ **這是全文唯一打破單向依賴的指標** —— 它的輸入是階段 0 的 IR 波形，不是 NN 序列。它也是全鏈**唯一真的用 FFT** 的地方（波形是等間隔取樣，可以用；NN 序列不行，見 §8.1）。

- **一句話**：脈搏諧波能量 ÷ 其餘頻帶能量
- **公式**：
  ```
  前置：bpm 為 null 或 <= 0 → null；樣本數 < fs × 5（500 筆 / 5 秒）→ null
  f0   = bpm / 60
  去趨勢 + Hann 窗：re_i = (ir_i − mean(ir)) × (0.5 − 0.5·cos(2πi/(n−1)))
  FFT size = nextPow2(n)（零填補），binHz = fs / size
  對每個 f = k · binHz：
      f < 0.5 或 f > 4.0                      → 跳過（既不算訊號也不算雜訊）
      |f − f0| <= 0.2 或 |f − 2·f0| <= 0.2    → sig   += re² + im²
      其餘                                     → noise += re² + im²
  snr_db = 10 · log₁₀(sig / noise)            // sig <= 0 或 noise <= 0 → null
  ```
- **輸入**：§0.1 IR 波形、§6.5 bpm（定位基頻）
- **單位**：dB
- **出處**：rPPG 領域常見定義；頻帶常數逐字對應 aquivio-vitals `core.py`（`SNR_BAND_LO_HZ, SNR_BAND_HI_HZ = 0.5, 4.0`、`SNR_PEAK_HALFWIDTH_HZ = 0.2`）
- **為什麼上界是 4.0 而不是 5.0**：心率 > 120 bpm 時二次諧波會超過 4 Hz，若「不算訊號又不算雜訊」，比值會被系統性拉高。照抄他們的處理
- **陷阱**：**這不是 SQI。** SQI 的 spike 是時域的「最大起伏 ÷ 典型起伏」，這裡是頻域的能量比，**兩者不能互相換算**
- **陷阱**：`snrDb` 的 docstring 還寫著舊的頻帶（±0.1 Hz / 0.5~5 Hz），與實作不符 —— 以本節與程式碼常數為準，舊值的來龍去脈見[歷史文件 §9](vitals_metrics_history.md#9-衍生分數)
- **實作**：`k2_vitals_metrics.dart` → `snrDb`、`_fft`

---

## 9.7 CONFIDENCE（可信度）

> ⚠️ 兩個值都會送出，判斷依據完全不同。這不是生理指標，是工程指標：「這次的數字該信幾分」。

### 9.7.a 拍數版　`confidence_by_beats`

- **一句話**：看拍數 + SQI + 沉澱期
- **公式**：
  ```
  settling = true            → null
  beats < 9（minBeatsForHrv）→ null
  beats >= 20 且 sqiOk       → 'good'
  beats >= 13                → 'rough'
  其餘                        → 'very rough'
  ```
- **輸入**：§7.1 beats、§5.1 sqiOk、§1.2 settling
- **出處**：自訂
- **陷阱**：門檻**必須在自己的視窗上限內可達**。舊值 `good >= 25` 沒驗證這件事：28 秒視窗可達拍數是 `28 × bpm / 60`，25 拍需要心率 ≥ 54 bpm，低於這個數的人（運動員、深慢呼吸時）**永遠拿不到 good**。現值 20 / 13 對應心率 43 / 28 bpm
- **實作**：`k2_vitals_metrics.dart` → `confidence`

### 9.7.b SNR 版　`confidence` ＝ `confidence_video`

- **一句話**：**只看 SNR，與拍數完全無關**
- **公式**：`snr_db >= 6.0 → 'good'`、`>= 1.0 → 'rough'`、其餘 `'very rough'`（null → null）
- **輸入**：§9.6 `snr_db`
- **出處**：逐字照抄 aquivio-vitals 的 `hrv_confidence()`。他們選 6 dB 的理由寫在 `core.py` 註解裡：低於約 6 dB 時 RMSSD 的雜訊底線會超過典型靜息 HRV（實測 1.5 dB 時真值 19 ms 會膨脹到約 60 ms）
- **陷阱**：**短視窗會誤報。** 它不看拍數，所以 10 秒的量測只要波形乾淨就照樣回 `good`
- **為什麼 `confidence` 送的是這一版**：`confidence` 是對方 `VitalsResult` 宣告的欄位，名字不能動，而整條軟體鏈（station → Strapi → LLM prompt）的門檻都是照 rPPG 那台機器的尺度校準的。`confidence_video` 是同一個值的別名，名字講明了出處（「video」指最早期用來測試的攝影機機台）。詳見 [SERVER_GUIDE.zh-TW.md 的 `confidence_video` 一節](../docs/SERVER_GUIDE.zh-TW.md)
- **實作**：`k2_vitals_metrics.dart` → `confidenceFromSnr`

### 9.7.c 並排

| | `confidence_by_beats` | `confidence` / `confidence_video` |
|---|---|---|
| 依據 | 拍數 + SQI + 沉澱期 | 只有 SNR |
| 門檻 | `>= 20 good`、`>= 13 rough` | `>= 6 dB good`、`>= 1 dB rough` |
| 10 秒量測 | `very rough`（正確） | **`good`（誤導）** |
| 出處 | 自訂 | aquivio `hrv_confidence()` |
| 送給誰 | 我們自己 | 整合方 |

### 9.7.d 該看哪一個

判斷「這筆能不能用」看 `confidence_by_beats`。`confidence` 存在的目的是讓整合方不必為了換感測器而改判斷邏輯 —— **但「大致相當」不是「等價」**，他們的門檻是對 rPPG 校準的，我們是接觸式 PPG，沒有人驗證過同一個人在兩台機器上會落在同一級。

---

## 階段 10｜輸出契約（28 個 key）

`GET /vitals` 的 `strapi` 區塊 = `VitalsMetrics.toStrapiJson()`。

**宣告的 12 個欄位一個都不會缺**，沒有值就是 `null` —— 對方把 `activity` 之類宣告成 `number | null` 而非 optional，少了 key 那側會拿到 `undefined` 而不是 `null`，型別就對不上。

### 10.1 VitalsResult 宣告的 12 個

| key | 來自 | 單位 | null 條件 | 尺度族 |
|---|---|---|---|---|
| `mean_hr` | §7.2 | bpm | 拍數 < 9 | 物理 |
| `sdnn` | §7.3 | ms | 拍數 < 9 | 物理 |
| `rmssd` | §7.4 | ms | 拍數 < 9 | 物理 |
| `ln_rmssd` | §7.4 | ln(ms) | RMSSD ≤ 0 | 物理 |
| `lf_hf` | §8.5 | 無單位 | 拍數 < 8 | 物理 |
| `sqi` | §5.1 | 1 / 0 | 不會 null | bool |
| `snr_db` | §9.6 | dB | 波形 < 5 秒 | 物理 |
| `confidence` | §9.7.b | 字串 | `snr_db` 為 null | 等級 |
| `pns` | §9.1.b | 0~100 | RMSSD ≤ 0 | 整合方 |
| `ans` | §9.2.b | 0~100 | `lf_hf` ≤ 0 | 整合方 |
| `stress` | §9.3.b | 0~100 | `pns` 或 `ans` 為 null | 整合方 |
| `activity` | §9.5 | 0~100 | `mean_hr` 為 null | 整合方 |

### 10.2 頻譜與可信度的 11 個額外欄位

| key | 來自 | 單位 | null 條件 | 尺度族 |
|---|---|---|---|---|
| `lf` | §8.4 | 整合方單位 | 拍數 < 8 | 物理 |
| `hf` | §8.4 | 整合方單位 | 拍數 < 8 | 物理 |
| `lf_ms2` | §8.4 | ms² | 拍數 < 8 | 物理 |
| `hf_ms2` | §8.4 | ms² | 拍數 < 8 | 物理 |
| `vlf_ms2` | §8.4 | ms² | 拍數 < 8 | 物理 |
| `confidence_video` | §9.7.b | 字串 | 同 `confidence`（同值別名） | 等級 |
| `lf_reliable` | §8.6 | bool | 無（頻譜為 null → `false`） | bool |
| `hf_reliable` | §8.6 | bool | 無（頻譜為 null → `false`） | bool |
| `lf_cycles` | §8.6 | 圈 | 拍數 < 8 | 物理 |
| `hf_cycles` | §8.6 | 圈 | 拍數 < 8 | 物理 |
| `window_sec` | §8.6 | 秒 | 拍數 < 8 | 物理 |

### 10.3 我們自己判讀的 5 個

| key | 來自 | 單位 | null 條件 | 尺度族 |
|---|---|---|---|---|
| `pns_z` | §9.1.a | z | 拍數 < 9 | z |
| `sns_z` | §9.4 | z | 拍數 < 9 | z |
| `ans_time_domain` | §9.2.a | z 差 | 拍數 < 9 | z |
| `stress_baevsky` | §9.3.a | 約 7~12 | RR 數 < 5 | Baevsky |
| `confidence_by_beats` | §9.7.a | 字串 | 沉澱期或拍數 < 9 | 等級 |

### 10.4 命名後綴的意義

```
_z            z-score（0 = 常模平均，可能是負的）
_baevsky      Baevsky 壓力指數的平方根（靜息常態約 7~12）
_time_domain  算法出處：時域
_by_beats     算法出處：看拍數
_ms2          我們的原始單位 ms²（沒有這個後綴的 lf / hf 是整合方單位）
_video        照最早期那台 rPPG 攝影機機台的尺度算的
```

不加 `_max30102` 後綴 —— 整個服務本來就是 MAX30102，標了是贅字。

---
---

# 附錄

## 附錄 A：依賴圖

```
階段 0  原始 RED/IR (counts)
   │
   ├──────────────────────────────────────────────┐
   ▼                                              │
階段 1  閘門（手指 / 沉澱 / 方向）                 │  ← 方向要用 4.2 的 R
   ▼                                              │
階段 2  前處理（截尾 → baseline → 去趨勢 → 取負）   │
   ▼                                              │
階段 3  谷偵測 ──┬─→ 谷間距 → beatsOk             │
   │             │                                │
   │             └─→ 階段 5  SQI ──┐              │
   ▼                               │              │
階段 4  逐拍 AC/DC → R ─→ SpO2     │              │
   │        └───────────────────────────→ 方向判定（回到階段 1）
   ▼                               │
階段 6  NN 序列 ←──────────────────┘（SQI 是硬閘門）
   │        └─→ bpm
   ▼
階段 7  HRV 時域（clean → SDNN / RMSSD / pNN50 / SD1 / SD2 / hrvScore）
   │        │
   │        ├─→ 階段 9.1a pns_z ──┐
   │        ├─→ 階段 9.3a √SI ────┼─→ 9.4 sns_z ─→ 9.2a ans_time_domain
   │        ├─→ 階段 9.1b pns ────┼──────────────→ 9.3b stress
   │        └─→ 階段 9.5 activity │
   ▼                              │
階段 8  HRV 頻域（Lomb-Scargle → VLF/LF/HF → lf_hf）
            └─→ 9.2b ans ─────────┘

階段 9.6  snr_db ←═══════════════════ 階段 0 的 IR 波形（唯一的回頭邊）
            └─→ 9.7b confidence
```

## 附錄 B：10 秒的實測與怎麼重現

工具：`tools/lf_window_compare.dart`（驗證用，不屬交接核心，未進 git）

```
dart run tools/lf_window_compare.dart <快照.json> --slide
```

它拿同一份快照的 NN，切成不同長度的視窗重算 —— 同一個人、同一次量測、同一份程式碼，**唯一的變因是視窗長度**。

2026-09-29 的一份 27.9 秒快照（bpm 69.8）：

| 欄位 | 10 秒 | 整段 | 差 |
|---|---|---|---|
| `mean_hr` | 69.4 | 68.8 | 1% |
| `ln_rmssd` | 3.71 | 3.63 | 2% |
| `rmssd` | 41.0 | 37.7 | 9% |
| `pns` | 67.8 | 63.8 | 6% |
| `ans_time_domain` | 2.03 | 2.13 | 5% |
| `stress_baevsky` | 4.2 | 4.1 | 2% |
| `sdnn` | 33.3 | 28.1 | 18% |
| `hf_ms2` | 836.4 | 462.3 | 1.8 倍 |
| `lf_hf` | 0.25 | 0.50 | 2 倍 |
| `stress` | 19.4 | 31.8 | 1.6 倍 |
| **`ans`** | **0.3** | **25.2** | **77 倍** |

同一次量測裡 10 秒視窗每 2 秒滑一次：`lf` 35~414（12 倍）、`hf` 232~1111（4.8 倍）、`lf_hf` 0.05~0.55（11 倍）、`ans` 0.0~28.7。

**還要記得**：上面的「10 秒」是最好的情況 —— 切的是已經過了空轉期、沉澱期、方向判定之後的 NN。真實的「按下去 10 秒」還要再扣掉 §1.2 的 3.5~5.5 秒。

## 附錄 C：出處清單

| 代號 | 出處 | 涵蓋 | 類型 |
|---|---|---|---|
| CHEATSHEET | `MAX30102_CHEATSHEET.md §7.4` —— **在母專案 `ai_docs/bootloader/spec/`，本 repo 沒有** | §0.1 | 內部規格 |
| libdriver | [libdriver/max30102](https://github.com/libdriver/max30102) | §0.1 架構分工 | 第三方庫 |
| Maxim | Maxim 官方 `algorithm.cpp`（逐拍找谷、峰減基線） | §3.2、§4.1、§4.2 | 廠商參考碼 |
| SparkFun | SparkFun / Maxim 應用註記的二次擬合 | §4.3 | 廠商註記 |
| CAVEDU | [CAVEDU GitBook](https://cavedu.gitbook.io/cavedu/sheng-wu-yi-xue-cai-liao-bao/max30102-xinl-mai-bo-xue-yang-gan-ce-qi) | §4.4 EMA；已退場的整窗 RMS 與線性式 | 教學 |
| scipy | `scipy.signal.find_peaks(prominence=)` 概念 | §3.1 | 第三方庫（概念） |
| robust | robust statistics 的 MAD 慣例（σ ≈ 1.4826 × MAD） | §7.1 | 統計慣例 |
| TF1996 | Task Force 1996 HRV 標準 | §7.3、§7.4、§7.5、§8.4、§8.6 | 文獻 |
| Poincaré | Poincaré 圖標準關係式 | §7.6 | 文獻 |
| EliteHRV | Elite HRV 風格的分數刻度 | §7.7 | 消費性慣例 |
| Lomb/Scargle | Lomb 1976 / Scargle 1982 | §8.2 | 文獻 |
| Kubios | Kubios 的 PNS/SNS index 形式與 √SI 慣例 | §9.1.a、§9.3.a、§9.4 | 商業軟體慣例 |
| Baevsky | Baevsky 壓力指數 | §9.3.a | 文獻 |
| aquivio | aquivio-vitals `core.py::derived_scores()`、`hrv_confidence()`、`hrv.py freq_domain()`、他們的 `docs/VITALS.md` | §8.4 換算、§9.1.b、§9.2.b、§9.3.b、§9.5、§9.6、§9.7.b | 整合方原始碼 |
| 自訂 | 截尾滑動平均、SQI、方向判定、±40% 閘門、search-back、可用性門檻 | 散見 | 自訂強化 |

## 附錄 D：文件分工

| 文件 | 回答什麼 |
|---|---|
| [SERVER_GUIDE.zh-TW.md](../docs/SERVER_GUIDE.zh-TW.md) | **怎麼用**（API、部署、疑難排解） |
| [VITALS_FIELDS.zh-TW.md](../docs/VITALS_FIELDS.zh-TW.md) | **每個欄位對整合方意味什麼**（含交涉紀錄與實測附錄） |
| **本文** | **每個數字怎麼算出來的** |
| [vitals_metrics_history.md](vitals_metrics_history.md) | **曾經是什麼、為什麼換掉** |
| [k2_architecture.html](k2_architecture.html) | 交接核心的整體架構 |
| [serial_protocol.md](serial_protocol.md) | 封包與命令 |

## 附錄 E：待決事項

| 事項 | 現況 |
|---|---|
| `spo2Valid` 沒被採用（§4.3） | 拍不可信或值超出 70~100 時照樣輸出血氧。收緊會讓血氧更常 null |
| `sqi` 給不出連續值（§5.1） | `cv` 與 `keptCount` 只活在 `Max30102Sqi` 內部，要連續值得先改交接核心 |
| `snrDb` 的 docstring 與實作不符（§9.6） | 註解還寫舊頻帶 ±0.1 / 0.5~5 Hz |
| SQI 的 `spike` 用整窗單一最大值 | 改用高百分位可減少單點造成的反覆凍結，門檻要一併重新定標 |
| 短視窗（10 秒）模式 | `ans` / `stress` / `confidence` 要改來源才能用，需與整合方談定義與門檻 |
