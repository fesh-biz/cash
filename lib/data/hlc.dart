/// Гибридные логические часы (HLC).
///
/// Каждая правка получает метку вида `000001791924515370-000000-<deviceId>`.
/// Метки сравниваются как строки: более поздняя правка всегда «больше»,
/// даже если часы устройств немного расходятся — после получения чужих
/// данных локальные часы «догоняют» самую позднюю увиденную метку.
class Hlc {
  Hlc(this.nodeId, {int millis = 0, int counter = 0})
      : _millis = millis,
        _counter = counter;

  final String nodeId;
  int _millis;
  int _counter;

  int get millis => _millis;
  int get counter => _counter;

  /// Новая метка для локальной правки.
  String now() {
    final wall = DateTime.now().millisecondsSinceEpoch;
    if (wall > _millis) {
      _millis = wall;
      _counter = 0;
    } else {
      _counter++;
    }
    return encode(_millis, _counter, nodeId);
  }

  /// Учитывает метку, пришедшую с другого устройства.
  void observe(String remote) {
    final p = tryParse(remote);
    if (p == null) return;
    final (m, c) = p;
    if (m > _millis) {
      _millis = m;
      _counter = c;
    } else if (m == _millis && c > _counter) {
      _counter = c;
    }
  }

  static String encode(int millis, int counter, String node) =>
      '${millis.toString().padLeft(15, '0')}-${counter.toString().padLeft(6, '0')}-$node';

  static (int, int)? tryParse(String s) {
    final parts = s.split('-');
    if (parts.length < 3) return null;
    final m = int.tryParse(parts[0]);
    final c = int.tryParse(parts[1]);
    if (m == null || c == null) return null;
    return (m, c);
  }
}
