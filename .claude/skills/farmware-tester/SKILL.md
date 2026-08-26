---
name: farmware-tester
description: Flutter Farmware Tester V01 - STM32/Arduino hardware testing application with auto-detection, MOSFET diagnostics, and serial communication
---

# Flutter Farmware Tester V01

## Project Overview

This is a **Flutter Desktop (Windows)** application for automated hardware testing of STM32-based farmware boards. It communicates with two serial devices simultaneously:
- **STM32 board** (binary protocol via UR commands)
- **Arduino board** (text-mode serial commands for ADC readings)

The app performs automated testing of 24 hardware channels (ID 0-23), including GPIO output testing, sensor validation, adjacent pin short-circuit detection, and MOSFET fault diagnosis.

## Architecture

- **Framework**: Flutter 3.x (Windows Desktop)
- **Pattern**: Mixin-based Controllers + Singleton Services + StatefulWidget UI
- **State Management**: `ValueNotifier` for reactive UI updates
- **Persistence**: `SharedPreferences` via `ThresholdSettingsService`
- **Language**: Dart, with Chinese/English dual-language support via `LocalizationService`

### Key Design Patterns
- Controllers use `mixin ... on State<T>` to share logic across widgets while accessing `setState()` and `mounted`
- Services use Singleton pattern (`factory` constructor returning `_instance`)
- Serial communication uses `SerialPortManager` with heartbeat monitoring

## File Structure

```
lib/
  main.dart                              # App entry point, MainPage StatefulWidget, Drawer navigation
  controllers/
    auto_detection_controller.dart       # 6-step auto detection flow, MOSFET diagnostics
    serial_controller.dart               # Arduino/STM32 connect, disconnect, command sending
  services/
    serial_port_manager.dart             # Serial port open/close/send, heartbeat, data parsing
    data_storage_service.dart            # In-memory storage for 24-channel hardware + sensor data
    ur_command_builder.dart              # STM32 binary command builder (header + payload + checksum)
    threshold_settings_service.dart      # All configurable thresholds, SharedPreferences persistence
    adjacent_pins_service.dart           # GPIO pin adjacency map for short-circuit testing
    localization_service.dart            # Chinese/English string maps
    stlink_programmer_service.dart       # ST-Link firmware programming
    cli_checker_service.dart             # CLI tool availability checker
  widgets/
    auto_detection_page.dart             # Auto detection UI, result display, adjacent data display
    data_storage_page.dart               # Live data monitoring page (24 channels)
    arduino_panel.dart                   # Arduino command panel
    settings_page.dart                   # Threshold settings UI
    detection_rules_page.dart            # Editable detection rules with reset-to-defaults
    operation_page.dart                  # Quick operations (auto-connect, warm water, stop)
    cli_check_dialog.dart                # CLI availability check dialog
```

## STM32 Communication Protocol

### Command Format
```
[Header1][Header2][Header3][Payload...][Checksum]
  0x40     0x71     0x30    (variable)    CS
```
- **Checksum**: `CS = (0x100 - (sum_of_all_bytes & 0xFF)) & 0xFF`
- Built via `URCommandBuilder.buildCommand(List<int> payload)`

### Common Payload Commands
| Byte0 (CMD) | Description | Payload Format |
|-------------|-------------|----------------|
| `0x01` | GPIO ON | `[0x01, lowByte, midByte, highByte, 0x00]` - 24-bit bitmask |
| `0x02` | GPIO OFF | `[0x02, lowByte, midByte, highByte, 0x00]` - 24-bit bitmask |
| `0x03` | Read ADC | `[0x03, id, 0x00, 0x00, 0x00]` - Read single channel |
| `0x04` | Clear value | `[0x04, id, 0x00, 0x00, 0x00]` |
| `0x05` | Query firmware | `[0x05, 0x00, 0x00, 0x00, 0x00]` - Used as PING |

### GPIO Bitmask Encoding
24-bit bitmask across 3 bytes: `lowByte | (midByte << 8) | (highByte << 16)`
- Example: Turn on ID0 only = `[0x01, 0x01, 0x00, 0x00, 0x00]`
- Example: Turn off all 18 = `[0x02, 0xFF, 0xFF, 0x03, 0x00]`

### GPIO Command Confirmation
`sendGpioCommandAndWait()` uses a `Completer`-based mechanism:
1. Send GPIO command
2. Wait for STM32 echo confirmation (100ms timeout)
3. Retry up to `maxRetryPerID` times (default 5)
4. If all retries fail, abort detection

## Arduino Communication

Text-mode serial commands:
- **ADC read**: `s0` through `s9` for channels 0-9; `u0`, `u1`, `u2` for 10-12; `water`, `bib`, `mcu` for sensors
- **Flow control**: `flowon` / `flowoff`
- **Response format**: Text lines parsed by `SerialPortManager`

## Channel ID Configuration

| ID Range | Type | Description |
|----------|------|-------------|
| 0-17 | Hardware GPIO | STM32 output pins (MOSFET controlled) |
| 18 | Sensor | Flow meter |
| 19 | Sensor | CO2 Pressure |
| 20 | Sensor | Water Pressure |
| 21 | Sensor | MCU Temperature |
| 22 | Sensor (STM32 only) | Water Temperature |
| 23 | Sensor (STM32 only) | BIB Temperature |

## Auto Detection Flow (6 Steps)

1. **Connect** (`_stepConnect`): Auto-scan ports, connect Arduino + STM32, verify STM32 firmware response
2. **Idle Reading** (`_stepIdleReading`): Read all channels with GPIO OFF, validate against idle thresholds
3. **Adjacent Short + Running** (`_stepAdjacentAndRunning`): For each ID 0-17, turn ON single GPIO, read STM32+Arduino values, compare adjacent pin readings for short detection
4. **Close GPIO** (`_stepCloseGpio`): Turn off all GPIO outputs
5. **Sensor Reading** (`_stepSensorReading`): Read sensor channels (ID 18-23), validate ranges and cross-device differences
6. **Result** (`_stepResult`): Run diagnostic detection, compile results, show pass/fail dialog

### Batch Read with Retry
`_batchReadHardwareParallel()` reads each ID with per-ID retry (max `maxRetryPerID` times). Each read:
1. Send `0x03` command to STM32
2. Wait `hardwareWaitMs` (default 300ms)
3. Send Arduino `sX` / `uX` command
4. Wait `hardwareWaitMs`
5. Validate responses, retry if null

## MOSFET Diagnostic Detection

Priority chain in `_runDiagnosticDetection()` (highest priority first):
1. **D-12V Short**: Arduino value > 1000
2. **G-D Short**: Arduino Running 350~480 AND STM32 Running 420~570
3. **D-S Short**: Arduino Idle 25~60 AND STM32 Idle 330~375
4. **D-Ground Short**: Arduino ADC < 10 (Vss threshold)
5. **G-Ground Short**: Arduino Idle < 700 (abnormally low)
6. **G-S Short**: STM32 Running > 400 AND STM32 Idle < 50
7. **Load Disconnected**: STM32 Running < 100, Arduino diff < 180, STM32 Running in 40~70
8. **Wire Error**: Arduino diff < wireErrorDiffThreshold AND STM32 Running is normal

All thresholds are configurable via `ThresholdSettingsService` and editable in the Detection Rules page.

## GPIO Pin Adjacency (Short-Circuit Testing)

Defined in `AdjacentPinsService.pinInfoMap`. Key adjacencies:
- ID3 (PB12) is adjacent to **Vdd** (power)
- ID4 (PB11) is adjacent to **Vss** (ground)
- Physical pairs: 0-1, 2-3, 4-5, 5-6, 6-7, 7-8, 8-9, 10-17, 10-16, 11-13, 11-12, 13-17, 14-15, 15-16

Short-circuit detection: Compare adjacent pin ADC reading change vs baseline (idle). If difference > `adjacentShortThreshold` (default 100), flag as short.

## Default Threshold Values

### Hardware Thresholds (per-ID, all IDs same default)
| Category | Min | Max |
|----------|-----|-----|
| Arduino Idle | 770 | 830 |
| Arduino Running | 25 | 60 |
| STM32 Idle | 0 | 55 |
| STM32 Running | 300 | 380 |

### Sensor Thresholds
| Sensor | Arduino Range | STM32 Range |
|--------|--------------|-------------|
| Flow (18) | 0~10000 | 0~10000 |
| PressureCO2 (19) | 190~260 | 930~980 |
| PressureWater (20) | 190~260 | 930~980 |
| MCUtemp (21) | -20~100 | -20~100 |
| WATERtemp (22) | N/A | -20~100 |
| BIBtemp (23) | N/A | -20~100 |

### Temperature Diff Thresholds
- Flow diff: 3
- Temperature diff (ID 21-23): 5
- DS18B20 error value: 85

## Standard Workflows

### Adding a New Diagnostic Rule
1. Add default threshold constant in `ThresholdSettingsService` (`defaultXxx`)
2. Add private field with getter/setter (`_xxx`, `get xxx`, `setXxx()`)
3. Add load logic in `_loadSettings()` and reset in `_resetDiagnosticValues()`
4. Use the threshold in `auto_detection_controller.dart` `_runDiagnosticDetection()`
5. Add result list (`_xxxItems`, `_lastXxxItems`) in controller
6. Pass to `showTestResultDialog()`
7. Add display in `auto_detection_page.dart` result dialog
8. Add editable card in `detection_rules_page.dart`
9. Add localization strings in `localization_service.dart` (both zh/en maps)

### Adding a New Hardware Channel
1. Update `DataStorageService` capacity if needed
2. Add pin info in `AdjacentPinsService.pinInfoMap`
3. Update bitmask range in `sendUrCommand()` (currently 24-bit)
4. Add Arduino read command mapping if applicable
5. Update threshold defaults in `ThresholdSettingsService`

### Adding a New Page
1. Create widget in `lib/widgets/`
2. Add drawer entry in `main.dart` `_buildDrawerItem()`
3. Add page index in `_buildBody()` switch case
4. Add required localization strings

## Important Notes

- STM32 connection requires firmware version verification (0x05 command as PING, 2-second timeout)
- Arduino auto-sends `flowoff` on connect after 500ms delay
- Serial port conflict protection: same port cannot be used by both Arduino and STM32
- GPIO commands use `sendGpioCommandAndWait()` with confirmation — never fire-and-forget for GPIO ON/OFF during auto-detection
- `DataStorageService` stores both raw values and `HardwareState` (idle/running/error) per channel
- All detection thresholds persist via SharedPreferences with `threshold_` key prefix
- Temperature sensor readings for ID 21-23 use DS18B20; error value 85 indicates sensor fault
- The app supports slow debug mode with pause/resume and step-through history navigation
