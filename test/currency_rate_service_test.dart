import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:stocktrack/currency_rate_service.dart';

class _CurrencyApiClient extends http.BaseClient {
  http.BaseRequest? request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request;
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"data":{"EUR":0.92}}')),
      200,
    );
  }
}

void main() {
  test('requests USD to EUR rate using the API key header', () async {
    final client = _CurrencyApiClient();
    final service = CurrencyRateService(client: client, apiKey: 'test-key');

    expect(await service.loadUsdToEurRate(), 0.92);
    expect(
      client.request!.url.toString(),
      'https://api.freecurrencyapi.com/v1/latest',
    );
    expect(client.request!.headers['apikey'], 'test-key');
    client.close();
  });

  test('loads the API key from the configured provider', () async {
    final client = _CurrencyApiClient();
    var providerCalls = 0;
    final service = CurrencyRateService(
      client: client,
      apiKeyProvider: () async {
        providerCalls++;
        return 'asset-config-key';
      },
    );

    expect(await service.loadUsdToEurRate(), 0.92);
    expect(providerCalls, 1);
    expect(client.request!.headers['apikey'], 'asset-config-key');
    client.close();
  });
}
