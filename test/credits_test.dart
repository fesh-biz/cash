import 'package:cash/data/models.dart';
import 'package:cash/data/store.dart';
import 'package:cash/logic/credits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CreditItem installment({int payments = 12, DateTime? first, double amount = 1850}) => CreditItem(
        id: 'c1',
        periodId: 'p',
        name: 'Рассрочка',
        amount: amount,
        payments: payments,
        firstDate: first ?? DateTime(2026, 5, 15),
      );

  test('даты платежей: тот же день месяца, 31-е в коротком месяце', () {
    expect(installmentDate(DateTime(2026, 5, 15), 5), DateTime(2026, 10, 15));
    expect(installmentDate(DateTime(2027, 1, 31), 1), DateTime(2027, 2, 28));
    expect(installmentDate(DateTime(2026, 10, 15), -3), DateTime(2026, 7, 15));
  });

  test('сколько осталось платежей', () {
    final i = InstallmentInfo.of(installment(), DateTime(2026, 10, 14));
    expect(i.paid, 5); // май–сентябрь
    expect(i.left, 7);
    expect(i.next, DateTime(2026, 10, 15));
    expect(i.last, DateTime(2027, 4, 15));
    expect(i.totalSum, 22200);
    expect(i.leftSum, 12950);

    // В день платежа он ещё предстоящий, на следующий день — прошёл.
    expect(InstallmentInfo.of(installment(), DateTime(2026, 10, 15)).left, 7);
    expect(InstallmentInfo.of(installment(), DateTime(2026, 10, 16)).left, 6);
    expect(InstallmentInfo.of(installment(), DateTime(2027, 5, 1)).finished, isTrue);
  });

  test('платёж в периоде', () {
    final c = installment(payments: 3, first: DateTime(2026, 8, 15)); // авг, сен, окт
    expect(hasPaymentIn(c, DateTime(2026, 10, 10), DateTime(2026, 11, 9)), isTrue);
    expect(hasPaymentIn(c, DateTime(2026, 11, 10), DateTime(2026, 12, 9)), isFalse);
  });

  test('правки и удаление переходят в следующие периоды, выплаченное не копируется', () {
    final store = Store.inMemory();
    final oct = store.loadSample();
    store.saveCredit(CreditItem(
      id: 'inst',
      periodId: oct.id,
      name: 'Телефон',
      amount: 1000,
      payments: 10,
      firstDate: DateTime(2026, 9, 20),
    ));
    store.saveCredit(CreditItem(
      id: 'short',
      periodId: oct.id,
      name: 'Почти всё',
      amount: 500,
      payments: 2,
      firstDate: DateTime(2026, 9, 20), // последний 20.10 — до ноябрьского периода
    ));
    final nov = store.createNextPeriod(oct);
    final novItems = store.creditsOf(nov.id);
    expect(novItems.any((c) => c.name == 'Почти всё'), isFalse);
    final copy = novItems.singleWhere((c) => c.name == 'Телефон');
    expect(copy.payments, 10);
    expect(copy.firstDate, DateTime(2026, 9, 20));

    // Правка в октябре обновляет копию в ноябре.
    final orig = store.creditsOf(oct.id).singleWhere((c) => c.id == 'inst');
    store.saveCredit(CreditItem(
      id: orig.id,
      periodId: oct.id,
      name: 'Телефон',
      amount: 1200,
      payments: 8,
      firstDate: orig.firstDate,
      key: orig.key,
    ));
    final updated = store.creditsOf(nov.id).singleWhere((c) => c.name == 'Телефон');
    expect(updated.amount, 1200);
    expect(updated.payments, 8);

    // Удаление — тоже.
    final ids = store.removeCredit(store.creditsOf(oct.id).singleWhere((c) => c.id == 'inst'));
    expect(ids.length, 2);
    expect(store.creditsOf(nov.id).any((c) => c.name == 'Телефон'), isFalse);
    for (final id in ids) {
      store.restore(id);
    }
    expect(store.creditsOf(nov.id).any((c) => c.name == 'Телефон'), isTrue);
  });
}
