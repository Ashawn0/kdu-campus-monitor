import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:sqflite/sqflite.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BLE UUIDs — must match EcoSense_Node_1 firmware exactly
// ─────────────────────────────────────────────────────────────────────────────
const String _kServiceUuid    = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
const String _kNotifyCharUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
const String _kWriteCharUuid  = "beb5483e-36e1-4688-b7f5-ea07361b26a9";

// ─────────────────────────────────────────────────────────────────────────────
// SQLite WAL — singleton helper
// Schema v2 adds node_id + record_key so flushes route to the correct Firebase
// path and can reuse the original push key.
// ─────────────────────────────────────────────────────────────────────────────
class WalDatabase {
  WalDatabase._();
  static final WalDatabase instance = WalDatabase._();

  Database? _db;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final databasePath = await getDatabasesPath();
    final dbPath = '$databasePath/wal_queue.db';
    return openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE IF NOT EXISTS wal_queue (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          node_id     TEXT    NOT NULL DEFAULT '',
          record_key  TEXT    NOT NULL DEFAULT '',
          payload     TEXT    NOT NULL,
          sync_status INTEGER NOT NULL DEFAULT 0,
          queued_at   INTEGER NOT NULL
        )
      '''),
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Add columns to existing v1 databases; existing rows get empty string.
          await db.execute(
              "ALTER TABLE wal_queue ADD COLUMN node_id TEXT NOT NULL DEFAULT ''");
          await db.execute(
              "ALTER TABLE wal_queue ADD COLUMN record_key TEXT NOT NULL DEFAULT ''");
        }
      },
    );
  }

  /// Caches [payload] for later flush.
  ///
  /// [nodeId]    — Firebase node path segment (e.g. "EcoSense_Node_1").
  /// [recordKey] — The Firebase push key that was generated before the failed
  ///               set(); stored so the flush can reuse the same key.
  ///
  /// gateway_receive_time is already embedded in [payload] — never recalculate.
  /// ServerValue.timestamp is replaced with a client-side ms value for storage.
  Future<void> insert(
    Map<String, dynamic> payload, {
    required String nodeId,
    required String recordKey,
  }) async {
    final database = await db;
    final storable = Map<String, dynamic>.from(payload);
    storable['cloud_sync_time'] = DateTime.now().millisecondsSinceEpoch;
    await database.insert('wal_queue', {
      'node_id':     nodeId,
      'record_key':  recordKey,
      'payload':     jsonEncode(storable),
      'sync_status': 0,
      'queued_at':   DateTime.now().millisecondsSinceEpoch,
    });
    debugPrint('[WAL] Cached record nodeId=$nodeId recordKey=$recordKey.');
  }

  Future<List<Map<String, dynamic>>> pendingRows() async {
    final database = await db;
    return database.query(
      'wal_queue',
      where: 'sync_status = ?',
      whereArgs: [0],
      orderBy: 'queued_at ASC',
    );
  }

  Future<void> markSynced(int id) async {
    final database = await db;
    await database.update(
      'wal_queue',
      {'sync_status': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> pendingCount() async {
    final database = await db;
    final result = await database.rawQuery(
      'SELECT COUNT(*) as cnt FROM wal_queue WHERE sync_status = 0',
    );
    return (result.first['cnt'] as int?) ?? 0;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// App entry
// ─────────────────────────────────────────────────────────────────────────────
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

// ─────────────────────────────────────────────────────────────────────────────
// Scan Page
// ─────────────────────────────────────────────────────────────────────────────
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
    setState(() {
      isScanning = true;
      scanResults.clear();
    });
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
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.tealAccent,
                ),
              ),
            )
          else
            IconButton(icon: const Icon(Icons.refresh), onPressed: startScan),
        ],
      ),
      body: ListView.builder(
        itemCount: scanResults.length,
        itemBuilder: (context, index) {
          final device     = scanResults[index].device;
          final deviceName = device.platformName.isNotEmpty
              ? device.platformName
              : 'Unknown Device';
          final isTarget =
              deviceName == 'EcoSense_Node_1' || deviceName == 'KDU-Monitor';

          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: ListTile(
              leading: const Icon(Icons.bluetooth, color: Colors.tealAccent),
              title: Text(
                deviceName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(device.remoteId.toString()),
              trailing: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      isTarget ? Colors.tealAccent : Colors.grey[800],
                  foregroundColor: isTarget ? Colors.black : Colors.white,
                ),
                child: const Text('Connect'),
                onPressed: () async {
                  await FlutterBluePlus.stopScan();
                  if (!mounted) return;
                  // ignore: use_build_context_synchronously
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DashboardPage(device: device),
                  ));
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dashboard Page — Mobile Gateway
// ─────────────────────────────────────────────────────────────────────────────
class DashboardPage extends StatefulWidget {
  final BluetoothDevice device;
  const DashboardPage({super.key, required this.device});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // ── Firebase ──────────────────────────────────────────────────────────────
  // Root reference — pushes go to /readings/{nodeId}/{auto_id}
  final DatabaseReference _readingsRef =
      FirebaseDatabase.instance.ref('readings');

  // ── BLE ───────────────────────────────────────────────────────────────────
  BluetoothCharacteristic? _writeChar;

  // ── Mode state ────────────────────────────────────────────────────────────
  String _requestedMode = 'edge';
  String _confirmedMode = 'edge';

  // ── Gate (MODE_ACK handshake) ─────────────────────────────────────────────
  bool _gating = false;
  DateTime? _gateStart;
  static const Duration _gateTimeout = Duration(seconds: 3);

  // ── Sensor state (from ESP32 payloads) ───────────────────────────────────
  bool isConnected = false;
  double temp = 0.0;
  double hum  = 0.0;
  int    co2  = 0;
  int    sound = 0;
  int    esp32ProcessingUs = 0;
  int    packetCount = 0;
  bool   bufferReady = false;

  // Edge-mode IAQ — populated directly from ESP32 payload; never calculated here
  double iaqMovingAvg = 0.0;
  double iaqScore     = 0.0;
  String alert        = '–';

  // ── Cloud listener state ──────────────────────────────────────────────────
  String? _cloudIaqScore;      // null → "Awaiting Cloud..."
  String? _cloudAlert;
  String? _cloudProcessingMs;  // null → "Calculating..."
  StreamSubscription<DatabaseEvent>? _cloudListener;

  // ── Counters ──────────────────────────────────────────────────────────────
  int totalSynced = 0;
  int walCached   = 0;

  // ── Connectivity ──────────────────────────────────────────────────────────
  late final StreamSubscription<List<ConnectivityResult>> _connectivitySub;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _connectToDevice();
    _listenConnectivity();
  }

  @override
  void dispose() {
    _connectivitySub.cancel();
    _cloudListener?.cancel();
    widget.device.disconnect();
    super.dispose();
  }

  // ── Connectivity listener → trigger WAL flush on reconnect ───────────────
  void _listenConnectivity() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = results.any((r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet);
      if (hasNetwork) _flushWal();
    });
  }

  // ── WAL flush ─────────────────────────────────────────────────────────────
  Future<void> _flushWal() async {
    final rows = await WalDatabase.instance.pendingRows();
    if (rows.isEmpty) return;
    debugPrint('[WAL] Flushing ${rows.length} cached record(s)…');

    for (final row in rows) {
      try {
        final Map<String, dynamic> data =
            jsonDecode(row['payload'] as String) as Map<String, dynamic>;

        // Re-apply live server timestamp; gateway_receive_time stays as stored.
        data['cloud_sync_time'] = ServerValue.timestamp;

        final storedNodeId = (row['node_id']    as String?) ?? '';
        final storedKey    = (row['record_key'] as String?) ?? '';
        final nodeId = storedNodeId.isNotEmpty
            ? storedNodeId
            : (data['node_id'] as String? ?? 'EcoSense_Node_1');

        String? recordId;
        if (storedKey.isNotEmpty) {
          // Reuse the original push key so the record ID is consistent.
          await _readingsRef.child(nodeId).child(storedKey).set(data);
          recordId = storedKey;
        } else {
          // Fallback: generate a fresh push key.
          final ref = _readingsRef.child(nodeId).push();
          recordId = ref.key;
          await ref.set(data);
        }

        await WalDatabase.instance.markSynced(row['id'] as int);
        debugPrint('[WAL] Flushed row id=${row['id']} recordId=$recordId.');
      } catch (e) {
        debugPrint('[WAL] Flush failed for row id=${row['id']}: $e');
      }
    }
    await _refreshWalCount();
  }

  Future<void> _refreshWalCount() async {
    final count = await WalDatabase.instance.pendingCount();
    if (mounted) setState(() => walCached = count);
  }

  // ── BLE connection ────────────────────────────────────────────────────────
  void _connectToDevice() async {
    try {
      await widget.device.connect(autoConnect: false);
      if (mounted) setState(() => isConnected = true);

      try { await widget.device.requestMtu(512); } catch (_) {}

      final services = await widget.device.discoverServices();
      for (final service in services) {
        if (service.uuid.toString().toLowerCase() !=
            _kServiceUuid.toLowerCase()) continue;

        for (final c in service.characteristics) {
          final uuid = c.uuid.toString().toLowerCase();
          if (uuid == _kNotifyCharUuid.toLowerCase()) {
            await c.setNotifyValue(true);
            c.onValueReceived.listen(_onBleData);
          } else if (uuid == _kWriteCharUuid.toLowerCase()) {
            _writeChar = c;
            debugPrint('[BLE] Write characteristic found.');
          }
        }
      }
    } catch (e) {
      debugPrint('[BLE] Connection error: $e');
      if (mounted) setState(() => isConnected = false);
    }
  }

  // ── BLE data handler ──────────────────────────────────────────────────────
  void _onBleData(List<int> value) async {
    // CRITICAL: capture gateway receive time as the VERY FIRST operation —
    // before any decoding, parsing, or processing.
    final int gatewayReceiveTime = DateTime.now().millisecondsSinceEpoch;

    final String jsonString = utf8.decode(value);
    debugPrint('[BLE RX] $jsonString');

    // ── MODE_ACK gate ─────────────────────────────────────────────────────
    if (_gating) {
      try {
        final ack = jsonDecode(jsonString) as Map<String, dynamic>;
        if (ack['status'] == 'MODE_ACK') {
          final ackedMode = ack['mode'] as String? ?? _requestedMode;
          debugPrint('[GATE] MODE_ACK received. Confirmed mode: $ackedMode');
          if (mounted) {
            setState(() {
              _confirmedMode = ackedMode;
              _gating    = false;
              _gateStart = null;
              if (ackedMode == 'edge') _resetCloudState();
            });
          }
          return; // Do not log the ACK packet
        }
      } catch (_) {}

      // Check gate timeout
      if (_gateStart != null &&
          DateTime.now().difference(_gateStart!) >= _gateTimeout) {
        debugPrint('[GATE] Timeout. Confirming mode: $_requestedMode');
        if (mounted) {
          setState(() {
            _confirmedMode = _requestedMode;
            _gating    = false;
            _gateStart = null;
            if (_requestedMode == 'edge') _resetCloudState();
          });
        }
        // Fall through — process this packet now that gate has expired
      } else {
        debugPrint('[GATE] Dropping packet during gate window.');
        return;
      }
    }

    _parseAndSync(jsonString, gatewayReceiveTime);
  }

  // ── Reset cloud listener + UI state when returning to edge mode ───────────
  void _resetCloudState() {
    _cloudListener?.cancel();
    _cloudListener    = null;
    _cloudIaqScore    = null;
    _cloudAlert       = null;
    _cloudProcessingMs = null;
  }

  // ── Parse ESP32 payload, inject gateway metadata, push / WAL ─────────────
  void _parseAndSync(String jsonString, int gatewayReceiveTime) async {
    try {
      final Map<String, dynamic> data =
          jsonDecode(jsonString) as Map<String, dynamic>;

      // ── Update UI sensor values ──────────────────────────────────────────
      if (mounted) {
        setState(() {
          temp  = (data['temp']  as num?)?.toDouble() ?? temp;
          hum   = (data['hum']   as num?)?.toDouble() ?? hum;
          co2   = (data['co2']   as num?)?.toInt()    ?? co2;
          sound = (data['sound'] as num?)?.toInt()    ?? sound;
          esp32ProcessingUs =
              (data['esp32_processing_us'] as num?)?.toInt() ?? esp32ProcessingUs;
          packetCount =
              (data['packet_count'] as num?)?.toInt() ?? packetCount;
          // Edge-only fields — absent in cloud payloads; retain previous values
          iaqMovingAvg =
              (data['iaq_moving_avg'] as num?)?.toDouble() ?? iaqMovingAvg;
          iaqScore  = (data['iaq_score'] as num?)?.toDouble() ?? iaqScore;
          alert      = data['alert']        as String? ?? alert;
          bufferReady = data['buffer_ready'] as bool?   ?? bufferReady;
        });
      }

      // ── Inject gateway metadata ──────────────────────────────────────────
      // gateway_receive_time was captured at the top of _onBleData — do NOT
      // recalculate here or during WAL flush.
      data['gateway_receive_time'] = gatewayReceiveTime;
      data['cloud_sync_time']      = ServerValue.timestamp;
      data['session_location']     = 'dorm_room';
      data['time_of_day']          = DateTime.now().hour;

      final List<ConnectivityResult> connectivity =
          await Connectivity().checkConnectivity();
      data['network_type'] =
          connectivity.isNotEmpty ? connectivity.first.name : 'none';

      // ── Push to Firebase — generate key upfront so WAL can store it ──────
      final nodeId = data['node_id'] as String? ?? 'EcoSense_Node_1';
      final ref    = _readingsRef.child(nodeId).push();
      final recordId = ref.key ?? '';

      try {
        await ref.set(data);
        if (mounted) setState(() => totalSynced++);

        // Cloud mode: listen for Cloud Function write-back on this record
        if (_confirmedMode == 'cloud' && recordId.isNotEmpty) {
          _setupCloudListener(nodeId, recordId);
        }
      } catch (e) {
        debugPrint('[Firebase] Push failed: $e — writing to WAL.');
        // Store the pre-generated push key so WAL flush reuses the same record ID.
        await WalDatabase.instance.insert(
          data,
          nodeId:    nodeId,
          recordKey: recordId,
        );
        await _refreshWalCount();
      }
    } catch (e) {
      debugPrint('[Parse/Sync] Error: $e');
    }
  }

  // ── Firebase realtime listener for Cloud Function results ─────────────────
  void _setupCloudListener(String nodeId, String recordId) {
    _cloudListener?.cancel(); // always cancel the previous listener first
    if (mounted) {
      setState(() {
        _cloudIaqScore    = null;
        _cloudAlert       = null;
        _cloudProcessingMs = null;
      });
    }

    _cloudListener = _readingsRef
        .child(nodeId)
        .child(recordId)
        .onValue
        .listen((DatabaseEvent event) {
      final val = event.snapshot.value;
      if (val == null || val is! Map) return;
      // After the is! Map check, Dart promotes val to Map — no cast needed.
      final map = Map<String, dynamic>.from(val);
      if (mounted) {
        setState(() {
          if (map.containsKey('cloud_iaq_score')) {
            _cloudIaqScore =
                (map['cloud_iaq_score'] as num).toStringAsFixed(1);
          }
          if (map.containsKey('cloud_alert')) {
            _cloudAlert = map['cloud_alert'] as String?;
          }
          if (map.containsKey('cloud_processing_ms')) {
            _cloudProcessingMs = map['cloud_processing_ms'].toString();
          }
        });
      }
    });
  }

  // ── Send mode command to ESP32 ────────────────────────────────────────────
  Future<void> _sendModeCommand(String mode) async {
    if (_writeChar == null) {
      debugPrint('[BLE] Write characteristic not available.');
      return;
    }
    final command = mode == 'edge' ? 'CMD: EDGE' : 'CMD: CLOUD';
    debugPrint('[BLE TX] $command');
    try {
      await _writeChar!.write(utf8.encode(command), withoutResponse: false);
      if (mounted) {
        setState(() {
          _gating    = true;
          _gateStart = DateTime.now();
        });
      }
    } catch (e) {
      debugPrint('[BLE TX] Write error: $e');
      if (mounted) setState(() => _requestedMode = _confirmedMode); // revert
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  Color _getCO2Color(int val) {
    if (val < 800)  return Colors.greenAccent;
    if (val <= 1000) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  /// "Quiet (0)" when zero; raw number otherwise.
  String _soundLabel() => sound == 0 ? 'Quiet (0)' : '$sound';

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final bool isEdge = _confirmedMode == 'edge';
    final bool showAlert =
        isEdge ? alert == 'OPEN_WINDOW' : _cloudAlert == 'OPEN_WINDOW';

    return Scaffold(
      appBar: AppBar(
        title: const Text('EcoSense Gateway'),
        backgroundColor: Colors.black,
        actions: [
          // Gate / handshake indicator
          if (_gating)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange, width: 1),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12, height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: Colors.orange,
                    ),
                  ),
                  SizedBox(width: 6),
                  Text('Syncing…',
                      style: TextStyle(color: Colors.orange, fontSize: 11)),
                ],
              ),
            ),
          // Mode toggle (EDGE ←→ CLOUD)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('EDGE',
                    style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.bold,
                      color: _requestedMode == 'edge'
                          ? Colors.tealAccent : Colors.grey[600],
                    )),
                Switch(
                  value: _requestedMode == 'cloud',
                  thumbColor: WidgetStateProperty.resolveWith((states) =>
                      _requestedMode == 'cloud'
                          ? Colors.blueAccent : Colors.tealAccent),
                  trackColor: WidgetStateProperty.resolveWith((states) =>
                      _requestedMode == 'cloud'
                          ? Colors.blueAccent.withValues(alpha: 0.4)
                          : Colors.tealAccent.withValues(alpha: 0.3)),
                  onChanged: _gating
                      ? null
                      : (cloudSelected) {
                          final newMode = cloudSelected ? 'cloud' : 'edge';
                          setState(() => _requestedMode = newMode);
                          _sendModeCommand(newMode);
                        },
                ),
                Text('CLOUD',
                    style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.bold,
                      color: _requestedMode == 'cloud'
                          ? Colors.blueAccent : Colors.grey[600],
                    )),
              ],
            ),
          ),
          // BLE status icon
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Icon(
              isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: isConnected ? Colors.tealAccent : Colors.red,
            ),
          ),
        ],
      ),

      // ── Body ───────────────────────────────────────────────────────────────
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            children: [

              // ── Status bar — 4 badges ────────────────────────────────────
              Row(
                children: [
                  Expanded(child: _statusBadge(
                    icon: isEdge ? '⚡' : '☁️',
                    label: 'Mode',
                    value: _confirmedMode.toUpperCase(),
                    color: isEdge ? Colors.tealAccent : Colors.blueAccent,
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: _statusBadge(
                    icon: '☁️',
                    label: 'Firebase',
                    value: '$totalSynced uploaded',
                    color: Colors.blueAccent,
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: _statusBadge(
                    icon: '⏳',
                    label: 'WAL Cache',
                    value: '$walCached pending',
                    color: walCached > 0 ? Colors.orangeAccent : Colors.grey,
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: _statusBadge(
                    icon: '⚙️',
                    label: 'Latency',
                    value: esp32ProcessingUs > 0
                        ? '${esp32ProcessingUs}μs' : '–',
                    color: Colors.cyanAccent,
                  )),
                ],
              ),
              const SizedBox(height: 12),

              // ── Sensor grid ──────────────────────────────────────────────
              // Edge:  Temp · Hum · CO₂ · Sound · IAQ Avg · IAQ Score
              //        + Edge Processing Time (7th card)
              // Cloud: Temp · Hum · CO₂ · Sound · Cloud IAQ Score
              //        · Cloud Processing Time + ESP32 Serialization (7th)
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                children: [
                  // ── Common cards (both modes) ──
                  _buildSensorCard('Temperature',
                      '${temp.toStringAsFixed(1)} °C',
                      Icons.thermostat, Colors.orange),
                  _buildSensorCard('Humidity',
                      '${hum.toStringAsFixed(1)} %',
                      Icons.water_drop, Colors.blue),
                  _buildSensorCard('CO₂ Level',
                      '$co2 ppm',
                      Icons.air, _getCO2Color(co2)),
                  _buildSensorCard('Sound',
                      _soundLabel(),
                      Icons.mic, Colors.amber),

                  // ── Edge-mode cards ──
                  if (isEdge) ...[
                    _buildSensorCard('IAQ Moving Avg CO₂',
                        iaqMovingAvg.toStringAsFixed(1),
                        Icons.analytics, Colors.purpleAccent),
                    _buildSensorCard('IAQ Score',
                        iaqScore.toStringAsFixed(1),
                        Icons.health_and_safety,
                        alert == 'OPEN_WINDOW'
                            ? Colors.redAccent : Colors.greenAccent),
                    _buildSensorCard('Edge Processing Time',
                        '${esp32ProcessingUs}μs',
                        Icons.speed, Colors.cyanAccent),
                  ]

                  // ── Cloud-mode cards ──
                  else ...[
                    _buildSensorCard('Cloud IAQ Score',
                        _cloudIaqScore ?? 'Awaiting Cloud...',
                        Icons.cloud,
                        _cloudIaqScore != null
                            ? Colors.blueAccent : Colors.grey),
                    _buildSensorCard('Cloud Processing Time',
                        _cloudProcessingMs != null
                            ? '${_cloudProcessingMs}ms' : 'Calculating...',
                        Icons.timer,
                        _cloudProcessingMs != null
                            ? Colors.blueAccent : Colors.grey),
                    _buildSensorCard('ESP32 Serialization Time',
                        '${esp32ProcessingUs}μs',
                        Icons.speed, Colors.cyanAccent),
                  ],
                ],
              ),
              const SizedBox(height: 10),

              // ── Edge: buffer warming indicator ───────────────────────────
              if (isEdge && !bufferReady)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      vertical: 8, horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: Colors.orangeAccent.withValues(alpha: 0.4)),
                  ),
                  child: const Text(
                    'Buffer warming up',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),

              // ── Alert banner (full width, both modes) ────────────────────
              if (showAlert) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      vertical: 14, horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.redAccent, width: 2),
                  ),
                  child: const Text(
                    '⚠️ OPEN WINDOW — Ventilate the room',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Status badge ──────────────────────────────────────────────────────────
  Widget _statusBadge({
    required String icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$icon $label',
            style: TextStyle(
                color: color, fontWeight: FontWeight.bold, fontSize: 10),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ── Sensor card ───────────────────────────────────────────────────────────
  Widget _buildSensorCard(
      String title, String value, IconData icon, Color color) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 36, color: color),
            const SizedBox(height: 8),
            Text(title,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: color),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
