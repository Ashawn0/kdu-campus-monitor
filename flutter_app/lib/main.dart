import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

const String kServiceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
const String kCharUuid    = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
const String kDeviceName  = "KDU-Monitor";

void main() {
  runApp(const KduMonitorApp());
}

class KduMonitorApp extends StatelessWidget {
  const KduMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KDU Campus Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      home: const ScanPage(),
    );
  }
}

// ─────────────────────────────────────────────
// Scan Page
// ─────────────────────────────────────────────

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final List<ScanResult> _results = [];
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        _results
          ..clear()
          ..addAll(results);
      });
    });
    FlutterBluePlus.isScanning.listen((scanning) {
      setState(() => _scanning = scanning);
    });
  }

  void _startScan() {
    _results.clear();
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
  }

  void _stopScan() => FlutterBluePlus.stopScan();

  Future<void> _connect(BluetoothDevice device) async {
    _stopScan();
    await device.connect(timeout: const Duration(seconds: 10));
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DashboardPage(device: device)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('KDU Campus Monitor'),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Searching for "$kDeviceName"...',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: _scanning
                        ? const CircularProgressIndicator()
                        : const Text('No devices found. Tap Scan.'),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (ctx, i) {
                      final r      = _results[i];
                      final name   = r.device.platformName;
                      final isKdu  = name == kDeviceName;
                      return ListTile(
                        leading: Icon(
                          Icons.bluetooth,
                          color: isKdu ? Colors.blue : Colors.grey,
                        ),
                        title: Text(name.isEmpty ? '(unnamed)' : name),
                        subtitle: Text(r.device.remoteId.toString()),
                        trailing: isKdu
                            ? ElevatedButton(
                                onPressed: () => _connect(r.device),
                                child: const Text('Connect'),
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanning ? _stopScan : _startScan,
        label: Text(_scanning ? 'Stop' : 'Scan'),
        icon: Icon(_scanning ? Icons.stop : Icons.search),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Dashboard Page
// ─────────────────────────────────────────────

class DashboardPage extends StatefulWidget {
  final BluetoothDevice device;

  const DashboardPage({super.key, required this.device});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Map<String, dynamic> _data = {};
  bool _connected = true;

  @override
  void initState() {
    super.initState();
    _discoverAndListen();
    widget.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        setState(() => _connected = false);
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _discoverAndListen() async {
    final services = await widget.device.discoverServices();
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() == kServiceUuid) {
        for (final char in service.characteristics) {
          if (char.uuid.toString().toLowerCase() == kCharUuid) {
            await char.setNotifyValue(true);
            char.onValueReceived.listen((value) {
              try {
                final json = utf8.decode(value);
                setState(() => _data = jsonDecode(json));
              } catch (_) {}
            });
          }
        }
      }
    }
  }

  @override
  void dispose() {
    widget.device.disconnect();
    super.dispose();
  }

  String _fmt(dynamic value, String unit, {int decimals = 1}) {
    if (value == null) return 'N/A';
    if (value is num) return '${value.toStringAsFixed(decimals)} $unit';
    return '$value $unit';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Dashboard'),
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(
              _connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              color: _connected ? Colors.greenAccent : Colors.redAccent,
            ),
          ),
        ],
      ),
      backgroundColor: const Color(0xFFF5F7FA),
      body: _data.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: GridView.count(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                children: [
                  _SensorCard(
                    icon: Icons.thermostat,
                    label: 'Temperature',
                    value: _fmt(_data['temp'], '°C', decimals: 2),
                    color: Colors.orange,
                  ),
                  _SensorCard(
                    icon: Icons.water_drop,
                    label: 'Humidity',
                    value: _fmt(_data['humidity'], '%', decimals: 2),
                    color: Colors.blue,
                  ),
                  _SensorCard(
                    icon: Icons.air,
                    label: 'Air Quality',
                    value: _data['air'] != null
                        ? '${_data['air']} raw'
                        : 'N/A',
                    color: Colors.green,
                  ),
                  _SensorCard(
                    icon: Icons.volume_up,
                    label: 'Sound Level',
                    value: _data['sound'] != null
                        ? '${_data['sound']} raw'
                        : 'N/A',
                    color: Colors.purple,
                  ),
                  _SensorCard(
                    icon: Icons.cloud,
                    label: 'CO₂',
                    value: _fmt(_data['co2'], 'ppm', decimals: 0),
                    color: Colors.red,
                  ),
                  _SensorCard(
                    icon: Icons.wb_sunny,
                    label: 'Light',
                    value: _data['light'] != null
                        ? '${_data['light']} lux'
                        : 'Pending',
                    color: Colors.amber,
                  ),
                ],
              ),
            ),
    );
  }
}

class _SensorCard extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  final Color    color;

  const _SensorCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 36, color: color),
          const SizedBox(height: 10),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.black54,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
