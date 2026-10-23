import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

late Database db;
const uuid = Uuid();

// Must match API_KEY on the server.
const apiKey = 'change-me-secret-key';
const defaultServerUrl = 'http://192.168.1.100:8000'; // change in the app (gear icon)

int nowMs() => DateTime.now().millisecondsSinceEpoch;
String today() => DateTime.now().toIso8601String().substring(0, 10);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  db = await openDatabase(
    p.join(await getDatabasesPath(), 'dairy_v2.db'),
    version: 2,
    onCreate: (d, v) async {
      // id is a UUID made on the phone; synced: 0 = pending, 1 = on server.
      await d.execute('''
        CREATE TABLE cows(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          tag TEXT NOT NULL DEFAULT '',
          updated_at INTEGER NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0,
          deleted INTEGER NOT NULL DEFAULT 0
        )''');
      await d.execute('''
        CREATE TABLE milk(
          id TEXT PRIMARY KEY,
          cow_id TEXT NOT NULL,
          litres REAL NOT NULL,
          session TEXT NOT NULL,
          date TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0,
          deleted INTEGER NOT NULL DEFAULT 0
        )''');
      await d.execute('CREATE INDEX idx_milk_synced ON milk(synced)');
      await d.execute('CREATE INDEX idx_cows_synced ON cows(synced)');
      await d.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
    },
    onUpgrade: (d, oldV, newV) async {
      if (oldV < 2) {
        await d.execute('ALTER TABLE cows ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0');
        await d.execute('ALTER TABLE milk ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0');
      }
    },
  );
  runApp(const DairyApp());
}

// ---------- settings ----------
Future<String> getServerUrl() async {
  final r = await db.query('settings', where: 'key = ?', whereArgs: ['server_url']);
  return r.isEmpty ? defaultServerUrl : r.first['value'] as String;
}

Future<void> setServerUrl(String url) async {
  await db.insert('settings', {'key': 'server_url', 'value': url},
      conflictAlgorithm: ConflictAlgorithm.replace);
}

// ---------- sync ----------
class SyncService {
  static bool _running = false;

  /// Sends every unsynced cow and milk record to the server in one batch.
  static Future<String> sync() async {
    if (_running) return 'Sync already running';
    _running = true;
    try {
      final cows = await db.query('cows', where: 'synced = 0');
      final milk = await db.query('milk', where: 'synced = 0');
      if (cows.isEmpty && milk.isEmpty) return 'Everything is already synced';

      final url = Uri.parse('${await getServerUrl()}/api/sync');
      final res = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json', 'X-API-Key': apiKey},
            body: jsonEncode({'cows': cows, 'milk': milk}),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200 && jsonDecode(res.body)['success'] == true) {
        // Only mark rows synced if they were not edited while sending.
        final batch = db.batch();
        for (final c in cows) {
          batch.update('cows', {'synced': 1},
              where: 'id = ? AND updated_at = ?', whereArgs: [c['id'], c['updated_at']]);
        }
        for (final m in milk) {
          batch.update('milk', {'synced': 1},
              where: 'id = ? AND updated_at = ?', whereArgs: [m['id'], m['updated_at']]);
        }
        await batch.commit(noResult: true);
        return 'Synced ${cows.length} cows and ${milk.length} milk records';
      }
      return 'Server error (${res.statusCode})';
    } on TimeoutException {
      return 'Server not reachable (timed out)';
    } catch (e) {
      return 'Sync failed: $e';
    } finally {
      _running = false;
    }
  }
}

// ---------- UI ----------
class DairyApp extends StatelessWidget {
  const DairyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Dairy App',
        theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, Object?>> cows = [];
  int pending = 0;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  @override
  void initState() {
    super.initState();
    load();
    // Automatic sync whenever the phone gets a network connection.
    _sub = Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) syncNow(silent: true);
    });
    syncNow(silent: true);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final rows = await db.rawQuery('''
      SELECT c.id, c.name, c.tag, COALESCE(SUM(m.litres), 0) AS today
      FROM cows c LEFT JOIN milk m ON m.cow_id = c.id AND m.date = ?
      GROUP BY c.id ORDER BY c.name''', [today()]);
    final pc = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT (SELECT COUNT(*) FROM cows WHERE synced = 0) + (SELECT COUNT(*) FROM milk WHERE synced = 0)')) ??
        0;
    if (!mounted) return;
    setState(() {
      cows = rows;
      pending = pc;
    });
  }

  Future<void> syncNow({bool silent = false}) async {
    final msg = await SyncService.sync();
    await load();
    if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> addCow() async {
    final name = TextEditingController();
    final tag = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add cow'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
          TextField(controller: tag, decoration: const InputDecoration(labelText: 'Tag number')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      await db.insert('cows', {
        'id': uuid.v4(),
        'name': name.text.trim(),
        'tag': tag.text.trim(),
        'updated_at': nowMs(),
        'synced': 0,
      });
      await load();
      syncNow(silent: true);
    }
  }

  Future<void> addMilk(String cowId, String cowName) async {
    final litres = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Milk from $cowName'),
        content: TextField(
          controller: litres,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Litres'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    final value = double.tryParse(litres.text);
    if (ok == true && value != null) {
      await db.insert('milk', {
        'id': uuid.v4(),
        'cow_id': cowId,
        'litres': value,
        'session': DateTime.now().hour < 12 ? 'morning' : 'evening',
        'date': today(),
        'updated_at': nowMs(),
        'synced': 0,
      });
      await load();
      syncNow(silent: true);
    }
  }

  Future<void> editServer() async {
    final c = TextEditingController(text: await getServerUrl());
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Server address'),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
              labelText: 'URL', hintText: 'http://192.168.1.100:8000'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok == true) {
      await setServerUrl(c.text.trim().replaceAll(RegExp(r'/+$'), ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = cows.fold<double>(0, (s, c) => s + (c['today'] as num).toDouble());
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Cows'),
        actions: [
          IconButton(
            tooltip: 'Server address',
            icon: const Icon(Icons.settings),
            onPressed: editServer,
          ),
          IconButton(
            tooltip: 'Sync now',
            onPressed: () => syncNow(),
            icon: Badge(
              isLabelVisible: pending > 0,
              label: Text('$pending'),
              child: const Icon(Icons.cloud_upload),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: addCow,
        icon: const Icon(Icons.add),
        label: const Text('Add cow'),
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            "Today's milk: ${total.toStringAsFixed(1)} L"
            '${pending > 0 ? '   •   $pending waiting to sync' : '   •   all synced'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Expanded(
          child: cows.isEmpty
              ? const Center(child: Text('No cows yet. Tap "Add cow".'))
              : ListView(children: [
                  for (final c in cows)
                    ListTile(
                      leading: const Icon(Icons.pets),
                      title: Text('${c['name']}'),
                      subtitle: Text('Tag: ${c['tag']}'),
                      trailing: Text('${(c['today'] as num).toStringAsFixed(1)} L'),
                      onTap: () => addMilk('${c['id']}', '${c['name']}'),
                    ),
                ]),
        ),
      ]),
    );
  }
}
