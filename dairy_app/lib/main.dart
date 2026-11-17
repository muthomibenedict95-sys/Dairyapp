import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

late Database db;
const uuid = Uuid();

// Must match API_KEY on the server.
const defaultServerUrl = 'http://192.168.1.100:8000'; // change in the app (gear icon)

int nowMs() => DateTime.now().millisecondsSinceEpoch;
String today() => DateTime.now().toIso8601String().substring(0, 10);

// Category rules: one place decides what each category can have.
const categories = ['cow', 'heifer', 'bull', 'calf'];
bool hasCalving(String c) => c == 'cow';
bool givesMilk(String c) => c == 'cow';
String categoryLabel(String c) => c[0].toUpperCase() + c.substring(1);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  db = await openDatabase(
    p.join(await getDatabasesPath(), 'dairy_v2.db'),
    version: 5,
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
          category TEXT NOT NULL DEFAULT 'cow',
          birth_date TEXT NOT NULL DEFAULT '',
          calving_date TEXT NOT NULL DEFAULT '',
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
      if (oldV < 5) {
        await d.execute("ALTER TABLE cows ADD COLUMN category TEXT NOT NULL DEFAULT 'cow'");
        await d.execute("ALTER TABLE cows ADD COLUMN birth_date TEXT NOT NULL DEFAULT ''");
        await d.execute("ALTER TABLE cows ADD COLUMN calving_date TEXT NOT NULL DEFAULT ''");
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
  Map<String, double> useToday = {};
  StreamSubscription<List<ConnectivityResult>>? _sub;

  @override
  void initState() {
    super.initState();
    load();
    initReminders();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final rows = await db.rawQuery('''
      SELECT c.id, c.name, c.tag, c.category,
        COALESCE(SUM(m.litres), 0) AS today,
        COALESCE(SUM(CASE WHEN m.session = 'morning' THEN m.litres END), 0) AS morning,
        COALESCE(SUM(CASE WHEN m.session = 'midday' THEN m.litres END), 0) AS midday,
        COALESCE(SUM(CASE WHEN m.session = 'evening' THEN m.litres END), 0) AS evening
      FROM cows c LEFT JOIN milk m ON m.cow_id = c.id AND m.date = ? AND m.deleted = 0
      WHERE c.deleted = 0
      GROUP BY c.id ORDER BY c.name''', [today()]);
    final useRows = await db.query('milk_use',
        columns: ['kind', 'litres'], where: 'date = ? AND deleted = 0', whereArgs: [today()]);
    final useMap = {
      for (final r in useRows) '${r['kind']}': (r['litres'] as num).toDouble()
    };
    final pc = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT (SELECT COUNT(*) FROM cows WHERE synced = 0) + (SELECT COUNT(*) FROM milk WHERE synced = 0)')) ??
        0;
    if (!mounted) return;
    setState(() {
      cows = rows;
      pending = pc;
      useToday = useMap;
    });
    scheduleReminders();
  }

  Future<void> syncNow({bool silent = false}) async {
    await load();
  }

  Future<void> addCow() async {
    final name = TextEditingController();
    final tag = TextEditingController();
    String category = 'cow';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setS) => AlertDialog(
          title: const Text('Add animal'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: tag, decoration: const InputDecoration(labelText: 'Tag number')),
            DropdownButtonFormField<String>(
              initialValue: category,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [for (final c in categories) DropdownMenuItem(value: c, child: Text(categoryLabel(c)))],
              onChanged: (v) => setS(() => category = v!),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      await db.insert('cows', {
        'id': uuid.v4(),
        'name': name.text.trim(),
        'tag': tag.text.trim(),
        'category': category,
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
    const dayLabels = ['Today', 'Yesterday', '2 days ago'];
    var daysBack = 0;
    var session = defaultSession();
    String dayOf(int back) =>
        DateTime.now().subtract(Duration(days: back)).toIso8601String().substring(0, 10);
    // A session is open once its start time has passed; past days are fully open.
    bool isOpen(String s) {
      if (daysBack > 0) return true;
      final h = DateTime.now().hour;
      return s == 'morning' || (s == 'midday' && h >= 10) || (s == 'evening' && h >= 15);
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Milk from $cowName'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 8, children: [
              for (var i = 0; i < dayLabels.length; i++)
                ChoiceChip(
                  label: Text(dayLabels[i]),
                  selected: daysBack == i,
                  onSelected: (_) => setLocal(() {
                    daysBack = i;
                    if (!isOpen(session)) session = 'morning';
                  }),
                ),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final s in ['morning', 'midday', 'evening'])
                ChoiceChip(
                  label: Text(s[0].toUpperCase() + s.substring(1)),
                  selected: session == s,
                  onSelected: isOpen(s) ? (_) => setLocal(() => session = s) : null,
                ),
            ]),
            if (daysBack == 0)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Midday opens at 10:00, evening at 15:00',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
              ),
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
    final date = dayOf(daysBack);
    final when = daysBack == 0 ? '' : ' for ${dayLabels[daysBack].toLowerCase()}';
    final existing = await db.query('milk',
        where: 'cow_id = ? AND session = ? AND date = ? AND deleted = 0',
        whereArgs: [cowId, session, date]);
    String msg;
    if (existing.isEmpty) {
      await db.insert('milk', {
        'id': uuid.v4(),
        'cow_id': cowId,
        'litres': value,
        'session': session,
        'date': date,
        'updated_at': nowMs(),
        'synced': 0,
        'deleted': 0,
      });
      msg = 'Saved $session milk$when';
    } else {
      await db.update('milk',
          {'litres': value, 'updated_at': nowMs(), 'synced': 0},
          where: 'id = ?', whereArgs: [existing.first['id']]);
      msg = 'Updated $session milk$when (was ${existing.first['litres']} L)';
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

  Future<void> remindersInfo() async {
    final android = notifier
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final allowed = await android?.areNotificationsEnabled() ?? true;
    final scheduled = (await notifier.pendingNotificationRequests()).length;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Milk reminders'),
        content: Text('Reminders at 6:00, 12:00 and 18:00.\n'
            'A reminder is skipped when every cow already has that session recorded.\n\n'
            '${allowed ? 'Notifications are allowed.' : 'Notifications are blocked. Allow them in the phone settings.'}\n$scheduled reminders scheduled.'),
        actions: [
          TextButton(
            onPressed: () {
              notifier.show(
                id: 99,
                title: 'Dairy App',
                body: 'Test reminder',
                notificationDetails: reminderDetails,
              );
              Navigator.pop(context);
            },
            child: const Text('Send test'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> accountMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.lock_reset),
            title: const Text('Change PIN'),
            onTap: () => Navigator.pop(context, 'pin'),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Log out'),
            onTap: () => Navigator.pop(context, 'logout'),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    if (choice == 'pin') await changePin();
    if (choice == 'logout') await logOut();
  }

  Future<void> logOut() async {
    await load();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Log out?'),
        content: Text(pending > 0
            ? '$pending records are not synced yet. They stay on this phone and will sync after you log in again.'
            : 'Your records stay on this phone. You will need your PIN to log in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Log out')),
        ],
      ),
    );
    if (ok == true) await setToken(null);
  }

  Future<void> changePin() async {
    final oldC = TextEditingController();
    final newC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Change PIN'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: oldC,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            decoration: const InputDecoration(labelText: 'Current PIN'),
          ),
          TextField(
            controller: newC,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 4,
            decoration: const InputDecoration(labelText: 'New 4-digit PIN'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    var msg = '';
    if (!RegExp(r'^\d{4}$').hasMatch(newC.text.trim())) {
      msg = 'New PIN must be 4 digits';
    } else {
      try {
        final token = await getToken();
        final res = await http
            .post(
              Uri.parse('${await getServerUrl()}/api/change_pin'),
              headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
              body: jsonEncode({'old_pin': oldC.text.trim(), 'new_pin': newC.text.trim()}),
            )
            .timeout(const Duration(seconds: 10));
        if (res.statusCode == 200) {
          msg = 'PIN changed';
        } else if (res.statusCode == 403) {
          msg = 'Current PIN is wrong';
        } else if (res.statusCode == 401) {
          msg = 'Please log in again';
        } else {
          msg = 'Could not change PIN (${res.statusCode})';
        }
      } catch (_) {
        msg = 'Server not reachable';
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

  Widget useField(TextEditingController c, String label) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      );

  Widget useCard(double produced) {
    final h = useToday['household'] ?? 0;
    final s = useToday['sold'] ?? 0;
    final sp = useToday['spoiled'] ?? 0;
    final left = produced - h - s - sp;
    String l(double v) => v.toStringAsFixed(1);
    final status = left.abs() < 0.05
        ? 'All milk accounted for'
        : left > 0
            ? '${l(left)} L not accounted for'
            : '${l(-left)} L more than recorded';
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: InkWell(
        onTap: editUse,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.local_drink),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Where did the milk go?',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              TextButton(
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const UseReportPage())),
                child: const Text('Report'),
              ),
            ]),
            Text('Household ${l(h)} L  •  Sold ${l(s)} L  •  Spoiled ${l(sp)} L'),
            const SizedBox(height: 2),
            Text(status,
                style: TextStyle(color: left > 0.05 ? Colors.orange.shade800 : null)),
          ]),
        ),
      ),
    );
  }

  Future<void> editUse() async {
    final produced = cows.fold<double>(0, (a, c) => a + (c['today'] as num).toDouble());
    final rows = await db.query('milk_use',
        where: 'date = ? AND deleted = 0', whereArgs: [today()]);
    Object? field(String kind, String col) {
      for (final r in rows) {
        if (r['kind'] == kind) return r[col];
      }
      return null;
    }

    String show(Object? v) {
      final n = v is num ? v.toDouble() : 0.0;
      return n == 0 ? '' : n.toString();
    }

    final household = TextEditingController(text: show(field('household', 'litres')));
    final sold = TextEditingController(text: show(field('sold', 'litres')));
    final spoiled = TextEditingController(text: show(field('spoiled', 'litres')));
    final price = TextEditingController(text: show(field('sold', 'price_per_litre')));
    if (!mounted) return;
    final left = ValueNotifier<double>(produced);
    void refresh() {
      double n(TextEditingController c) =>
          double.tryParse(c.text.trim().replaceAll(',', '.')) ?? 0.0;
      left.value = produced - (n(household) + n(sold) + n(spoiled));
    }
    for (final c in [household, sold, spoiled]) {
      c.addListener(refresh);
    }
    refresh();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Where did the milk go?'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Milk recorded today: ${produced.toStringAsFixed(1)} L'),
            ValueListenableBuilder<double>(
              valueListenable: left,
              builder: (_, l, _) => Text(
                l < -0.05
                    ? 'Too much: ${(-l).toStringAsFixed(1)} L more than was recorded. Reduce the amounts.'
                    : 'Left to account for: ${l.toStringAsFixed(1)} L',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: l < -0.05 ? Colors.red.shade700 : Colors.green.shade800),
              ),
            ),
            const SizedBox(height: 12),
            useField(household, 'Used in the household (L)'),
            const SizedBox(height: 8),
            useField(sold, 'Sold (L)'),
            const SizedBox(height: 8),
            useField(price, 'Price per litre sold (optional)'),
            const SizedBox(height: 8),
            useField(spoiled, 'Spoiled (L)'),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ValueListenableBuilder<double>(valueListenable: left, builder: (_, l, _) => FilledButton(onPressed: l < -0.05 ? null : () => Navigator.pop(context, true), child: const Text('Save'))),
        ],
      ),
    );
    if (ok != true) return;
    double? parse(TextEditingController c) {
      final t = c.text.trim().replaceAll(',', '.');
      if (t.isEmpty) return 0.0;
      final v = double.tryParse(t);
      return (v == null || v < 0) ? null : v;
    }

    final hVal = parse(household);
    final sVal = parse(sold);
    final spVal = parse(spoiled);
    final prVal = parse(price);
    if (hVal == null || sVal == null || spVal == null || prVal == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please enter valid numbers only')));
      }
      return;
    }
    final accounted = hVal + sVal + spVal;
    if (accounted > produced + 0.05) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('That is ${accounted.toStringAsFixed(1)} L but only ${produced.toStringAsFixed(1)} L was recorded today')));
      }
      return;
    }
    await saveMilkUse('household', hVal, null);
    await saveMilkUse('sold', sVal, prVal > 0 ? prVal : null);
    await saveMilkUse('spoiled', spVal, null);
    await load();
    syncNow(silent: true);
  }

  Widget cowCard(Map<String, Object?> c) {
    final id = '${c['id']}';
    final name = '${c['name']}';
    final tag = '${c['tag']}';
    final category = '${c['category'] ?? 'cow'}';
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
            Text(category == 'bull' ? '🐂' : category == 'calf' ? '🐮' : '🐄', style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                if (tag.isNotEmpty) Text('Tag $tag', style: const TextStyle(fontSize: 14)),
                Text(categoryLabel(category), style: const TextStyle(fontSize: 14, color: Colors.black54)),
              ]),
            ),
            IconButton(
              tooltip: 'Edit or remove',
              icon: const Icon(Icons.more_vert),
              onPressed: () => cowMenu(id, name, tag),
            ),
          ]),
          if (givesMilk(category)) ...[
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
                onPressed: givesMilk(category) ? () => addMilk(id, name) : null,
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
          ],
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
            tooltip: 'Reminders',
            icon: const Icon(Icons.notifications),
            onPressed: remindersInfo,
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
            "Today's milk: ${total.toStringAsFixed(1)} L",
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        useCard(total),
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
  double avg = 0, lastDay = 0;
  int dayCount = 0;

  Widget summary() {
    final low = dayCount >= 3 && lastDay <= avg * 0.8;
    final drop = avg > 0 ? ((avg - lastDay) / avg * 100).round() : 0;
    return Card(
      margin: const EdgeInsets.all(12),
      color: low ? Colors.red.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: dayCount < 3
            ? const Text('Not enough data yet: the 7-day average needs at least 3 full days of records.')
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('7-day average: ${avg.toStringAsFixed(1)} L per day', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                Text('Last full day: ${lastDay.toStringAsFixed(1)} L'),
                if (low) Text('Low milk: $drop% below average. Check this cow.', style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.bold)),
              ]),
      ),
    );
  }

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
    // Daily totals for completed days only (today is still in progress).
    final totals = <String, double>{};
    for (final r in rows) {
      final d = '${r['date']}';
      if (d == today()) continue;
      totals[d] = (totals[d] ?? 0) + (r['litres'] as num).toDouble();
    }
    final days = totals.keys.toList()..sort((a, b) => b.compareTo(a));
    final recent = days.take(7).toList();
    var a = 0.0, last = 0.0;
    if (recent.isNotEmpty) {
      a = recent.map((d) => totals[d]!).reduce((x, y) => x + y) / recent.length;
      last = totals[recent.first]!;
    }
    setState(() {
      records = rows;
      avg = a;
      lastDay = last;
      dayCount = recent.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.cowName)),
      body: records.isEmpty
          ? const Center(child: Text('No milk recorded yet.'))
          : ListView.builder(
              itemCount: records.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) return summary();
                final r = records[i - 1];
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
  mustChange.value = await getFlag('must_change');
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
          if (!v) return const LoginPage();
          return ValueListenableBuilder<bool>(
            valueListenable: mustChange,
            builder: (context, m, _) => m ? const ForcePinPage() : const HomePage(),
          );
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
        final body = jsonDecode(res.body);
        final token = body['token'] as String;
        final must = body['must_change'] == true;
        final blocked = await claimPhoneFor(body['farmer_id'] as String);
        if (blocked != null) {
          setState(() => error = blocked);
          return;
        }
        // Claim everything already on this phone for this farmer.
        await db.update('cows', {'synced': 0});
        await db.update('milk', {'synced': 0});
        await db.update('milk_use', {'synced': 0});
        await setFlag('must_change', must);
        mustChange.value = must;
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

// ---------- milk use (household / sold / spoiled) ----------
/// One record per kind per day: update it if it exists, otherwise create it.
Future<void> saveMilkUse(String kind, double litres, double? price) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final ex = await db.query('milk_use',
      where: 'date = ? AND kind = ?', whereArgs: [today(), kind]);
  if (ex.isEmpty) {
    if (litres == 0) return;
    await db.insert('milk_use', {
      'id': uuid.v4(),
      'date': today(),
      'kind': kind,
      'litres': litres,
      'price_per_litre': price,
      'updated_at': now,
      'synced': 0,
      'deleted': 0,
    });
  } else {
    await db.update(
        'milk_use',
        {
          'litres': litres,
          'price_per_litre': price,
          'updated_at': now,
          'synced': 0,
          'deleted': 0,
        },
        where: 'id = ?',
        whereArgs: [ex.first['id']]);
  }
}

class UseReportPage extends StatefulWidget {
  const UseReportPage({super.key});
  @override
  State<UseReportPage> createState() => _UseReportPageState();
}

class _UseReportPageState extends State<UseReportPage> {
  static const days = 14;
  List<Map<String, Object?>> rows = [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final dates = [
      for (var i = 0; i < days; i++)
        DateTime.now().subtract(Duration(days: i)).toIso8601String().substring(0, 10)
    ];
    final from = dates.last;
    final produced = await db.rawQuery(
        'SELECT date, SUM(litres) AS l FROM milk WHERE deleted = 0 AND date >= ? GROUP BY date',
        [from]);
    final uses = await db.rawQuery(
        'SELECT date, kind, SUM(litres) AS l, SUM(litres * COALESCE(price_per_litre, 0)) AS money '
        'FROM milk_use WHERE deleted = 0 AND date >= ? GROUP BY date, kind',
        [from]);
    final out = <Map<String, Object?>>[];
    for (final d in dates) {
      double prod = 0, h = 0, s = 0, sp = 0, money = 0;
      for (final r in produced) {
        if (r['date'] == d) prod += (r['l'] as num).toDouble();
      }
      for (final r in uses) {
        if (r['date'] != d) continue;
        final l = (r['l'] as num).toDouble();
        final k = '${r['kind']}';
        if (k == 'household') {
          h += l;
        } else if (k == 'sold') {
          s += l;
          money += (r['money'] as num).toDouble();
        } else if (k == 'spoiled') {
          sp += l;
        }
      }
      out.add({'date': d, 'prod': prod, 'h': h, 's': s, 'sp': sp, 'money': money});
    }
    if (!mounted) return;
    setState(() => rows = out);
  }

  Widget dayTile(Map<String, Object?> r) {
    double v(String k) => (r[k] as num).toDouble();
    String l(double x) => x.toStringAsFixed(1);
    final left = v('prod') - v('h') - v('s') - v('sp');
    return Card(
      child: ListTile(
        title: Text('${niceDate('${r['date']}')}  •  ${l(v('prod'))} L produced'),
        subtitle: Text([
          'Household ${l(v('h'))} L  •  Sold ${l(v('s'))} L  •  Spoiled ${l(v('sp'))} L',
          if (v('money') > 0) 'Income: KSh ${v('money').toStringAsFixed(0)}',
          if (v('prod') > 0 && left.abs() >= 0.05)
            (left > 0 ? '${l(left)} L not accounted for' : '${l(-left)} L more than recorded'),
        ].join('\n')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    double sum(String k) => rows.fold<double>(0, (a, r) => a + (r[k] as num).toDouble());
    String l(double x) => x.toStringAsFixed(1);
    return Scaffold(
      appBar: AppBar(title: const Text('Milk report')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Last $days days', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text('Produced ${l(sum('prod'))} L'),
              Text('Household ${l(sum('h'))} L'),
              Text('Sold ${l(sum('s'))} L'),
              Text('Spoiled ${l(sum('sp'))} L'),
              if (sum('money') > 0)
                Text('Income from sales: KSh ${sum('money').toStringAsFixed(0)}'),
            ]),
          ),
        ),
        for (final r in rows) dayTile(r),
      ]),
    );
  }
}

// ---------- reminders ----------
class ReminderSlot {
  final int id;
  final String session;
  final int hour;
  const ReminderSlot(this.id, this.session, this.hour);
}

const reminderSlots = [
  ReminderSlot(1, 'morning', 6),
  ReminderSlot(2, 'midday', 12),
  ReminderSlot(3, 'evening', 18),
];

final FlutterLocalNotificationsPlugin notifier = FlutterLocalNotificationsPlugin();

const reminderDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'milk_reminders',
    'Milk reminders',
    channelDescription: 'Reminders to record milk',
    importance: Importance.high,
    priority: Priority.high,
  ),
);

bool _remindersReady = false;

Future<void> initReminders() async {
  try {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Africa/Nairobi'));
    await notifier.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    await notifier
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _remindersReady = true;
    await scheduleReminders();
  } catch (_) {}
}

/// Schedules the three daily reminders. A session that already has a record
/// for every cow today is moved to tomorrow, so the farmer is not nagged.
Future<void> scheduleReminders() async {
  if (!_remindersReady) return;
  try {
    final now = tz.TZDateTime.now(tz.local);
    final cowCount = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM cows WHERE deleted = 0')) ??
        0;
    for (final slot in reminderSlots) {
      final recorded = Sqflite.firstIntValue(await db.rawQuery(
              'SELECT COUNT(DISTINCT cow_id) FROM milk WHERE date = ? AND session = ? AND deleted = 0',
              [today(), slot.session])) ??
          0;
      final done = cowCount == 0 || recorded >= cowCount;
      var when = tz.TZDateTime(tz.local, now.year, now.month, now.day, slot.hour);
      if (done || !when.isAfter(now)) {
        when = when.add(const Duration(days: 1));
      }
      await notifier.zonedSchedule(
        id: slot.id,
        scheduledDate: when,
        notificationDetails: reminderDetails,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        title: 'Dairy App',
        body: 'Time to record the ${slot.session} milk',
        matchDateTimeComponents: DateTimeComponents.time,
      );
    }
  } catch (_) {}
}

// ---------- forced PIN change (after an admin reset) ----------
final ValueNotifier<bool> mustChange = ValueNotifier<bool>(false);

Future<bool> getFlag(String key) async {
  final r = await db.query('settings', where: 'key = ?', whereArgs: [key]);
  return r.isNotEmpty && r.first['value'] == '1';
}

Future<void> setFlag(String key, bool v) async {
  await db.insert('settings', {'key': key, 'value': v ? '1' : '0'},
      conflictAlgorithm: ConflictAlgorithm.replace);
}

class ForcePinPage extends StatefulWidget {
  const ForcePinPage({super.key});
  @override
  State<ForcePinPage> createState() => _ForcePinPageState();
}

class _ForcePinPageState extends State<ForcePinPage> {
  final oldC = TextEditingController();
  final newC = TextEditingController();
  final againC = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    oldC.dispose();
    newC.dispose();
    againC.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final o = oldC.text.trim();
    final n = newC.text.trim();
    final a = againC.text.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(n)) {
      setState(() => error = 'New PIN must be 4 digits');
      return;
    }
    if (n != a) {
      setState(() => error = 'The two new PINs do not match');
      return;
    }
    if (n == o) {
      setState(() => error = 'Choose a PIN different from the temporary one');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final token = await getToken();
      final res = await http
          .post(
            Uri.parse('${await getServerUrl()}/api/change_pin'),
            headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
            body: jsonEncode({'old_pin': o, 'new_pin': n}),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        await setFlag('must_change', false);
        mustChange.value = false;
        return;
      }
      if (res.statusCode == 401) {
        await setToken(null);
        return;
      }
      String detail = 'Could not change PIN (${res.statusCode})';
      if (res.statusCode == 403) {
        detail = 'The temporary PIN is wrong';
      }
      setState(() => error = detail);
    } catch (_) {
      setState(() => error = 'Server not reachable. Try again when you are online.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: Scaffold(
          appBar: AppBar(title: const Text('Choose a new PIN')),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                  'Your administrator gave you a temporary PIN. Choose your own 4-digit PIN to continue.'),
              const SizedBox(height: 16),
              TextField(
                controller: oldC,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 4,
                decoration: const InputDecoration(
                    labelText: 'Temporary PIN', border: OutlineInputBorder()),
              ),
              TextField(
                controller: newC,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 4,
                decoration: const InputDecoration(
                    labelText: 'New 4-digit PIN', border: OutlineInputBorder()),
              ),
              TextField(
                controller: againC,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 4,
                decoration: const InputDecoration(
                    labelText: 'New PIN again', border: OutlineInputBorder()),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: busy ? null : submit,
                child: Text(busy ? 'Please wait...' : 'Save new PIN'),
              ),
              TextButton(
                onPressed: busy ? null : () => setToken(null),
                child: const Text('Log out'),
              ),
            ],
          ),
        ),
      );
}

// ---------- one farmer per phone ----------
Future<String?> getSetting(String key) async {
  final r = await db.query('settings', where: 'key = ?', whereArgs: [key]);
  return r.isEmpty ? null : r.first['value'] as String;
}

Future<void> setSetting(String key, String value) async {
  await db.insert('settings', {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace);
}

/// Returns an error message when another farmer's unsynced records block this
/// login. Otherwise returns null. A different farmer logging in clears this
/// phone's local copy: everything synced stays safe on the server.
Future<String?> claimPhoneFor(String farmerId) async {
  final owner = await getSetting('owner_id');
  if (owner != null && owner != farmerId) {
    final unsynced = Sqflite.firstIntValue(await db.rawQuery(
            'SELECT (SELECT COUNT(*) FROM cows WHERE synced = 0) + '
            '(SELECT COUNT(*) FROM milk WHERE synced = 0) + '
            '(SELECT COUNT(*) FROM milk_use WHERE synced = 0)')) ??
        0;
    if (unsynced > 0) {
      return 'This phone holds unsynced records of another farmer. Log in as that farmer and sync first.';
    }
    await db.delete('milk');
    await db.delete('milk_use');
    await db.delete('cows');
  }
  await setSetting('owner_id', farmerId);
  return null;
}
