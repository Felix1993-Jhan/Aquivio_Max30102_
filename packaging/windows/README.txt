max30102_server for Windows (x64)
=================================

Files
-----
  max30102_server.exe   the server
  serialport.dll        serial port library the server loads at runtime

Keep both files in the same folder. Windows finds serialport.dll next to the
executable automatically; no installation or environment variable is needed.
The DLL is built with the C runtime linked in, so the Visual C++
Redistributable is not required either.

Start the server
----------------
  max30102_server.exe --mode serial --serial COM4

Find the COM number in Device Manager under "Ports (COM & LPT)":
"STMicroelectronics STLink Virtual COM Port (COMx)".

Check
-----
  curl -s http://localhost:8770/health

Connected correctly: "mode":"serial", "open":true, "lastError":null.
If "mode" is "feed", the serial port could not be opened; the reason is
printed in the server's startup output.

Note: this executable is not code-signed. Windows SmartScreen or company
application-control policies may block it the first time.
