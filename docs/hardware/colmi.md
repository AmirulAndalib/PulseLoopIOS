---
title: Colmi / Yawell
description: >-
  The $15–30 Colmi/Yawell ring family (R02/R0x/R1x/H59) — sold with either the
  QRing app (Nordic-UART protocol) or the SmartHealth app (Yucheng YCBT).
---

# Colmi / Yawell

**PulseLoop support: ✅ Supported on QRing** (R11 tested; rest implemented, needs testing 🧪) ·
**🧪 Limited on SmartHealth** ([see below](#smarthealth-app-colmi-rings))

The QRing family — manufactured by Yawell and most commonly sold under the
**Colmi** brand. These $15–30 rings speak a Nordic-UART–based protocol and bring
sensors the cheaper [56ff / Jring](jring.md) lacks: skin temperature, REM sleep,
HRV, stress, and continuous background sync.

!!! warning "The same ring is sold with two different firmwares"
    A Colmi ring ships with **either the QRing app or the SmartHealth app**, and the two speak
    *completely different BLE protocols*. Everything on this page down to
    [Hackability](#hackability) describes the **QRing** firmware. If your ring came with
    **SmartHealth**, jump to [SmartHealth-app Colmi rings](#smarthealth-app-colmi-rings) — it is a
    different driver, a different capability set, and PulseLoop asks you which one you have when you
    pair.

## At a glance

| | Detail |
|---|---|
| **SoC** | Realtek RTL8762 family (Realtek AB2026 on R11) |
| **Bluetooth** | BLE 5.0 |
| **PPG sensor** | Vcare VC30F (red + green dual LED) on R10/R11/R12 |
| **Accelerometer** | STK8321 / ST LIS2DOC |
| **Battery / life** | 15–18 mAh · ~4–7 days |
| **Waterproof** | IP68 / 3ATM–5ATM (varies by model) |
| **Price** | $15–30 |
| **Protocol** | Nordic-UART QRing (`6e40fff0` / `de5bf728`), 16-byte frames, cleartext |
| **App** | QRing (R11 also: Da Rings) |
| **Custom firmware** | ✅ on R02/R03 (BXMicro); ⚠️ unknown on R10/R12 |

## Manufacturer

- **Shenzhen Yawell Intelligent Technology Co., Ltd.** (est. 2016, Shenzhen)
- 3 factories, 16 assembly lines, 500+ workers, 100+ R&D engineers
- Largest smart ring factory in South China (5,000 m², established 2024)
- 150K+ monthly smart ring shipments
- OEM/ODM for Lenovo, Nokia, Skyworth, Noise, Titan, Fire Boltt
- First smart ring launched: 2023
- Official app: **QRing** (by Yawell)
- **Colmi** (Shenzhen Colmi Technology Co., Ltd.) is the most popular licensed brand selling Yawell's QRing rings
- Website: [yawellfit.com](https://www.yawellfit.com/), [colmi.com](https://www.colmi.com/)

## Protocol (QRing firmware)

| Property | Value |
|---|---|
| **BLE family** | Nordic-UART (`6e40fff0` / `de5bf728`) |
| **App** | QRing |
| **Frame size** | 16 bytes (checksum) |
| **Encryption** | None |

A SmartHealth-flavoured unit speaks none of this — see
[SmartHealth-app Colmi rings](#smarthealth-app-colmi-rings).

## Models — QRing platform

| Model | CPU | Bluetooth | Battery | Waterproof | Display | Sensors | Notes |
|---|---|---|---|---|---|---|---|
| **R02** | Realtek RTL8762 | BLE 5.0 | Varies | IP68/3ATM | No | Unknown | Entry-level, "highly supported" per Gadgetbridge |
| **R03** | Realtek RTL8762 | BLE 5.0 | Varies | Unknown | No | Unknown | |
| **R06** | Realtek RTL8762 | BLE 5.0 | Varies | Unknown | No | Unknown | |
| **R07** | Realtek RTL8762 | BLE 5.0 | Varies | Unknown | No | Unknown | |
| **R09** | Realtek RTL8762 | BLE 5.0 | Varies | Unknown | No | Unknown | |
| **R10** | RTL8762 ESF | BLE 5.0 | 17 mAh | 5ATM | No | Vcare VC30F + STK8321 | Charging case: 200 mAh |
| **R12** | Realtek RTL8762 | BLE 5.0 | 15/18 mAh | IP68 + 1ATM | Yes | Vcare VC30F + ST LIS2DOC | Newest (2025), 4g weight |

### Yawell-branded QRing models

- R05, R10, R11, H59 — all use the same QRing protocol

## Colmi R11 — QRing-Compatible with Fidget Shell

The Colmi R11 uses a Realtek AB2026 SoC rather than the RTL8762 found in other QRing models,
but speaks the same Nordic-UART QRing protocol. It pairs with both the **Da Rings** app and the
**QRing** app.

| Component | Detail |
|---|---|
| **CPU** | Realtek AB2026 |
| **Bluetooth** | BLE 5.0 |
| **PPG sensor** | Vcare VC30F (red + green dual LED) |
| **Accelerometer** | STK8321 (3-axis MEMS) |
| **Battery** | 15 mAh (sizes 8–9) / 18 mAh (sizes 10–13) |
| **Charging case** | 200 mAh |
| **Waterproof** | IP68 + 5ATM |
| **Build** | Stainless steel casing with fidget-spinner outer shell |
| **Apps** | Da Rings or QRing (Android 5.1+ / iOS 12.0+) |

PulseLoop matches R11 rings via the `R11C?_[0-9A-F]{4}$` pattern in the Colmi QRing driver.
Capabilities should match the R10 (same VC30F + STK8321 sensor pair).

## Sensors

### Vcare VC30F

The VC30F is the PPG bio-sensor used in R10, R11, and R12:

- **Red + green LED emitters** — dual wavelength for HR and SpO₂
- **Integrated photodiode** — detects reflected light with ambient light rejection
- **Analog front-end (AFE)** — filters and amplifies raw signal
- **Digital controller** — outputs processed pulse data
- Available on JLCPCB's parts library (traceable component)
- Real-world accuracy: within 1 BPM of medical-grade BP monitor (per R12 review)

### ST LIS2DOC (R12) / STK8321 (R10, R11)

3-axis MEMS accelerometer for:

- Step counting and gesture detection
- Wear detection (wake on motion)
- Raw acceleration data for sleep and activity algorithms

## Capabilities per model (QRing firmware)

| Capability | R10 | R12 | R11 | Other QRing¹ |
|---|---|---|---|---|
| **Heart rate — spot** | ✅ | ✅ | ✅ | 🧪 |
| **Heart rate — history** | ✅ | ✅ | ✅ | 🧪 |
| **Heart rate — live** | ✅ | ✅ | ✅ | 🧪 |
| **SpO₂ — history** | ✅ | ✅ | ✅ | 🧪 |
| **SpO₂ — spot** | —² | —² | —² | —² |
| **Steps / distance / calories** | ✅ | ✅ | ✅ | 🧪 |
| **Sleep stages** (light/deep/awake) | ✅ | ✅ | ✅ | 🧪 |
| **REM sleep** | ✅ | ✅ | ✅ | 🧪 |
| **HRV** | ✅ | ✅ | ✅ | 🧪 |
| **Stress** | ✅ | ✅ | ✅ | 🧪 |
| **Body temperature** | ✅ | ✅ | ✅ | 🧪 |
| **Battery level** | ✅ | ✅ | ✅ | 🧪 |
| **Find device** | ✅ | ✅ | ✅ | 🧪 |
| **Blood pressure** | ❌ | ❌ | ❌ | ❌ |
| **Blood sugar** | ❌ | ❌ | ❌ | ❌ |

¹ R02, R03, R06, R07, R09 + Yawell R05, R10, R11, H59
² Colmi family has no on-demand SpO₂ reading; SpO₂ is all-day background only
³ Colmi has no blood pressure or blood sugar support. Its `userPreferences` (gender/age/height/weight) is for general health metric tuning only — not for BP/BS computation.

### What the Colmi family CAN do (that 56ff cannot)

- REM sleep detection
- Body temperature (skin temperature sensor)
- HRV
- Stress scoring
- Continuous background sync (autonomous notifications while worn)

---

## SmartHealth-app Colmi rings

**PulseLoop support: 🧪 Limited — implemented, never connected to a physical ring**

Some Colmi rings ship with **SmartHealth** (`com.zhuoting.healthyucheng`) instead of QRing. Same
brand, same product numbers, often the same box art — but the firmware inside speaks the **Yucheng
YCBT** protocol on a `be940…` service, which has *nothing* in common at the wire level with QRing's
Nordic-UART frames. It is the identical protocol the [TK5](tk5.md) speaks, byte for byte, so PulseLoop
drives these rings with the same shared stack and only a per-family capability set on top.

Byte-level spec: **[YCBT protocol](../YCBT-Protocol.md)** — and [§0](../YCBT-Protocol.md#0-the-two-families-that-speak-it)
in particular, which is the complete list of what differs between a TK5 and a SmartHealth-Colmi.

### Which rings

| Ring | Ships with SmartHealth? |
|---|---|
| **Colmi R09, R10** | ✅ Confirmed by the project owner (these are the units this support was written for) |
| Any other Colmi/Yawell model (R02, R03, R06, R07, R08, R11, R12, H59, Yawell R05/R10/R11) | ❔ Possible. The app a ring ships with is a seller/OEM choice, not a hardware one — the *same* model number is sold both ways. If yours came with SmartHealth, PulseLoop will try to drive it as a YCBT ring; it should work, and a report either way is genuinely useful |

### How to tell which app your ring uses

There is no way to tell from the ring itself, and **PulseLoop cannot reliably detect it either** — the
Bluetooth local name (`R09_ABCD`, `COLMI R10_1234`) is set by the OEM, not by the app, so a QRing ring
and a SmartHealth ring can advertise the *identical* name. So: check the box, the manual, the QR code
on the leaflet, or the listing that sold it to you. Whichever app it told you to install is the answer.

If you genuinely don't know, just try one — a wrong pick is a 20-second dead end with a one-tap fix,
not a broken ring ([below](#if-you-pick-the-wrong-app)).

### The pairing app-type picker

Because the answer can't be detected, PulseLoop **asks**. Under every Colmi card in *Add your ring*
there is a segmented picker — *"Which app came with your ring?"* — with **QRing** and **SmartHealth**.

- **QRing is the default**, because it is the mature, hardware-proven driver.
- The scan may *hint*: a ring whose advertisement looks like a SmartHealth unit defaults the picker to
  SmartHealth. The hint is only a default — it is [provisional](#whats-still-provisional) and it may
  never fire.
- **Your pick is authoritative.** It, not the scan, chooses the driver; and it changes what the card
  shows you before you connect (capability chips and the *Limited support* badge both follow the
  picker, because the two firmwares expose different metric sets).
- jring and TK5 cards show no picker: those rings ship with exactly one app, so they stay fully
  auto-detected.

### If you pick the wrong app

Nothing breaks, and nothing wrong gets saved. The driver for the app you picked goes looking for
service UUIDs the ring doesn't have: the Bluetooth link opens, GATT discovery comes up empty, and the
connection never completes.

PulseLoop times a user-initiated connect out after **20 seconds** and says so in the app's own terms —
*"This ring didn't answer as a SmartHealth ring. If it came with the QRing app, switch the app type
and try again."* — with a one-tap **"Try as QRing"** button that flips the picker and re-dials the same
ring. (And symmetrically in the other direction.) Only the pairing attempt times out; a background
reconnect to a ring you have already paired keeps waiting, as it should.

### Capabilities

The baseline is **what every YCBT ring does regardless of its sensors** — it is a protocol floor, not a
SKU description. Everything sensor-dependent is *gated on the ring's own capability bitmap*: the
handshake asks the ring what it has (`02 01` → `YCBTSupportFunction`), and PulseLoop claims those
extras only if the ring itself claims them. The bitmap can only **add** capabilities from a
pre-approved list — a garbled or truncated reply can never take one away.

| Capability | QRing-Colmi | **SmartHealth-Colmi** | TK5 |
|---|:---:|:---:|:---:|
| Heart rate — history / live / spot | ✅ | 🧪 baseline | 🧪 |
| SpO₂ — history | ✅ | 🧪 baseline | 🧪 |
| SpO₂ — **spot** | ❌ (all-day only) | 🧪 baseline | 🧪 |
| Steps / distance / calories | ✅ | 🧪 baseline | 🧪 |
| Sleep, incl. REM | ✅ | 🧪 baseline | 🧪 |
| HRV — history | ✅ | 🧪 baseline | 🧪 |
| HRV — **spot** | ❌ | 🧪 baseline | 🧪 |
| Battery level | ✅ | 🧪 baseline | 🧪 |
| Find device | ✅ | 🧪 baseline | 🧪 |
| Measurement intervals | ✅ | 🧪 baseline | 🧪 |
| Skin temperature | ✅ | ❔ **bitmap** | 🧪 |
| Stress | ✅ | ❔ **bitmap** | 🧪 |
| Blood pressure — history | ❌ | ❔ **bitmap** | 🧪 |
| Blood pressure — spot | ❌ | ❔ **bitmap** | 🧪 |
| Blood sugar | ❌ | ❔ **bitmap** | 🧪 |
| Fatigue | ✅ | ❌ | 🧪 |
| Power off / factory reset | ✅ | ❌ | ❌ |
| Continuous background sync | ✅ | ❌ | ❌ |

- **🧪 baseline** — claimed for every SmartHealth-Colmi, but no unit has confirmed any of it yet.
- **❔ bitmap** — claimed *only* if this particular ring's SupportFunction bitmap sets the bit. Two
  Colmi rings on the identical protocol genuinely differ on whether they carry a temperature or
  blood-pressure sensor, so this is a per-unit answer, not a per-family one.
- **Fatigue is deliberately not claimed**, unlike on the TK5. It rides the body-data record and *no
  bit names it*, so it can be neither gated nor honestly promised on hardware nobody has connected —
  and an unsupported claim here is user-visible, as a Vitals gauge stuck at "No fatigue score yet". The
  first real sync decides; adding it back is a one-line change.
- **Power off / factory reset** are QRing-protocol commands with no YCBT equivalent in PulseLoop, so
  the SmartHealth firmware simply doesn't offer them.
- **No background sync while disconnected** — like the TK5, the ring keeps logging on its own (that's
  what the all-day monitors are for), but PulseLoop only reads it while connected: on connect, every
  30 minutes thereafter, and after a workout.

### 🧪 What's still provisional

**No SmartHealth-Colmi has ever been connected to PulseLoop.** The protocol is not the risk — it is
byte-identical to the TK5's and is exercised by the same unit tests — but everything *specific to this
family* is a prediction until a real ring answers:

| Provisional | What it is | If it's wrong |
|---|---|---|
| **The advertisement match** | `ColmiSmartHealthCoordinator.Advertisement` — a Colmi-line local name **and** the `1078` product code somewhere in the manufacturer data **and** *no* QRing service UUID (`6e40fff0` / `de5bf728`). Taken from the vendor SDK's own scan filter (`BleHelper.filterDevice` accepts any advertisement whose hex *contains* `1078`), never from a capture of one of these rings | **Nothing stops working.** This is only the *hint* that pre-selects the picker. The user's pick chooses the driver, so a hint that never fires costs one toggle flip, not a connection. Both constants live in one place, to be refined the moment a capture exists |
| **The capability bitmap** | Which bits an R09/R10 actually sets — i.e. whether it really has temperature, BP, stress, blood sugar | A gated capability silently stays off (safe), or the ring claims one whose data never arrives (the card stays empty) |
| **`AE00` / JieLi RCSP gating** | The TK5 answers health commands in plaintext with no auth handshake, and the SDK proves the two code paths are independent — but it cannot prove a given *firmware* doesn't refuse `05 xx` until RCSP auth completes. See [TK5 → the AE00 service](tk5.md#the-ae00-service) | The one scenario that would be a **hard stop** for this family: the RCSP key is native and not recoverable. It is the first thing the first real sync checks |
| **GATT topology** | That a SmartHealth-Colmi exposes the same `be940000/01/03` service and characteristics as the TK5 | The driver finds nothing to subscribe and the connect times out — same failure, and the same recovery, as picking the wrong app |

Support stays **Limited** until a physical R09/R10 pairs, syncs, and its bitmap is read. If you own
one, [Contributing](../project/contributing.md) explains how to send a report — a `nRF Connect` scan of
the advertisement alone is already useful.

---

## Hackability

### 🏆 Full-Stack Hackable: Colmi R02 / R03 / R06

Per Hackaday's deep-dive by Aaron Christophel, the Colmi R02 is the most hacker-friendly ring:

| What | Detail |
|---|---|
| **Custom firmware** | Flashable via BLE OTA — **no signing, no encryption** |
| **Debug interface** | SWD pads accessible (scrape epoxy to expose) |
| **MCU** | BXMicro chip, 512 KB flash, 200 KB RAM |
| **SDK** | [BXMicro SDK3](https://gitee.com/BXMicro/SDK3) |
| **Reference FW** | [atc1441/ATC_RF03_Ring](https://github.com/atc1441/ATC_RF03_Ring) |
| **App protocol** | Documented in PulseLoop + Gadgetbridge |
| **Price** | $15–25 |

The manufacturer publishes firmware update images with no authenticity checks — upload whatever you want over BLE. Combined with SWD debugging, this is the closest thing to an open-source smart ring in production.

### 🥉 Protocol-Documented: the wider QRing family

- ✅ BLE protocol reverse-engineered (PulseLoop + Gadgetbridge)
- ✅ Nordic-UART based, unencrypted
- ✅ Custom app possible (PulseLoop already does it)
- ⚠️ Custom firmware: confirmed possible on R02/R03 (BXMicro); unknown for R10/R12 (Realtek RTL8762)
- **Price:** $15–30

---

See the [hardware overview](index.md) for the full cross-manufacturer comparison
tables, the [Jring / 56ff](jring.md) page for the cheaper option, or — if your Colmi came with the
SmartHealth app — the [TK5](tk5.md) page and the [YCBT protocol](../YCBT-Protocol.md) reference, whose
driver it shares.
