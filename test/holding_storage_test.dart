import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stocktrack/holding_storage.dart';

void main() {
  test('saves and reloads holdings as JSON', () async {
    final directory = await Directory.systemTemp.createTemp('holdings_test');
    addTearDown(() => directory.delete(recursive: true));
    final storage = HoldingStorage(directoryProvider: () async => directory);
    final holdings = [
      {'symbol': 'AAPL', 'shares': 10.0, 'averagePrice': 190.0},
    ];

    await storage.saveHoldings(holdings);

    final file = File('${directory.path}/${HoldingStorage.fileName}');
    expect(await file.readAsString(), jsonEncode(holdings));
    expect(await storage.loadHoldings(), holdings);
  });
}
