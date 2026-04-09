import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const KduMonitorApp());
}

class KduMonitorApp extends StatelessWidget {
  const KduMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KDU Campus Monitor',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.tealAccent,
        scaffoldBackgroundColor: const Color(0xFF121212),
        cardColor: const Color(0xFF1E1E1E),
      ),
      home: const ScanPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  List<ScanResult> scanResults = [];
  bool isScanning = false;

  @override
  void initState() {
    super.initState();
    startScan();
  }

  void startScan() async {
    setState(() => isScanning = true);
    scanResults.clear();
    
    FlutterBluePlus.scanResults.listen((results) {
      if (mounted) setState(() => scanResults = results);
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    if (mounted) setState(() => isScanning = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan for Edge Node'),
        backgroundColor: Colors.black,
        actions: [
          if (isScanning)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.tealAccent)),
            )
          else
            IconButton(icon: const Icon(Icons.refresh), onPressed: startScan)
        ],
      ),
      body: ListView.builder(
        itemCount: scanResults.length,
        itemBuilder: (context, index) {
          final device = scanResults[index].device;
          final deviceName = device.platformName.isNotEmpty ? device.platformName : "Unknown Device";
          
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: ListTile(
              leading: const Icon(Icons.bluetooth, color: Colors.tealAccent),
              title: Text(deviceName, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(device.remoteId.toString()),
              trailing: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: deviceName == "KDU-Monitor" ? Colors.tealAccent : Colors.grey[800],
                  foregroundColor: deviceName == "KDU-Monitor" ? Colors.black : Colors.white,
                ),
                child: const Text('Connect'),
                onPressed: () async {
                  await FlutterBluePlus.stopScan();
                  if (!mounted) return;
                  Navigator.push(context, MaterialPageRoute(builder: (context) => DashboardPage(device: device)));
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class DashboardPage extends StatefulWidget {
  final BluetoothDevice device;
  const DashboardPage({super.key, required this.device});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final String SERVICE_UUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String CHARACTERISTIC_UUID = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref('classroom_readings');
  
  double temp = 0.0, hum = 0.0;
  int co2 = 0, air = 0, sound = 0, light = 0, healthScore = 0, totalSynced = 0;
  String lightStat = "Connecting...";
  bool isConnected = false;

  @override
  void initState() {
    super.initState();
    connectToDevice();
  }

  void connectToDevice() async {
    try {
      await widget.device.connect(autoConnect: false);
      if (mounted) setState(() => isConnected = true);

      // Attempt to expand MTU for larger JSON payloads; not critical if it fails
      try {
        await widget.device.requestMtu(512);
      } catch (_) {}

      List<BluetoothService> services = await widget.device.discoverServices();
      for (BluetoothService service in services) {
        print("Found service: ${service.uuid}");
        if (service.uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase()) {
          for (BluetoothCharacteristic c in service.characteristics) {
            print("Found characteristic: ${c.uuid}");
            if (c.uuid.toString().toLowerCase() == CHARACTERISTIC_UUID.toLowerCase()) {
              await c.setNotifyValue(true);
              c.onValueReceived.listen((value) {
                final jsonString = utf8.decode(value);
                print("BLE RX: $jsonString");
                parseAndSyncData(jsonString);
              });
            }
          }
        }
      }
    } catch (e) {
      print("Connection error: $e");
      if (mounted) setState(() => isConnected = false);
    }
  }

  void parseAndSyncData(String jsonString) async {
    try {
      Map<String, dynamic> data = jsonDecode(jsonString);
      if (mounted) {
        setState(() {
          temp = data['temp']?.toDouble() ?? 0.0;
          hum = data['hum']?.toDouble() ?? 0.0;
          co2 = data['co2'] ?? 0;
          air = data['air'] ?? 0;
          sound = data['sound'] ?? 0;
          light = data['light'] ?? 0;
          lightStat = data['light_stat'] ?? "Unknown";
          healthScore = data['health_score'] ?? 0;
        });
      }
      data['cloud_sync_time'] = ServerValue.timestamp;
      await _dbRef.push().set(data);
      if (mounted) setState(() => totalSynced++);
    } catch (e) {
      print("Parse/Sync Error: $e");
    }
  }

  @override
  void dispose() {
    widget.device.disconnect();
    super.dispose();
  }

  Color getCO2Color(int co2Value) {
    if (co2Value < 800) return Colors.greenAccent;
    if (co2Value < 1500) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edge Dashboard'),
        backgroundColor: Colors.black,
        actions: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Icon(isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled, color: isConnected ? Colors.tealAccent : Colors.red),
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.2), borderRadius: BorderRadius.circular(10)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("☁️ Firebase Sync:", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                  Text("$totalSynced packets uploaded", style: const TextStyle(color: Colors.white)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: Colors.tealAccent.withOpacity(0.1), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.tealAccent, width: 2)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("Edge Health Score", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  Text("$healthScore / 100", style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.tealAccent)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10,
                children: [
                  _buildSensorCard("Temperature", "$temp °C", Icons.thermostat, Colors.orange),
                  _buildSensorCard("Humidity", "$hum %", Icons.water_drop, Colors.blue),
                  _buildSensorCard("CO2 Level", "$co2 ppm", Icons.air, getCO2Color(co2)),
                  _buildSensorCard("Air (Raw)", "$air", Icons.masks, Colors.purpleAccent),
                  _buildSensorCard("Sound", sound > 100 ? "Loud ($sound)" : "Quiet ($sound)", Icons.mic, Colors.amber),
                  _buildSensorCard("Light", lightStat == "Not Detected" ? "Offline" : "$light lx", Icons.lightbulb, lightStat == "Not Detected" ? Colors.grey : Colors.yellow),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSensorCard(String title, String value, IconData icon, Color color) {
    return Card(
      elevation: 4, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 40, color: color), const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontSize: 16, color: Colors.grey)), const SizedBox(height: 5),
            Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }
}
