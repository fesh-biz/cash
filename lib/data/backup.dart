import 'dart:convert';
import 'dart:io';

import 'record.dart';

/// Зачем сделана резервная копия.
enum BackupReason {
  /// Пользователь сохранил копию сам.
  manual('manual', 'Створена вручну'),

  /// Автокопия перед восстановлением другой копии на этом устройстве.
  beforeImport('before-import', 'Перед відновленням з копії'),

  /// Автокопия перед заменой данных во время синхронизации.
  beforeSync('before-sync', 'Перед заміною даних під час синхронізації');

  const BackupReason(this.code, this.label);

  final String code;
  final String label;

  static BackupReason fromCode(Object? code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return manual;
  }
}

/// Ошибка чтения файла резервной копии (сообщение — для пользователя).
class BackupFormatException implements Exception {
  BackupFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Резервная копия всех данных приложения.
///
/// В копию входят все живые записи (периоды, расходы, кредиты, показания…).
/// Локальные настройки устройства — название, код синхронизации, список
/// устройств — не входят: они у каждого устройства свои.
class Backup {
  Backup({
    required this.createdAt,
    required this.device,
    required this.reason,
    required this.records,
  });

  static const kind = 'cash-backup';
  static const formatVersion = 1;

  final DateTime createdAt;

  /// Название устройства, на котором сделана копия.
  final String device;
  final BackupReason reason;
  final List<SyncRecord> records;

  String encode() => jsonEncode({
        'app': 'cash',
        'kind': kind,
        'format': formatVersion,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'device': device,
        'reason': reason.code,
        'records': records.map((r) => r.toJson()).toList(),
      });

  static Backup parse(String text) {
    Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      throw BackupFormatException('Це не файл резервної копії Cash');
    }
    if (json is! Map || json['kind'] != kind) {
      throw BackupFormatException('Це не файл резервної копії Cash');
    }
    final format = json['format'];
    if (format is num && format > formatVersion) {
      throw BackupFormatException('Копію створено новішою версією Cash — спершу оновіть застосунок');
    }
    final list = json['records'];
    if (list is! List) throw BackupFormatException('Файл копії пошкоджено');
    final records = list.map(SyncRecord.tryFromJson).whereType<SyncRecord>().where((r) => !r.deleted).toList();
    final created = json['createdAt'];
    return Backup(
      createdAt: created is num ? DateTime.fromMillisecondsSinceEpoch(created.toInt()) : DateTime.now(),
      device: json['device'] is String ? json['device'] as String : '',
      reason: BackupReason.fromCode(json['reason']),
      records: records,
    );
  }
}

/// Резервная копия, лежащая в файле (автокопии в папке приложения).
class StoredBackup {
  StoredBackup(this.file, this.backup);
  final File file;
  final Backup backup;
}

/// Сведения о «поколении» данных: где и когда восстановили резервную копию.
class EpochInfo {
  EpochInfo({required this.device, required this.at, this.backupAt});

  /// Устройство, на котором восстановили копию.
  final String device;

  /// Когда восстановили.
  final DateTime at;

  /// Когда была сделана сама копия.
  final DateTime? backupAt;

  Map<String, dynamic> toJson() => {
        'device': device,
        'at': at.millisecondsSinceEpoch,
        if (backupAt != null) 'backupAt': backupAt!.millisecondsSinceEpoch,
      };

  static EpochInfo? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final at = j['at'];
    if (at is! num) return null;
    final backupAt = j['backupAt'];
    return EpochInfo(
      device: j['device'] is String ? j['device'] as String : '',
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
      backupAt: backupAt is num ? DateTime.fromMillisecondsSinceEpoch(backupAt.toInt()) : null,
    );
  }
}

/// Сообщение пользователю: данные этого устройства заменены при синхронизации
/// восстановленной на другом устройстве копией.
class ReplaceNotice {
  ReplaceNotice({required this.info, this.autoBackup});

  final EpochInfo info;

  /// Автокопия прежних данных (null — данных не было, копировать было нечего).
  final String? autoBackup;

  Map<String, dynamic> toJson() => {
        'info': info.toJson(),
        if (autoBackup != null) 'autoBackup': autoBackup,
      };

  static ReplaceNotice? tryFromJson(Object? j) {
    if (j is! Map) return null;
    final info = EpochInfo.tryFromJson(j['info']);
    if (info == null) return null;
    return ReplaceNotice(info: info, autoBackup: j['autoBackup'] is String ? j['autoBackup'] as String : null);
  }
}
