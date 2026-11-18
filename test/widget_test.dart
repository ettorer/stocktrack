// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:stocktrack/main.dart';
import 'package:stocktrack/currency_rate_service.dart';
import 'package:stocktrack/holding_storage.dart';
import 'package:stocktrack/quote_storage.dart';
import 'package:yahoo_finance_data_reader/yahoo_finance_data_reader.dart';

class _FakeExchangeRateService implements ExchangeRateService {
  _FakeExchangeRateService(this.rate, {this.error});

  final double rate;
  final Object? error;
  int calls = 0;

  @override
  Future<double> loadUsdToEurRate() async {
    calls++;
    if (error != null) throw error!;
    return rate;
  }
}

class _MemoryQuoteStorage extends QuoteStorage {
  _MemoryQuoteStorage()
    : super(directoryProvider: () async => throw UnimplementedError());

  List<Map<String, Object?>> _quotes = [];

  @override
  Future<List<Map<String, dynamic>>> loadQuotes() async =>
      _quotes.map(Map<String, dynamic>.from).toList();

  @override
  Future<void> saveQuotes(List<Map<String, Object?>> quotes) async {
    _quotes = quotes.map(Map<String, Object?>.from).toList();
  }
}

class _MemoryHoldingStorage extends HoldingStorage {
  _MemoryHoldingStorage([List<Map<String, Object?>> holdings = const []])
    : _holdings = holdings.map(Map<String, Object?>.from).toList(),
      super(directoryProvider: () async => throw UnimplementedError());

  List<Map<String, Object?>> _holdings;

  @override
  Future<List<Map<String, dynamic>>> loadHoldings() async =>
      _holdings.map(Map<String, dynamic>.from).toList();

  @override
  Future<void> saveHoldings(List<Map<String, Object?>> holdings) async {
    _holdings = holdings.map(Map<String, Object?>.from).toList();
  }
}

void main() {
  testWidgets('shows errors in a dismissible modal bottom sheet', (
    tester,
  ) async {
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [],
        holdingStorage: _MemoryHoldingStorage(),
        currencyRateService: _FakeExchangeRateService(
          0.9,
          error: Exception('exchange service unavailable'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Could not load the USD to EUR exchange rate'),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(MaterialBanner), findsNothing);
    expect(find.text('OK'), findsOneWidget);

    await tester.pump(const Duration(seconds: 30));
    expect(
      find.textContaining('Could not load the USD to EUR exchange rate'),
      findsOneWidget,
    );

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Could not load the USD to EUR exchange rate'),
      findsNothing,
    );
    expect(find.byType(BottomSheet), findsNothing);
  });

  test('persists quote provider and accepts legacy quote data', () {
    const quote = Quote(
      symbol: 'AAPL',
      companyName: 'The Walt Disney Company',
      currentPrice: 190,
      change: -1,
      percentChange: -0.5,
      previousClose: 191,
      timestamp: null,
      provider: QuoteProvider.twelveData,
    );
    final savedQuote = quote.toStorageJson();
    expect(
      Quote.fromStorageJson(savedQuote).companyName,
      'The Walt Disney Company',
    );
    expect(
      Quote.fromStorageJson(savedQuote).provider,
      QuoteProvider.twelveData,
    );

    final legacyQuote = savedQuote
      ..remove('companyName')
      ..remove('provider');
    final loadedLegacyQuote = Quote.fromStorageJson(legacyQuote);
    expect(loadedLegacyQuote.companyName, isNull);
    expect(loadedLegacyQuote.provider, isNull);
  });

  test('persists holding currency and defaults legacy holdings to USD', () {
    const eurHolding = Holding(
      symbol: 'SAP',
      shares: 4,
      averagePrice: 80,
      currency: HoldingCurrency.eur,
    );
    expect(Holding.fromJson(eurHolding.toJson()).currency, HoldingCurrency.eur);
    expect(
      Holding.fromJson({'symbol': 'AAPL', 'shares': 2, 'averagePrice': 100})
          .currency,
      HoldingCurrency.usd,
    );
  });

  test('maps the most recent Yahoo daily candle to a quote', () {
    final response = YahooFinanceResponse(
      candlesData: [
        YahooFinanceCandleData(
          date: DateTime.utc(2026, 11, 14),
          open: 98,
          high: 103,
          low: 97,
          close: 101,
          adjClose: 100.5,
          volume: 1200,
        ),
        YahooFinanceCandleData(
          date: DateTime.utc(2026, 11, 17),
          open: 101,
          high: 106,
          low: 100,
          close: 105,
          adjClose: 104.5,
          volume: 1500,
        ),
      ],
    );

    final quote = Quote.fromYahooFinanceResponse('^GSPC', response);

    expect(quote.symbol, '^GSPC');
    expect(quote.currentPrice, 105);
    expect(quote.previousClose, 101);
    expect(quote.change, 4);
    expect(quote.percentChange, closeTo(3.9604, 0.0001));
    expect(quote.timestamp, DateTime.utc(2026, 11, 17));
    expect(quote.provider, QuoteProvider.yahooFinance);
  });

  test('rejects empty or invalid Yahoo daily history', () {
    expect(
      () => Quote.fromYahooFinanceResponse('AAPL', YahooFinanceResponse()),
      throwsA(
        isA<QuoteException>().having(
          (error) => error.message,
          'message',
          contains('no daily history'),
        ),
      ),
    );
    expect(
      () => Quote.fromYahooFinanceResponse(
        'AAPL',
        YahooFinanceResponse(
          candlesData: [
            YahooFinanceCandleData(date: DateTime.utc(2026, 11, 17), close: -1),
          ],
        ),
      ),
      throwsA(isA<QuoteException>()),
    );
  });

  test('parses Twelve Data quote responses', () {
    final quote = Quote.fromTwelveDataJson('CSSPX', {
      'symbol': 'CSSPX',
      'name': 'Cohen & Steers Global Realty Shares, Inc. Class I',
      'close': '58.0099983',
      'previous_close': '58.11000',
      'change': '-0.10000229',
      'percent_change': '-0.17209136',
      'timestamp': '1794839400',
    });

    expect(quote.symbol, 'CSSPX');
    expect(
      quote.companyName,
      'Cohen & Steers Global Realty Shares, Inc. Class I',
    );
    expect(quote.currentPrice, closeTo(58.0099983, 0.0000001));
    expect(quote.change, closeTo(-0.10000229, 0.0000001));
    expect(quote.percentChange, closeTo(-0.17209136, 0.0000001));
    expect(quote.previousClose, closeTo(58.11, 0.00001));
    expect(quote.timestamp, isNotNull);

    expect(
      () => Quote.fromTwelveDataJson('CSSPX', {
        'status': 'error',
        'code': 401,
        'message': 'Invalid API key',
      }),
      throwsA(isA<QuoteException>()),
    );
  });

  testWidgets('opens Holdings by default and shows bottom navigation', (
    tester,
  ) async {
    final rateService = _FakeExchangeRateService(0.9);
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [],
        holdingStorage: _MemoryHoldingStorage(),
        currencyRateService: rateService,
      ),
    );
    await tester.pumpAndSettle();

    expect(rateService.calls, 1);
    expect(find.text('Holdings'), findsOneWidget);
    expect(find.text('No holdings yet'), findsOneWidget);
    expect(find.text('Holding'), findsOneWidget);
    expect(tester.getSize(find.byType(NavigationBar)).height, 64);
    await tester.tap(find.text('Quotes'));
    await tester.pumpAndSettle();
    expect(find.text('Quotes'), findsNWidgets(2));
    expect(find.text('Ticker'), findsOneWidget);
    expect(find.text('Last Price'), findsOneWidget);
    expect(find.text('Change'), findsOneWidget);
    expect(find.text('No quotes yet'), findsOneWidget);
  });

  testWidgets('refreshes saved quotes at startup for Quotes and Holdings', (
    tester,
  ) async {
    final storage = _MemoryQuoteStorage()
      .._quotes = [
        const Quote(
          symbol: 'AAPL',
          companyName: 'Apple Inc.',
          currentPrice: 100,
          change: 1,
          percentChange: 1,
          previousClose: 99,
          timestamp: null,
        ).toStorageJson(),
      ];
    var refreshCalls = 0;
    await tester.pumpWidget(
      StocktrackApp(
        storage: storage,
        holdingStorage: _MemoryHoldingStorage([
          {'symbol': 'AAPL', 'shares': 2.0, 'averagePrice': 50.0},
        ]),
        currencyRateService: _FakeExchangeRateService(0.9),
        quoteFetcher: (symbol) async {
          refreshCalls++;
          return Quote(
            symbol: symbol,
            currentPrice: 125,
            change: 5,
            percentChange: 4,
            previousClose: 120,
            timestamp: null,
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(refreshCalls, 1);
    expect(find.text('\$250.00'), findsNWidgets(2));
    expect(storage._quotes.single['currentPrice'], 125);

    await tester.tap(find.text('Quotes'));
    await tester.pumpAndSettle();
    expect(find.text('\$125.00'), findsOneWidget);
    expect(find.text('Apple Inc.'), findsOneWidget);
  });

  testWidgets('falls back to Yahoo when Finnhub cannot quote a symbol', (
    tester,
  ) async {
    var finnhubCalls = 0;
    var twelveDataCalls = 0;
    var yahooCalls = 0;
    final storage = _MemoryQuoteStorage();
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [
          Quote(
            symbol: 'CSSPX',
            currentPrice: 55,
            change: 0,
            percentChange: 0,
            previousClose: 55,
            timestamp: null,
          ),
        ],
        storage: storage,
        holdingStorage: _MemoryHoldingStorage([
          {'symbol': 'CSSPX', 'shares': 2.0, 'averagePrice': 50.0},
        ]),
        currencyRateService: _FakeExchangeRateService(0.9),
        quoteFetcher: (symbol) async {
          finnhubCalls++;
          throw const QuoteException('No quote was returned for CSSPX.');
        },
        twelveDataQuoteFetcher: (symbol) async {
          twelveDataCalls++;
          throw const QuoteException('Twelve Data must not be used.');
        },
        yahooFinanceDailyFetcher: (symbol) async {
          yahooCalls++;
          return YahooFinanceResponse(
            candlesData: [
              YahooFinanceCandleData(
                date: DateTime.utc(2026, 11, 16),
                close: 58.11,
              ),
              YahooFinanceCandleData(
                date: DateTime.utc(2026, 11, 17),
                close: 58.01,
              ),
            ],
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Refresh quotes'));
    await tester.pumpAndSettle();
    expect(finnhubCalls, 1);
    expect(twelveDataCalls, 0);
    expect(yahooCalls, 1);
    expect(storage._quotes.single['provider'], 'yahooFinance');
    expect(find.text('\$116.02'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Refresh quotes'));
    await tester.pumpAndSettle();
    expect(finnhubCalls, 1);
    expect(twelveDataCalls, 0);
    expect(yahooCalls, 2);

    await tester.tap(find.text('Quotes'));
    await tester.pumpAndSettle();
    expect(find.text('\$58.01'), findsOneWidget);
  });

  testWidgets('refreshes a Yahoo quote only from Yahoo daily history', (
    tester,
  ) async {
    var yahooCalls = 0;
    var otherProviderCalls = 0;
    final storage = _MemoryQuoteStorage();
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [
          Quote(
            symbol: '^GSPC',
            currentPrice: 5000,
            change: 0,
            percentChange: 0,
            previousClose: 5000,
            timestamp: null,
            provider: QuoteProvider.yahooFinance,
          ),
        ],
        storage: storage,
        holdingStorage: _MemoryHoldingStorage(),
        currencyRateService: _FakeExchangeRateService(0.9),
        quoteFetcher: (symbol) async {
          otherProviderCalls++;
          throw const QuoteException('Unexpected Finnhub request.');
        },
        twelveDataQuoteFetcher: (symbol) async {
          otherProviderCalls++;
          throw const QuoteException('Unexpected Twelve Data request.');
        },
        yahooFinanceDailyFetcher: (symbol) async {
          yahooCalls++;
          expect(symbol, '^GSPC');
          return YahooFinanceResponse(
            candlesData: [
              YahooFinanceCandleData(
                date: DateTime.utc(2026, 11, 16),
                close: 6000,
              ),
            ],
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quotes').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Refresh quotes'));
    await tester.pumpAndSettle();

    expect(yahooCalls, 1);
    expect(otherProviderCalls, 0);
    expect(storage._quotes.single['provider'], 'yahooFinance');
    expect(storage._quotes.single['currentPrice'], 6000);
    expect(find.text('2026-11-16'), findsOneWidget);
    expect(find.textContaining('Daily close'), findsNothing);
  });

  testWidgets('uses Yahoo as the last fallback for special ticker symbols', (
    tester,
  ) async {
    var finnhubCalls = 0;
    var twelveDataCalls = 0;
    var yahooCalls = 0;
    final storage = _MemoryQuoteStorage();
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [],
        storage: storage,
        holdingStorage: _MemoryHoldingStorage(),
        currencyRateService: _FakeExchangeRateService(0.9),
        quoteFetcher: (symbol) async {
          finnhubCalls++;
          throw const QuoteException('No quote.');
        },
        twelveDataQuoteFetcher: (symbol) async {
          twelveDataCalls++;
          throw const QuoteException('No quote.');
        },
        yahooFinanceDailyFetcher: (symbol) async {
          yahooCalls++;
          expect(symbol, '^GSPC');
          return YahooFinanceResponse(
            candlesData: [
              YahooFinanceCandleData(
                date: DateTime.utc(2026, 11, 17),
                close: 6000,
              ),
            ],
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quotes').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add ticker'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '^GSPC');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(finnhubCalls, 1);
    expect(twelveDataCalls, 0);
    expect(yahooCalls, 1);
    expect(storage._quotes.single['symbol'], '^GSPC');
    expect(storage._quotes.single['provider'], 'yahooFinance');
  });

  testWidgets('surfaces Yahoo failures without trying another provider', (
    tester,
  ) async {
    var otherProviderCalls = 0;
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [
          Quote(
            symbol: 'AAPL',
            currentPrice: 100,
            change: 0,
            percentChange: 0,
            previousClose: 100,
            timestamp: null,
            provider: QuoteProvider.yahooFinance,
          ),
        ],
        holdingStorage: _MemoryHoldingStorage(),
        currencyRateService: _FakeExchangeRateService(0.9),
        quoteFetcher: (symbol) async {
          otherProviderCalls++;
          throw const QuoteException('Unexpected Finnhub request.');
        },
        twelveDataQuoteFetcher: (symbol) async {
          otherProviderCalls++;
          throw const QuoteException('Unexpected Twelve Data request.');
        },
        yahooFinanceDailyFetcher: (symbol) async {
          throw const QuoteException('Yahoo request failed.');
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Refresh quotes'));
    await tester.pumpAndSettle();

    expect(otherProviderCalls, 0);
    expect(
      find.textContaining(
        'Some quotes could not be refreshed: Yahoo Finance failed '
        '(Yahoo request failed.)',
      ),
      findsOneWidget,
    );
  });

  testWidgets('refresh buttons update quotes from both pages', (tester) async {
    var refreshCalls = 0;
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [
          Quote(
            symbol: 'AAPL',
            companyName: 'Apple Inc.',
            currentPrice: 100,
            change: 1,
            percentChange: 1,
            previousClose: 99,
            timestamp: null,
          ),
        ],
        storage: _MemoryQuoteStorage(),
        holdingStorage: _MemoryHoldingStorage([
          {'symbol': 'AAPL', 'shares': 2.0, 'averagePrice': 50.0},
        ]),
        currencyRateService: _FakeExchangeRateService(0.9),
        quoteFetcher: (symbol) async {
          refreshCalls++;
          final price = 100 + refreshCalls * 50;
          return Quote(
            symbol: symbol,
            currentPrice: price.toDouble(),
            change: 5,
            percentChange: 5,
            previousClose: (price - 5).toDouble(),
            timestamp: null,
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    final refreshButton = find.byTooltip('Refresh quotes');
    final addButton = find.byTooltip('Add holding');
    expect(tester.getSize(refreshButton), tester.getSize(addButton));
    expect(tester.getSize(refreshButton), const Size(40, 40));
    final refreshWidget = tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byIcon(Icons.refresh),
            matching: find.byType(IconButton),
          )
          .first,
    );
    expect(
      refreshWidget.style?.backgroundColor?.resolve(<WidgetState>{}),
      const Color(0xFF81D4FA),
    );

    await tester.tap(refreshButton);
    await tester.pumpAndSettle();
    expect(refreshCalls, 1);
    expect(find.text('\$300.00'), findsNWidgets(2));

    await tester.tap(find.text('Quotes'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Refresh quotes'));
    await tester.pumpAndSettle();
    expect(refreshCalls, 2);
    expect(find.text('\$200.00'), findsOneWidget);
    expect(find.byTooltip('Refresh quotes'), findsOneWidget);
  });

  testWidgets('aligns the Quotes and Holdings title and list positions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [
          Quote(
            symbol: 'AAPL',
            companyName: 'Apple Inc.',
            currentPrice: 120,
            change: 2,
            percentChange: 1.7,
            previousClose: 118,
            timestamp: null,
          ),
        ],
        holdingStorage: _MemoryHoldingStorage([
          {'symbol': 'AAPL', 'shares': 10.0, 'averagePrice': 100.0},
        ]),
        currencyRateService: _FakeExchangeRateService(0.9),
      ),
    );
    await tester.pumpAndSettle();

    final holdingTitleTop = tester
        .getTopLeft(find.byKey(const ValueKey('holdings-title-row')))
        .dy;
    final holdingRefreshTop = tester
        .getTopLeft(find.byTooltip('Refresh quotes'))
        .dy;
    final holdingHeaderTop = tester
        .getTopLeft(find.byKey(const ValueKey('holdings-table-header')))
        .dy;
    final holdingRowTop = tester
        .getTopLeft(
          find
              .ancestor(
                of: find.text('AAPL'),
                matching: find.byType(GestureDetector),
              )
              .first,
        )
        .dy;

    await tester.tap(find.text('Quotes'));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byKey(const ValueKey('quotes-title-row'))).dy,
      holdingTitleTop,
    );
    expect(
      tester.getTopLeft(find.byTooltip('Refresh quotes')).dy,
      holdingRefreshTop,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('quotes-table-header'))).dy,
      holdingHeaderTop,
    );
    final quoteRowTop = tester
        .getTopLeft(
          find
              .ancestor(
                of: find.text('AAPL'),
                matching: find.byType(GestureDetector),
              )
              .first,
        )
        .dy;
    expect(quoteRowTop, holdingRowTop);
  });

  testWidgets('sorts tickers and allows removing them in edit mode', (
    tester,
  ) async {
    final storage = _MemoryQuoteStorage();
    final rateService = _FakeExchangeRateService(0.9);
    const quotes = [
      Quote(
        symbol: 'MSFT',
        currentPrice: 420,
        change: 2,
        percentChange: 0.5,
        previousClose: 418,
        timestamp: null,
      ),
      Quote(
        symbol: 'AAPL',
        currentPrice: 190,
        change: -1,
        percentChange: -0.5,
        previousClose: 191,
        timestamp: null,
      ),
    ];
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: quotes,
        storage: storage,
        holdingStorage: _MemoryHoldingStorage(),
        currencyRateService: rateService,
      ),
    );
    await tester.tap(find.text('Quotes'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ticker'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('AAPL')).dy,
      lessThan(tester.getTopLeft(find.text('MSFT')).dy),
    );

    await tester.longPress(find.text('AAPL'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove AAPL'), findsOneWidget);

    final handle = find.byIcon(Icons.drag_handle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 200));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('MSFT')).dy,
      lessThan(tester.getTopLeft(find.text('AAPL')).dy),
    );

    await tester.tap(find.byTooltip('Remove AAPL'));
    await tester.pumpAndSettle();
    expect(find.text('AAPL'), findsNothing);
    expect(find.text('MSFT'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      StocktrackApp(
        storage: storage,
        holdingStorage: _MemoryHoldingStorage(),
        currencyRateService: _FakeExchangeRateService(0.9),
        quoteFetcher: (symbol) async => Quote(
          symbol: symbol,
          companyName: '$symbol Inc.',
          currentPrice: 100,
          change: 0,
          percentChange: 0,
          previousClose: 100,
          timestamp: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quotes'));
    await tester.pumpAndSettle();
    expect(find.text('AAPL'), findsNothing);
    expect(find.text('MSFT'), findsOneWidget);
  });

  testWidgets('shows holdings and opens the add-holding form', (tester) async {
    final rateService = _FakeExchangeRateService(0.9);
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [],
        holdingStorage: _MemoryHoldingStorage(),
        currencyRateService: rateService,
      ),
    );
    await tester.tap(find.text('Holding'));
    await tester.pumpAndSettle();

    expect(find.text('Holdings'), findsOneWidget);
    expect(find.text('No holdings yet'), findsOneWidget);
    await tester.tap(find.byTooltip('Add holding'));
    await tester.pumpAndSettle();

    expect(find.text('Add holding'), findsOneWidget);
    expect(find.text('Stock ticker'), findsOneWidget);
    expect(find.text('Shares'), findsOneWidget);
    expect(find.text('Currency'), findsOneWidget);
    expect(find.text('Share price currency'), findsNothing);
    expect(find.textContaining('Average price per share'), findsOneWidget);
    final sharesField = tester.getRect(find.byType(TextFormField).at(1));
    final currencyField = tester.getRect(
      find.byType(DropdownButtonFormField<HoldingCurrency>),
    );
    expect(sharesField.top, currencyField.top);
    expect(sharesField.right, lessThan(currencyField.left));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Quotes').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add ticker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('selects and saves EUR when adding a holding', (tester) async {
    final holdingStorage = _MemoryHoldingStorage();
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [
          Quote(
            symbol: 'SAP',
            currentPrice: 120,
            change: 2,
            percentChange: 1.7,
            previousClose: 118,
            timestamp: null,
          ),
        ],
        holdingStorage: holdingStorage,
        currencyRateService: _FakeExchangeRateService(0.9),
        quoteFetcher: (symbol) async => Quote(
          symbol: symbol,
          currentPrice: 120,
          change: 2,
          percentChange: 1.7,
          previousClose: 118,
          timestamp: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add holding'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'SAP');
    await tester.enterText(find.byType(TextFormField).at(1), '4');
    await tester.enterText(find.byType(TextFormField).at(2), '80');
    await tester.tap(find.byType(DropdownButtonFormField<HoldingCurrency>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EUR (€)').last);
    await tester.pumpAndSettle();
    expect(find.text('Average price per share (EUR)'), findsOneWidget);
    expect(find.text('€'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(holdingStorage._holdings.single['currency'], 'eur');
    expect(holdingStorage._holdings.single['averagePrice'], 80);
  });

  testWidgets('converts EUR holdings and portfolio totals correctly', (
    tester,
  ) async {
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [
          Quote(
            symbol: 'SAP',
            currentPrice: 120,
            change: 2,
            percentChange: 1.7,
            previousClose: 118,
            timestamp: null,
          ),
        ],
        holdingStorage: _MemoryHoldingStorage([
          {
            'symbol': 'SAP',
            'shares': 10.0,
            'averagePrice': 80.0,
            'currency': 'eur',
          },
        ]),
        currencyRateService: _FakeExchangeRateService(0.9),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('€120.00', findRichText: true), findsOneWidget);
    expect(find.textContaining('\$133.33', findRichText: true), findsOneWidget);
    expect(find.text('€1200.00'), findsNWidgets(2));
    expect(find.text('€800.00'), findsNWidgets(2));
    expect(find.text('+€20.00'), findsNWidgets(2));
    expect(find.text('+€400.00'), findsNWidgets(2));
    expect(find.text('\$1333.33'), findsOneWidget);
    expect(find.text('\$888.89'), findsOneWidget);
    expect(find.text('+\$22.22'), findsOneWidget);
    expect(find.text('+\$444.44'), findsNWidgets(2));
  });

  testWidgets('normalizes mixed-currency holdings before portfolio totals', (
    tester,
  ) async {
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [
          Quote(
            symbol: 'AAPL',
            currentPrice: 100,
            change: 10,
            percentChange: 11.1,
            previousClose: 90,
            timestamp: null,
          ),
          Quote(
            symbol: 'SAP',
            currentPrice: 100,
            change: 5,
            percentChange: 5.3,
            previousClose: 95,
            timestamp: null,
          ),
        ],
        holdingStorage: _MemoryHoldingStorage([
          {'symbol': 'AAPL', 'shares': 2.0, 'averagePrice': 80.0},
          {
            'symbol': 'SAP',
            'shares': 1.0,
            'averagePrice': 80.0,
            'currency': 'eur',
          },
        ]),
        currencyRateService: _FakeExchangeRateService(0.9),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('\$311.11'), findsOneWidget);
    expect(find.text('€280.00'), findsOneWidget);
    expect(find.text('\$248.89'), findsOneWidget);
    expect(find.text('€224.00'), findsOneWidget);
    expect(find.text('+\$25.56'), findsOneWidget);
    expect(find.text('+€23.00'), findsOneWidget);
    expect(find.text('+\$62.22'), findsOneWidget);
    expect(find.text('+€56.00'), findsOneWidget);
  });

  testWidgets('keeps Add holding usable above the phone keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 270);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [],
        holdingStorage: _MemoryHoldingStorage(),
        currencyRateService: _FakeExchangeRateService(0.9),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add holding'));
    await tester.pumpAndSettle();

    expect(find.text('Stock ticker'), findsOneWidget);
    expect(find.text('Shares'), findsOneWidget);
    expect(find.textContaining('Average price per share'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    expect(
      tester.getRect(find.byType(TextFormField).at(2)).bottom,
      lessThanOrEqualTo(510),
    );
    expect(tester.getRect(find.text('Add')).bottom, lessThanOrEqualTo(510));
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps Edit holding usable above the phone keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [],
        holdingStorage: _MemoryHoldingStorage([
          {
            'symbol': 'AAPL',
            'shares': 10.0,
            'averagePrice': 100.0,
            'currency': 'eur',
          },
        ]),
        currencyRateService: _FakeExchangeRateService(0.9),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Holding'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('AAPL'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit holding'));
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: 270);
    await tester.pumpAndSettle();

    expect(find.text('Average price per share (EUR)'), findsOneWidget);
    expect(find.text('Currency'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(tester.getRect(find.text('Save')).bottom, lessThanOrEqualTo(510));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows configuration export and import options', (tester) async {
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [],
        holdingStorage: _MemoryHoldingStorage(),
        currencyRateService: _FakeExchangeRateService(0.9),
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Configuration'), findsOneWidget);
    expect(find.text('Export configuration'), findsOneWidget);
    expect(find.text('Import configuration'), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
  });

  testWidgets('long-press menu edits and deletes a holding', (tester) async {
    final rateService = _FakeExchangeRateService(0.9);
    final holdingStorage = _MemoryHoldingStorage([
      {
        'symbol': 'AAPL',
        'shares': 10.0,
        'averagePrice': 100.0,
        'currency': 'eur',
      },
    ]);
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [
          Quote(
            symbol: 'AAPL',
            currentPrice: 120,
            change: 2,
            percentChange: 1.7,
            previousClose: 118,
            timestamp: null,
          ),
        ],
        holdingStorage: holdingStorage,
        currencyRateService: rateService,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Holding'));
    await tester.pumpAndSettle();
    expect(rateService.calls, 1);
    expect(find.textContaining('+€200.00'), findsNWidgets(2));

    await tester.longPress(find.text('AAPL'));
    await tester.pumpAndSettle();
    expect(find.text('Edit holding'), findsOneWidget);
    expect(find.text('Delete holding'), findsOneWidget);
    expect(find.text('Reorder holdings'), findsOneWidget);

    await tester.tap(find.text('Edit holding'));
    await tester.pumpAndSettle();
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Average price per share (EUR)'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).at(1), '15');
    await tester.enterText(find.byType(TextFormField).at(2), '105');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('15 shares'), findsOneWidget);
    expect(find.textContaining('€105.00', findRichText: true), findsOneWidget);
    expect(holdingStorage._holdings.single['currency'], 'eur');

    await tester.longPress(find.text('AAPL'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete holding'));
    await tester.pumpAndSettle();
    expect(find.text('Delete holding?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('No holdings yet'), findsOneWidget);
    expect(holdingStorage._holdings, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reorders holdings from the long-press menu', (tester) async {
    final holdingStorage = _MemoryHoldingStorage([
      {'symbol': 'AAPL', 'shares': 10.0, 'averagePrice': 100.0},
      {'symbol': 'MSFT', 'shares': 5.0, 'averagePrice': 200.0},
    ]);
    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [],
        holdingStorage: holdingStorage,
        currencyRateService: _FakeExchangeRateService(0.9),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('AAPL'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reorder holdings'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Done reordering'), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.drag_handle).first),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, 200));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(holdingStorage._holdings.map((item) => item['symbol']), [
      'MSFT',
      'AAPL',
    ]);
    await tester.tap(find.byTooltip('Done reordering'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.drag_handle), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits all holding columns on a portrait phone', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [
          Quote(
            symbol: 'AAPL',
            currentPrice: 120,
            change: 2,
            percentChange: 1.7,
            previousClose: 118,
            timestamp: null,
          ),
        ],
        holdingStorage: _MemoryHoldingStorage([
          {'symbol': 'AAPL', 'shares': 10.0, 'averagePrice': 100.0},
        ]),
        currencyRateService: _FakeExchangeRateService(0.9),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Holding'));
    await tester.pumpAndSettle();

    expect(tester.getRect(find.text('Ticker')).left, greaterThanOrEqualTo(0));
    expect(tester.getRect(find.text('Total')).right, lessThanOrEqualTo(390));
    expect(find.textContaining('+€180.00'), findsNWidgets(2));
    expect(
      tester.getSize(find.byKey(const ValueKey('holding-totals-row'))).height,
      88,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('holdings-title-row'))).height,
      52,
    );
    final holdingRow = find
        .ancestor(of: find.text('AAPL'), matching: find.byType(GestureDetector))
        .first;
    expect(tester.getSize(holdingRow).height, lessThanOrEqualTo(54));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows quote change column on a portrait phone', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      StocktrackApp(
        initialQuotes: const [
          Quote(
            symbol: 'AAPL',
            companyName: 'The Walt Disney Company',
            currentPrice: 120,
            change: 2,
            percentChange: 1.7,
            previousClose: 118,
            timestamp: null,
          ),
        ],
        holdingStorage: _MemoryHoldingStorage(),
        currencyRateService: _FakeExchangeRateService(0.9),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Quotes'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Change')).right, lessThanOrEqualTo(390));
    expect(tester.getRect(find.text('+2.00')).right, lessThanOrEqualTo(390));
    final companyName = find.text('The Walt Disney Company');
    expect(companyName, findsOneWidget);
    expect(
      tester.renderObject<RenderParagraph>(companyName).didExceedMaxLines,
      isFalse,
    );
    final quoteRow = find
        .ancestor(of: find.text('AAPL'), matching: find.byType(GestureDetector))
        .first;
    expect(tester.getSize(quoteRow).height, 46);
    expect(tester.takeException(), isNull);
  });
}
