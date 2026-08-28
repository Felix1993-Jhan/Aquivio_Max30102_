# ============================================================================
# serial_to_server.ps1 — 從串口讀 MAX30102 資料,轉發給無頭 server
# ============================================================================
# 用途:
#   當 server 自己不能開串口時(例如 Windows 上 serialport.dll 被 Application
#   Control 擋住),由這支腳本代勞:開串口、定時送 QUERY_FIFO、把回應原封 POST
#   到 server 的 /feed。server 只負責計算。
#
#   這也是**上層 Koa 端的參考實作** —— 流程完全一樣:
#     開串口 → 定時送查詢指令 → 讀回應 → 組框 → POST /feed → 讀 /vitals
#
# 用法:
#   .\tools\serial_to_server.ps1                      # 預設 COM71
#   .\tools\serial_to_server.ps1 -Port COM3
#   .\tools\serial_to_server.ps1 -Port COM71 -Seconds 60
#
# ⚠️ 執行前請確認 Flutter App 已關閉(同一個 COM 埠不能兩個程式同時開)。
# ============================================================================

param(
    [string]$Port       = "COM71",
    [int]   $Baud       = 115200,
    [string]$Server     = "http://localhost:8770",
    [int]   $IntervalMs = 100,
    [int]   $Board      = 0x31,   # 0x31=擴充板(MAX30102 預設) / 0x30=主板
    [int]   $Seconds    = 60,     # 跑多久
    [switch]$SkipInit             # 跳過晶片初始化
)

# ── 建封包:[40 71 board 09 payload...] + checksum ──────────────────────────
function New-Packet([byte[]]$Payload) {
    $body = @(0x40, 0x71, $Board, 0x09) + $Payload
    $sum  = 0
    foreach ($b in $body) { $sum += $b }
    $cs = (0x100 - ($sum -band 0xFF)) -band 0xFF
    return [byte[]]($body + $cs)
}

$CMD_QUERY = New-Packet @(0x00, 0x00, 0x00, 0x00)  # QUERY_FIFO
$CMD_INIT  = New-Packet @(0x04, 0x00, 0x00, 0x00)  # RE-INIT

# ── 開串口 ────────────────────────────────────────────────────────────────
Write-Host "開啟 $Port @$Baud ..." -ForegroundColor Cyan
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout  = 500
$sp.WriteTimeout = 500
try {
    $sp.Open()
} catch {
    Write-Host "❌ 開啟失敗:$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   → Flutter App 還開著嗎?同一個埠不能雙開。" -ForegroundColor Yellow
    exit 1
}
Write-Host "✅ 串口已開" -ForegroundColor Green

# ── 初始化晶片 ────────────────────────────────────────────────────────────
if (-not $SkipInit) {
    Write-Host "送出 RE-INIT(初始化晶片)..." -ForegroundColor Cyan
    $sp.Write($CMD_INIT, 0, $CMD_INIT.Length)
    Start-Sleep -Milliseconds 500
    $sp.DiscardInBuffer()
}

# ── 主迴圈:送查詢 → 讀回應 → 組框 → POST ────────────────────────────────
$buffer   = New-Object System.Collections.Generic.List[byte]
$deadline = (Get-Date).AddSeconds($Seconds)
$sent = 0; $packets = 0; $posted = 0; $lastReport = Get-Date

Write-Host "開始讀取(按 Ctrl+C 可中止,或等 $Seconds 秒自動結束)" -ForegroundColor Cyan
Write-Host "把手指放上感測器..." -ForegroundColor Yellow

try {
    while ((Get-Date) -lt $deadline) {
        # 送一次 QUERY_FIFO
        try { $sp.Write($CMD_QUERY, 0, $CMD_QUERY.Length); $sent++ } catch {}

        Start-Sleep -Milliseconds $IntervalMs

        # 把串口收到的 bytes 全部倒進 buffer
        $n = $sp.BytesToRead
        if ($n -gt 0) {
            $chunk = New-Object byte[] $n
            $read  = $sp.Read($chunk, 0, $n)
            for ($i = 0; $i -lt $read; $i++) { $buffer.Add($chunk[$i]) }
        }

        # ── 組框 ──
        # 串口是 byte 流,封包會被切碎或黏在一起,必須自己找邊界:
        #   [0]=40 [1]=71 [2]=board [3]=09 [4]=sub [5]=N*6 ... 總長 = 7 + [5]
        while ($buffer.Count -ge 7) {
            # 找表頭 40 71
            $start = -1
            for ($i = 0; $i -le $buffer.Count - 2; $i++) {
                if ($buffer[$i] -eq 0x40 -and $buffer[$i + 1] -eq 0x71) { $start = $i; break }
            }
            if ($start -lt 0) { $buffer.Clear(); break }
            if ($start -gt 0) { $buffer.RemoveRange(0, $start) }   # 丟掉表頭前的雜訊
            if ($buffer.Count -lt 7) { break }

            if ($buffer[3] -ne 0x09) { $buffer.RemoveRange(0, 2); continue }  # 不是 0x09 命令

            $total = 7 + $buffer[5]
            if ($buffer.Count -lt $total) { break }   # 還沒收完,等下一輪

            $pkt = $buffer.GetRange(0, $total).ToArray()
            $buffer.RemoveRange(0, $total)
            $packets++

            # ── 原封 POST 給 server(驗 checksum、拆樣本都由 server 的核心做)──
            $body = '{"bytes":[' + (($pkt | ForEach-Object { [int]$_ }) -join ',') + ']}'
            try {
                Invoke-RestMethod -Uri "$Server/feed" -Method Post `
                    -ContentType "application/json" -Body $body -TimeoutSec 5 | Out-Null
                $posted++
            } catch {
                Write-Host "⚠ POST 失敗:$($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        # 每 3 秒回報一次現況
        if (((Get-Date) - $lastReport).TotalSeconds -ge 3) {
            $lastReport = Get-Date
            try {
                $v = Invoke-RestMethod -Uri "$Server/vitals" -TimeoutSec 5
                $bpm  = if ($null -ne $v.bpm)  { [math]::Round($v.bpm, 1)  } else { "—" }
                $spo2 = if ($null -ne $v.spo2) { [math]::Round($v.spo2, 1) } else { "—" }
                $state = if ($v.settling) { "沉澱中" }
                         elseif (-not $v.fingerPresent) { "沒手指" }
                         else { "量測中" }
                Write-Host ("[{0}] 封包 {1} / 已送 {2}  |  手指={3} {4}  心率={5} bpm  血氧={6}%  樣本={7}" -f `
                    (Get-Date -Format "HH:mm:ss"), $packets, $posted, $v.fingerPresent, $state, $bpm, $spo2, $v.totalSamples)
            } catch {
                Write-Host "⚠ 讀 /vitals 失敗 —— server 還開著嗎?" -ForegroundColor Yellow
            }
        }
    }
} finally {
    Write-Host "`n收尾:關閉串口" -ForegroundColor Cyan
    try { $sp.Close() } catch {}
    try { $sp.Dispose() } catch {}
    Write-Host "送出查詢 $sent 次,收到完整封包 $packets 個,成功轉發 $posted 個" -ForegroundColor Green
}
