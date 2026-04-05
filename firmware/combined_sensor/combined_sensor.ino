/*
 * KDU Campus Monitor — Combined Sensor Firmware
 * ESP32 WROOM-32D V4
 *
 * Sensors:
 *   DHT22    → GPIO26 (temp + humidity)
 *   MQ-135   → GPIO32 (air quality, ADC)
 *   DFR0034  → GPIO33 (sound level, ADC)
 *   MH-Z19C  → TX:GPIO14 / RX:GPIO12 (CO2, UART)
 *   BH1750   → SDA:GPIO27 / SCL:GPIO25 (light, I2C) — pending soldering
 *
 * Output: JSON to Serial at 115200 baud, every 2 seconds
 */

#include <DHT.h>
#include <MHZ19.h>
#include <HardwareSerial.h>

#define DHT_PIN       26
#define DHT_TYPE      DHT22
#define MQ135_PIN     32
#define SOUND_PIN     33
#define CO2_TX        14
#define CO2_RX        12

DHT dht(DHT_PIN, DHT_TYPE);
MHZ19 mhz19;
HardwareSerial co2Serial(2);   // UART2

void setup() {
  Serial.begin(115200);
  delay(500);

  dht.begin();

  co2Serial.begin(9600, SERIAL_8N1, CO2_RX, CO2_TX);
  mhz19.begin(co2Serial);
  mhz19.autoCalibration(false);

  // ADC resolution
  analogReadResolution(12);

  Serial.println("KDU Campus Monitor — ready");
}

void loop() {
  float temp     = dht.readTemperature();
  float humidity = dht.readHumidity();
  int   airRaw   = analogRead(MQ135_PIN);
  int   soundRaw = analogRead(SOUND_PIN);
  int   co2      = mhz19.getCO2();

  Serial.println("==============================");

  if (isnan(temp) || isnan(humidity)) {
    Serial.println("DHT22 read error");
  } else {
    Serial.printf("Temperature: %.2f°C\n", temp);
    Serial.printf("Humidity:    %.2f%%\n", humidity);
  }

  Serial.println("Light:       pending (BH1750 unsoldered)");
  Serial.printf("Air Quality: %d raw\n", airRaw);
  Serial.printf("Sound:       %d raw\n", soundRaw);
  Serial.printf("CO2:         %d ppm\n", co2);
  Serial.println("==============================");

  // JSON output for logging / BLE parsing later
  Serial.printf(
    "{\"temp\":%.2f,\"humidity\":%.2f,\"air\":%d,\"sound\":%d,\"co2\":%d,\"light\":null}\n",
    temp, humidity, airRaw, soundRaw, co2
  );

  delay(2000);
}
