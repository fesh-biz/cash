/// Универсальная синхронизируемая запись.
///
/// Все данные приложения (периоды, расходы, кредиты…) хранятся как записи
/// с уникальным id, типом, HLC-меткой последней правки и полем `data`.
/// Удаление — это «надгробие» (deleted = true), чтобы удаление тоже
/// синхронизировалось. При слиянии побеждает запись с большей меткой.
class SyncRecord {
  SyncRecord({
    required this.id,
    required this.type,
    required this.hlc,
    required this.data,
    this.deleted = false,
    this.seq = 0,
  });

  final String id;
  final String type;
  final String hlc;
  final Map<String, dynamic> data;
  final bool deleted;

  /// Локальный порядковый номер изменения (у каждого устройства свой).
  /// Нужен, чтобы отдавать другим устройствам только новые изменения.
  int seq;

  Map<String, dynamic> toJson({bool withSeq = false}) => {
        'id': id,
        'type': type,
        'hlc': hlc,
        if (deleted) 'deleted': true,
        'data': data,
        if (withSeq) 'seq': seq,
      };

  static SyncRecord? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final type = json['type'];
    final hlc = json['hlc'];
    if (id is! String || type is! String || hlc is! String) return null;
    if (id.isEmpty || id.length > 200) return null;
    final data = json['data'];
    return SyncRecord(
      id: id,
      type: type,
      hlc: hlc,
      data: data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{},
      deleted: json['deleted'] == true,
      seq: (json['seq'] is num) ? (json['seq'] as num).toInt() : 0,
    );
  }
}
