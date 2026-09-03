# MAX30102 Vitals Service — Integration Guide

> For the integrating team (React + Koa).
> You don't need to know Dart, and you don't need to build anything —
> the binary runs as-is.
>
> 繁體中文版本：[SERVER_GUIDE.zh-TW.md](SERVER_GUIDE.zh-TW.md)

---

## What this is

A long-running HTTP / WebSocket service that turns raw MAX30102 sensor signals
into **heart rate, SpO₂, and HRV (heart rate variability)**.

```
MAX30102 sensor ──> this service ──> your Koa ──> React frontend
                    (computes)       (proxies)     (renders)
```

It **only computes**. No database, no UI, no auth.
Persisting history is your side's job — the service only ever holds the last 30 seconds.

---

## What you receive

| File | Notes |
|---|---|
| `max30102_server` | Linux x86-64 executable. **No runtime to install** — not even Dart. |
| This document | |

---

## Three-minute start

```bash
# 1. Make it executable
chmod +x max30102_server

# 2. Start it (no hardware needed for this first check)
./max30102_server --mode feed --port 8770 &

# 3. Verify
curl http://localhost:8770/health
```

Success looks like this:

```json
{"ok":true,"mode":"feed","uptimeMs":1204,"totalSamples":0,"resetOnFingerOff":true,"source":{}}
```

> The service has no UI. After starting it just sits there waiting for requests —
> that is the expected behaviour, not a hang.

---

## ★ Before measuring: confirm the hardware actually came up

There are three links in the chain, and **a break in any of them looks identical
from the outside** (all values `null`):

```
MAX30102 chip  ←I2C→  MCU (STM32)  ←serial→  this service
      1                    2                     3
```

| Broken link | Symptom | How to check |
|---|---|---|
| 3 — serial | Service can't open the device | `/health` shows `"open": false` and a `lastError` |
| 2 — MCU | Port is open but nobody answers | [`/chip`](#chip) shows `mcu.online: false` |
| 1 — chip | MCU fine but sensor unreachable | [`/chip`](#chip) shows `chip.online: false` |

### What you can check today

```bash
# 1. Did the serial port open?
curl http://localhost:8770/health
#    → confirm "open": true

# 2. Place a finger on the sensor, wait ~5s, then:
curl http://localhost:8770/vitals
#    → "fingerPresent": true means links 1-2-3 are all good
#    → a "bpm" value appearing shortly after means the maths works too
```

**Step 2 is currently the only end-to-end verification.** If placing a finger
produces a reaction, the chip, the MCU and the serial link are all healthy.

### ⚠️ Current limitation (important)

**The service does not initialise the MAX30102 on startup.**

If the chip is in an uninitialised (sleeping) state, the service will keep polling,
keep receiving empty data, and **report no error at all** — `/health` looks healthy
and `/vitals` is all `null`, which is indistinguishable from "nobody is measuring".

If placing a finger produces no reaction whatsoever, use these two to diagnose and fix:

```bash
# Which link in the chain is broken?
curl http://localhost:8770/chip

# Initialise the chip
curl -X POST http://localhost:8770/chip/init
```

In `serial` mode the service **initialises the chip automatically on connect**, so
this rarely needs doing by hand.

---

## Two input modes — pick one

There are two ways for sensor data to reach the service. You choose at startup,
and you can switch at runtime.

| | `serial` | `feed` |
|---|---|---|
| Who opens the serial port | **The service does** | **You do** |
| How data gets in | Service polls the sensor every 100ms | You `POST /feed` the raw bytes |
| What you have to implement | Nothing — just read `/vitals` | Open port, send query command, forward bytes |
| Best for | Service runs on the same box as the hardware | You already own the serial logic and just want the maths |

### Use `serial` unless you have a reason not to

```bash
./max30102_server --mode serial --serial /dev/ttyUSB0 --port 8770
```

With this you never touch the hardware — just read `/vitals`.

**Prerequisites (only for `serial` mode):**

```bash
# 1. Install the serial library (the -dev package is required — see below)
sudo apt-get install -y libserialport-dev

# 2. Grant serial port access (log out and back in afterwards)
sudo usermod -a -G dialout $USER

# 3. Find which device the sensor is on
ls -l /dev/ttyUSB* /dev/ttyACM*
```

#### ⚠️ Why `-dev` and not `libserialport0`

The service calls `dlopen("libserialport.so")` through FFI — the **unversioned**
filename. Linux packaging splits these:

| Package | Ships |
|---|---|
| `libserialport0` (runtime) | `libserialport.so.0`, `libserialport.so.0.1.1` |
| `libserialport-dev` | **`libserialport.so` (unversioned symlink)** ← this is what's needed |

Installing only `libserialport0` gives you:

```
Failed to load dynamic library 'libserialport.so': cannot open shared object file
```

If you'd rather not install `-dev`, these two are equivalent:

```bash
# a) Create the symlink yourself
sudo ln -s libserialport.so.0.1.1 /usr/lib/x86_64-linux-gnu/libserialport.so

# b) Point at it via env var (no system directories touched — good for containers)
export LIBSERIALPORT_PATH=/usr/lib/x86_64-linux-gnu/libserialport.so.0.1.1
./max30102_server --mode serial --serial /dev/ttyUSB0
```

### ⚠️ A serial port cannot be opened twice

If the desktop test tool (the Flutter app) is connected to the same device,
this service cannot open it. Only one process may hold the port at a time.

---

## API

The service listens on `http://localhost:8770` (change the port with `--port`).
All paths below hang off that base, e.g. `http://localhost:8770/vitals`.
Everything returns JSON.

<a id="api-overview"></a>
### API at a glance

| Endpoint | Method | Purpose | Key response fields |
|---|---|---|---|
| [`/health`](#health) | GET | Is the service alive, current mode, serial status | `ok` `mode` `source` |
| [`/vitals`](#vitals) | GET | **★ Most used** — heart rate, SpO₂, HRV | `bpm` `spo2` `hrv` `fingerPresent` `settling` [`strapi`](#strapi) |
| [`/waveform`](#waveform) | GET | Last N seconds of waveform (raw + smoothed) | `ir` `red` `irTrim` `redTrim` `firstAbs` |
| [`/stream`](#stream) | WS | **★ Recommended** — live push, ~1/sec | same as `/vitals` |
| [`/feed`](#feed) | POST | Push raw data (**feed mode only**) | `accepted` `computed` `totalSamples` |
| [`/mode`](#mode) | POST | Switch between serial / feed mode | `mode` `source` |
| [`/chip`](#chip) | GET | MCU and MAX30102 status (serial mode only) | `mcu` `chip` `inSync` |
| [`/chip/init`](#chip-init) | POST | Initialise the chip (RE-INIT) | `ok` `sent` |
| [`/chip/reset`](#chip-init) | POST | Reset the chip (⚠️ it then sleeps) | `ok` `sent` `warning` |
| [`/chip/reset-init`](#chip-init) | POST | Reset then immediately initialise | `ok` `sent` |

#### 📝 Every response is bilingual

Error and hint fields always come in pairs: **English in the main field, Chinese
with a `Zh` suffix**.

```json
{
  "error":   "mode must be \"serial\" or \"feed\"",
  "errorZh": "mode 必須是 \"serial\" 或 \"feed\""
}
```

This applies to `error` / `reason` / `hint` / `note` / `warning`.
Pick whichever matches your user's language — the main field names are unchanged.

#### ⚠️ How chip-control endpoints differ between modes

Chip control (init / reset) targets the MAX30102 directly and is unrelated to the
input mode. What *does* differ is **who can put the command on the wire**:

| Mode | Does the service hold the port? | Behaviour |
|---|---|---|
| `serial` | ✅ Yes | The service **sends it** and waits for the MCU to confirm |
| `feed` | ❌ No | The service returns the **prepared packet**; **you write it to your port** |

`feed` mode means "you own the serial port, the service only does the maths" — so
the service simply has no wire to send on. The responses look like this:

```json
// serial mode: already sent for you
{ "ok": true, "sent": true, "confirmed": true }

// feed mode: please send this packet yourself
{ "ok": true, "sent": false,
  "packet": [64, 113, 49, 9, 4, 0, 0, 0, 17],
  "note": "no serial port in feed mode — please send this packet yourself" }
```

The same Koa code works for both modes, with one extra check:

```js
const r = await fetch(`${K2}/chip/init`, { method: 'POST' }).then(r => r.json());
if (!r.sent) mySerialPort.write(Buffer.from(r.packet));   // feed mode only
```

This way **you never touch protocol details** — headers and checksums are computed
for you. (A packet with a wrong checksum is silently discarded by the MCU, with no
error message — painful to debug.)

The actual packets (board = 0x31, expansion):

| Command | hex | JSON bytes |
|---|---|---|
| RE-INIT | `40 71 31 09 04 00 00 00 11` | `[64,113,49,9,4,0,0,0,17]` |
| RESET | `40 71 31 09 03 00 00 00 12` | `[64,113,49,9,3,0,0,0,18]` |
| READ_REG(0xFF) | `40 71 31 09 02 FF 00 00 14` | `[64,113,49,9,2,255,0,0,20]` |

⚠️ **After `/chip/reset` the chip sleeps and stops sampling.** You must call
`/chip/init` to bring it back. Prefer `/chip/init` for normal recovery, or
`/chip/reset-init`, which bundles both steps so the init can't be forgotten.

### ⚠️ Security: this service has no access control

- It binds to **`0.0.0.0:8770` (all interfaces)**, not just loopback
- There is **no authentication** — anyone who can reach the port can read
  measurement data and switch modes

Block external access at deployment. Either approach works:

```bash
# a) Firewall (recommended)
sudo ufw deny 8770

# b) Or iptables
sudo iptables -A INPUT -p tcp --dport 8770 ! -s 127.0.0.1 -j DROP
```

The intended setup is **Koa and the service on the same machine**: Koa talks to
`127.0.0.1:8770` and proxies to the frontend. Port 8770 never needs to be
reachable from outside.

<a id="health"></a>
### `GET /health` — liveness

```bash
curl http://localhost:8770/health
```

```json
{
  "ok": true,
  "mode": "serial",
  "uptimeMs": 60123,
  "totalSamples": 6000,
  "resetOnFingerOff": true,
  "source": {
    "serial": "/dev/ttyUSB0", "baud": 115200,
    "open": true, "lastError": null
  }
}
```

**Use this for health checks, not `/vitals`.** When nobody is being measured,
`/vitals` returns `null` for every value — that is a normal state, not a failure.

`source.open` and `source.lastError` tell you whether the serial link is still alive.
If the USB device is unplugged the service **stays up**, but these two fields will reflect it.

---

<a id="vitals"></a>
### `GET /vitals` — current readings ★ the one you'll use most

```json
{
  "fingerPresent": true,
  "sqiOk": true,
  "settling": false,
  "bpm": 72.5,
  "spo2": 97.3,
  "hrv": {
    "sdnn": 42.1, "rmssd": 38.6, "pnn50": 12.5,
    "sd1": 27.3, "sd2": 53.2,
    "meanRr": 827.6, "meanHr": 72.5,
    "hrvScore": 73.0, "beats": 30
  },
  "totalSamples": 6000,
  "strapi": { "…see the strapi block below…" }
}
```

> ⚠️ **`GET /vitals` and the WebSocket `/stream` return the same payload.**
> The socket pushes a snapshot on connect and then one after every computation
> (roughly once per second). Everything below applies to both.

| Field | Meaning |
|---|---|
| `fingerPresent` | Whether a finger is detected on the sensor |
| `settling` | **Stabilising** — finger just placed, waiting for the signal to settle |
| `sqiOk` | Whether signal quality passed for this round |
| `bpm` | Heart rate (**median** of the last 6 beats — reacts quickly) |
| `spo2` | Blood oxygen saturation (%) |
| `hrv` | Heart rate variability, see below |
| `totalSamples` | Cumulative samples received (100 samples = 1 second) |
| `strapi` | Block shaped to your interface — see [the `strapi` block](#strapi) |

HRV fields (milliseconds unless noted):

| Field | Meaning |
|---|---|
| `sdnn` | Overall variability |
| `rmssd` | Beat-to-beat variability; parasympathetic indicator |
| `pnn50` | Percentage of adjacent intervals differing by more than 50ms |
| `sd1` / `sd2` | Poincaré plot short / long axis |
| `meanRr` / `meanHr` | Mean beat interval / mean heart rate |
| `hrvScore` | Friendly score = `ln(rmssd) × 20`, capped at 150 (compare against yourself) |
| `beats` | How many beats this statistic is based on |

---

<a id="strapi"></a>
### The `strapi` block — shaped to your interface

The `strapi` object inside `/vitals` matches `aquivio-station`'s `VitalsResult`
exactly, so you can use it without any mapping:

```ts
const v: VitalsResult = (await res.json()).strapi;
```

```json
"strapi": {
  "mean_hr": 70.13,
  "sdnn": 39.79,
  "rmssd": 48.65,
  "ln_rmssd": 3.885,
  "lf_hf": null,
  "sqi": 1,
  "snr_db": 13.96,
  "confidence": "good",
  "pns": 0.029,
  "ans": null,
  "stress": 15.59,
  "activity": null,

  "lf": 19.4,
  "hf": 1558.1,
  "lf_hf_raw": 0.0124,
  "lf_reliable": false,
  "hf_reliable": true,
  "lf_cycles": 1.16,
  "window_sec": 29.09,
  "ans_time_domain": 1.481,
  "sns": 1.511
}
```

The first group is the 12 fields your `VitalsResult` declares — **none of them
is ever omitted; a missing value is `null`, never `undefined`**. The second
group is extra, carried by the interface's `[key: string]: unknown`.

#### Why we didn't just rename the outer fields

Because some of them are **not the same quantity**, so renaming would send you
the wrong value:

| Ours | Yours | Difference |
|---|---|---|
| `sqiOk` | `sqi` | Boolean vs numeric 1/0 — different type |
| `bpm` | `mean_hr` | **Median** of the last 6 beats vs **mean** over the whole window — they differ by 1–3 bpm in the same reading |

So both live side by side. Duplicated fields such as `sdnn` are derived from
**the same `HrvStats` object**, not computed twice — there's a test pinning
`strapi.sdnn == hrv.sdnn` so the two can never drift apart.

#### Two fields that are always `null`

**`lf_hf`** — these values are computed over a **30-second window**, and the
lower edge of the LF band (0.04 Hz) has a 25-second period, so 30 seconds
contains barely 1.2 cycles of it (see `lf_cycles`).

Measured, by slicing one continuous recording into different window lengths and
comparing against a 5-minute baseline:

| Window | Median deviation | Within ±20% |
|---|---|---|
| 30 seconds | **42%** | 6 of 28 |
| 2 minutes | **26%** | 1 of 7 |

And it **drifts continuously** rather than fluctuating around a stable value —
within a single 5-minute recording the 2-minute windows moved monotonically from
−39% to +63%. So a longer measurement would not fix it.

`lf_hf` therefore returns `null`. **The raw numbers are not hidden**: `lf`, `hf`
and `lf_hf_raw` are all provided, along with `lf_reliable` / `lf_cycles` /
`window_sec` so you can judge for yourself.

**`ans`** — your `ans` is derived from LF/HF. We do have a **time-domain**
substitute (`SNS − PNS`, computable in 30 seconds), but it has a **different
definition and a different scale**, so putting it in `ans` would make the same
field name mean different things on the two devices. It is exposed under the
separate name `ans_time_domain` instead. If you'd like us to populate `ans` with
it, let us know first so we can confirm your downstream — especially the LLM
prompt — can accept the change of definition.

#### Suggested substitute: `rmssd`

The half of LF/HF that is mechanistically sound is **HF (parasympathetic)**, and
`rmssd` correlates with HF at **r > 0.9** — RMSSD is a first difference of the
interval series, which is a high-pass filter, so it measures essentially the same
thing. Unlike HF, RMSSD **is validated at 30-second windows** in the literature.

So if what you need is a relaxation / recovery signal, `rmssd` or `ln_rmssd`
gives you that today. What we can't give you is the sympathetic half — and that
is the half LF was never really measuring.

#### Extra fields

| Field | Meaning |
|---|---|
| `lf` / `hf` | Absolute band power (ms²). The ratio discards information — a rising `lf_hf` can mean LF went up *or* HF went down, and only the absolute values tell you which |
| `lf_hf_raw` | The raw ratio, without the reliability filter |
| `lf_reliable` / `hf_reliable` | Whether that band is trustworthy at this window length |
| `lf_cycles` | How many full cycles of the LF lower edge (0.04 Hz) fit in this window. Below 4.4 it isn't trustworthy |
| `window_sec` | How many seconds these values actually span (typically 28–29) |
| `ans_time_domain` | Time-domain autonomic balance = `sns − pns` |
| `sns` | Sympathetic index (time domain: mean HR + stress index + SD2) |

---

<a id="waveform"></a>
### `GET /waveform?seconds=5` — raw waveform (for plotting)

```json
{
  "firstAbs": 5500, "fs": 100, "count": 500,
  "ir":      [90325, 89699, ...],
  "red":     [60112, 59980, ...],
  "irTrim":  [89982.4, 89759.4, ...],
  "redTrim": [60043.1, 59961.7, ...]
}
```

- `fs: 100` — 100Hz sampling rate, so 500 samples = 5 seconds
- `firstAbs` — absolute position of element 0 (see "Reset on finger removal" below)
- `ir` / `red` — **raw** sensor readings
- `irTrim` / `redTrim` — **trim-smoothed** values; **use these to draw a clean line**

All four arrays are **element-aligned and the same length** (equal to `count`).

Both raw and smoothed are provided deliberately: smoothing makes the line look
better but also erases some real variation. Use `irTrim` for display, `ir` for
further analysis — and you never need to smooth it yourself, since this is the
same processing the core uses for heart rate and HRV.

**Do not poll this for live updates.** A 30-second window is 3000 samples × 2 arrays,
roughly 40KB of JSON. Use the WebSocket for numbers, and only fetch waveform data
when you actually need to redraw a chart — with a small `seconds` value.

---

<a id="stream"></a>
### `WS /stream` — live push ★ recommended

The service pushes a payload identical to `/vitals` every time it computes a new
result (roughly once per second). **You receive a snapshot immediately on connect**,
so there's no wait for the first frame.

```js
const ws = new WebSocket('ws://localhost:8770/stream');
ws.on('message', (raw) => {
  const v = JSON.parse(raw);
  console.log(v.bpm, v.spo2, v.hrv?.rmssd);
});
```

---

<a id="mode"></a>
### `POST /mode` — switch input mode at runtime

```bash
curl -X POST http://localhost:8770/mode \
  -H 'Content-Type: application/json' \
  -d '{"mode":"serial","serial":"/dev/ttyUSB0","baud":115200}'
```

```bash
curl -X POST http://localhost:8770/mode \
  -H 'Content-Type: application/json' -d '{"mode":"feed"}'
```

Switching resets the computation core so the new source starts from a clean state.

If switching to `serial` fails (device missing, busy, no permission) you get a **400**
with the reason, and the service **falls back to `feed` mode** rather than sitting in a
half-dead state:

```json
{
  "error": "Cannot open serial port /dev/ttyUSB9 (in use? is the user in the dialout group?)",
  "mode": "feed",
  "note": "switch failed, fell back to feed mode"
}
```

---

<a id="feed"></a>
### `POST /feed` — push raw data (only in `feed` mode)

If you own the serial port, forward the raw packets verbatim:

```bash
curl -X POST http://localhost:8770/feed \
  -H 'Content-Type: application/octet-stream' --data-binary @packet.bin
```

A JSON array is also accepted, which is handy for manual testing:

```bash
curl -X POST http://localhost:8770/feed \
  -H 'Content-Type: application/json' \
  -d '{"bytes":[64,113,49,9,0,6,96,234,0,80,102,1,14]}'
```

⚠️ **In `serial` mode this endpoint returns 409 by design.**
Feeding from two sources interleaves two independent timelines. Beat intervals
would be computed from garbage — **and nothing would report an error**.
An explicit rejection beats a silent miscalculation.

---

<a id="chip"></a>
### `GET /chip` — MCU and chip status

**`serial` mode only.** In feed mode the service holds no serial port, so it
returns 409 along with the packet you can send yourself.

```bash
curl http://localhost:8770/chip
```

```json
{
  "mcu":  { "online": true },
  "chip": { "online": true, "partId": "0x15", "ledRed": 36, "ledIr": 36 },
  "expected": { "partId": "0x15", "ledRed": 36, "ledIr": 36 },
  "inSync": true
}
```

**One query distinguishes three situations** — something `/health` cannot do
(it only knows the port is open):

| Response | Meaning |
|---|---|
| `mcu.online: false` | No reply from the MCU — firmware not running, or wiring problem |
| `mcu.online: true`, `chip.online: false` | MCU is fine, but the MAX30102 is unreachable (not connected or faulty) |
| Both `true` | The hardware chain is healthy; no readings simply means no finger |

`inSync` reports whether the chip's actual LED currents match the service's
configuration. A mismatch suggests the chip was reset to factory defaults —
call `/chip/init` to bring both sides back in line.

> ⚠️ This endpoint only reports; it **does not auto-repair**. Init restarts the
> chip, which would destroy a measurement in progress. When you see
> `inSync: false`, decide for yourself when to fix it.

---

#### Response fields

| Field | Type | Description |
|---|---|---|
| `mcu.online` | bool | Whether the MCU (STM32) replied at all |
| `mcu.error` / `mcu.errorZh` | string | Why it did not reply (EN / ZH) |
| `chip.online` | bool | Whether the MAX30102 is reachable (PART_ID == `0x15`) |
| `chip.partId` | string | PART_ID actually read back, e.g. `"0x15"` |
| `chip.ledRed` / `chip.ledIr` | int | LED currents **actually on the chip** |
| `expected.partId` | string | What it should be (`"0x15"`) |
| `expected.ledRed` / `expected.ledIr` | int | LED currents **this service expects** |
| `inSync` | bool | Whether chip settings match the service configuration |
| `hint` / `hintZh` | string | What to check next (EN / ZH) |

#### Diagnosis matrix

| `mcu.online` | `chip.online` | `inSync` | Meaning | Action |
|---|---|---|---|---|
| `true` | `true` | `true` | **All healthy.** No readings simply means no finger | none |
| `true` | `true` | `false` | Chip online, but LED currents differ from config (likely reset to baseline) | `POST /chip/init` |
| `true` | `false` | `false` | **MCU fine, MAX30102 unreachable** — not connected or faulty | Check sensor wiring |
| `false` | `false` | `false` | **No reply from MCU** — port is open but nobody answers | Check firmware is running, check wiring |

> 💡 `mcu.online: false` and `source.open: false` (in `/health`) mean **different
> things**: `open: false` means the port itself cannot be opened (device missing,
> in use, or no permission); `mcu.online: false` means the port is open but
> nothing answers on the other end.

#### Failure response examples

MCU not responding:

```json
{
  "mcu":  { "online": false,
            "error": "no reply from MCU (timeout 1000ms)",
            "errorZh": "MCU 沒有回應(逾時 1000ms)" },
  "chip": { "online": false },
  "inSync": false,
  "hint": "no reply from the MCU. The serial port itself is fine ...",
  "hintZh": "MCU 沒有回應。串口是通的 ..."
}
```

Chip unreachable:

```json
{
  "mcu":  { "online": true },
  "chip": { "online": false, "partId": "0x00", "ledRed": 0, "ledIr": 0 },
  "inSync": false,
  "hint": "PART_ID is not 0x15 — the chip is not connected or is faulty",
  "hintZh": "PART_ID 不是 0x15 —— 晶片沒接好或已損壞"
}
```

---

<a id="chip-init"></a>
### `POST /chip/init` · `/chip/reset` · `/chip/reset-init` — chip control

```bash
curl -X POST http://localhost:8770/chip/init
```

| Endpoint | Action | When to use |
|---|---|---|
| `/chip/init` | RE-INIT | **Most common** — try this first when the chip is unresponsive |
| `/chip/reset` | RESET | ⚠️ Only to put the chip to sleep. **Init is required afterwards** |
| `/chip/reset-init` | RESET → wait 500ms → RE-INIT | **Full restart**, the cleanest recovery |

In `serial` mode the service **waits for the MCU to confirm** — it does not
assume success just because the command was sent:

```json
{ "ok": true, "sent": true, "confirmed": true, "action": "init" }
```

Failures explain themselves:

```json
{ "ok": false, "sent": true, "action": "init",
  "error": "MCU reported init failure (is the chip connected?)",
  "errorZh": "MCU 回報初始化失敗(晶片是否接好?)" }
```

In `feed` mode the service has no port, so it hands you the packet instead
(see [above](#api-overview)).

> 💡 In `serial` mode the chip is **initialised automatically on connect**.
> The firmware already does this at boot; this is an extra safeguard — the
> service may connect long afterwards, by which time the chip's state could
> have been changed by something else.

---

## Reading the values: three things you must know

### 1. `null` is not an error — it means "not known yet"

| Situation | Response |
|---|---|
| No finger detected | `fingerPresent:false`, all values `null` |
| Stabilising | `settling:true`, values still `null` |
| Not enough beats (fewer than 9) | `hrv:null`, though `bpm` may already have a value |

**Do not render `null` as `0`.** That reads as "heart stopped".
Show something like "Measuring…" instead.

### 2. Expect ~3.5 seconds before the first number appears

This is deliberate. The moment a finger presses down produces a large transient;
letting it into the buffer would corrupt the baseline and throw off every
subsequent heart rate reading. The service discards the first 1.5 seconds, then
accumulates 2 seconds before it starts producing output.

**This is not a hang** — `settling: true` is the service telling you to wait.

### 3. ★ Everything resets when the finger is removed

The service defaults to a **single-session** measurement model:
once finger removal is confirmed, the sample counter resets to zero so the next
person starts completely fresh.

```
first person    → totalSamples climbs to 4488
finger removed  → totalSamples resets to 0, all values return to null
(nobody present)→ totalSamples stays at 0
second person   → totalSamples starts from 0 again
```

**What you need to handle:** `firstAbs` from `/waveform` is an absolute position and
becomes invalid at the moment of reset. Detecting this is simple — **`totalSamples`
drops sharply**. When you see that, clear any waveform you've accumulated client-side.

If your use case is continuous monitoring rather than one-person-at-a-time, disable it:

```bash
./max30102_server --reset-on-finger-off false
```

#### ⚠️ "Stopped sending data" is not "finger removed"

The reset is triggered by **receiving a finger-absent signal** (three consecutive
batches with infrared below threshold) — not by the absence of incoming data.

```
Finger removed, data still flowing → service sees low signal → resets after 3 batches ✅
You simply stop calling /feed       → service receives nothing → state is preserved   ❌
```

In `serial` mode this is a non-issue: the service polls continuously and detects
removal on its own.

But if you use `feed` mode and push data **intermittently** (e.g. you stop sending
once a session ends), reset explicitly when you stop. Otherwise the next person
inherits the previous person's state:

```bash
curl -X POST http://localhost:8770/mode -H 'Content-Type: application/json' -d '{"mode":"feed"}'
```

---

## Koa integration example

```js
const Router = require('@koa/router');
const WebSocket = require('ws');

const K2 = 'http://127.0.0.1:8770';
const router = new Router();

// ── Polling endpoints for the frontend ──
router.get('/api/vitals', async (ctx) => {
  const res = await fetch(`${K2}/vitals`);
  ctx.body = await res.json();
});

router.get('/api/waveform', async (ctx) => {
  const sec = ctx.query.seconds || 5;
  const res = await fetch(`${K2}/waveform?seconds=${sec}`);
  ctx.body = await res.json();
});

// ── Health check ──
router.get('/api/health', async (ctx) => {
  try {
    const res = await fetch(`${K2}/health`);
    ctx.body = await res.json();
  } catch (e) {
    ctx.status = 503;
    ctx.body = { ok: false, error: 'vitals service unreachable' };
  }
});

// ── Point the service at the device on startup ──
async function initDevice(path = '/dev/ttyUSB0') {
  const res = await fetch(`${K2}/mode`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mode: 'serial', serial: path }),
  });
  const body = await res.json();
  if (!res.ok) console.error('failed to open serial port:', body.error);
  return body;
}

// ── Live stream, with auto-reconnect ──
function subscribe(onVitals) {
  const ws = new WebSocket('ws://127.0.0.1:8770/stream');
  ws.on('message', (raw) => onVitals(JSON.parse(raw)));
  ws.on('close', () => setTimeout(() => subscribe(onVitals), 3000));
  return ws;
}
```

---

## Running as a service (systemd)

```ini
# /etc/systemd/system/max30102.service
[Unit]
Description=MAX30102 vitals service
After=network.target

[Service]
Type=simple
User=your-username
ExecStart=/opt/max30102/max30102_server --mode serial --serial /dev/ttyUSB0 --port 8770
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now max30102
sudo journalctl -u max30102 -f     # follow logs
```

On `systemctl stop` the service releases the serial port cleanly before exiting.

---

## Command-line options

| Option | Default | Description |
|---|---|---|
| `--mode <serial\|feed>` | `feed` | Input mode |
| `--serial <path>` | `/dev/ttyUSB0` | Serial device |
| `--baud <n>` | `115200` | Baud rate |
| `--port <n>` | `8770` | HTTP listen port |
| `--interval <ms>` | `100` | Serial polling interval |
| `--wave-seconds <n>` | `30` | Seconds of waveform retained for `/waveform` |
| `--reset-on-finger-off <true\|false>` | `true` | Reset on finger removal |

Environment variables are also supported: `K2_MODE`, `K2_SERIAL`, `K2_PORT`,
`K2_BAUD`, `K2_INTERVAL`, `K2_WAVE_SECONDS`, `K2_RESET_ON_FINGER_OFF`.
Command-line options take precedence.

Run with `--help` for the full listing.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Failed to load dynamic library 'libserialport.so'` | You installed `libserialport0` → install `libserialport-dev` instead (see "Install the serial library") |
| `Cannot open serial port ... (in use? dialout group?)` | (a) another process holds the port, or (b) missing permission → `sudo usermod -a -G dialout $USER`, then **log out and back in** |
| `/vitals` always all `null` | Finger not placed properly, or `source.open` is `false` in `/health` (port never opened) |
| Stuck at `settling: true` | Normal for ~3.5s. If it persists, signal quality is insufficient (finger pressed too hard or too loosely) |
| `POST /feed` returns 409 | You're in `serial` mode. Switch first: `POST /mode {"mode":"feed"}` |
| `totalSamples` suddenly 0 | Normal — finger removal triggered a reset. Clear any client-side waveform |
| No response after unplugging USB | The service stays up. Check `source.lastError` in `/health`; after replugging, call `POST /mode` again |

---

## Appendix: developing without hardware

Use `feed` mode with synthetic data to exercise the whole pipeline before the
sensor is available:

```js
// Build a fake 100Hz, 72bpm packet (24 samples)
function fakePacket(startIndex, bpm = 72) {
  const body = [0x40, 0x71, 0x31, 0x09, 0x00, 24 * 6];
  for (let k = 0; k < 24; k++) {
    const ph = 2 * Math.PI * (bpm / 60) * ((startIndex + k) / 100);
    const ir  = 90000 + Math.round(3000 * Math.sin(ph));
    const red = 60000 + Math.round(1500 * Math.sin(ph));
    body.push(red & 0xFF, (red >> 8) & 0xFF, (red >> 16) & 0x03);
    body.push(ir  & 0xFF, (ir  >> 8) & 0xFF, (ir  >> 16) & 0x03);
  }
  const sum = body.reduce((a, b) => a + b, 0);
  body.push((0x100 - (sum & 0xFF)) & 0xFF);   // checksum
  return body;
}

// Feed one packet every 240ms (24 samples @100Hz).
// A heart rate appears after roughly 4 seconds.
let idx = 0;
setInterval(async () => {
  await fetch('http://127.0.0.1:8770/feed', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ bytes: fakePacket(idx) }),
  });
  idx += 24;
}, 240);
```

After about 45 seconds `/vitals` should report `bpm` close to 72 — a good end-to-end
sanity check.

> Note: SpO₂ from synthetic data is a fixed value (the red/IR amplitude ratio is
> hard-coded), so it carries no physiological meaning. It only confirms data is flowing.
