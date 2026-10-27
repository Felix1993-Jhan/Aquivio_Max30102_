max30102_server for macOS (Apple Silicon / arm64)
=================================================

Files
-----
  max30102_server       the server
  libserialport.dylib   serial port library the server loads at runtime
  run.sh                starts the server with the library path set

No Homebrew or other installation is needed.

1. Remove the download quarantine (once, after extracting)
---------------------------------------------------------
  xattr -dr com.apple.quarantine <this folder>

2. Start the server
-------------------
macOS does not look for libraries next to the executable, so the server must be
told where libserialport.dylib is. Either:

  a) use the script:
       ./run.sh --mode serial --serial /dev/cu.usbmodemXXXX

  b) or set the variable yourself (e.g. when your software launches the server):
       LIBSERIALPORT_PATH=<this folder>/libserialport.dylib \
         ./max30102_server --mode serial --serial /dev/cu.usbmodemXXXX

Find the port with:  ls /dev/cu.usbmodem*
Use the cu. device, not tty.

3. Check
--------
  curl -s http://localhost:8770/health

Connected correctly: "mode":"serial", "open":true, "lastError":null.
If "mode" is "feed", the serial port could not be opened; the reason is
printed in the server's startup output.
