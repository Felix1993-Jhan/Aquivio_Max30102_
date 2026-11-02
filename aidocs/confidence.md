# 可信度（`confidence`）

> 目前版本：server **0.0.0.8**（2026-11-02）
> 實作：[k2_vitals_metrics.dart](../lib/main_mode/max30102_K2/k2_vitals_metrics.dart) 的 `confidenceByPulse` / `cleanShare()` / `rrGaps()`、
> [k2_hrv_calculator.dart](../lib/main_mode/max30102_K2/k2_hrv_calculator.dart) 的 `classify()`
>
> 舊版規則：[old/confidence_v0.0.0.7.md](old/confidence_v0.0.0.7.md)（異常 ≤ 1 次，只有 good / very rough）

---

## 1. 現行規則

```
乾淨拍數 < 9（含手指離開、沉澱中）  →  very rough
乾淨比例 < 65%                      →  very rough
乾淨比例 < 80%，或這一輪 SQI 沒過     →  rough
其餘                                →  good
```

- 三級：`good` / `rough` / `very rough`。**不會是 `null`**。
- `confidence`、`confidence_video`、`confidence_by_beats` **三個欄位送同一個值**（0.0.0.7 起），對方讀哪一個都一樣。
- SQI 沒過最多給 `rough`：乾淨比例看的是整段，SQI 看的是「現在」（例如手指正在移開），兩個都好才是 `good`。

### 乾淨 RR 怎麼判

每一筆 RR 跟「自己前後各 4 筆，共 9 筆」的**中位數**比（`classify()`）：

| 分類 | 條件 | 進 HRV？ |
|---|---|---|
| 乾淨 | 與局部中位數相差 ±20% 以內 | ✅ |
| 漏拍 | 約是局部中位數的 2~4 倍（離整數倍 ±0.2 以內） | ❌ |
| 偽拍 | 其餘 | ❌ |

- 局部中位數取**所有**鄰居（含漏拍、偽拍）：中位數本身抗離群，9 筆裡要一半以上是壞的才會被帶偏；從第一拍就生效，不像舊的「近 9 拍 ±40%」要先有 3 拍基準。
- 序列兩端拿得到幾筆就用幾筆；最新那幾筆的「後面 4 筆」還沒出現，新拍進來時可能改判 → 比例會慢慢穩定。
- 生理閘門 250~2000 ms 在進序列前就擋掉了（`k2_beatseries.feed()`）。

### 乾淨比例怎麼算

```
乾淨比例 = 乾淨 RR 數 ÷ (乾淨 RR 數 + 空洞裡應有的間距數)
空洞裡應有的間距數 = max(1, round(空洞長度 ÷ 乾淨 RR 的中位數))
```

- 輸入是核心交出的乾淨 RR（`K2Compute.rrPoints`），漏拍、偽拍、SQI 差那輪、生理閘門擋掉的拍，在序列上各留下一個**空洞**（`rrPoints[i+1].startAbs ≠ rrPoints[i].endAbs`）。
- 空洞有多長就換算成幾個間距 —— 一個 5 秒的 SQI 差空洞與一個漏拍不會算成一樣（0.0.0.7 的「數空洞個數」做不到這件事）。
- 第一筆乾淨 RR 之前、最後一筆之後的不乾淨拍看不到。
- 範圍：server 是手指放上去到現在（最多 30 秒）的全部 RR；App 定長模式是 12 秒窗裡的 RR。

### 80% / 65% 這兩個門檻

整合方用 10/30 兩份站台錄音、逐拍原型 `scripts/max30102-beats.cjs` 分類訂的：

- 訊號好的段落乾淨 89~100%，RMSSD 與原型差 < 25%；
- 漂移 / 晃動的段落乾淨 45~65%，那些段落的 RMSSD 互相差到兩倍以上，不能用；
- 規格（老闆訂的）要求「70% 以下不可以是 good」，80% 留了餘裕。

---

## 2. 站台拿它做什麼

**攝影機流程**（`VitalsFlow.tsx` / `VitalsScan.tsx`）在呼叫推薦之前先看 `confidence`：

```ts
const reliable = !!result
    && result.confidence !== null
    && result.confidence !== 'very rough';
if (!reliable) return;   // 不去要推薦
```

| `confidence` | 站台行為 |
|---|---|
| `good` | 顯示結果並請求推薦 |
| `rough` | 請求推薦，畫面多一行「近似讀數」黃字 |
| `very rough` / `null` | **不請求推薦** |

**手指流程**（`useVitalsFingerScan.ts`，10/28 版）**不看** `confidence`，看的是 12 秒倒數：第一次收到 `sqiOk = true` 開始倒數、手指離開才重設，倒數到 0 那一刻拿**最新一份** `strapi` 送去要推薦。`confidence` 只出現在提示詞的 `Reading confidence: X`。

- 要「不可信就不推薦」，得由站台在 `reliable` 加上 `confidence` 的判斷。
- 站台的波形在 `sqiOk = false` 的那幾秒**整段丟掉**，SQI 恢復時 `firstAbs` 接不上 → 整張圖清空重畫。這是站台程式的行為，與 `confidence` 無關。
- 0.0.0.8 起最新的拍約 1.5 秒後才進 HRV（見 [trough_line.md](trough_line.md) §4），倒數結束那一刻拿到的數值，最後約 1.5 秒的拍還不在裡面。

---

## 3. 一拍從被抓到、到進 HRV 要過的關卡

| 關卡 | 位置 | 條件 | 留下空洞？ |
|---|---|---|---|
| 右緣 | `k2_core._compute()` | 谷離最新資料 < 154 筆 → 這輪不收，下一輪再收（線還沒定下來） | ❌（只是晚收） |
| ① SQI | `k2_beatseries.feed()` | 這一輪 SQI 沒過 → 這輪的谷不記 | ✅ |
| ② 補漏拍 | 同上 | **預設關閉**（`searchBackEnabled = false`） | 補成功 ❌ |
| ③ 生理閘門（過長） | 同上 | > 2000 ms（30 bpm） | ✅ |
| ③ 生理閘門（過短） | 同上 | < 250 ms（240 bpm） | ❌ 當成假谷，基準不推進 |
| ④ 分類 | `k2_hrv_calculator.classify()` | 漏拍 / 偽拍 | ✅ |
| 訊號中斷 | `markDiscontinuity()` | 起點被清掉 | ✅ |

0.0.0.7 的「近 9 拍 ±40%」閘門與 clean() 的「全窗中位數 ± max(2.5×MAD, 50%)」**已拿掉**，由 ④ 取代。拿掉 ±40% 的理由：起步 3 拍內全收，早期的壞拍直接進 RMSSD；起步若連漏幾拍，中位數變 2 倍，之後的真拍全被判太短 → 序列鎖死在半速（10/30 錄音：心率 110 讀成 56）。

---

## 4. 已知限制

### 一長一短，兩筆都在 ±20% 以內

谷被推偏時，前一個 RR 變長、後一個變短，兩筆加起來約兩拍。只要兩筆都只偏離局部中位數 20% 以內，**分類會把它們當成乾淨**，照樣進 RMSSD。

- 11/02 08:39 快照：0.0.0.7 的 `870 / 680 / 860`（680 只比周圍短 16%）、0.0.0.8 的 `740 / 830`（短 9%），都沒被剔除。
- 0.0.0.8 這類情況少很多，是靠帶通把谷的位置抓穩（見 [trough_line.md](trough_line.md)），不是靠分類。

### 手指動的那幾拍

11/02 定長 12 秒快照（刻意動一下手指）：0.0.0.8 的 RMSSD 76.6（0.0.0.7 是 217.8），可信度仍是 `good`、乾淨比例 100%。動作附近的 `853 → 776 → 882 → 727 → 698 → 834` 都在 ±20% 內。

### 尚未採用的方向

| 方向 | 做法 | 狀態 |
|---|---|---|
| 一長一短偵測 | 相鄰兩筆加起來 ≈ 2 倍局部中位數、又一長一短 → 兩筆一起剔除 | 未做 |
| 用波形判斷動作 | 谷深突然變成平常的兩倍等 → 附近幾拍不收 | 未做 |
| 谷底拋物線內插 | 時間精度從 10 ms 提高到 1 ms 以下 | 未做 |
| 波動幅度 AC/DC | 手指 0.82%~5.4%、木頭 0.20%，候選門檻 < 0.5%（擋非手指） | 未做，29 份快照訂的 |
| IR 與 RED 相關係數 | 手指 +0.98~+1.00、木頭 +0.06，候選門檻 < 0.9 | 未做 |

---

## 5. 快照波形與谷位置的換算

定長模式的快照裡，`ir` / `red` 從 `base` 起算，`goldTroughs` 存的是**每拍的終谷**：

```
base       = rrEndAbs[0] − goldTroughs[0]
波形索引    = 絕對位置 − base
```

> ⚠️ 不要用 `rrStartAbs[0] − goldTroughs[0]`，那會錯一拍（約 0.7 秒）。

---

## 6. 送出的相關欄位

| 欄位 | 0.0.0.6 | 0.0.0.7 | 0.0.0.8 |
|---|---|---|---|
| `confidence` | SNR 三級 / `null` | good / very rough | **good / rough / very rough**（§1） |
| `confidence_video` | 與 `confidence` 同值 | 與 `confidence` 同值 | 與 `confidence` 同值 |
| `confidence_by_beats` | 拍數版 | 與 `confidence` 同值 | 與 `confidence` 同值 |
| `snr_db` | 原始 dB | 照送 | 照送 |
| `sqi` | 1 / 0 | 照送 | 照送 |

- 可信度只出現在 `strapi` 區塊；`/vitals` 與 WS `/stream` 用同一個函式產生；`/health`、`/waveform` 沒有。
- SNR 版仍在 App 上當對照顯示（標「不送出」）。

---

## 7. 在機台上確認

```bash
./max30102_server --version      # 0.0.0.8
curl -s http://localhost:8770/vitals | python3 -m json.tool | grep -E '"sqi"|"confidence"'
```

- 手指剛放上、乾淨拍未滿 9 → `very rough`，之後才 `good`。
- 量測中動手指 → 可能出現 `rough`（SQI 沒過或乾淨比例掉到 65~80%）。

---

## 8. 沿革

| 版本 | `confidence` 的判斷 |
|---|---|
| 0.0.0.3 | 照 aquivio-vitals 的 SNR 門檻，但頻帶用自己的定義（偏嚴） |
| 0.0.0.4 | SNR 頻帶補齊為 aquivio-vitals 的定義；新增 `confidence_video` 別名 |
| 0.0.0.7（`f3ac733`，未交付） | 只看 SQI：good / very rough |
| 0.0.0.7（`86f0436` → `755c052`） | SQI + 拍數 + RR 空洞（異常 ≤ 1 次）：good / very rough；三欄同值 |
| **0.0.0.8** | **乾淨 RR 比例 + 乾淨拍數 + SQI：good / rough / very rough；三欄同值** |
