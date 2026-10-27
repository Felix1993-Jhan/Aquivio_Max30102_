#!/bin/bash
# 啟動 max30102_server,並讓它找到同一個資料夾裡的 libserialport.dylib。
#
# macOS 不會在執行檔旁邊找函式庫(Windows 會),所以要用 LIBSERIALPORT_PATH
# 明確指給它。由其他程式啟動 server 時,直接在那裡帶這個環境變數即可,
# 不一定要經過這支腳本。
#
# 用法:./run.sh --mode serial --serial /dev/cu.usbmodemXXXX
DIR="$(cd "$(dirname "$0")" && pwd)"
export LIBSERIALPORT_PATH="$DIR/libserialport.dylib"
exec "$DIR/max30102_server" "$@"
