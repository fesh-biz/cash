import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../logic/credits.dart';
import '../util/format.dart';
import 'hlc.dart';
import 'models.dart';
import 'record.dart';

/// Курсоры синхронизации с конкретным устройством.
class PeerCursor {
  PeerCursor({this.pull = 0, this.push = 0});

  /// До какого seq мы уже забрали изменения с того устройства.
  int pull;

  /// До какого нашего seq мы уже отправили изменения на то устройство.
  int push;

  Map<String, dynamic> toJson() => {'pull': pull, 'push': push};

  static PeerCursor fromJson(Object? j) {
    if (j is! Map) return PeerCursor();
    return PeerCursor(
      pull: (j['pull'] as num?)?.toInt() ?? 0,
      push: (j['push'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Запомненное устройство для синхронизации.
class KnownPeer {
  KnownPeer({required this.id, required this.name, required this.host, required this.port, this.lastSync});

  final String id;
  String name;
  String host;
  int port;
  int? lastSync;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        if (lastSync != null) 'lastSync': lastSync,
      };

  static KnownPeer? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final host = j['host'];
    if (id is! String || host is! String) return null;
    return KnownPeer(
      id: id,
      name: j['name'] is String ? j['name'] as String : id,
      host: host,
      port: (j['port'] as num?)?.toInt() ?? 47800,
      lastSync: (j['lastSync'] as num?)?.toInt(),
    );
  }
}

/// Локальные (не синхронизируемые) настройки устройства.
class LocalSettings {
  String deviceName = '';
  String syncKey = '';
  bool autoSync = true;
  final List<String> manualHosts = [];
  final Map<String, KnownPeer> knownPeers = {};
  final Map<String, PeerCursor> cursors = {};

  PeerCursor cursorFor(String peerId) => cursors.putIfAbsent(peerId, () => PeerCursor());

  Map<String, dynamic> toJson() => {
        'deviceName': deviceName,
        'syncKey': syncKey,
        'autoSync': autoSync,
        'manualHosts': manualHosts,
        'knownPeers': knownPeers.values.map((p) => p.toJson()).toList(),
        'cursors': cursors.map((k, v) => MapEntry(k, v.toJson())),
      };

  void load(Object? j) {
    if (j is! Map) return;
    deviceName = j['deviceName'] is String ? j['deviceName'] as String : '';
    syncKey = j['syncKey'] is String ? j['syncKey'] as String : '';
    autoSync = j['autoSync'] != false;
    final mh = j['manualHosts'];
    if (mh is List) manualHosts.addAll(mh.whereType<String>());
    final kp = j['knownPeers'];
    if (kp is List) {
      for (final e in kp) {
        final p = KnownPeer.fromJson(e);
        if (p != null) knownPeers[p.id] = p;
      }
    }
    final c = j['cursors'];
    if (c is Map) {
      c.forEach((k, v) {
        if (k is String) cursors[k] = PeerCursor.fromJson(v);
      });
    }
  }
}

/// Хранилище данных: все записи в памяти + JSON-файл на диске.
///
/// Объём данных у личного бюджета небольшой (сотни–тысячи записей в год),
/// поэтому одного файла достаточно; запись идёт атомарно через временный файл.
class Store extends ChangeNotifier {
  Store._(this._file);

  /// Хранилище без файла — для тестов.
  factory Store.inMemory({String deviceId = 'test'}) {
    final s = Store._(null);
    s._deviceId = deviceId;
    s._hlc = Hlc(deviceId);
    s.settings.deviceName = deviceId;
    return s;
  }

  static Future<Store> open() async {
    Directory dir;
    try {
      dir = await getApplicationSupportDirectory();
    } catch (_) {
      dir = Directory.current;
    }
    await dir.create(recursive: true);
    final s = Store._(File('${dir.path}${Platform.pathSeparator}cash_data.json'));
    await s._load();
    return s;
  }

  final File? _file;
  late String _deviceId;
  late Hlc _hlc;
  int _seq = 0;
  final Map<String, SyncRecord> _records = {};
  final LocalSettings settings = LocalSettings();
  final StreamController<void> _localChanges = StreamController<void>.broadcast();

  String get deviceId => _deviceId;

  /// Текущий локальный номер изменения.
  int get seq => _seq;

  /// Срабатывает при каждой локальной правке (для автосинхронизации).
  Stream<void> get localChanges => _localChanges.stream;

  String? get dataPath => _file?.path;

  // ---------------------------------------------------------------- загрузка

  Future<void> _load() async {
    final f = _file!;
    Map<String, dynamic>? json;
    for (final candidate in [f, File('${f.path}.bak')]) {
      try {
        if (await candidate.exists()) {
          final decoded = jsonDecode(await candidate.readAsString());
          if (decoded is Map<String, dynamic>) {
            json = decoded;
            break;
          }
        }
      } catch (e) {
        debugPrint('Не удалось прочитать ${candidate.path}: $e');
      }
    }

    if (json == null) {
      _deviceId = _randomHex(12);
      _hlc = Hlc(_deviceId);
      settings.deviceName = _defaultDeviceName();
      await _writeNow();
      return;
    }

    // Резервная копия последней удачно прочитанной версии.
    try {
      if (await f.exists()) await f.copy('${f.path}.bak');
    } catch (_) {}

    _deviceId = json['deviceId'] is String ? json['deviceId'] as String : _randomHex(12);
    final h = json['hlc'];
    _hlc = Hlc(
      _deviceId,
      millis: h is Map ? (h['m'] as num?)?.toInt() ?? 0 : 0,
      counter: h is Map ? (h['c'] as num?)?.toInt() ?? 0 : 0,
    );
    _seq = (json['seq'] as num?)?.toInt() ?? 0;
    settings.load(json['settings']);
    if (settings.deviceName.isEmpty) settings.deviceName = _defaultDeviceName();
    final recs = json['records'];
    if (recs is List) {
      for (final e in recs) {
        final r = SyncRecord.tryFromJson(e);
        if (r == null) continue;
        _records[r.id] = r;
        if (r.seq > _seq) _seq = r.seq;
      }
    }
  }

  static String _defaultDeviceName() {
    if (Platform.isWindows) {
      try {
        return 'ПК ${Platform.localHostname}';
      } catch (_) {
        return 'Компьютер';
      }
    }
    if (Platform.isAndroid || Platform.isIOS) return 'Телефон';
    return 'Устройство';
  }

  // ---------------------------------------------------------------- запись

  Timer? _saveTimer;
  bool _saving = false;
  bool _savePending = false;

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_save());
    });
  }

  /// Немедленно сохранить (при сворачивании/закрытии приложения).
  Future<void> flush() async {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      await _save();
    }
  }

  Future<void> _save() async {
    if (_saving) {
      _savePending = true;
      return;
    }
    _saving = true;
    try {
      do {
        _savePending = false;
        await _writeNow();
      } while (_savePending);
    } catch (e) {
      debugPrint('Ошибка сохранения: $e');
    } finally {
      _saving = false;
    }
  }

  Map<String, dynamic> _toJson() => {
        'format': 1,
        'deviceId': _deviceId,
        'seq': _seq,
        'hlc': {'m': _hlc.millis, 'c': _hlc.counter},
        'settings': settings.toJson(),
        'records': _records.values.map((r) => r.toJson(withSeq: true)).toList(),
      };

  Future<void> _writeNow() async {
    final f = _file;
    if (f == null) return;
    final text = jsonEncode(_toJson());
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    try {
      await tmp.rename(f.path);
    } on FileSystemException {
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
    }
  }

  /// Сохранить изменения локальных настроек.
  void saveSettings({bool notify = true}) {
    _scheduleSave();
    if (notify) notifyListeners();
  }

  // ---------------------------------------------------------------- записи

  static final Random _rnd = Random.secure();

  static String _randomHex(int bytes) {
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(_rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Новый уникальный id.
  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_randomHex(5)}';

  void _changed({required bool local}) {
    notifyListeners();
    _scheduleSave();
    if (local) _localChanges.add(null);
  }

  /// Создать или изменить запись.
  void put(String type, String id, Map<String, dynamic> data) {
    _records[id] = SyncRecord(id: id, type: type, hlc: _hlc.now(), data: data, seq: ++_seq);
    _changed(local: true);
  }

  /// Удалить запись (с возможностью отмены через [restore]).
  void remove(String id) {
    final r = _records[id];
    if (r == null || r.deleted) return;
    _records[id] = SyncRecord(
      id: id,
      type: r.type,
      hlc: _hlc.now(),
      data: r.data,
      deleted: true,
      seq: ++_seq,
    );
    _changed(local: true);
  }

  /// Отменить удаление.
  void restore(String id) {
    final r = _records[id];
    if (r == null || !r.deleted) return;
    put(r.type, id, Map<String, dynamic>.from(r.data));
  }

  /// Несколько правок как одна (одно уведомление интерфейса).
  void batch(void Function() body) {
    _batchDepth++;
    try {
      body();
    } finally {
      _batchDepth--;
    }
    if (_batchDepth == 0 && _batchDirty) {
      _batchDirty = false;
      _changed(local: true);
    }
  }

  int _batchDepth = 0;
  bool _batchDirty = false;

  void _putQuiet(String type, String id, Map<String, dynamic> data, {bool deleted = false}) {
    _records[id] = SyncRecord(
      id: id,
      type: type,
      hlc: _hlc.now(),
      data: data,
      deleted: deleted,
      seq: ++_seq,
    );
    if (_batchDepth > 0) {
      _batchDirty = true;
    } else {
      _changed(local: true);
    }
  }

  // ------------------------------------------------------------ синхронизация

  /// Изменения с номером больше [since] (для отправки другому устройству).
  List<SyncRecord> changesSince(int since, {int? upTo}) {
    final list = _records.values
        .where((r) => r.seq > since && (upTo == null || r.seq <= upTo))
        .toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    return list;
  }

  /// Слить записи, полученные с другого устройства. Возвращает число принятых.
  int mergeRemote(Iterable<SyncRecord> incoming) {
    var n = 0;
    for (final r in incoming) {
      _hlc.observe(r.hlc);
      final local = _records[r.id];
      if (local == null || r.hlc.compareTo(local.hlc) > 0) {
        r.seq = ++_seq;
        _records[r.id] = r;
        n++;
      }
    }
    if (n > 0) _changed(local: false);
    return n;
  }

  // ------------------------------------------------------------ запросы

  Iterable<SyncRecord> _live(String type) =>
      _records.values.where((r) => !r.deleted && r.type == type);

  List<Period> get periods {
    final list = _live(RecType.period).map(Period.fromRecord).whereType<Period>().toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return list;
  }

  Period? periodById(String? id) {
    if (id == null) return null;
    final r = _records[id];
    if (r == null || r.deleted || r.type != RecType.period) return null;
    return Period.fromRecord(r);
  }

  Period? periodFor(DateTime date) {
    for (final p in periods) {
      if (p.contains(date)) return p;
    }
    return null;
  }

  /// Период «по умолчанию»: текущий по дате, иначе ближайший прошедший,
  /// иначе первый будущий.
  Period? defaultPeriod(DateTime now) {
    final all = periods;
    if (all.isEmpty) return null;
    for (final p in all) {
      if (p.contains(now)) return p;
    }
    Period? past;
    for (final p in all) {
      if (p.end.isBefore(now)) past = p;
    }
    return past ?? all.first;
  }

  List<FixedExpense> fixedOf(String periodId) {
    final list = _live(RecType.fixed)
        .map(FixedExpense.fromRecord)
        .where((f) => f.periodId == periodId)
        .toList()
      ..sort((a, b) => a.order != b.order ? a.order.compareTo(b.order) : a.name.compareTo(b.name));
    return list;
  }

  List<CreditItem> creditsOf(String periodId) {
    final list = _live(RecType.credit)
        .map(CreditItem.fromRecord)
        .where((c) => c.periodId == periodId)
        .toList()
      ..sort((a, b) => a.order != b.order ? a.order.compareTo(b.order) : a.name.compareTo(b.name));
    return list;
  }

  List<CreditDeposit> depositsOf(String periodId) {
    final list = _live(RecType.deposit)
        .map(CreditDeposit.fromRecord)
        .whereType<CreditDeposit>()
        .where((d) => d.periodId == periodId)
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return list;
  }

  List<Expense> expensesBetween(DateTime from, DateTime to) {
    final list = _live(RecType.expense)
        .map(Expense.fromRecord)
        .whereType<Expense>()
        .where((e) => !e.date.isBefore(from) && !e.date.isAfter(to))
        .toList()
      ..sort((a, b) {
        final c = a.date.compareTo(b.date);
        return c != 0 ? c : a.created.compareTo(b.created);
      });
    return list;
  }

  List<Expense> expensesOn(DateTime day) => expensesBetween(dateOnly(day), dateOnly(day));

  /// Частые комментарии к расходам — для быстрых подсказок.
  List<String> frequentNotes({int limit = 8}) {
    final from = addDays(today(), -90);
    final counts = <String, int>{};
    for (final e in expensesBetween(from, addDays(today(), 365))) {
      final n = e.note.trim();
      if (n.isEmpty) continue;
      counts[n] = (counts[n] ?? 0) + 1;
    }
    final list = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return list.take(limit).map((e) => e.key).toList();
  }

  // ------------------------------------------------------------ действия

  void savePeriod(Period p) => put(RecType.period, p.id, p.toData());

  void saveFixed(FixedExpense f) => put(RecType.fixed, f.id, f.toData());

  /// Сохраняет платёж по кредиту и переносит правку в следующие периоды
  /// (в копии этого же кредита), чтобы не править каждый месяц вручную.
  void saveCredit(CreditItem c) {
    final from = periodById(c.periodId);
    batch(() {
      _putQuiet(RecType.credit, c.id, c.toData());
      if (from == null) return;
      for (final later in _laterCopies(c, from)) {
        _putQuiet(
          RecType.credit,
          later.id,
          CreditItem(
            id: later.id,
            periodId: later.periodId,
            name: c.name,
            amount: c.amount,
            order: later.order,
            payments: c.payments,
            firstDate: c.firstDate,
            key: c.key,
          ).toData(),
        );
      }
    });
  }

  /// Удаляет платёж из периода и из следующих периодов. Возвращает id
  /// удалённых записей (для отмены через [restore]).
  List<String> removeCredit(CreditItem c) {
    final ids = <String>[c.id];
    final from = periodById(c.periodId);
    if (from != null) ids.addAll(_laterCopies(c, from).map((x) => x.id));
    batch(() {
      for (final id in ids) {
        final r = _records[id];
        if (r != null && !r.deleted) _putQuiet(r.type, id, r.data, deleted: true);
      }
    });
    return ids;
  }

  /// Копии кредита [c] в периодах после [from]: по общему ключу,
  /// а для старых записей без ключа — по совпадению названия.
  List<CreditItem> _laterCopies(CreditItem c, Period from) {
    final result = <CreditItem>[];
    for (final p in periods.where((p) => p.start.isAfter(from.start))) {
      for (final x in creditsOf(p.id)) {
        if (x.id == c.id) continue;
        final sameKey = x.key == c.key;
        final legacyByName = x.key == x.id && c.name.isNotEmpty && x.name == c.name;
        if (sameKey || legacyByName) result.add(x);
      }
    }
    return result;
  }

  void saveDeposit(CreditDeposit d) => put(RecType.deposit, d.id, d.toData());

  Expense addExpense(DateTime date, double amount, String note) {
    final e = Expense(
      id: newId(),
      date: dateOnly(date),
      amount: amount,
      note: note.trim(),
      created: DateTime.now().millisecondsSinceEpoch,
    );
    put(RecType.expense, e.id, e.toData());
    return e;
  }

  void updateExpense(Expense e) => put(RecType.expense, e.id, e.toData());

  /// Удаляет период вместе с его обязательными расходами и кредитами.
  /// Ежедневные расходы привязаны к датам и не удаляются.
  void deletePeriod(String periodId) {
    batch(() {
      for (final r in _records.values.toList()) {
        if (r.deleted) continue;
        final belongs = r.id == periodId || r.data['periodId'] == periodId;
        if (belongs) _putQuiet(r.type, r.id, r.data, deleted: true);
      }
    });
  }

  static String periodIdFor(DateTime start) => 'p-${dateKey(start)}';

  /// Первый период: от последнего «дня зарплаты» [payday] до дня перед следующим.
  Period createFirstPeriod(DateTime now, {int payday = 10}) {
    final t = dateOnly(now);
    final start = t.day >= payday ? DateTime(t.year, t.month, payday) : DateTime(t.year, t.month - 1, payday);
    final end = DateTime(start.year, start.month + 1, start.day - 1);
    final p = Period(
      id: periodIdFor(start),
      start: start,
      end: end,
      rate: 51,
      incomeEur: 740,
      creditPlan: 10000,
    );
    batch(() {
      _putQuiet(RecType.period, p.id, p.toData());
      _putQuiet(RecType.fixed, '${p.id}-fx-0',
          FixedExpense(id: '${p.id}-fx-0', periodId: p.id, name: 'Квартира', amount: 10000, order: 0).toData());
      _putQuiet(RecType.fixed, '${p.id}-fx-1',
          FixedExpense(id: '${p.id}-fx-1', periodId: p.id, name: 'Коммуналка', amount: 4000, order: 1).toData());
    });
    return p;
  }

  /// Следующий период с теми же настройками (курс, доход, обязательные
  /// расходы, платежи по кредитам). Внесённые суммы не копируются.
  Period createNextPeriod(Period prev) {
    final start = addDays(prev.end, 1);
    final end = DateTime(start.year, start.month + 1, start.day - 1);
    final p = Period(
      id: periodIdFor(start),
      start: start,
      end: end,
      rate: prev.rate,
      incomeEur: prev.incomeEur,
      creditPlan: prev.creditPlan,
    );
    batch(() {
      _putQuiet(RecType.period, p.id, p.toData());
      var i = 0;
      for (final f in fixedOf(prev.id)) {
        final id = '${p.id}-fx-$i';
        _putQuiet(RecType.fixed, id,
            FixedExpense(id: id, periodId: p.id, name: f.name, amount: f.amount, order: i).toData());
        i++;
      }
      i = 0;
      for (final c in creditsOf(prev.id)) {
        // Выплаченные до начала нового периода рассрочки не переносим.
        if (c.isInstallment && InstallmentInfo.of(c, start).last.isBefore(start)) continue;
        final id = '${p.id}-cr-$i';
        _putQuiet(RecType.credit, id, c.copyWith(id: id, periodId: p.id, order: i).toData());
        i++;
      }
    });
    return p;
  }

  /// Данные из исходной таблицы (период 10.10.2026 – 09.11.2026).
  /// Id фиксированные, поэтому загрузка на двух устройствах не создаст дублей.
  Period loadSample() {
    final start = DateTime(2026, 10, 10);
    final p = Period(
      id: periodIdFor(start),
      start: start,
      end: DateTime(2026, 11, 9),
      rate: 51,
      incomeEur: 740,
      creditPlan: 10000,
    );
    batch(() {
      _putQuiet(RecType.period, p.id, p.toData());
      final fixed = [('Квартира', 10000.0), ('Коммуналка', 4000.0)];
      for (var i = 0; i < fixed.length; i++) {
        final id = '${p.id}-fx-$i';
        _putQuiet(RecType.fixed, id,
            FixedExpense(id: id, periodId: p.id, name: fixed[i].$1, amount: fixed[i].$2, order: i).toData());
      }
      final credits = [('Кредит 1', 1850.0), ('Кредит 2', 666.0), ('Кредит 3', 640.0), ('Проценты', 700.0)];
      for (var i = 0; i < credits.length; i++) {
        final id = '${p.id}-cr-$i';
        _putQuiet(RecType.credit, id,
            CreditItem(id: id, periodId: p.id, name: credits[i].$1, amount: credits[i].$2, order: i).toData());
      }
      _putQuiet(RecType.deposit, '${p.id}-dep-sample',
          CreditDeposit(id: '${p.id}-dep-sample', periodId: p.id, date: start, amount: 8000).toData());
      final spent = [(10, 1500.0), (11, 500.0), (12, 500.0), (13, 1750.0)];
      for (final (day, amount) in spent) {
        final id = '${p.id}-ex-sample-$day';
        _putQuiet(RecType.expense, id,
            Expense(id: id, date: DateTime(2026, 10, day), amount: amount, created: day).toData());
      }
    });
    return p;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _localChanges.close();
    super.dispose();
  }
}
