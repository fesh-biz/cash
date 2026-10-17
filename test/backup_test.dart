import 'dart:io';

import 'package:cash/data/backup.dart';
import 'package:cash/data/store.dart';
import 'package:cash/sync/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final day = DateTime(2026, 10, 14);

  group('резервная копия', () {
    test('файл копии читается обратно, чужой файл — нет', () {
      final s = Store.inMemory(deviceId: 'aaaa');
      s.loadSample();
      final b = Backup.parse(s.makeBackup(BackupReason.manual).encode());
      expect(b.records.length, s.snapshot().length);
      expect(b.reason, BackupReason.manual);
      expect(b.device, s.settings.deviceName);
      expect(() => Backup.parse('{"x": 1}'), throwsA(isA<BackupFormatException>()));
      expect(() => Backup.parse('не json'), throwsA(isA<BackupFormatException>()));
    });

    test('восстановление заменяет данные и сначала делает автокопию', () async {
      final dir = await Directory.systemTemp.createTemp('cash-test');
      addTearDown(() => dir.delete(recursive: true));
      final s = Store.inMemory(deviceId: 'aaaa', backupDir: dir);
      s.loadSample();
      final copy = s.makeBackup(BackupReason.manual);
      s.addExpense(day, 999, 'після копії');
      expect(s.epoch, '');

      final auto = await s.importBackup(copy);
      expect(auto, isNotNull);
      expect(s.epoch, isNotEmpty);
      expect(s.epochInfo?.device, s.settings.deviceName);
      expect(s.expensesOn(day), isEmpty);
      expect(s.periods.length, 1);
      expect(s.replaceNotice, isNull, reason: 'на своём устройстве сообщение не нужно');

      final autos = await s.listAutoBackups();
      expect(autos.length, 1);
      expect(autos.single.backup.reason, BackupReason.beforeImport);
      expect(autos.single.backup.records.any((r) => r.data['amount'] == 999), isTrue);
    });
  });

  group('восстановленная копия при синхронизации', () {
    late Directory dirA, dirB;
    late Store a, b;
    late SyncService sa, sb;

    Peer bOnA() => sa.peers['bbbb']!;
    Peer aOnB() => sb.peers['aaaa']!;

    setUp(() async {
      dirA = await Directory.systemTemp.createTemp('cash-a');
      dirB = await Directory.systemTemp.createTemp('cash-b');
      a = Store.inMemory(deviceId: 'aaaa', backupDir: dirA);
      b = Store.inMemory(deviceId: 'bbbb', backupDir: dirB);
      for (final s in [a, b]) {
        s.settings.syncKey = 'secret-key';
        s.settings.autoSync = false;
      }
      sa = SyncService(a);
      sb = SyncService(b);
      await sa.start();
      await sb.start();
      a.loadSample();
      expect(await sa.addManual('127.0.0.1:${sb.port}'), isNull);
      expect(b.periods.length, 1);
    });

    tearDown(() async {
      await sa.stop();
      await sb.stop();
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    });

    test('копия с A заменяет данные B, обмен начинает A', () async {
      final copy = a.makeBackup(BackupReason.manual);
      b.addExpense(day, 999, 'на B');
      await sa.syncWith(bOnA(), force: true);
      expect(a.expensesOn(day).single.amount, 999);

      await a.importBackup(copy);
      expect(a.expensesOn(day), isEmpty);

      await sa.syncWith(bOnA(), force: true);
      expect(bOnA().error, isNull);
      expect(b.epoch, a.epoch);
      expect(b.expensesOn(day), isEmpty);
      expect(b.periods.length, 1);
      expect(b.replaceNotice?.info.device, a.settings.deviceName);
      final autos = await b.listAutoBackups();
      expect(autos.single.backup.reason, BackupReason.beforeSync);
      expect(autos.single.backup.records.any((r) => r.data['amount'] == 999), isTrue);

      // После замены обычный обмен идёт в обе стороны.
      b.addExpense(day, 50, 'нова');
      a.addExpense(day, 70, 'з A');
      await sa.syncWith(bOnA(), force: true);
      expect(a.expensesOn(day).map((e) => e.amount).toSet(), {50.0, 70.0});
      expect(b.expensesOn(day).map((e) => e.amount).toSet(), {50.0, 70.0});
    });

    test('копия с A заменяет данные B, обмен начинает B', () async {
      final copy = a.makeBackup(BackupReason.manual);
      b.addExpense(day, 999, 'на B');
      await a.importBackup(copy);

      await sb.syncWith(aOnB(), force: true);
      expect(aOnB().error, isNull);
      expect(b.epoch, a.epoch);
      expect(b.expensesOn(day), isEmpty);
      expect(b.replaceNotice, isNotNull);

      // Старые данные B не возвращаются на A.
      await sa.syncWith(bOnA(), force: true);
      expect(bOnA().error, isNull);
      expect(a.expensesOn(day), isEmpty);
      expect(b.expensesOn(day), isEmpty);
    });

    test('побеждает более позднее восстановление', () async {
      final first = a.makeBackup(BackupReason.manual);
      a.addExpense(day, 10, '');
      await sa.syncWith(bOnA(), force: true);
      final second = b.makeBackup(BackupReason.manual);

      await a.importBackup(first);
      await sa.syncWith(bOnA(), force: true);
      expect(b.expensesOn(day), isEmpty);

      await b.importBackup(second);
      expect(b.epoch.compareTo(a.epoch), greaterThan(0));
      await sa.syncWith(bOnA(), force: true);
      expect(a.epoch, b.epoch);
      expect(a.expensesOn(day).single.amount, 10);
      expect(a.replaceNotice, isNotNull);
    });
  });
}
