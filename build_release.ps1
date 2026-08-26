# ============================================================================
# Farmware Tester - Windows Release Build Script
# ============================================================================
# 用法: .\build_release.ps1
# 功能: 編譯 Release 版本並自動建立 firmware 資料夾
# ============================================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Farmware Tester - Release Build" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. 清理舊的建置
Write-Host "[1/4] Cleaning old build..." -ForegroundColor Yellow
flutter clean

# 2. 取得 dependencies
Write-Host "[2/4] Getting dependencies..." -ForegroundColor Yellow
flutter pub get

# 3. 編譯 Release 版本
Write-Host "[3/4] Building Windows Release..." -ForegroundColor Yellow
flutter build windows --release

# 4. 建立 firmware 資料夾
$releasePath = "build\windows\x64\runner\Release"
$firmwarePath = "$releasePath\firmware"

Write-Host "[4/4] Creating firmware folder..." -ForegroundColor Yellow
if (!(Test-Path $firmwarePath)) {
    New-Item -ItemType Directory -Path $firmwarePath -Force | Out-Null
    Write-Host "  Created: $firmwarePath" -ForegroundColor Green
} else {
    Write-Host "  Already exists: $firmwarePath" -ForegroundColor Gray
}

# 完成
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Output folder: $releasePath" -ForegroundColor Cyan
Write-Host ""
Write-Host "You can copy the entire Release folder to distribute." -ForegroundColor Gray
