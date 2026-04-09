# KDU Campus Monitor

![Status](https://img.shields.io/badge/Status-🟢%20Edge--to--Cloud%20Live-brightgreen)
![Completion](https://img.shields.io/badge/Completion-95%25-blue)
![Platform](https://img.shields.io/badge/Platform-ESP32%20%2B%20Flutter%20%2B%20Firebase-orange)
![License](https://img.shields.io/badge/License-Apache%202.0-green)

An ongoing exploration into low-cost IoT edge computing for real-time indoor environmental quality monitoring in university classroom contexts. An ESP32 edge node reads five environmental sensors and broadcasts live data to an Android application over BLE; the app re-publishes every reading to Firebase Realtime Database for cloud-side logging and future analysis. This emerging exploration in edge-to-cloud architecture forms the empirical foundation of the **EcoSense** GURP (Graduate Undergraduate Research Programme) research project at KDU Global.

---

## Project Status: 95% Complete

The full edge-to-cloud data pipeline is operational and validated on physical hardware. The ESP32 firmware streams a structured JSON sensor payload every 2 seconds via BLE GATT notification. The Flutter Android application scans, connects, parses the payload, renders a live dashboard, and uploads each reading to Firebase Realtime Database.

| Component | Status |
|-----------|--------|
| ESP32 BLE GATT firmware | ✅ Operational |
| Flutter BLE scanner & live dashboard | ✅ Operational |
| Firebase Realtime Database sync | ✅ Operational |
| BH1750 light sensor integration | ⏳ Pending — solder fix required |
| GURP structured data collection | ⏳ Pending |

---

## Architecture

```
┌────────────────────┐       BLE GATT        ┌──────────────────────────┐
│   ESP32 WROOM-32D  │ ─────────────────────▶│   Flutter Android App    │
│                    │   JSON every 2s         │   (flutter_blue_plus)    │
│  DHT22   MQ-135    │                        └──────────┬───────────────┘
│  DFR0034 MH-Z19C   │                                   │  firebase_database
│  BH1750 (pending)  │                                   ▼
└────────────────────┘                        ┌──────────────────────────┐
                                              │  Firebase Realtime DB    │
                                              │  ecosense-c2fc3-rtdb     │
                                              └──────────────────────────┘
```

---

## Hardware

| Sensor | Parameter | Interface | GPIO | Status |
|--------|-----------|-----------|------|--------|
| DHT22 | Temperature + Humidity | Digital | GPIO26 | ✅ Working |
| MQ-135 | Air Quality (VOC / CO) | ADC | GPIO32 | ✅ Working |
| DFR0034 | Sound Level | ADC | GPIO33 | ✅ Working |
| MH-Z19C | CO₂ (NDIR) | UART | TX:14 / RX:12 | ✅ Working |
| BH1750 | Light Intensity | I2C | SDA:27 / SCL:25 | ⏳ Pending (solder fix) |

**Microcontroller:** ESP32 WROOM-32D V4  
**Power:** USB (5V via USB-C)

---

## BLE Configuration

| Field | Value |
|-------|-------|
| Device name | `KDU-Monitor` |
| Service UUID | `4fafc201-1fb5-459e-8fcc-c5c9c331914b` |
| Characteristic UUID | `beb5483e-36e1-4688-b7f5-ea07361b26a8` |
| Payload format | JSON string, notify every 2 seconds |
| BLE MTU | 512 bytes (negotiated on connect) |

**Example payload:**
```json
{"temp":23.00,"hum":61.20,"air":111,"sound":400,"co2":1588,"light":0,"light_stat":"Not Detected","health_score":72}
```

---

## System Documentation

### Hardware Setup

<img src="docs/hardware_setup.png" alt="ESP32 sensor wiring on breadboard" width="250">

*ESP32 WROOM-32D wired on an MB-102 breadboard with all active sensors prior to BLE firmware deployment.*

<img src="docs/serial_monitor.png" alt="Arduino IDE Serial Monitor output" width="250">

*Arduino IDE Serial Monitor confirming all sensors polling correctly, showing the raw JSON output before BLE integration.*

---

### Mobile Gateway

<img src="Photos/SearchingOnAppStart.jpg" alt="Flutter BLE Scanner on app start" width="250">

*Flutter application on launch, performing an active BLE scan for the `KDU-Monitor` edge node.*

<img src="Photos/MonitorFoundAndConnectOptionShown.jpg" alt="Edge node discovered with Connect option" width="250">

*The target `KDU-Monitor` peripheral is discovered and presented alongside other nearby Bluetooth devices, with a highlighted Connect button.*

<img src="Photos/LiveReadingPlusPacketUpload.jpg" alt="Live dashboard with Firebase upload counter" width="250">

*Real-time sensor dashboard showing live readings from the ESP32. The Firebase sync counter reflects packets successfully uploaded to the cloud.*

<img src="Photos/Screenshot_20260409_141522.jpg" alt="Edge Health Score composite indicator" width="250">

*The composite Edge Health Score, derived from the aggregation of all sensor values, provides a single-value indicator of classroom environmental quality.*

---

### Cloud Integration

<img src="Photos/FireBaseRealTimeReading.png" alt="Firebase RTDB live data view" width="250">

*Firebase Realtime Database console receiving live sensor data. Each node represents a timestamped JSON record pushed on every BLE notification.*

<img src="Photos/FireBaseRealTimeReadingExpanded.png" alt="Firebase RTDB expanded JSON record" width="250">

*An expanded RTDB record showing the full sensor payload: temperature, humidity, CO₂ (ppm), air quality (raw ADC), sound level, health score, and server-side timestamp.*

---

## Progress

- [x] Hardware wiring and sensor validation
- [x] Combined sensor firmware (Serial JSON output)
- [x] BLE GATT server firmware
- [x] Flutter BLE scanner and live dashboard
- [x] End-to-end validation on physical Android device (Samsung S22)
- [x] Firebase Realtime Database live sync
- [x] BLE MTU negotiation (512 bytes) for full JSON payload delivery
- [ ] BH1750 light sensor soldering fix
- [ ] GURP structured data collection phase
- [ ] Edge vs. cloud latency benchmark analysis
- [ ] Research paper submission (EcoSense — targeting TechRxiv)

---

## Next Steps / Pending Tasks

### Hardware

**Light sensor soldering** — The BH1750 I²C light sensor is mounted but requires re-soldering for a stable electrical connection. Once resolved, the `light` and `light_stat` payload fields will report live lux values in place of the current `"Not Detected"` placeholder.

### Research (GURP — EcoSense)

**Structured data collection** — With the complete edge-to-cloud pipeline operational, the project advances to the systematic data collection phase. Sensor readings will be captured across multiple KDU Global classroom environments during scheduled class sessions. This dataset will underpin the EcoSense analysis of indoor environmental quality and its potential correlation with student performance and concentration.

---

## Repo Structure

```
kdu-campus-monitor/
├── firmware/
│   ├── combined_sensor/
│   │   └── combined_sensor.ino   # All sensors, Serial JSON output
│   └── ble_gatt_server/
│       └── ble_gatt_server.ino   # BLE GATT server, notifies Flutter app
├── kdu_monitor/                  # Flutter Android application
│   ├── lib/
│   │   └── main.dart             # ScanPage + DashboardPage + Firebase sync
│   └── android/
│       └── app/
│           └── google-services.json
├── Photos/                       # Live system documentation
├── docs/
│   ├── hardware_setup.png
│   └── serial_monitor.png
└── README.md
```

---

## Built With

- [Arduino / ESP32 Arduino Core](https://github.com/espressif/arduino-esp32)
- [DHT sensor library (Adafruit)](https://github.com/adafruit/DHT-sensor-library)
- [MHZ19 library](https://github.com/strange-v/MHZ19)
- [Flutter](https://flutter.dev)
- [flutter_blue_plus 1.35.3](https://pub.dev/packages/flutter_blue_plus)
- [Firebase Realtime Database](https://firebase.google.com/products/realtime-database)
- [firebase_database (Flutter)](https://pub.dev/packages/firebase_database)

---

*Gyawali Aabhushan — KDU Global, Smart Computing F22*  
*GURP Research Project: EcoSense — Indoor Environmental Quality Monitoring*
