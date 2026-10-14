import 'package:cash/data/models.dart';
import 'package:cash/data/store.dart';
import 'package:cash/sync/sync_service.dart';
import 'package:cash/util/format.dart';
import 'package:flutter_test/flutter_test.dart';

/// Две копии приложения синхронизируются через настоящий HTTP на 127.0.0.1.
void main() {
  late Store a, b;
  late SyncService sa, sb;

  setUp(() async {
    a = Store.inMemory(deviceId: 'aaaa');
    b = Store.inMemory(deviceId: 'bbbb');
    for (final s in [a, b]) {
      s.settings.syncKey = 'secret-key';
      s.settings.autoSync = false;
    }
    sa = SyncService(a);
    sb = SyncService(b);
    await sa.start();
    await sb.start();
  });

  tearDown(() async {
    await sa.stop();
    await sb.stop();
  });

  test('данные переходят в обе стороны', () async {
    a.loadSample();
    b.addExpense(DateTime(2026, 10, 14), 300, 'кофе');

    final err = await sa.addManual('127.0.0.1:${sb.port}');
    expect(err, isNull);

    expect(b.periods.length, 1);
    expect(b.expensesBetween(DateTime(2026, 10, 10), DateTime(2026, 11, 9)).length, 5);
    expect(a.expensesOn(DateTime(2026, 10, 14)).single.note, 'кофе');
  });

  test('удаление и последняя правка побеждают', () async {
    final e = a.addExpense(DateTime(2026, 10, 14), 100, '');
    expect(await sa.addManual('127.0.0.1:${sb.port}'), isNull);
    expect(b.expensesOn(DateTime(2026, 10, 14)).length, 1);

    // Правим одну запись на обоих: более поздняя правка (на B) должна победить.
    a.updateExpense(Expense(id: e.id, date: e.date, amount: 150, created: e.created));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    b.updateExpense(Expense(id: e.id, date: e.date, amount: 200, created: e.created));
    await sa.syncWith(sa.peers.values.single, force: true);
    expect(a.expensesOn(e.date).single.amount, 200);
    expect(b.expensesOn(e.date).single.amount, 200);

    b.remove(e.id);
    await sa.syncWith(sa.peers.values.single, force: true);
    expect(a.expensesOn(e.date), isEmpty);
  });

  test('чужой код синхронизации не пускает', () async {
    b.settings.syncKey = 'other-key';
    b.addExpense(today(), 100, '');
    final err = await sa.addManual('127.0.0.1:${sb.port}');
    expect(err, isNull, reason: 'устройство добавляется, ошибка — в статусе');
    expect(sa.peers.values.single.error, contains('Код синхронизации'));
    expect(a.expensesOn(today()), isEmpty);
  });
}
