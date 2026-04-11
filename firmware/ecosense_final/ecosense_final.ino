#include "nvs_flash.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <ArduinoJson.h>
#include "DHT.h"
#include <HardwareSerial.h>
#include <MHZ19.h>

// ── PIN DEFINITIONS ──────────────────────────────────────────────
#define DHTPIN        26
#define DHTTYPE       DHT22
#define MQ135_PIN     32
#define SOUND_PIN     33
#define CO2_RX_PIN    14
#define CO2_TX_PIN    13

// ── BLE UUIDs ────────────────────────────────────────────────────
#define SERVICE_UUID          "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define NOTIFY_CHARACTERISTIC "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define WRITE_CHARACTERISTIC  "beb5483e-36e1-4688-b7f5-ea07361b26a9"

// ── NODE IDENTITY ─────────────────────────────────────────────────
#define NODE_ID       "EcoSense_Node_1"

// ── SENSOR OBJECTS ───────────────────────────────────────────────
DHT dht(DHTPIN, DHTTYPE);
MHZ19 myMHZ19;
HardwareSerial co2Serial(2);

// ── BLE OBJECTS ──────────────────────────────────────────────────
BLEServer* pServer = NULL;
BLECharacteristic* pNotifyCharacteristic = NULL;
BLECharacteristic* pWriteCharacteristic = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// ── RESEARCH STATE ────────────────────────────────────────────────
bool isEdgeMode = true;

// ── IAQ MOVING AVERAGE BUFFER ─────────────────────────────────────
const int BUFFER_SIZE = 5;
float co2Buffer[BUFFER_SIZE] = {400, 400, 400, 400, 400};
int bufferIndex = 0;
int bufferFillCount = 0;

// ── SESSION PACKET COUNTER ────────────────────────────────────────
uint32_t packetCount = 0;

// ── SENSOR STATUS FLAGS ───────────────────────────────────────────
bool dhtOk  = false;
bool co2Ok  = false;

// ── BLE SERVER CALLBACKS ──────────────────────────────────────────
class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    packetCount = 0;
    Serial.println("Gateway connected. Session started.");
  }
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("Gateway disconnected.");
  }
};

// ── BLE WRITE CALLBACKS ───────────────────────────────────────────
class MyWriteCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    String command = pCharacteristic->getValue();
    command.trim();

    if (command == "CMD: CLOUD") {
      isEdgeMode = false;
    } else if (command == "CMD: EDGE") {
      isEdgeMode = true;
    }

    StaticJsonDocument<128> ackDoc;
    ackDoc["status"] = "MODE_ACK";
    ackDoc["mode"]   = isEdgeMode ? "edge" : "cloud";
    char ackStr[128];
    serializeJson(ackDoc, ackStr);
    pNotifyCharacteristic->setValue(ackStr);
    pNotifyCharacteristic->notify();

    Serial.print("ACK sent: ");
    Serial.println(ackStr);
  }
};

// ── SENSOR READ HELPERS ───────────────────────────────────────────
float readTemp() {
  float v = dht.readTemperature();
  dhtOk = !isnan(v);
  return dhtOk ? v : -999.0;
}

float readHum() {
  float v = dht.readHumidity();
  return !isnan(v) ? v : -999.0;
}

int readCO2() {
  int v = myMHZ19.getCO2();
  co2Ok = (v > 0);
  return co2Ok ? v : -1;
}

// ── SETUP ─────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);

  esp_err_t ret = nvs_flash_init();
  if (ret == ESP_ERR_NVS_NO_FREE_PAGES ||
      ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    nvs_flash_erase();
    nvs_flash_init();
  }
  Serial.println("NVS initialised.");

  dht.begin();
  Serial.println("DHT22 initialised.");

  // Auto calibration OFF — critical for indoor use
  // Without this, MH-Z19C assumes lowest reading = 400ppm
  // (outdoor air). In a sealed room this causes drift.
  co2Serial.begin(9600, SERIAL_8N1, CO2_RX_PIN, CO2_TX_PIN);
  myMHZ19.begin(co2Serial);
  myMHZ19.autoCalibration(false);
  Serial.println("MH-Z19C initialised. Warming up...");
  delay(3000);

  BLEDevice::init(NODE_ID);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  pNotifyCharacteristic = pService->createCharacteristic(
    NOTIFY_CHARACTERISTIC,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pNotifyCharacteristic->addDescriptor(new BLE2902());

  pWriteCharacteristic = pService->createCharacteristic(
    WRITE_CHARACTERISTIC,
    BLECharacteristic::PROPERTY_WRITE
  );
  pWriteCharacteristic->setCallbacks(new MyWriteCallbacks());

  pService->start();

  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(false);
  pAdvertising->setMinPreferred(0x0);
  BLEDevice::startAdvertising();

  Serial.println("EcoSense Node Ready. Waiting for Gateway...");
}

// ── LOOP ──────────────────────────────────────────────────────────
void loop() {
  if (deviceConnected) {

    float rawTemp  = readTemp();
    float rawHum   = readHum();
    int   rawCO2   = readCO2();
    int   rawMQ135 = analogRead(MQ135_PIN);
    int   rawSound = analogRead(SOUND_PIN);

    // Timer wraps ALL payload work including math + serializeJson()
    // This measures the true computational penalty of edge processing
    uint32_t processStart = micros();

    StaticJsonDocument<512> doc;

    doc["node_id"]      = NODE_ID;
    doc["packet_count"] = ++packetCount;
    doc["node_tick_ms"] = millis();
    doc["mode"]         = isEdgeMode ? "edge" : "cloud";

    doc["temp"]  = dhtOk  ? rawTemp : (float)-999;
    doc["hum"]   = dhtOk  ? rawHum  : (float)-999;
    doc["co2"]   = co2Ok  ? rawCO2  : -1;
    doc["air"]   = rawMQ135;
    doc["sound"] = rawSound;

    JsonObject status = doc.createNestedObject("sensor_status");
    status["dht22"]  = dhtOk ? "OK" : "ERROR";
    status["mhz19c"] = co2Ok ? "OK" : "ERROR";
    status["mq135"]  = "OK";
    status["sound"]  = "OK";

    if (isEdgeMode) {
      if (co2Ok && dhtOk) {
        co2Buffer[bufferIndex] = rawCO2;
        bufferIndex = (bufferIndex + 1) % BUFFER_SIZE;
        if (bufferFillCount < BUFFER_SIZE) bufferFillCount++;

        bool bufferReady = (bufferFillCount >= BUFFER_SIZE);
        doc["buffer_ready"] = bufferReady;

        float sum = 0;
        for (int i = 0; i < BUFFER_SIZE; i++) sum += co2Buffer[i];
        float movingAvg = sum / BUFFER_SIZE;

        float tempCompensation = (rawTemp - 22.0) * 0.5;
        float iaqScore = movingAvg + tempCompensation;

        doc["iaq_moving_avg"] = movingAvg;
        doc["iaq_score"]      = iaqScore;
        doc["alert"] = (iaqScore > 1000) ? "OPEN_WINDOW" : "NORMAL";

      } else {
        doc["buffer_ready"]   = false;
        doc["iaq_moving_avg"] = "SENSOR_ERROR";
        doc["iaq_score"]      = "SENSOR_ERROR";
        doc["alert"]          = "SENSOR_MISSING";
      }
    }
    // CLOUD MODE: no computation on ESP32
    // Firebase Cloud Function handles IAQ calculation server-side
    // This is the A/B test control condition

    char payloadStr[512];
    serializeJson(doc, payloadStr);

    uint32_t processEnd = micros();
    uint32_t processingTime = processEnd - processStart;

    StaticJsonDocument<640> finalDoc;
    deserializeJson(finalDoc, payloadStr);
    finalDoc["esp32_processing_us"] = processingTime;

    char finalPayload[640];
    serializeJson(finalDoc, finalPayload);

    pNotifyCharacteristic->setValue(finalPayload);
    pNotifyCharacteristic->notify();

    Serial.print("Mode: ");
    Serial.print(isEdgeMode ? "EDGE" : "CLOUD");
    Serial.print(" | Processing: ");
    Serial.print(processingTime);
    Serial.print("us | Packet: ");
    Serial.print(packetCount);
    Serial.print(" | Payload: ");
    Serial.println(finalPayload);

    delay(2000);
  }

  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    Serial.println("Restarting advertising...");
    oldDeviceConnected = false;
  }
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = true;
  }
}
