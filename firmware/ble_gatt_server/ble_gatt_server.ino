/*
 * KDU Campus Monitor — BLE GATT Server Firmware
 * ESP32 WROOM-32D V4
 *
 * Sensors:
 *   DHT22    → GPIO26 (temp + humidity)
 *   MQ-135   → GPIO32 (air quality, ADC)
 *   DFR0034  → GPIO33 (sound level, ADC)
 *   MH-Z19C  → TX:GPIO14 / RX:GPIO12 (CO2, UART)
 *   BH1750   → SDA:GPIO27 / SCL:GPIO25 (light, I2C) — pending soldering
 *
 * BLE:
 *   Device name   : KDU-Monitor
 *   Service UUID  : 4fafc201-1fb5-459e-8fcc-c5c9c331914b
 *   Char UUID     : beb5483e-36e1-4688-b7f5-ea07361b26a8
 *   Payload       : JSON string pushed via notify every 2s
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <DHT.h>
#include <MHZ19.h>
#include <HardwareSerial.h>

#define DEVICE_NAME     "KDU-Monitor"
#define SERVICE_UUID    "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_UUID       "beb5483e-36e1-4688-b7f5-ea07361b26a8"

#define DHT_PIN         26
#define DHT_TYPE        DHT22
#define MQ135_PIN       32
#define SOUND_PIN       33
#define CO2_TX          14
#define CO2_RX          12

DHT dht(DHT_PIN, DHT_TYPE);
MHZ19 mhz19;
HardwareSerial co2Serial(2);

BLEServer*          pServer         = nullptr;
BLECharacteristic*  pCharacteristic = nullptr;
bool                deviceConnected = false;

class ConnectionHandler : public BLEServerCallbacks {
  void onConnect(BLEServer* s) override {
    deviceConnected = true;
    Serial.println("BLE client connected");
  }
  void onDisconnect(BLEServer* s) override {
    deviceConnected = false;
    Serial.println("BLE client disconnected — restarting advertising");
    BLEDevice::startAdvertising();
  }
};

void setup() {
  Serial.begin(115200);
  delay(500);

  dht.begin();

  co2Serial.begin(9600, SERIAL_8N1, CO2_RX, CO2_TX);
  mhz19.begin(co2Serial);
  mhz19.autoCalibration(false);

  analogReadResolution(12);

  // BLE init
  BLEDevice::init(DEVICE_NAME);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ConnectionHandler());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  pCharacteristic = pService->createCharacteristic(
    CHAR_UUID,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharacteristic->addDescriptor(new BLE2902());

  pService->start();

  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  BLEDevice::startAdvertising();

  Serial.println("BLE advertising started — waiting for connection");
}

void loop() {
  float temp     = dht.readTemperature();
  float humidity = dht.readHumidity();
  int   airRaw   = analogRead(MQ135_PIN);
  int   soundRaw = analogRead(SOUND_PIN);
  int   co2      = mhz19.getCO2();

  // Build JSON payload
  char payload[128];
  if (isnan(temp) || isnan(humidity)) {
    snprintf(payload, sizeof(payload),
      "{\"temp\":null,\"humidity\":null,\"air\":%d,\"sound\":%d,\"co2\":%d,\"light\":null}",
      airRaw, soundRaw, co2
    );
  } else {
    snprintf(payload, sizeof(payload),
      "{\"temp\":%.2f,\"humidity\":%.2f,\"air\":%d,\"sound\":%d,\"co2\":%d,\"light\":null}",
      temp, humidity, airRaw, soundRaw, co2
    );
  }

  Serial.println(payload);

  if (deviceConnected) {
    pCharacteristic->setValue((uint8_t*)payload, strlen(payload));
    pCharacteristic->notify();
  }

  delay(2000);
}
