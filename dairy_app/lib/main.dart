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
const defaultServerUrl = 'http://192.168.1.100:8000'; // change in the app (gear icon)

int nowMs() => DateTime.now().millisecondsSinceEpoch;
String today() => DateTime.now().toIso8601String().substring(0, 10);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  db = await openDatabase(
    p.join(await getDatabasesPath(), 'dairy_v2.db'),
    version: 4,
    onCreate: (d, v) async {
      // id is a UUID made on the phone; synced: 0 = pending, 1 = on server.
      await d.execute('''
        CREATE TABLE cows(
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          tag TEXT NOT NULL DEFAULT '',
          updated_at INTEGER NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0,
          removed_reason TEXT NOT NULL DEFAULT '',
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
      await d.execute('CREATE TABLE milk_use(id TEXT PRIMARY KEY, date TEXT NOT NULL, kind TEXT NOT NULL, litres REAL NOT NULL, price_per_litre REAL, updated_at INTEGER NOT NULL, synced INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)');
      await d.execute('CREATE INDEX idx_use_synced ON milk_use(synced)');
    },
    onUpgrade: (d, oldV, newV) async {
      if (oldV < 2) {
        await d.execute('ALTER TABLE cows ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0');
        await d.execute('ALTER TABLE milk ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0');
      }
      if (oldV < 4) {
        await d.execute('CREATE TABLE milk_use(id TEXT PRIMARY KEY, date TEXT NOT NULL, kind TEXT NOT NULL, litres REAL NOT NULL, price_per_litre REAL, updated_at INTEGER NOT NULL, synced INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)');
        await d.execute('CREATE INDEX idx_use_synced ON milk_use(synced)');
      }
      if (oldV < 3) {
        await d.execute("ALTER TABLE cows ADD COLUMN removed_reason TEXT NOT NULL DEFAULT ''");
      }
    },
  );
  await loadAuthState();
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
      final uses = await db.query('milk_use', where: 'synced = 0');
      if (cows.isEmpty && milk.isEmpty && uses.isEmpty) return 'Everything is already synced';

      final token = await getToken();
      if (token == null) return 'Please log in';
      final url = Uri.parse('${await getServerUrl()}/api/sync');
      final res = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'cows': cows, 'milk': milk, 'milk_use': uses}),
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
        for (final u in uses) {
          batch.update('milk_use', {'synced': 1},
              where: 'id = ? AND updated_at = ?', whereArgs: [u['id'], u['updated_at']]);
        }
        await batch.commit(noResult: true);
        return 'Synced ${cows.length} cows and ${milk.length} milk records';
      }
      if (res.statusCode == 401) {
        await setToken(null);
        return 'Please log in again';
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
        home: const AuthGate(),
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
      SELECT c.id, c.name, c.tag,
        COALESCE(SUM(m.litres), 0) AS today,
        COALESCE(SUM(CASE WHEN m.session = 'morning' THEN m.litres END), 0) AS morning,
        COALESCE(SUM(CASE WHEN m.session = 'midday' THEN m.litres END), 0) AS midday,
        COALESCE(SUM(CASE WHEN m.session = 'evening' THEN m.litres END), 0) AS evening
      FROM cows c LEFT JOIN milk m ON m.cow_id = c.id AND m.date = ? AND m.deleted = 0
      WHERE c.deleted = 0
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

  String defaultSession() {
    final h = DateTime.now().hour;
    if (h < 10) return 'morning';
    if (h < 15) return 'midday';
    return 'evening';
  }

  Future<void> addMilk(String cowId, String cowName) async {
    final litres = TextEditingController();
    var session = defaultSession();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Milk from $cowName'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 8, children: [
              for (final s in ['morning', 'midday', 'evening'])
                ChoiceChip(
                  label: Text(s[0].toUpperCase() + s.substring(1)),
                  selected: session == s,
                  onSelected: (_) => setLocal(() => session = s),
                ),
            ]),
            TextField(
              controller: litres,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Litres'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final value = double.tryParse(litres.text.trim().replaceAll(',', '.'));
    if (value == null || value <= 0 || value > 50) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter litres between 0 and 50')));
      return;
    }
    final existing = await db.query('milk',
        where: 'cow_id = ? AND session = ? AND date = ? AND deleted = 0',
        whereArgs: [cowId, session, today()]);
    String msg;
    if (existing.isEmpty) {
      await db.insert('milk', {
        'id': uuid.v4(),
        'cow_id': cowId,
        'litres': value,
        'session': session,
        'date': today(),
        'updated_at': nowMs(),
        'synced': 0,
        'deleted': 0,
      });
      msg = 'Saved $session milk';
    } else {
      await db.update('milk',
          {'litres': value, 'updated_at': nowMs(), 'synced': 0},
          where: 'id = ?', whereArgs: [existing.first['id']]);
      msg = 'Updated $session milk (was ${existing.first['litres']} L)';
    }
    await load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
    syncNow(silent: true);
  }

  Future<void> cowMenu(String id, String name, String tag) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.edit),
            title: Text('Edit $name'),
            onTap: () => Navigator.pop(context, 'edit'),
          ),
          ListTile(
            leading: const Icon(Icons.delete),
            title: Text('Remove $name'),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    if (choice == 'edit') await editCow(id, name, tag);
    if (choice == 'delete') await deleteCow(id, name);
  }

  Future<void> editCow(String id, String name, String tag) async {
    final n = TextEditingController(text: name);
    final t = TextEditingController(text: tag);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Edit cow'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: n, decoration: const InputDecoration(labelText: 'Name')),
          TextField(controller: t, decoration: const InputDecoration(labelText: 'Tag number')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || n.text.trim().isEmpty) return;
    await db.update(
        'cows',
        {'name': n.text.trim(), 'tag': t.text.trim(), 'updated_at': nowMs(), 'synced': 0},
        where: 'id = ?',
        whereArgs: [id]);
    await load();
    syncNow(silent: true);
  }

  Future<void> deleteCow(String id, String name) async {
    String? reason;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Remove $name?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Why is she leaving the herd?'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final r in ['sold', 'died', 'other'])
                  ChoiceChip(
                    label: Text(r[0].toUpperCase() + r.substring(1)),
                    selected: reason == r,
                    onSelected: (_) => setLocal(() => reason = r),
                  ),
              ]),
              const SizedBox(height: 12),
              const Text('Her milk records stay in your history.'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: reason == null ? null : () => Navigator.pop(context, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || reason == null) return;
    await db.update(
        'cows',
        {'deleted': 1, 'removed_reason': reason, 'updated_at': nowMs(), 'synced': 0},
        where: 'id = ?',
        whereArgs: [id]);
    await load();
    syncNow(silent: true);
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

  Widget cowCard(Map<String, Object?> c) {
    final id = '${c['id']}';
    final name = '${c['name']}';
    final tag = '${c['tag']}';
    double v(String k) => (c[k] as num).toDouble();

    Widget slot(String label, double litres) {
      final done = litres > 0;
      return Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: done ? Colors.green.shade100 : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            Text(done ? '${litres.toStringAsFixed(1)} L' : '-',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ]),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.pets, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                if (tag.isNotEmpty) Text('Tag $tag', style: const TextStyle(fontSize: 14)),
              ]),
            ),
            IconButton(
              tooltip: 'Edit or remove',
              icon: const Icon(Icons.more_vert),
              onPressed: () => cowMenu(id, name, tag),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            slot('Morning', v('morning')),
            slot('Midday', v('midday')),
            slot('Evening', v('evening')),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => addMilk(id, name),
                icon: const Icon(Icons.add),
                label: const Text('Add milk'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => CowPage(cowId: id, cowName: name))),
                icon: const Icon(Icons.history),
                label: const Text('History'),
              ),
            ),
          ]),
        ]),
      ),
    );
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
                  for (final c in cows) cowCard(c),
                ]),
        ),
      ]),
    );
  }
}


String niceDate(String d) {
  if (d == today()) return 'Today';
  final y = DateTime.now().subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
  if (d == y) return 'Yesterday';
  return d;
}

class CowPage extends StatefulWidget {
  final String cowId;
  final String cowName;
  const CowPage({super.key, required this.cowId, required this.cowName});
  @override
  State<CowPage> createState() => _CowPageState();
}

class _CowPageState extends State<CowPage> {
  List<Map<String, Object?>> records = [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final rows = await db.query(
      'milk',
      where: 'cow_id = ? AND deleted = 0',
      whereArgs: [widget.cowId],
      orderBy: "date DESC, CASE session WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 ELSE 1 END DESC",
    );
    if (!mounted) return;
    setState(() => records = rows);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.cowName)),
      body: records.isEmpty
          ? const Center(child: Text('No milk recorded yet.'))
          : ListView.builder(
              itemCount: records.length,
              itemBuilder: (context, i) {
                final r = records[i];
                final session = '${r['session']}';
                return ListTile(
                  leading: const Icon(Icons.water_drop),
                  title: Text('${(r['litres'] as num).toStringAsFixed(1)} L',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      '${niceDate('${r['date']}')}  -  ${session[0].toUpperCase()}${session.substring(1)}'),
                );
              },
            ),
    );
  }
}

// ---------- login ----------
final ValueNotifier<bool?> authState = ValueNotifier<bool?>(null);

Future<String?> getToken() async {
  final r = await db.query('settings', where: 'key = ?', whereArgs: ['auth_token']);
  return r.isEmpty ? null : r.first['value'] as String;
}

Future<void> setToken(String? token) async {
  if (token == null) {
    await db.delete('settings', where: 'key = ?', whereArgs: ['auth_token']);
  } else {
    await db.insert('settings', {'key': 'auth_token', 'value': token},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
  authState.value = token != null;
}

Future<void> loadAuthState() async {
  authState.value = (await getToken()) != null;
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool?>(
        valueListenable: authState,
        builder: (context, v, _) {
          if (v == null) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return v ? const HomePage() : const LoginPage();
        },
      );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final phone = TextEditingController();
  final pin = TextEditingController();
  final url = TextEditingController();
  bool registering = false;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    getServerUrl().then((u) => url.text = u);
  }

  @override
  void dispose() {
    phone.dispose();
    pin.dispose();
    url.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final p = phone.text.trim();
    final c = pin.text.trim();
    if (p.isEmpty) {
      setState(() => error = 'Enter your phone number');
      return;
    }
    if (!RegExp(r'^\d{4}$').hasMatch(c)) {
      setState(() => error = 'PIN must be 4 digits');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final base = url.text.trim().replaceAll(RegExp(r'/+$'), '');
      await setServerUrl(base);
      final res = await http
          .post(
            Uri.parse('$base/api/${registering ? 'register' : 'login'}'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'phone': p, 'pin': c}),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final token = jsonDecode(res.body)['token'] as String;
        // Claim everything already on this phone for this farmer.
        await db.update('cows', {'synced': 0});
        await db.update('milk', {'synced': 0});
        await db.update('milk_use', {'synced': 0});
        await setToken(token);
        return;
      }
      String detail = 'Something went wrong (${res.statusCode})';
      try {
        final d = jsonDecode(res.body)['detail'];
        if (d is String) detail = d;
      } catch (_) {}
      setState(() => error = detail);
    } on TimeoutException {
      setState(() => error = 'Server not reachable. Check the address and your network.');
    } catch (_) {
      setState(() => error = 'Could not connect. Check the address and your network.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Dairy App')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(registering ? 'Create your account' : 'Log in',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 16),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'Phone number', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pin,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 4,
              decoration: const InputDecoration(
                  labelText: '4-digit PIN', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                  labelText: 'Server address', border: OutlineInputBorder()),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : submit,
              child: Text(busy ? 'Please wait...' : (registering ? 'Register' : 'Log in')),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                        registering = !registering;
                        error = null;
                      }),
              child: Text(registering ? 'I already have an account' : 'New farmer? Register'),
            ),
            if (!registering)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Forgot your PIN? Contact your administrator.',
                    textAlign: TextAlign.center),
              ),
          ],
        ),
      );
}
