import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

abstract interface class ExchangeRateService {
  Future<double> loadUsdToEurRate();
}

class CurrencyRateService implements ExchangeRateService {
  CurrencyRateService({
    http.Client? client,
    this._apiKey,
    Future<String> Function()? apiKeyProvider,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _apiKeyProvider = apiKeyProvider ?? (() async => '');

  final http.Client _client;
  final bool _ownsClient;
  final String? _apiKey;
  final Future<String> Function() _apiKeyProvider;

  @override
  Future<double> loadUsdToEurRate() async {
    final apiKey = (_apiKey ?? await _apiKeyProvider()).trim();
    if (apiKey.isEmpty) {
      throw StateError(
        'Add free_currency_api_key to assets/config.local.json and run '
        'dart run tool/prepare_config.dart to load EUR rates.',
      );
    }

    final response = await _client
        .get(
          Uri.https('api.freecurrencyapi.com', '/v1/latest'),
          headers: {'apikey': apiKey},
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw HttpException('Currency API returned HTTP ${response.statusCode}.');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> ||
        decoded['data'] is! Map<String, dynamic>) {
      throw const FormatException('Currency API returned invalid JSON.');
    }
    final rate = (decoded['data'] as Map<String, dynamic>)['EUR'];
    if (rate is! num || !rate.toDouble().isFinite || rate <= 0) {
      throw const FormatException('Currency API returned an invalid EUR rate.');
    }
    return rate.toDouble();
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
