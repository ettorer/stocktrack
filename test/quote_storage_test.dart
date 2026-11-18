import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stocktrack/quote_storage.dart';

void main() {
  test('saves and reloads tracked quotes as JSON', () async {
    final directory = await Directory.systemTemp.createTemp('stocktrack_test');
    addTearDown(() => directory.delete(recursive: true));
    final storage = QuoteStorage(directoryProvider: () async => directory);
    final quotes = [
      {
        'symbol': 'AAPL',
        'currentPrice': 190.0,
        'change': -1.0,
        'percentChange': -0.5,
        'previousClose': 191.0,
        'timestamp': null,
      },
    ];

    await storage.saveQuotes(quotes);

    final file = File('${directory.path}/${QuoteStorage.fileName}');
    expect(await file.readAsString(), jsonEncode(quotes));
    expect(await storage.loadQuotes(), quotes);
  });
}
