# Linux 部署說明

## 建構 Linux 版本

在 Windows 開發機器上執行：

```bash
# 建構 Release 版本
flutter build linux --release

# 建構完成後，執行檔位於：
# build/linux/x64/release/bundle/
```

## 部署到 Linux 機器

### 1. 複製檔案

將整個 `build/linux/x64/release/bundle/` 資料夾複製到 Linux 機器，例如：
- `/opt/firmware_tester/`
- 或使用者主目錄 `~/firmware_tester/`

### 2. 設定串口權限

**重要：必須執行此步驟才能存取 COM 埠**

```bash
# 將目前使用者加入 dialout 群組
sudo usermod -a -G dialout $USER

# 重新登入以套用權限，或執行：
newgrp dialout

# 驗證權限
groups | grep dialout
```

### 3. 執行程式

```bash
cd /opt/firmware_tester/
./flutter_firmware_tester_unified
```

### 4. （選用）建立桌面捷徑

建立檔案 `~/.local/share/applications/firmware-tester.desktop`：

```ini
[Desktop Entry]
Name=Firmware Tester Unified
Comment=Hardware Firmware Testing Tool
Exec=/opt/firmware_tester/flutter_firmware_tester_unified
Icon=/opt/firmware_tester/data/flutter_assets/assets/images/logo.png
Terminal=false
Type=Application
Categories=Development;Electronics;
```

然後執行：
```bash
chmod +x ~/.local/share/applications/firmware-tester.desktop
update-desktop-database ~/.local/share/applications/
```

## STM32CubeProgrammer 安裝（僅 Main 模式燒錄需要）

### 1. 下載

從 STMicroelectronics 官網下載 Linux 版本：
https://www.st.com/en/development-tools/stm32cubeprog.html

### 2. 安裝

```bash
# 假設下載檔案為 SetupSTM32CubeProgrammer-x.x.x.linux
chmod +x SetupSTM32CubeProgrammer-*.linux
sudo ./SetupSTM32CubeProgrammer-*.linux

# 預設安裝路徑
# /usr/local/STMicroelectronics/STM32Cube/STM32CubeProgrammer/
```

### 3. 設定 udev 規則（ST-Link 權限）

建立檔案 `/etc/udev/rules.d/49-stlinkv2.rules`：

```bash
# STLink V2
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="3748", MODE="0666"
# STLink V2-1
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374b", MODE="0666"
# STLink V3
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374d", MODE="0666"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374e", MODE="0666"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374f", MODE="0666"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="0483", ATTRS{idProduct}=="3753", MODE="0666"
```

重新載入 udev 規則：
```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

## 測試串口連接

### 列出所有串口裝置

```bash
# 列出 USB 串口
ls -l /dev/ttyUSB*
ls -l /dev/ttyACM*

# 查看詳細資訊
dmesg | grep tty
```

### Arduino/CH340 驅動

大部分 Linux 發行版已內建 CH340/CH341 驅動，如果無法識別：

```bash
# 檢查是否載入驅動
lsmod | grep ch341

# 手動載入（通常不需要）
sudo modprobe ch341
```

## 常見問題

### 1. 無法開啟串口（Permission denied）

```bash
# 檢查權限
ls -l /dev/ttyUSB0

# 應顯示 dialout 群組
# crw-rw---- 1 root dialout

# 確認使用者在 dialout 群組中
groups | grep dialout

# 如果不在群組中，執行
sudo usermod -a -G dialout $USER
# 然後重新登入
```

### 2. 找不到 STM32_Programmer_CLI

如果安裝在非預設路徑，可在程式的「韌體上傳」頁面手動設定 CLI 路徑。

### 3. ST-Link 無法連接

```bash
# 檢查 ST-Link 是否被識別
lsusb | grep STMicro

# 應顯示類似：
# Bus 001 Device 005: ID 0483:374b STMicroelectronics ST-LINK/V2.1

# 檢查 udev 規則是否生效
udevadm info /dev/bus/usb/001/005 | grep MODE
```

## 支援的 Linux 發行版

已測試：
- Ubuntu 20.04 / 22.04 / 24.04
- Debian 11 / 12
- Fedora 38+
- Arch Linux

理論上支援所有使用 systemd 和 udev 的現代 Linux 發行版。

## 系統需求

- **OS**: Linux x64（GTK 3.0+）
- **RAM**: 最低 512MB，建議 1GB+
- **儲存**: 約 100MB
- **USB**: USB 2.0+ 埠口用於串口通訊

## 權限總結

| 功能 | 需要權限 | 設定方式 |
|------|---------|---------|
| Arduino 串口 | dialout 群組 | `sudo usermod -a -G dialout $USER` |
| STM32 串口 | dialout 群組 | 同上 |
| ST-Link 燒錄 | udev 規則 | 建立 `/etc/udev/rules.d/49-stlinkv2.rules` |

---

**注意**：所有權限設定完成後，請**登出並重新登入**才會生效。