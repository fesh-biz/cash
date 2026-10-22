import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../logic/credits.dart';
import '../logic/utilities.dart';
import '../util/format.dart';
import 'backup.dart';
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
  Store._(this._file, [this._backupDirOverride]);

  /// Хранилище без файла — для тестов. [backupDir] — куда писать автокопии
  /// (null — автокопии не пишутся).
  factory Store.inMemory({String deviceId = 'test', Directory? backupDir}) {
    final s = Store._(null, backupDir);
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
  final Directory? _backupDirOverride;
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
        debugPrint('Не вдалося прочитати ${candidate.path}: $e');
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
    _epoch = json['epoch'] is String ? json['epoch'] as String : '';
    _epochInfo = EpochInfo.tryFromJson(json['epochInfo']);
    _replaceNotice = ReplaceNotice.tryFromJson(json['replaceNotice']);
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
        return 'Комп’ютер';
      }
    }
    if (Platform.isAndroid || Platform.isIOS) return 'Телефон';
    return 'Пристрій';
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
      debugPrint('Помилка збереження: $e');
    } finally {
      _saving = false;
    }
  }

  Map<String, dynamic> _toJson() => {
        'format': 1,
        'deviceId': _deviceId,
        'seq': _seq,
        'hlc': {'m': _hlc.millis, 'c': _hlc.counter},
        'epoch': _epoch,
        if (_epochInfo != null) 'epochInfo': _epochInfo!.toJson(),
        if (_replaceNotice != null) 'replaceNotice': _replaceNotice!.toJson(),
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

  // ------------------------------------------------------- резервные копии

  /// «Поколение» данных. Меняется, когда на устройстве восстанавливают
  /// резервную копию. При синхронизации данные с более новым поколением
  /// полностью заменяют данные со старым (а не сливаются с ними), поэтому
  /// восстановленная копия имеет приоритет на всех устройствах.
  /// Это HLC-метка восстановления: строки сравниваются, '' — исходное поколение.
  String _epoch = '';
  EpochInfo? _epochInfo;
  ReplaceNotice? _replaceNotice;

  String get epoch => _epoch;

  /// Где и когда восстановили копию, с которой начались текущие данные.
  EpochInfo? get epochInfo => _epochInfo;

  /// Данные заменены копией с другого устройства — показать пользователю.
  ReplaceNotice? get replaceNotice => _replaceNotice;

  void clearReplaceNotice() {
    if (_replaceNotice == null) return;
    _replaceNotice = null;
    saveSettings();
  }

  /// Сколько автокопий хранить (старые удаляются).
  static const maxAutoBackups = 20;

  /// Папка автокопий (рядом с файлом данных).
  Directory? get backupDir {
    final f = _file;
    if (f == null) return _backupDirOverride;
    return Directory('${f.parent.path}${Platform.pathSeparator}backups');
  }

  /// Все живые записи — содержимое резервной копии.
  List<SyncRecord> snapshot() =>
      _records.values.where((r) => !r.deleted).toList()..sort((a, b) => a.seq.compareTo(b.seq));

  Backup makeBackup(BackupReason reason) => Backup(
        createdAt: DateTime.now(),
        device: settings.deviceName,
        reason: reason,
        records: snapshot(),
      );

  /// Автокопии, новые сверху. Повреждённые файлы пропускаются.
  Future<List<StoredBackup>> listAutoBackups() async {
    final dir = backupDir;
    if (dir == null || !await dir.exists()) return [];
    final result = <StoredBackup>[];
    for (final f in await _autoBackupFiles(dir)) {
      try {
        result.add(StoredBackup(f, Backup.parse(await f.readAsString())));
      } catch (e) {
        debugPrint('Автокопія ${f.path}: $e');
      }
    }
    result.sort((a, b) => b.backup.createdAt.compareTo(a.backup.createdAt));
    return result;
  }

  static Future<List<File>> _autoBackupFiles(Directory dir) async {
    final files = <File>[];
    await for (final e in dir.list()) {
      final name = e.uri.pathSegments.isEmpty ? '' : e.uri.pathSegments.last;
      if (e is File && name.startsWith('auto-') && name.endsWith('.json')) files.add(e);
    }
    // В имени — дата и время, поэтому по имени файлы идут по порядку создания.
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// Сохраняет текущие данные в автокопию перед их заменой.
  /// Если данных нет или папки для копий нет (тесты) — возвращает null.
  /// Ошибка записи пробрасывается: тогда данные заменять нельзя.
  Future<File?> _writeAutoBackup(BackupReason reason) async {
    final dir = backupDir;
    final b = makeBackup(reason);
    if (dir == null || b.records.isEmpty) return null;
    await dir.create(recursive: true);
    final base = '${dir.path}${Platform.pathSeparator}auto-${fileStamp(b.createdAt)}';
    var f = File('$base.json');
    for (var i = 2; await f.exists(); i++) {
      f = File('$base-$i.json');
    }
    await f.writeAsString(b.encode(), flush: true);
    try {
      final all = await _autoBackupFiles(dir);
      for (var i = 0; i < all.length - maxAutoBackups; i++) {
        await all[i].delete();
      }
    } catch (e) {
      debugPrint('Очищення автокопій: $e');
    }
    return f;
  }

  /// Заменяет все записи данными [incoming] (новые локальные номера изменений,
  /// чтобы другие устройства забрали их при следующем обмене).
  void _replaceRecords(Iterable<SyncRecord> incoming) {
    _records.clear();
    for (final r in incoming) {
      if (r.deleted) continue;
      _hlc.observe(r.hlc);
      _records[r.id] = SyncRecord(
        id: r.id,
        type: r.type,
        hlc: r.hlc,
        data: Map<String, dynamic>.from(r.data),
        seq: ++_seq,
      );
    }
  }

  /// Восстанавливает данные из резервной копии [b]. Текущие данные сначала
  /// сохраняются в автокопию (она и возвращается). Начинается новое поколение
  /// данных — при синхронизации оно заменит данные на других устройствах.
  Future<File?> importBackup(Backup b) async {
    await flush();
    final auto = await _writeAutoBackup(BackupReason.beforeImport);
    final now = DateTime.now();
    _epoch = _hlc.now();
    _epochInfo = EpochInfo(device: settings.deviceName, at: now, backupAt: b.createdAt);
    _replaceNotice = null;
    _replaceRecords(b.records);
    _changed(local: true);
    await flush();
    return auto;
  }

  /// Заменяет данные данными другого устройства, у которого более новое
  /// поколение (там восстановили резервную копию). Прежние данные сначала
  /// сохраняются в автокопию. Возвращает локальный номер изменения сразу
  /// после замены (всё, что после него, — уже новые правки) или null,
  /// если замена не нужна (поколение не новее текущего).
  Future<int?> adoptRemote({
    required String epoch,
    required EpochInfo? info,
    required Iterable<SyncRecord> records,
    required String fromDevice,
  }) async {
    if (epoch.compareTo(_epoch) <= 0) return null;
    await flush();
    final auto = await _writeAutoBackup(BackupReason.beforeSync);
    // Пока писалась копия, могла прийти та же замена с другой стороны.
    if (epoch.compareTo(_epoch) <= 0) return null;
    _hlc.observe(epoch);
    final effective = info ?? EpochInfo(device: fromDevice, at: DateTime.now());
    _epoch = epoch;
    _epochInfo = effective;
    _replaceNotice = ReplaceNotice(info: effective, autoBackup: auto?.path);
    _replaceRecords(records);
    final upTo = _seq;
    _changed(local: false);
    await flush();
    return upTo;
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

  /// Обязательные расходы периода. Сумма коммуналки уже подставлена:
  /// по показаниям счётчиков, а если их ещё нет — план по умолчанию.
  List<FixedExpense> fixedOf(String periodId) {
    final raw = _fixedRaw(periodId);
    if (!raw.any((f) => f.isUtilities)) return raw;
    final p = periodById(periodId);
    return [
      for (final f in raw)
        if (f.isUtilities && p != null) _resolveUtilities(f, p) else f,
    ];
  }

  /// Обязательные расходы как они записаны (без подстановки коммуналки).
  List<FixedExpense> _fixedRaw(String periodId) {
    final list = _live(RecType.fixed)
        .map(FixedExpense.fromRecord)
        .where((f) => f.periodId == periodId)
        .toList()
      ..sort((a, b) => a.order != b.order ? a.order.compareTo(b.order) : a.name.compareTo(b.name));
    return list;
  }

  FixedExpense _resolveUtilities(FixedExpense f, Period p) {
    final s = _utilityStatus(p, f);
    return f.resolved(amount: s.amount, isActual: s.isActual, readingDate: s.bill?.reading.date);
  }

  // ------------------------------------------------------------ коммуналка

  /// Настройки коммуналки. Если тарифы или день показаний ещё не сохранены
  /// в настройках (данные старых версий), они берутся из последних показаний.
  UtilityConfig get utilityConfig {
    final r = _records[UtilityConfig.id];
    final last = meterReadings.lastOrNull;
    return UtilityConfig.fromRecord(
      r,
      fallbackTariffs: last?.tariffs ?? UtilityTariffs.zero,
      fallbackMeterDay: last?.date.day,
    );
  }

  void saveUtilityConfig(UtilityConfig c) => put(RecType.utilConfig, UtilityConfig.id, c.toData());

  /// Все показания, по возрастанию даты.
  List<MeterReading> get meterReadings {
    final list = _live(RecType.meter).map(MeterReading.fromRecord).whereType<MeterReading>().toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return list;
  }

  MeterReading? readingById(String id) {
    final r = _records[id];
    if (r == null || r.deleted || r.type != RecType.meter) return null;
    return MeterReading.fromRecord(r);
  }

  /// Предыдущие показания (последние до даты [date]).
  MeterReading? readingBefore(DateTime date) {
    MeterReading? prev;
    for (final m in meterReadings) {
      if (!m.date.isBefore(date)) break;
      prev = m;
    }
    return prev;
  }

  /// Счёт за месяц; null — для самых первых показаний (не с чем сравнить).
  UtilityBill? billFor(MeterReading m) {
    final prev = readingBefore(m.date);
    return prev == null ? null : UtilityBill.of(m, prev);
  }

  /// Строка коммуналки в периоде (если есть).
  FixedExpense? utilitiesItemOf(String periodId) {
    for (final f in fixedOf(periodId)) {
      if (f.isUtilities) return f;
    }
    return null;
  }

  /// Коммуналка в периоде: показания, снятые внутри периода (28-го),
  /// а пока их нет — сумма по умолчанию.
  UtilityStatus utilityStatus(Period p) {
    FixedExpense? item;
    for (final f in _fixedRaw(p.id)) {
      if (f.isUtilities) {
        item = f;
        break;
      }
    }
    return _utilityStatus(p, item);
  }

  UtilityStatus _utilityStatus(Period p, FixedExpense? item) {
    final plan = utilityConfig.plan ?? item?.amount ?? 0;
    MeterReading? reading;
    for (final m in meterReadings) {
      if (p.contains(m.date)) reading = m;
    }
    final bill = reading == null ? null : billFor(reading);
    return UtilityStatus(
      amount: bill?.total ?? plan,
      plan: plan,
      dueDate: meterDateIn(p, utilityConfig.meterDay),
      bill: bill,
      reading: reading,
    );
  }

  /// Сохраняет показания. [previousId] — id записи до правки: если дату
  /// перенесли в другой месяц, старая запись удаляется.
  void saveReading(MeterReading m, {String? previousId}) {
    batch(() {
      if (previousId != null && previousId != m.id) {
        final old = _records[previousId];
        if (old != null && !old.deleted) _putQuiet(old.type, old.id, old.data, deleted: true);
      }
      _putQuiet(RecType.meter, m.id, m.toData());
    });
  }

  /// Подключает коммуналку периода к показаниям: переделывает строку
  /// «Коммуналка» или добавляет новую.
  void attachUtilities(Period p) {
    final raw = _fixedRaw(p.id);
    for (final f in raw) {
      if (isUtilitiesName(f.name)) {
        saveFixed(FixedExpense(
          id: f.id,
          periodId: f.periodId,
          name: f.name,
          amount: f.amount,
          order: f.order,
          kind: FixedKind.utilities,
        ));
        return;
      }
    }
    saveFixed(FixedExpense(
      id: newId(),
      periodId: p.id,
      name: 'Комуналка',
      amount: utilityConfig.plan ?? 0,
      order: raw.isEmpty ? 0 : raw.map((f) => f.order).reduce(max) + 1,
      kind: FixedKind.utilities,
    ));
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
            firstPaid: c.firstPaid,
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

  /// Новый период с заданными пользователем датами и доходом.
  /// Обязательные расходы и кредиты добавляются потом на вкладках.
  Period createPeriod({
    required DateTime start,
    required DateTime end,
    required double income,
    required String currency,
    double rate = 0,
    double creditPlan = 0,
  }) {
    final s = dateOnly(start);
    var id = periodIdFor(s);
    // Id по дате начала; если такой уже есть (например, удалённый и
    // восстановленный), берём уникальный.
    if (_records[id] != null && !_records[id]!.deleted) id = '$id-${_randomHex(3)}';
    final p = Period(
      id: id,
      start: s,
      end: dateOnly(end),
      income: income,
      currency: currency,
      rate: rate,
      creditPlan: creditPlan,
    );
    savePeriod(p);
    return p;
  }

  /// Периоды, которые пересекаются с датами [start]–[end] (кроме [exceptId]).
  List<Period> overlapping(DateTime start, DateTime end, {String? exceptId}) => periods
      .where((x) => x.id != exceptId)
      .where((x) => !(end.isBefore(x.start) || start.isAfter(x.end)))
      .toList();

  /// Следующий период с теми же настройками (курс, доход, обязательные
  /// расходы, платежи по кредитам). Внесённые суммы не копируются.
  Period createNextPeriod(Period prev) {
    final start = addDays(prev.end, 1);
    final end = DateTime(start.year, start.month + 1, start.day - 1);
    final p = Period(
      id: periodIdFor(start),
      start: start,
      end: end,
      income: prev.income,
      currency: prev.currency,
      rate: prev.rate,
      creditPlan: prev.creditPlan,
    );
    batch(() {
      _putQuiet(RecType.period, p.id, p.toData());
      var i = 0;
      for (final f in _fixedRaw(prev.id)) {
        final id = '${p.id}-fx-$i';
        _putQuiet(
            RecType.fixed,
            id,
            FixedExpense(
              id: id,
              periodId: p.id,
              name: f.name,
              amount: f.isUtilities ? (utilityConfig.plan ?? f.amount) : f.amount,
              order: i,
              kind: f.isUtilities ? FixedKind.utilities : f.kind,
            ).toData());
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

  @override
  void dispose() {
    _saveTimer?.cancel();
    _localChanges.close();
    super.dispose();
  }
}
