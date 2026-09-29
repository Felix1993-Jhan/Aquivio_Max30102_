# （已拆分）MAX30102 心率 / 血氧 運算方式總覽

本文件的內容已經全部拆進兩份新文件，**這裡不再維護**。

| 你要找的 | 去哪裡 |
|---|---|
| 現行算法：每個數字怎麼算出來的（公式 + 出處，依資料流排序） | [vitals_metrics_derivation.md](vitals_metrics_derivation.md) |
| 已退場的算法、曾經訂錯的門檻、為什麼換掉 | [vitals_metrics_history.md](vitals_metrics_history.md) |

拆分於 2026-09-29（對應 commit `6371c42`、server `0.0.0.6`）。

## 為什麼要拆

這份文件寫於舊架構時期，有兩處會誤導人的內容：

1. **對照的實作路徑早已不存在** —— 它指向 `lib/main_mode/services/max30102_algorithm.dart` 等三個檔案，現行實作全在 `lib/main_mode/max30102_K2/`。
2. **SQI 的定位寫反了** —— 它寫「只作燈號，不擋顯示」，但 K2 的 `sqiOk` 是**硬閘門**（false 的那一輪谷不進 NN 序列，間接擋住心率與 HRV）。

而且它只寫到 HR / SpO2 / SQI，**RR 之後的東西（HRV 時域、頻域、衍生分數、28 個輸出欄位）一個都沒有**。

完整原文見 git 歷史。
