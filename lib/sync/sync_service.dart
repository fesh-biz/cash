import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/backup.dart';
import '../data/record.dart';
import '../data/store.dart';

/// Порт HTTP-сервера синхронизации (если занят — берётся следующий).
const int kSyncPort = 47800;

/// UDP-порт для поиска устройств в сети.
const int kDiscoveryPort = 47801;

/// 2 — поколения данных (восстановленная резервная копия имеет приоритет).
const int kProtocol = 2;

/// Допустимое расхождение часов устройств при проверке подписи.
const Duration kClockTolerance = Duration(hours: 2);

/// Устройство, с которым синхронизируемся.
class Peer {
  Peer({required this.id, required this.name, required this.host, required this.port});

  final String id;
  String name;
  String host;
  int port;

  /// Когда последний раз слышали это устройство (broadcast или запрос).
  DateTime? lastSeen;
  DateTime? lastSync;
  String? error;

  /// Ошибка — просто нет связи (устройство выключено, приложение свёрнуто).
  bool networkError = false;
  bool busy = false;
  DateTime? _retryAfter;

  /// Во время обмена пришёл запрос на ещё один — повторить после.
  bool _again = false;

  /// Сколько раз подряд обмен прерывался из-за смены поколения данных.
  int _conflicts = 0;

  bool get online => lastSeen != null && DateTime.now().difference(lastSeen!) < const Duration(seconds: 30);

  /// Настоящая проблема, о которой стоит предупредить. Недоступность
  /// выключенного или свёрнутого устройства проблемой не считается —
  /// только если оно в сети (присылает о себе сигналы), а связаться не выходит.
  bool get hasProblem => error != null && (!networkError || online);

  void _ok(DateTime now) {
    lastSync = now;
    lastSeen = now;
    error = null;
    networkError = false;
    _retryAfter = null;
  }
}

class SyncException implements Exception {
  SyncException(this.message, {this.network = false, this.conflict = false});
  final String message;

  /// Нет связи (а не ошибка кода, часов и т.п.).
  final bool network;

  /// Поколение данных на том устройстве только что сменилось — обмен
  /// нужно просто повторить, это не ошибка.
  final bool conflict;
  @override
  String toString() => message;
}

String _sign(String key, String message) =>
    Hmac(sha256, utf8.encode(key)).convert(utf8.encode(message)).toString();

bool _safeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}

String _pathQuery(Uri u) => u.hasQuery ? '${u.path}?${u.query}' : u.path;

/// Синхронизация по локальной сети без внешних серверов.
///
/// * Каждое устройство держит маленький HTTP-сервер (порт 47800).
/// * Раз в 5 секунд рассылает UDP-broadcast «я здесь» (порт 47801),
///   так устройства находят друг друга. Можно добавить устройство и по IP.
/// * Запросы и ответы подписываются HMAC-SHA256 общим кодом синхронизации —
///   чужое устройство в сети без кода ничего не прочитает и не запишет.
/// * Обмен — только изменения после последней синхронизации (по курсорам),
///   конфликт правок одной записи решается по «последняя правка побеждает».
/// * Если на одном из устройств восстановили резервную копию, у его данных
///   более новое «поколение» ([Store.epoch]). Такие данные не сливаются,
///   а целиком заменяют данные устройства со старым поколением (там перед
///   заменой делается автокопия). Изменения со старым поколением не
///   принимаются, чтобы не вернуть в данные то, чего нет в копии.
class SyncService extends ChangeNotifier {
  SyncService(this.store);

  final Store store;

  HttpServer? _server;
  RawDatagramSocket? _udp;
  Timer? _announceTimer;
  Timer? _syncTimer;
  Timer? _debounce;
  StreamSubscription<void>? _changesSub;
  bool _syncingAll = false;
  bool _syncAgain = false;
  bool _started = false;

  int? port;
  String? serverError;
  String? discoveryError;
  List<String> addresses = const [];
  List<String> _broadcastTargets = const ['255.255.255.255'];
  DateTime? lastSyncAll;

  final Map<String, Peer> peers = {};

  bool get anyBusy => _syncingAll || peers.values.any((p) => p.busy);

  bool get hasKey => store.settings.syncKey.isNotEmpty;

  bool get hasErrors => peers.values.any((p) => p.hasProblem);

  Future<void> start() async {
    if (_started) return;
    _started = true;

    for (final k in store.settings.knownPeers.values) {
      peers[k.id] = Peer(id: k.id, name: k.name, host: k.host, port: k.port)
        ..lastSync = k.lastSync == null ? null : DateTime.fromMillisecondsSinceEpoch(k.lastSync!);
    }

    await _startServer();
    await refreshAddresses();
    await _startDiscovery();

    _changesSub = store.localChanges.listen((_) {
      if (!store.settings.autoSync) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 600), () {
        // Сообщаем другим устройствам, что есть новое, — они заберут сами,
        // даже если до них отсюда не достучаться.
        _announce();
        unawaited(syncAll());
      });
    });
    _syncTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (store.settings.autoSync) syncAll();
    });
    notifyListeners();
    unawaited(syncAll());
  }

  /// Приложение снова на экране (Android): обновить адреса и синхронизироваться.
  Future<void> onResume() async {
    await refreshAddresses();
    _announce();
    for (final p in peers.values) {
      p._retryAfter = null;
    }
    unawaited(syncAll());
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _syncTimer?.cancel();
    _debounce?.cancel();
    await _changesSub?.cancel();
    _udp?.close();
    await _server?.close(force: true);
    _started = false;
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }

  // ---------------------------------------------------------------- сеть

  Future<void> refreshAddresses() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      final addrs = <String>[];
      final targets = <String>{'255.255.255.255'};
      for (final ni in list) {
        for (final a in ni.addresses) {
          final ip = a.address;
          if (ip.startsWith('169.254.')) continue;
          addrs.add(ip);
          final parts = ip.split('.');
          if (parts.length == 4) targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
      addresses = addrs;
      _broadcastTargets = targets.toList();
    } catch (e) {
      debugPrint('NetworkInterface.list: $e');
    }
    notifyListeners();
  }

  Future<void> _startServer() async {
    for (var p = kSyncPort; p < kSyncPort + 10; p++) {
      try {
        final server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        _server = server;
        port = p;
        serverError = null;
        server.listen(_handle, onError: (Object e) => debugPrint('server: $e'));
        return;
      } catch (e) {
        serverError = 'Не вдалося відкрити порт: $e';
      }
    }
  }

  Future<void> _startDiscovery() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kDiscoveryPort, reuseAddress: true);
      s.broadcastEnabled = true;
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = s.receive();
        if (d != null) _onDatagram(d);
      });
      _udp = s;
      discoveryError = null;
    } catch (e) {
      discoveryError = 'Пошук пристроїв недоступний: $e';
      try {
        // Хотя бы отправлять о себе, даже если порт приёма занят.
        final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        s.broadcastEnabled = true;
        _udp = s;
      } catch (_) {}
    }
    _announceTimer = Timer.periodic(const Duration(seconds: 5), (t) {
      if (t.tick % 12 == 0) unawaited(refreshAddresses());
      _announce();
    });
    _announce();
  }

  void _announce() {
    final s = _udp;
    final myPort = port;
    if (s == null || myPort == null) return;
    final msg = utf8.encode(jsonEncode({
      'app': 'cash',
      'proto': kProtocol,
      'id': store.deviceId,
      'name': store.settings.deviceName,
      'port': myPort,
      'seq': store.seq,
      'epoch': store.epoch,
    }));
    for (final t in _broadcastTargets) {
      try {
        s.send(msg, InternetAddress(t), kDiscoveryPort);
      } catch (_) {}
    }
  }

  void _onDatagram(Datagram d) {
    try {
      final j = jsonDecode(utf8.decode(d.data));
      if (j is! Map || j['app'] != 'cash') return;
      final id = j['id'];
      final p = j['port'];
      if (id is! String || id == store.deviceId || p is! num) return;
      final existing = peers[id];
      final wasOnline = existing?.online ?? false;
      final peer = _touchPeer(id, j['name'] is String ? j['name'] as String : id, d.address.address, p.toInt());
      if (!store.settings.autoSync || !hasKey) return;
      // У того устройства есть изменения, которых мы ещё не забирали, —
      // забираем сразу, не дожидаясь планового обмена.
      final remoteSeq = j['seq'] is num ? (j['seq'] as num).toInt() : null;
      final behind = remoteSeq != null && remoteSeq > store.settings.cursorFor(id).pull;
      // Устройство снова в сети после обрыва связи — не ждём паузы между попытками.
      final cameBack = !wasOnline && peer.networkError;
      // Там восстановили резервную копию — забираем её сразу. Если же старое
      // поколение у того устройства, отправляем ему свои данные (с обычной
      // паузой после ошибки — вдруг там старая версия приложения).
      final remoteEpoch = j['epoch'] is String ? j['epoch'] as String : '';
      final epochCmp = remoteEpoch.compareTo(store.epoch);
      if (existing == null || behind || cameBack || epochCmp != 0) {
        unawaited(syncWith(peer, force: cameBack || epochCmp > 0));
      }
    } catch (_) {}
  }

  Peer _touchPeer(String id, String name, String host, int port) {
    final peer = peers.putIfAbsent(id, () => Peer(id: id, name: name, host: host, port: port));
    final changed = peer.host != host || peer.port != port || peer.name != name;
    peer
      ..name = name
      ..host = host
      ..port = port
      ..lastSeen = DateTime.now();
    final known = store.settings.knownPeers[id];
    if (known == null || changed) {
      store.settings.knownPeers[id] = KnownPeer(
        id: id,
        name: name,
        host: host,
        port: port,
        lastSync: known?.lastSync,
      );
      store.saveSettings(notify: false);
    }
    notifyListeners();
    return peer;
  }

  /// Забыть устройство.
  void forget(String peerId) {
    final p = peers.remove(peerId);
    store.settings.knownPeers.remove(peerId);
    store.settings.cursors.remove(peerId);
    if (p != null) store.settings.manualHosts.remove(p.host);
    store.saveSettings();
    notifyListeners();
  }

  // ---------------------------------------------------------------- сервер

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/cash/hello') {
        await _reply(res, 200, {
          'app': 'cash',
          'proto': kProtocol,
          'id': store.deviceId,
          'name': store.settings.deviceName,
          'epoch': store.epoch,
        });
        return;
      }

      final body = await utf8.decoder.bind(req).join();
      final key = store.settings.syncKey;
      if (key.isEmpty) {
        await _reply(res, 403, {'error': 'no_key'});
        return;
      }
      final peerId = req.headers.value('x-cash-id') ?? '';
      final ts = req.headers.value('x-cash-ts') ?? '';
      final sig = req.headers.value('x-cash-sig') ?? '';
      final expected = _sign(key, 'req\n${req.method}\n${_pathQuery(req.uri)}\n$peerId\n$ts\n$body');
      if (peerId.isEmpty || !_safeEquals(sig, expected)) {
        await _reply(res, 403, {'error': 'bad_sig'});
        return;
      }
      final tsMs = int.tryParse(ts) ?? 0;
      final skew = DateTime.now().millisecondsSinceEpoch - tsMs;
      if (skew.abs() > kClockTolerance.inMilliseconds) {
        await _reply(res, 403, {'error': 'clock'});
        return;
      }

      // Запоминаем устройство, которое к нам обратилось — так телефон узнаёт
      // компьютер, даже если broadcast в сети не проходит.
      final host = req.connectionInfo?.remoteAddress.address;
      final peerPort = int.tryParse(req.headers.value('x-cash-port') ?? '');
      final peerName = Uri.decodeComponent(req.headers.value('x-cash-name') ?? peerId);
      if (host != null && peerPort != null) {
        final peer = _touchPeer(peerId, peerName, host, peerPort);
        // То устройство само достучалось до нас с верным кодом — связь есть,
        // и обмен идёт (оно забирает наши изменения и отдаёт свои).
        final now = DateTime.now();
        peer._ok(now);
        store.settings.knownPeers[peerId]?.lastSync = now.millisecondsSinceEpoch;
        store.saveSettings(notify: false);
        notifyListeners();
      }

      if (req.method == 'GET' && path == '/cash/changes') {
        final since = int.tryParse(req.uri.queryParameters['since'] ?? '0') ?? 0;
        final maxSeq = store.seq;
        final records = store.changesSince(since, upTo: maxSeq);
        await _reply(res, 200, {
          'id': store.deviceId,
          'name': store.settings.deviceName,
          'epoch': store.epoch,
          'maxSeq': maxSeq,
          'records': records.map((r) => r.toJson()).toList(),
        }, key: key, reqSig: sig);
        return;
      }

      // Все данные целиком — для устройства со старым поколением данных.
      if (req.method == 'GET' && path == '/cash/snapshot') {
        final maxSeq = store.seq;
        await _reply(res, 200, {
          'id': store.deviceId,
          'name': store.settings.deviceName,
          'epoch': store.epoch,
          'epochInfo': store.epochInfo?.toJson(),
          'maxSeq': maxSeq,
          'records': store.snapshot().map((r) => r.toJson()).toList(),
        }, key: key, reqSig: sig);
        return;
      }

      if (req.method == 'POST' && path == '/cash/changes') {
        final j = jsonDecode(body);
        // Изменения из другого поколения данных не принимаем: устройство
        // со старым поколением сначала должно получить восстановленную копию.
        final epoch = (j is Map && j['epoch'] is String) ? j['epoch'] as String : '';
        if (epoch != store.epoch) {
          await _reply(res, 409, {'error': 'epoch', 'epoch': store.epoch}, key: key, reqSig: sig);
          return;
        }
        final list = (j is Map && j['records'] is List) ? j['records'] as List : const [];
        final records = list.map(SyncRecord.tryFromJson).whereType<SyncRecord>().toList();
        final merged = store.mergeRemote(records);
        await _reply(res, 200, {'merged': merged}, key: key, reqSig: sig);
        return;
      }

      // Устройство, где восстановили резервную копию, присылает все данные:
      // они заменяют наши, если их поколение новее.
      if (req.method == 'POST' && path == '/cash/replace') {
        final j = jsonDecode(body);
        if (j is! Map) {
          await _reply(res, 400, {'error': 'bad_request'}, key: key, reqSig: sig);
          return;
        }
        final epoch = j['epoch'] is String ? j['epoch'] as String : '';
        final list = j['records'] is List ? j['records'] as List : const [];
        int? upTo;
        try {
          upTo = await store.adoptRemote(
            epoch: epoch,
            info: EpochInfo.tryFromJson(j['epochInfo']),
            records: list.map(SyncRecord.tryFromJson).whereType<SyncRecord>().toList(),
            fromDevice: peerName,
          );
        } catch (e) {
          debugPrint('replace: $e');
          await _reply(res, 500, {'error': 'backup'}, key: key, reqSig: sig);
          return;
        }
        if (upTo == null) {
          // Поколение не новее нашего (или замену уже сделали) — пусть то
          // устройство просто повторит обмен.
          await _reply(res, 409, {'error': 'epoch', 'epoch': store.epoch}, key: key, reqSig: sig);
          return;
        }
        // maxSeq — номер сразу после замены: правки, сделанные здесь позже,
        // то устройство заберёт обычным обменом.
        await _reply(res, 200, {'epoch': store.epoch, 'maxSeq': upTo}, key: key, reqSig: sig);
        return;
      }

      await _reply(res, 404, {'error': 'not_found'});
    } catch (e) {
      debugPrint('sync handler: $e');
      try {
        await _reply(res, 500, {'error': 'internal'});
      } catch (_) {}
    }
  }

  Future<void> _reply(HttpResponse res, int status, Map<String, dynamic> json,
      {String? key, String? reqSig}) async {
    final body = jsonEncode(json);
    final bytes = utf8.encode(body);
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    if (key != null && reqSig != null) {
      res.headers.set('x-cash-sig', _sign(key, 'res\n$reqSig\n$body'));
    }
    res.contentLength = bytes.length;
    res.add(bytes);
    await res.close();
  }

  // ---------------------------------------------------------------- клиент

  Future<Map<String, dynamic>> _call(Peer p, String method, String pathQuery,
      {String body = '', bool signed = true}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('http://${p.host}:${p.port}$pathQuery');
      final req = await client.openUrl(method, uri).timeout(const Duration(seconds: 6));
      final key = store.settings.syncKey;
      String? sig;
      if (signed) {
        final ts = DateTime.now().millisecondsSinceEpoch.toString();
        sig = _sign(key, 'req\n$method\n${_pathQuery(uri)}\n${store.deviceId}\n$ts\n$body');
        req.headers
          ..set('x-cash-id', store.deviceId)
          ..set('x-cash-name', Uri.encodeComponent(store.settings.deviceName))
          ..set('x-cash-port', '${port ?? kSyncPort}')
          ..set('x-cash-ts', ts)
          ..set('x-cash-sig', sig);
      }
      final bytes = utf8.encode(body);
      if (bytes.isNotEmpty) {
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await utf8.decoder.bind(res).join().timeout(const Duration(seconds: 30));
      Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(text);
        json = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      } catch (_) {
        json = <String, dynamic>{};
      }
      if (res.statusCode == 403) {
        switch (json['error']) {
          case 'no_key':
            throw SyncException('На «${p.name}» не задано код синхронізації');
          case 'clock':
            throw SyncException('Годинники пристроїв розходяться більш ніж на 2 години');
          default:
            throw SyncException('Код синхронізації не збігається');
        }
      }
      if (res.statusCode == 409 && json['error'] == 'epoch') {
        throw SyncException('Дані на «${p.name}» щойно замінено — повторюю обмін', conflict: true);
      }
      if (res.statusCode == 404) {
        throw SyncException('На «${p.name}» стара версія Cash — оновіть застосунок');
      }
      if (res.statusCode == 500 && json['error'] == 'backup') {
        throw SyncException('На «${p.name}» не вдалося зберегти автокопію — дані там не замінено');
      }
      if (res.statusCode != 200) {
        throw SyncException('Помилка ${res.statusCode} на «${p.name}»');
      }
      if (signed) {
        final got = res.headers.value('x-cash-sig') ?? '';
        if (!_safeEquals(got, _sign(key, 'res\n$sig\n$text'))) {
          throw SyncException('Відповідь не підписано кодом синхронізації');
        }
      }
      return json;
    } on SocketException catch (_) {
      throw SyncException('Немає зв’язку з ${p.host}:${p.port}', network: true);
    } on TimeoutException catch (_) {
      throw SyncException('${p.host}:${p.port} не відповідає', network: true);
    } on HttpException catch (e) {
      throw SyncException('Помилка зв’язку: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// Добавить устройство по IP (если broadcast в сети не работает).
  Future<String?> addManual(String input) async {
    var text = input.trim();
    if (text.isEmpty) return 'Введіть IP-адресу';
    var p = kSyncPort;
    final m = RegExp(r'^([0-9.]+)(?::(\d+))?$').firstMatch(text);
    if (m == null) return 'Формат: 192.168.1.20 або 192.168.1.20:47800';
    text = m.group(1)!;
    if (m.group(2) != null) p = int.parse(m.group(2)!);
    final probe = Peer(id: '?', name: text, host: text, port: p);
    try {
      final hello = await _call(probe, 'GET', '/cash/hello', signed: false);
      final id = hello['id'];
      if (hello['app'] != 'cash' || id is! String) return 'За цією адресою не застосунок Cash';
      if (id == store.deviceId) return 'Це адреса цього ж пристрою';
      final peer = _touchPeer(id, hello['name'] is String ? hello['name'] as String : text, text, p);
      final hostKey = p == kSyncPort ? text : '$text:$p';
      if (!store.settings.manualHosts.contains(hostKey)) {
        store.settings.manualHosts.add(hostKey);
        store.saveSettings();
      }
      if (hasKey) await syncWith(peer, force: true);
      return null;
    } on SyncException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// Синхронизироваться со всеми известными устройствами (параллельно,
  /// чтобы недоступное устройство не задерживало остальные).
  /// Если обмен уже идёт — повторится сразу после него, правка не потеряется.
  Future<void> syncAll({bool force = false}) async {
    if (!hasKey) return;
    if (_syncingAll) {
      _syncAgain = true;
      return;
    }
    _syncingAll = true;
    notifyListeners();
    try {
      do {
        _syncAgain = false;
        await Future.wait([for (final p in peers.values.toList()) syncWith(p, force: force)]);
      } while (_syncAgain);
      lastSyncAll = DateTime.now();
    } finally {
      _syncingAll = false;
      notifyListeners();
    }
  }

  /// Двусторонняя синхронизация с одним устройством: забрать его изменения,
  /// затем отправить свои.
  Future<void> syncWith(Peer p, {bool force = false}) async {
    if (p.busy) {
      // Идёт обмен с этим устройством — повторим сразу после него.
      p._again = true;
      return;
    }
    if (!force && p._retryAfter != null && DateTime.now().isBefore(p._retryAfter!)) return;
    if (!hasKey) {
      p.error = 'Задайте код синхронізації';
      notifyListeners();
      return;
    }
    p.busy = true;
    notifyListeners();
    try {
      final cur = store.settings.cursorFor(p.id);

      // 1. Забираем изменения того устройства.
      var data = await _call(p, 'GET', '/cash/changes?since=${cur.pull}');
      if (data['id'] != p.id) {
        throw SyncException('За адресою ${p.host} тепер інший пристрій');
      }
      var maxSeq = (data['maxSeq'] as num?)?.toInt() ?? 0;
      if (maxSeq < cur.pull) {
        // Данные на том устройстве были сброшены — начинаем с нуля.
        cur
          ..pull = 0
          ..push = 0;
        data = await _call(p, 'GET', '/cash/changes?since=0');
        maxSeq = (data['maxSeq'] as num?)?.toInt() ?? 0;
      }
      // Поколения данных разные: на одном из устройств восстановили резервную
      // копию. Новое поколение целиком заменяет старое, без слияния.
      final remoteEpoch = data['epoch'] is String ? data['epoch'] as String : '';
      final epochCmp = remoteEpoch.compareTo(store.epoch);
      if (epochCmp > 0) {
        await _adoptFrom(p, cur);
      } else if (epochCmp < 0) {
        await _replaceOn(p, cur);
      } else {
        final list = data['records'] is List ? data['records'] as List : const [];
        store.mergeRemote(list.map(SyncRecord.tryFromJson).whereType<SyncRecord>());
        cur.pull = maxSeq;

        // 2. Отправляем свои изменения.
        final upTo = store.seq;
        final out = store.changesSince(cur.push, upTo: upTo);
        if (out.isNotEmpty) {
          await _call(p, 'POST', '/cash/changes',
              body: jsonEncode({
                'epoch': store.epoch,
                'records': out.map((r) => r.toJson()).toList(),
              }));
        }
        cur.push = upTo;
      }

      final now = DateTime.now();
      p._ok(now);
      p._conflicts = 0;
      store.settings.knownPeers[p.id]?.lastSync = now.millisecondsSinceEpoch;
      store.saveSettings(notify: false);
    } catch (e) {
      if (e is SyncException && e.conflict && p._conflicts < 3) {
        // Данные там только что заменили — просто повторяем обмен.
        p._conflicts++;
        p._again = true;
        return;
      }
      p.error = e is SyncException ? e.message : '$e';
      p.networkError = e is SyncException && e.network;
      p._conflicts = 0;
      // Недоступное устройство не дёргаем каждые 20 секунд. Если оно при этом
      // в сети (присылает о себе сигналы), пробуем почаще.
      final pause = p.networkError && p.online ? const Duration(seconds: 15) : const Duration(minutes: 1);
      p._retryAfter = DateTime.now().add(pause);
    } finally {
      p.busy = false;
      notifyListeners();
      if (p._again) {
        p._again = false;
        unawaited(syncWith(p));
      }
    }
  }

  /// У того устройства более новое поколение данных: забираем все его данные
  /// и заменяем ими свои (свои перед этим уходят в автокопию).
  Future<void> _adoptFrom(Peer p, PeerCursor cur) async {
    final snap = await _call(p, 'GET', '/cash/snapshot');
    if (snap['id'] != p.id) {
      throw SyncException('За адресою ${p.host} тепер інший пристрій');
    }
    final epoch = snap['epoch'] is String ? snap['epoch'] as String : '';
    final list = snap['records'] is List ? snap['records'] as List : const [];
    int? upTo;
    try {
      upTo = await store.adoptRemote(
        epoch: epoch,
        info: EpochInfo.tryFromJson(snap['epochInfo']),
        records: list.map(SyncRecord.tryFromJson).whereType<SyncRecord>().toList(),
        fromDevice: p.name,
      );
    } on FileSystemException catch (e) {
      throw SyncException('Не вдалося зберегти автокопію, дані не замінено: ${e.message}');
    }
    if (upTo == null) {
      // Пока шёл запрос, поколение уже сменилось — повторяем обмен.
      throw SyncException('Дані щойно змінилися — повторюю обмін', conflict: true);
    }
    // Теперь у нас те же данные, что у того устройства на момент снимка.
    cur
      ..pull = (snap['maxSeq'] as num?)?.toInt() ?? 0
      ..push = upTo;
  }

  /// У того устройства старое поколение данных: отправляем ему все свои
  /// данные, они заменят его данные (там перед этим делается автокопия).
  Future<void> _replaceOn(Peer p, PeerCursor cur) async {
    final upTo = store.seq;
    final res = await _call(p, 'POST', '/cash/replace',
        body: jsonEncode({
          'epoch': store.epoch,
          'epochInfo': store.epochInfo?.toJson(),
          'records': store.snapshot().map((r) => r.toJson()).toList(),
        }));
    cur
      ..pull = (res['maxSeq'] as num?)?.toInt() ?? cur.pull
      ..push = upTo;
  }
}
