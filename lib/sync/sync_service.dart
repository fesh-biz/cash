import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/record.dart';
import '../data/store.dart';

/// Порт HTTP-сервера синхронизации (если занят — берётся следующий).
const int kSyncPort = 47800;

/// UDP-порт для поиска устройств в сети.
const int kDiscoveryPort = 47801;

const int kProtocol = 1;

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
  bool busy = false;
  DateTime? _retryAfter;

  bool get online => lastSeen != null && DateTime.now().difference(lastSeen!) < const Duration(seconds: 30);
}

class SyncException implements Exception {
  SyncException(this.message);
  final String message;
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

  bool get hasErrors => peers.values.any((p) => p.error != null);

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
      _debounce = Timer(const Duration(milliseconds: 1500), () => syncAll());
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
        serverError = 'Не удалось открыть порт: $e';
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
      discoveryError = 'Поиск устройств недоступен: $e';
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
      final isNew = !peers.containsKey(id);
      _touchPeer(id, j['name'] is String ? j['name'] as String : id, d.address.address, p.toInt());
      if (isNew && store.settings.autoSync && hasKey) {
        unawaited(syncWith(peers[id]!));
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
      if (host != null && peerPort != null) _touchPeer(peerId, peerName, host, peerPort);

      if (req.method == 'GET' && path == '/cash/changes') {
        final since = int.tryParse(req.uri.queryParameters['since'] ?? '0') ?? 0;
        final maxSeq = store.seq;
        final records = store.changesSince(since, upTo: maxSeq);
        await _reply(res, 200, {
          'id': store.deviceId,
          'name': store.settings.deviceName,
          'maxSeq': maxSeq,
          'records': records.map((r) => r.toJson()).toList(),
        }, key: key, reqSig: sig);
        return;
      }

      if (req.method == 'POST' && path == '/cash/changes') {
        final j = jsonDecode(body);
        final list = (j is Map && j['records'] is List) ? j['records'] as List : const [];
        final records = list.map(SyncRecord.tryFromJson).whereType<SyncRecord>().toList();
        final merged = store.mergeRemote(records);
        await _reply(res, 200, {'merged': merged}, key: key, reqSig: sig);
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
            throw SyncException('На «${p.name}» не задан код синхронизации');
          case 'clock':
            throw SyncException('Часы устройств расходятся больше чем на 2 часа');
          default:
            throw SyncException('Код синхронизации не совпадает');
        }
      }
      if (res.statusCode != 200) {
        throw SyncException('Ошибка ${res.statusCode} на «${p.name}»');
      }
      if (signed) {
        final got = res.headers.value('x-cash-sig') ?? '';
        if (!_safeEquals(got, _sign(key, 'res\n$sig\n$text'))) {
          throw SyncException('Ответ не подписан кодом синхронизации');
        }
      }
      return json;
    } on SocketException catch (_) {
      throw SyncException('Нет связи с ${p.host}:${p.port}');
    } on TimeoutException catch (_) {
      throw SyncException('${p.host}:${p.port} не отвечает');
    } on HttpException catch (e) {
      throw SyncException('Ошибка связи: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// Добавить устройство по IP (если broadcast в сети не работает).
  Future<String?> addManual(String input) async {
    var text = input.trim();
    if (text.isEmpty) return 'Введите IP-адрес';
    var p = kSyncPort;
    final m = RegExp(r'^([0-9.]+)(?::(\d+))?$').firstMatch(text);
    if (m == null) return 'Формат: 192.168.1.20 или 192.168.1.20:47800';
    text = m.group(1)!;
    if (m.group(2) != null) p = int.parse(m.group(2)!);
    final probe = Peer(id: '?', name: text, host: text, port: p);
    try {
      final hello = await _call(probe, 'GET', '/cash/hello', signed: false);
      final id = hello['id'];
      if (hello['app'] != 'cash' || id is! String) return 'По этому адресу не приложение Cash';
      if (id == store.deviceId) return 'Это адрес этого же устройства';
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

  /// Синхронизироваться со всеми известными устройствами.
  Future<void> syncAll({bool force = false}) async {
    if (_syncingAll || !hasKey) return;
    _syncingAll = true;
    notifyListeners();
    try {
      for (final p in peers.values.toList()) {
        await syncWith(p, force: force);
      }
      lastSyncAll = DateTime.now();
    } finally {
      _syncingAll = false;
      notifyListeners();
    }
  }

  /// Двусторонняя синхронизация с одним устройством: забрать его изменения,
  /// затем отправить свои.
  Future<void> syncWith(Peer p, {bool force = false}) async {
    if (p.busy) return;
    if (!force && p._retryAfter != null && DateTime.now().isBefore(p._retryAfter!)) return;
    if (!hasKey) {
      p.error = 'Задайте код синхронизации';
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
        throw SyncException('По адресу ${p.host} теперь другое устройство');
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
      final list = data['records'] is List ? data['records'] as List : const [];
      store.mergeRemote(list.map(SyncRecord.tryFromJson).whereType<SyncRecord>());
      cur.pull = maxSeq;

      // 2. Отправляем свои изменения.
      final upTo = store.seq;
      final out = store.changesSince(cur.push, upTo: upTo);
      if (out.isNotEmpty) {
        await _call(p, 'POST', '/cash/changes',
            body: jsonEncode({'records': out.map((r) => r.toJson()).toList()}));
      }
      cur.push = upTo;

      final now = DateTime.now();
      p
        ..lastSync = now
        ..lastSeen = now
        ..error = null
        .._retryAfter = null;
      store.settings.knownPeers[p.id]?.lastSync = now.millisecondsSinceEpoch;
      store.saveSettings(notify: false);
    } catch (e) {
      p.error = e is SyncException ? e.message : '$e';
      // Недоступное устройство не дёргаем каждые 20 секунд.
      p._retryAfter = DateTime.now().add(const Duration(minutes: 1));
    } finally {
      p.busy = false;
      notifyListeners();
    }
  }
}
