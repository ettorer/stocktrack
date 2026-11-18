import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class HoldingStorage {
  HoldingStorage({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static const fileName = 'holdings.json';

  final Future<Directory> Function() _directoryProvider;
  Future<void> _writeQueue = Future<void>.value();

  Future<List<Map<String, dynamic>>> loadHoldings() async {
    await _writeQueue;
    final directory = await _directoryProvider();
    final file = File('${directory.path}/$fileName');
    if (!await file.exists()) return [];

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) {
      throw const FormatException('Saved holdings must be a JSON list.');
    }

    return decoded.map((holding) {
      if (holding is! Map) {
        throw const FormatException('Saved holding must be a JSON object.');
      }
      return Map<String, dynamic>.from(holding);
    }).toList();
  }

  Future<void> saveHoldings(List<Map<String, Object?>> holdings) async {
    final snapshot = List<Map<String, Object?>>.of(holdings);
    final write = _writeQueue.then((_) async {
      final directory = await _directoryProvider();
      await directory.create(recursive: true);
      final file = File('${directory.path}/$fileName');
      await file.writeAsString(jsonEncode(snapshot), flush: true);
    });
    _writeQueue = write.catchError((Object _) {});
    await write;
  }
}
