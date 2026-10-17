// Системные окна выбора файла для резервных копий.
//
// Windows — плагин file_selector (стандартные окна «Сохранить» / «Открыть»).
// Android — свой канал cash/files в MainActivity (platform/android/...):
// системный выбор папки или облака (Storage Access Framework).

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('cash/files');

const _jsonGroup = XTypeGroup(label: 'Резервна копія Cash (JSON)', extensions: <String>['json']);

/// Сохраняет [bytes] в файл, который выберет пользователь. Возвращает имя
/// или путь сохранённого файла; null — пользователь закрыл окно.
Future<String?> saveFileDialog(String suggestedName, Uint8List bytes) async {
  if (Platform.isAndroid) {
    return _channel.invokeMethod<String>('save', {'name': suggestedName, 'bytes': bytes});
  }
  final location = await getSaveLocation(
    suggestedName: suggestedName,
    acceptedTypeGroups: const [_jsonGroup],
  );
  if (location == null) return null;
  var path = location.path;
  if (!path.toLowerCase().endsWith('.json')) path = '$path.json';
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}

/// Содержимое файла, который выберет пользователь; null — окно закрыли.
Future<Uint8List?> openFileDialog() async {
  if (Platform.isAndroid) {
    return _channel.invokeMethod<Uint8List>('open');
  }
  final file = await openFile(acceptedTypeGroups: const [_jsonGroup]);
  if (file == null) return null;
  return file.readAsBytes();
}
