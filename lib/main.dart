import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:yahoo_finance_data_reader/yahoo_finance_data_reader.dart';

import 'currency_rate_service.dart';
import 'holding_storage.dart';
import 'quote_storage.dart';

void main() {
  runApp(const StocktrackApp());
}

typedef QuoteFetcher = Future<Quote> Function(String symbol);
typedef TwelveDataQuoteFetcher = Future<Quote> Function(String symbol);
typedef YahooFinanceDailyFetcher = Future<YahooFinanceResponse> Function(
  String symbol,
);

enum QuoteProvider { finnhub, twelveData, yahooFinance }

class StocktrackApp extends StatelessWidget {
  const StocktrackApp({
    super.key,
    this.initialQuotes,
    this.storage,
    this.holdingStorage,
    this.currencyRateService,
    this.quoteFetcher,
    this.twelveDataQuoteFetcher,
    this.yahooFinanceDailyFetcher,
  });

  final List<Quote>? initialQuotes;
  final QuoteStorage? storage;
  final HoldingStorage? holdingStorage;
  final ExchangeRateService? currencyRateService;
  final QuoteFetcher? quoteFetcher;
  final TwelveDataQuoteFetcher? twelveDataQuoteFetcher;
  final YahooFinanceDailyFetcher? yahooFinanceDailyFetcher;

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF090A0B);
    const surface = Color(0xFF151719);
    const accent = Color(0xFF58D6A0);

    return MaterialApp(
      title: 'Stocktrack',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: accent,
          surface: surface,
          error: Color(0xFFFF5A60),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xFF111315),
          indicatorColor: Color(0xFF183D30),
          labelTextStyle: WidgetStatePropertyAll(
            TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        dividerColor: const Color(0xFF292C2F),
        useMaterial3: true,
      ),
      home: StocktrackHome(
        initialQuotes: initialQuotes,
        storage: storage,
        holdingStorage: holdingStorage,
        currencyRateService: currencyRateService,
        quoteFetcher: quoteFetcher,
        twelveDataQuoteFetcher: twelveDataQuoteFetcher,
        yahooFinanceDailyFetcher: yahooFinanceDailyFetcher,
      ),
    );
  }
}

class StocktrackHome extends StatefulWidget {
  const StocktrackHome({
    super.key,
    this.initialQuotes,
    this.storage,
    this.holdingStorage,
    this.currencyRateService,
    this.quoteFetcher,
    this.twelveDataQuoteFetcher,
    this.yahooFinanceDailyFetcher,
  });

  final List<Quote>? initialQuotes;
  final QuoteStorage? storage;
  final HoldingStorage? holdingStorage;
  final ExchangeRateService? currencyRateService;
  final QuoteFetcher? quoteFetcher;
  final TwelveDataQuoteFetcher? twelveDataQuoteFetcher;
  final YahooFinanceDailyFetcher? yahooFinanceDailyFetcher;

  @override
  State<StocktrackHome> createState() => _StocktrackHomeState();
}

class _AppConfiguration {
  const _AppConfiguration({required this.quotes, required this.holdings});

  final List<Quote> quotes;
  final List<Holding> holdings;
}

class _StocktrackHomeState extends State<StocktrackHome> {
  late final QuoteStorage _storage;
  late final HoldingStorage _holdingStorage;
  late final ExchangeRateService _currencyRateService;
  late final bool _ownsCurrencyRateService;
  late List<Quote> _quotes;
  List<Holding> _holdings = [];
  double? _usdToEurRate;
  int _selectedTab = 1;
  bool _isEditing = false;
  bool _isReorderingHoldings = false;
  bool _isAdding = false;
  bool _isRefreshingQuotes = false;
  bool _isAddingHolding = false;
  bool _isProcessingBackup = false;
  final List<String> _pendingMessages = [];
  bool _isShowingMessage = false;
  late bool _isLoadingQuotes;
  late bool _isLoadingHoldings;
  SortColumn? _sortColumn;
  bool _sortAscending = true;
  Timer? _quoteRefreshTimer;

  @override
  void initState() {
    super.initState();
    _storage = widget.storage ?? QuoteStorage();
    _holdingStorage = widget.holdingStorage ?? HoldingStorage();
    _currencyRateService =
        widget.currencyRateService ??
        CurrencyRateService(apiKeyProvider: _loadCurrencyApiKey);
    _ownsCurrencyRateService = widget.currencyRateService == null;
    _isLoadingQuotes = widget.initialQuotes == null;
    _isLoadingHoldings = true;
    _quotes = List.of(widget.initialQuotes ?? const []);
    if (_isLoadingQuotes) _loadSavedQuotes();
    _loadSavedHoldings();
    _loadCurrencyRate();
    _quoteRefreshTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _refreshQuotes(),
    );
  }

  Future<void> _loadCurrencyRate() async {
    try {
      final rate = await _currencyRateService.loadUsdToEurRate();
      if (mounted) setState(() => _usdToEurRate = rate);
    } on StateError catch (error) {
      if (mounted) _showMessage(error.message.toString());
    } catch (error) {
      if (mounted) {
        _showMessage('Could not load the USD to EUR exchange rate: $error');
      }
    }
  }

  Future<String> _loadCurrencyApiKey() async {
    final configText = await rootBundle.loadString('assets/config.json');
    final config = jsonDecode(configText);
    if (config is! Map<String, dynamic>) {
      throw const FormatException('The app config file is not valid JSON.');
    }

    final apiKey = config['free_currency_api_key'];
    if (apiKey is! String || apiKey.trim().isEmpty) {
      throw StateError(
        'Add free_currency_api_key to assets/config.local.json, then run '
        'dart run tool/prepare_config.dart to enable EUR rates.',
      );
    }
    return apiKey.trim();
  }

  @override
  void dispose() {
    _quoteRefreshTimer?.cancel();
    if (_ownsCurrencyRateService) {
      final service = _currencyRateService;
      if (service is CurrencyRateService) service.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSavedQuotes() async {
    try {
      final saved = await _storage.loadQuotes();
      final quotes = saved.map(Quote.fromStorageJson).toList();
      if (mounted) {
        setState(() {
          _quotes = quotes;
          _isLoadingQuotes = false;
        });
        await _refreshQuotes();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingQuotes = false);
        _showMessage('Could not load your saved quotes.');
      }
    }
  }

  Future<void> _loadSavedHoldings() async {
    try {
      final saved = await _holdingStorage.loadHoldings();
      final holdings = saved.map(Holding.fromJson).toList();
      if (mounted) {
        setState(() {
          _holdings = holdings;
          _isLoadingHoldings = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingHoldings = false);
        _showMessage('Could not load your saved holdings.');
      }
    }
  }

  Future<void> _saveQuotes() {
    final snapshot = _quotes.map((quote) => quote.toStorageJson()).toList();
    return _storage.saveQuotes(snapshot).catchError((_) {
      if (mounted) _showMessage('Could not save your quotes.');
    });
  }

  List<Quote> get _displayQuotes {
    final result = List<Quote>.of(_quotes);
    final column = _sortColumn;
    if (column == null) return result;

    result.sort((first, second) {
      final comparison = switch (column) {
        SortColumn.ticker => first.symbol.compareTo(second.symbol),
        SortColumn.price => first.currentPrice.compareTo(second.currentPrice),
        SortColumn.change => first.percentChange.compareTo(
          second.percentChange,
        ),
      };
      return _sortAscending ? comparison : -comparison;
    });
    return result;
  }

  void _sortBy(SortColumn column) {
    setState(() {
      if (_sortColumn == column) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = column;
        _sortAscending = true;
      }
    });
  }

  void _enterEditMode() {
    if (_quotes.isEmpty || _isEditing) return;
    setState(() {
      _quotes = _displayQuotes;
      _sortColumn = null;
      _isEditing = true;
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final quote = _quotes.removeAt(oldIndex);
      _quotes.insert(newIndex, quote);
    });
    _saveQuotes();
  }

  void _reorderHolding(int oldIndex, int newIndex) {
    setState(() {
      final holding = _holdings.removeAt(oldIndex);
      _holdings.insert(newIndex, holding);
    });
    _saveHoldings();
  }

  Future<void> _promptToAddQuote() async {
    final symbol = await showDialog<String>(
      context: context,
      builder: (_) => const _AddQuoteDialog(),
    );
    if (symbol != null) await _addQuote(symbol);
  }

  Future<void> _promptToAddHolding() async {
    final holding = await showDialog<Holding>(
      context: context,
      builder: (_) => const _AddHoldingDialog(),
    );
    if (holding != null) await _addHolding(holding);
  }

  Future<void> _showHoldingActions(
    Holding holding,
    BuildContext rowContext,
  ) async {
    final row = rowContext.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final topLeft = row.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = row.localToGlobal(
      row.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final action = await showMenu<_HoldingAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(topLeft, bottomRight),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: _HoldingAction.edit,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined),
            title: Text('Edit holding'),
          ),
        ),
        PopupMenuItem(
          value: _HoldingAction.delete,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, color: Color(0xFFFF5A60)),
            title: Text('Delete holding'),
          ),
        ),
        PopupMenuItem(
          value: _HoldingAction.reorder,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.reorder),
            title: Text('Reorder holdings'),
          ),
        ),
      ],
    );

    switch (action) {
      case _HoldingAction.edit:
        await _editHolding(holding);
      case _HoldingAction.delete:
        await _confirmDeleteHolding(holding);
      case _HoldingAction.reorder:
        setState(() => _isReorderingHoldings = true);
      case null:
        break;
    }
  }

  Future<void> _editHolding(Holding current) async {
    final updated = await showDialog<Holding>(
      context: context,
      builder: (_) => _AddHoldingDialog(initialHolding: current),
    );
    if (updated == null) return;
    if (_holdings.any(
      (holding) =>
          holding.symbol == updated.symbol && holding.symbol != current.symbol,
    )) {
      _showMessage('${updated.symbol} is already in your holdings.');
      return;
    }

    setState(() => _isAddingHolding = true);
    try {
      final trackedQuote = _quotes.where(
        (quote) => quote.symbol == updated.symbol,
      );
      final quote = trackedQuote.isNotEmpty
          ? trackedQuote.first
          : updated.symbol == current.symbol
          ? null
          : await _fetchQuoteWithCompanyName(updated.symbol);
      if (!mounted) return;

      setState(() {
        _holdings = _holdings
            .map((holding) => holding == current ? updated : holding)
            .toList();
        if (quote != null && trackedQuote.isEmpty) {
          _quotes = [..._quotes, quote];
        }
      });
      await _saveHoldings();
      if (quote != null && trackedQuote.isEmpty) await _saveQuotes();
    } on QuoteException catch (error) {
      if (mounted) _showMessage(error.message);
    } on TimeoutException {
      if (mounted) _showMessage('Finnhub took too long to respond.');
    } catch (_) {
      if (mounted) {
        _showMessage('Could not update the holding. Check your connection.');
      }
    } finally {
      if (mounted) setState(() => _isAddingHolding = false);
    }
  }

  Future<void> _confirmDeleteHolding(Holding holding) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete holding?'),
        content: Text('Remove ${holding.symbol} from your holdings?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (shouldDelete != true || !mounted) return;

    setState(() {
      _holdings = _holdings.where((item) => item != holding).toList();
    });
    await _saveHoldings();
  }

  Future<void> _addHolding(Holding holding) async {
    if (_holdings.any((item) => item.symbol == holding.symbol)) {
      _showMessage('${holding.symbol} is already in your holdings.');
      return;
    }

    setState(() => _isAddingHolding = true);
    try {
      var quote = _quotes.where((item) => item.symbol == holding.symbol);
      final quoteIsTracked = quote.isNotEmpty;
      final currentQuote = quoteIsTracked
          ? quote.first
          : await _fetchQuoteWithCompanyName(holding.symbol);
      if (!mounted) return;

      setState(() {
        _holdings = [..._holdings, holding];
        if (!quoteIsTracked) _quotes = [..._quotes, currentQuote];
      });
      await _saveHoldings();
      if (!quoteIsTracked) await _saveQuotes();
    } on QuoteException catch (error) {
      if (mounted) _showMessage(error.message);
    } on TimeoutException {
      if (mounted) _showMessage('Finnhub took too long to respond.');
    } catch (_) {
      if (mounted) {
        _showMessage('Could not add the holding. Check your connection.');
      }
    } finally {
      if (mounted) setState(() => _isAddingHolding = false);
    }
  }

  Future<void> _saveHoldings() {
    final snapshot = _holdings.map((holding) => holding.toJson()).toList();
    return _holdingStorage.saveHoldings(snapshot).catchError((_) {
      if (mounted) _showMessage('Could not save your holdings.');
    });
  }

  Future<void> _exportConfiguration() async {
    if (_isLoadingQuotes || _isLoadingHoldings || _isProcessingBackup) return;
    setState(() => _isProcessingBackup = true);
    try {
      final configuration = {
        'format': 'stocktrack',
        'version': 1,
        'quotes': _quotes.map((quote) => quote.toStorageJson()).toList(),
        'holdings': _holdings.map((holding) => holding.toJson()).toList(),
      };
      final bytes = Uint8List.fromList(
        utf8.encode(
          '${const JsonEncoder.withIndent('  ').convert(configuration)}\n',
        ),
      );
      final savedFile = await FilePicker.saveFile(
        fileName: 'stocktrack-configuration.json',
        bytes: bytes,
        mimeType: 'application/json',
        dialogTitle: 'Export Stocktrack configuration',
      );
      if (savedFile != null && mounted) {
        _showMessage('Configuration exported successfully.');
      }
    } catch (_) {
      if (mounted) _showMessage('Could not export the configuration.');
    } finally {
      if (mounted) setState(() => _isProcessingBackup = false);
    }
  }

  Future<void> _importConfiguration() async {
    if (_isLoadingQuotes || _isLoadingHoldings || _isProcessingBackup) return;
    setState(() => _isProcessingBackup = true);
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: 'Import Stocktrack configuration',
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (file == null) return;

      final decoded = jsonDecode(utf8.decode(await file.readAsBytes()));
      final configuration = _decodeConfiguration(decoded);
      if (!mounted) return;

      final shouldImport = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Replace configuration?'),
          content: Text(
            'This will replace ${_quotes.length} tracked quote(s) and '
            '${_holdings.length} holding(s) with '
            '${configuration.quotes.length} quote(s) and '
            '${configuration.holdings.length} holding(s) from the selected file.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (shouldImport != true || !mounted) return;

      await _storage.saveQuotes(
        configuration.quotes.map((quote) => quote.toStorageJson()).toList(),
      );
      await _holdingStorage.saveHoldings(
        configuration.holdings.map((holding) => holding.toJson()).toList(),
      );
      if (!mounted) return;
      setState(() {
        _quotes = configuration.quotes;
        _holdings = configuration.holdings;
        _sortColumn = null;
        _isEditing = false;
        _isReorderingHoldings = false;
      });
      _showMessage('Configuration imported successfully.');
    } on FormatException catch (error) {
      if (mounted) {
        _showMessage('Invalid configuration file: ${error.message}');
      }
    } catch (_) {
      if (mounted) _showMessage('Could not import the configuration.');
    } finally {
      if (mounted) setState(() => _isProcessingBackup = false);
    }
  }

  _AppConfiguration _decodeConfiguration(Object? decoded) {
    if (decoded is! Map<String, dynamic> ||
        (decoded['format'] != 'stocktrack' &&
            decoded['format'] != 'stockcheck') ||
        decoded['version'] != 1 ||
        decoded['quotes'] is! List ||
        decoded['holdings'] is! List) {
      throw const FormatException(
        'Expected a Stocktrack configuration file (version 1).',
      );
    }

    final quotes = (decoded['quotes'] as List).map((value) {
      if (value is! Map) {
        throw const FormatException('Each quote must be a JSON object.');
      }
      return Quote.fromStorageJson(Map<String, dynamic>.from(value));
    }).toList();
    final holdings = (decoded['holdings'] as List).map((value) {
      if (value is! Map) {
        throw const FormatException('Each holding must be a JSON object.');
      }
      return Holding.fromJson(Map<String, dynamic>.from(value));
    }).toList();

    if (quotes.map((quote) => quote.symbol).toSet().length != quotes.length) {
      throw const FormatException('The file contains duplicate quote tickers.');
    }
    if (holdings.map((holding) => holding.symbol).toSet().length !=
        holdings.length) {
      throw const FormatException(
        'The file contains duplicate holding tickers.',
      );
    }
    return _AppConfiguration(quotes: quotes, holdings: holdings);
  }

  Future<void> _addQuote(String input) async {
    final symbol = input.trim().toUpperCase();
    if (symbol.isEmpty) return;
    if (_quotes.any((quote) => quote.symbol == symbol)) {
      _showMessage('$symbol is already in your quotes.');
      return;
    }

    setState(() => _isAdding = true);
    try {
      final quote = await _fetchQuoteWithCompanyName(symbol);
      if (!mounted) return;
      setState(() {
        _quotes = [..._quotes, quote];
        _sortColumn = null;
        _isEditing = false;
      });
      await _saveQuotes();
    } on QuoteException catch (error) {
      if (mounted) _showMessage(error.message);
    } on TimeoutException {
      if (mounted) _showMessage('Finnhub took too long to respond.');
    } catch (_) {
      if (mounted) {
        _showMessage('Could not reach Finnhub. Check your connection.');
      }
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  Future<Quote> _fetchQuote(
    String symbol, {
    QuoteProvider? preferredProvider,
  }) async {
    final providers = switch (preferredProvider) {
      QuoteProvider.yahooFinance => [QuoteProvider.yahooFinance],
      QuoteProvider.twelveData => [
        QuoteProvider.finnhub,
        QuoteProvider.yahooFinance,
      ],
      _ => [QuoteProvider.finnhub, QuoteProvider.yahooFinance],
    };
    final errors = <String>[];
    for (final provider in providers) {
      try {
        final quote = await _fetchFromProvider(symbol, provider);
        return quote.copyWith(provider: provider);
      } catch (error) {
        errors.add(
          '${_providerName(provider)} failed (${_quoteErrorMessage(error)})',
        );
      }
    }
    throw QuoteException(errors.join('; '));
  }

  Future<Quote> _fetchFromProvider(
    String symbol,
    QuoteProvider provider,
  ) async {
    return switch (provider) {
      QuoteProvider.finnhub =>
        await (widget.quoteFetcher?.call(symbol) ?? _fetchFinnhubQuote(symbol)),
      QuoteProvider.twelveData =>
        await (widget.twelveDataQuoteFetcher?.call(symbol) ??
            _fetchTwelveDataQuote(symbol)),
      QuoteProvider.yahooFinance => await _fetchYahooFinanceQuote(symbol),
    };
  }

  String _providerName(QuoteProvider provider) => switch (provider) {
    QuoteProvider.finnhub => 'Finnhub',
    QuoteProvider.twelveData => 'Twelve Data',
    QuoteProvider.yahooFinance => 'Yahoo Finance',
  };

  Future<Quote> _fetchFinnhubQuote(String symbol) async {
    final apiKey = await _loadFinnhubApiKey();
    final uri = Uri.https('finnhub.io', '/api/v1/quote', {
      'symbol': symbol,
      'token': apiKey,
    });
    final response = await http.get(uri).timeout(const Duration(seconds: 15));

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const QuoteException('Finnhub rejected the API key.');
    }
    if (response.statusCode == 429) {
      throw const QuoteException(
        'Finnhub rate limit reached. Try again shortly.',
      );
    }
    if (response.statusCode != 200) {
      throw QuoteException('Finnhub returned HTTP ${response.statusCode}.');
    }

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) {
      throw const QuoteException('Finnhub returned an unexpected response.');
    }
    final quote = Quote.fromJson(symbol, data);
    if (quote.currentPrice <= 0) {
      throw QuoteException('No quote was returned for $symbol.');
    }
    return quote;
  }

  String _quoteErrorMessage(Object error) => switch (error) {
    QuoteException(:final message) => message,
    TimeoutException() => 'request timed out',
    _ => 'network or response error',
  };

  Future<String> _loadTwelveDataApiKey() async {
    final configText = await rootBundle.loadString('assets/config.json');
    final config = jsonDecode(configText);
    if (config is! Map<String, dynamic>) {
      throw const QuoteException(
        'The Twelve Data config file is not valid JSON.',
      );
    }

    final apiKey = config['twelvedata_api_key'];
    if (apiKey is! String || apiKey.trim().isEmpty) {
      throw const QuoteException(
        'Add twelvedata_api_key to assets/config.local.json, then run '
        'dart run tool/prepare_config.dart.',
      );
    }
    return apiKey.trim();
  }

  Future<Quote> _fetchTwelveDataQuote(String symbol) async {
    final apiKey = await _loadTwelveDataApiKey();
    final uri = Uri.https('api.twelvedata.com', '/quote', {
      'symbol': symbol,
      'apikey': apiKey,
    });
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw QuoteException('Twelve Data returned HTTP ${response.statusCode}.');
    }

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) {
      throw const QuoteException(
        'Twelve Data returned an unexpected response.',
      );
    }
    return Quote.fromTwelveDataJson(symbol, data);
  }

  Future<Quote> _fetchYahooFinanceQuote(String symbol) async {
    final response =
        await (widget.yahooFinanceDailyFetcher?.call(symbol) ??
            YahooFinanceDailyReader().getDailyDTOs(symbol));
    return Quote.fromYahooFinanceResponse(symbol, response);
  }

  Future<String> _loadFinnhubApiKey() async {
    final configText = await rootBundle.loadString('assets/config.json');
    final config = jsonDecode(configText);
    if (config is! Map<String, dynamic>) {
      throw const QuoteException('The Finnhub config file is not valid JSON.');
    }

    final apiKey = config['finnhub_api_key'];
    if (apiKey is! String || apiKey.trim().isEmpty) {
      throw const QuoteException(
        'Add finnhub_api_key to assets/config.local.json, then run '
        'dart run tool/prepare_config.dart.',
      );
    }
    return apiKey.trim();
  }

  Future<String?> _fetchCompanyName(String symbol) async {
    final apiKey = await _loadFinnhubApiKey();
    final uri = Uri.https('finnhub.io', '/api/v1/stock/profile2', {
      'symbol': symbol,
      'token': apiKey,
    });
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const QuoteException('Finnhub rejected the API key.');
    }
    if (response.statusCode == 429) {
      throw const QuoteException(
        'Finnhub rate limit reached. Try again shortly.',
      );
    }
    if (response.statusCode != 200) {
      throw QuoteException('Finnhub returned HTTP ${response.statusCode}.');
    }
    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) {
      throw const QuoteException(
        'Finnhub returned an unexpected company profile.',
      );
    }
    final name = data['name'];
    return name is String && name.trim().isNotEmpty ? name.trim() : null;
  }

  Future<Quote> _fetchQuoteWithCompanyName(String symbol) async {
    final quote = await _fetchQuote(symbol);
    if (quote.companyName != null ||
        quote.provider == QuoteProvider.yahooFinance) {
      return quote;
    }
    try {
      return quote.copyWith(companyName: await _fetchCompanyName(symbol));
    } on QuoteException catch (error) {
      if (mounted) {
        _showMessage(
          'Could not load the company name for $symbol: ${error.message}',
        );
      }
    } on TimeoutException {
      if (mounted) {
        _showMessage(
          'Could not load the company name for $symbol: Finnhub timed out.',
        );
      }
    } catch (error) {
      if (mounted) {
        _showMessage('Could not load the company name for $symbol: $error');
      }
    }
    return quote;
  }

  Future<void> _refreshQuotes() async {
    if (_isRefreshingQuotes ||
        _isLoadingQuotes ||
        _quotes.isEmpty ||
        _isEditing ||
        _isAdding ||
        _isAddingHolding ||
        _isProcessingBackup) {
      return;
    }

    _isRefreshingQuotes = true;
    if (mounted) setState(() {});
    final refreshResults = <String, Quote>{};
    Object? refreshError;
    try {
      for (final quote in List<Quote>.of(_quotes)) {
        try {
          var updated = await _fetchQuote(
            quote.symbol,
            preferredProvider: quote.provider,
          );
          if (quote.companyName != null) {
            updated = updated.copyWith(companyName: quote.companyName);
          } else if (updated.companyName == null &&
              updated.provider != QuoteProvider.yahooFinance) {
            try {
              updated = updated.copyWith(
                companyName: await _fetchCompanyName(quote.symbol),
              );
            } catch (error) {
              refreshError ??= error;
            }
          }
          refreshResults[quote.symbol] = updated;
        } catch (error) {
          refreshError ??= error;
        }
      }

      if (!mounted) return;
      if (refreshResults.isNotEmpty) {
        setState(() {
          _quotes = _quotes
              .map((quote) => refreshResults[quote.symbol] ?? quote)
              .toList();
        });
        await _saveQuotes();
      }
      if (refreshError != null && mounted) {
        _showMessage(
          'Some quotes could not be refreshed: '
          '${_quoteErrorMessage(refreshError)}',
        );
      }
    } finally {
      _isRefreshingQuotes = false;
      if (mounted) setState(() {});
    }
  }

  void _deleteQuote(Quote quote) {
    setState(() => _quotes.removeWhere((item) => item.symbol == quote.symbol));
    _saveQuotes();
  }

  void _showMessage(String message) {
    _pendingMessages.add(message);
    if (!_isShowingMessage) unawaited(_showPendingMessages());
  }

  Future<void> _showPendingMessages() async {
    _isShowingMessage = true;
    try {
      while (mounted && _pendingMessages.isNotEmpty) {
        final message = _pendingMessages.removeAt(0);
        await showModalBottomSheet<void>(
          context: context,
          builder: (sheetContext) => SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Notice',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(message),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('OK'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    } finally {
      _isShowingMessage = false;
      if (mounted && _pendingMessages.isNotEmpty) {
        unawaited(_showPendingMessages());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _selectedTab,
          children: [
            _buildQuotesTab(context),
            _buildHoldingsTab(context),
            _buildConfigurationTab(context),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        height: 64,
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) => setState(() => _selectedTab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.show_chart_outlined),
            selectedIcon: Icon(Icons.show_chart),
            label: 'Quotes',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet),
            label: 'Holding',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildQuotesTab(BuildContext context) {
    return Column(
      children: [
        Padding(
          key: const ValueKey('quotes-title-row'),
          padding: const EdgeInsets.fromLTRB(20, 4, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Quotes',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Refresh quotes',
                onPressed: _canRefreshQuotes ? _refreshQuotes : null,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF81D4FA),
                  foregroundColor: const Color(0xFF10232B),
                  fixedSize: const Size(40, 40),
                  shape: const CircleBorder(),
                ),
                icon: _isRefreshingQuotes
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
              IconButton.filledTonal(
                tooltip: _isEditing ? 'Done editing' : 'Add ticker',
                onPressed: _isAdding || _isLoadingQuotes || _isRefreshingQuotes
                    ? null
                    : _isEditing
                    ? () => setState(() => _isEditing = false)
                    : _promptToAddQuote,
                icon: _isAdding
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_isEditing ? Icons.check : Icons.add),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _buildQuoteTable(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHoldingsTab(BuildContext context) {
    return Column(
      children: [
        Padding(
          key: const ValueKey('holdings-title-row'),
          padding: const EdgeInsets.fromLTRB(20, 4, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Holdings',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Refresh quotes',
                onPressed: _canRefreshQuotes ? _refreshQuotes : null,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF81D4FA),
                  foregroundColor: const Color(0xFF10232B),
                  fixedSize: const Size(40, 40),
                  shape: const CircleBorder(),
                ),
                icon: _isRefreshingQuotes
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
              IconButton.filledTonal(
                tooltip: _isReorderingHoldings
                    ? 'Done reordering'
                    : 'Add holding',
                onPressed:
                    _isLoadingHoldings ||
                        _isLoadingQuotes ||
                        _isAddingHolding ||
                        _isRefreshingQuotes
                    ? null
                    : _isReorderingHoldings
                    ? () => setState(() => _isReorderingHoldings = false)
                    : _promptToAddHolding,
                icon: _isAddingHolding
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_isReorderingHoldings ? Icons.check : Icons.add),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _isLoadingHoldings
                    ? const Center(child: CircularProgressIndicator())
                    : _holdings.isEmpty
                    ? const _EmptyHoldings()
                    : _buildHoldingTable(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool get _canRefreshQuotes =>
      !_isLoadingQuotes &&
      !_isRefreshingQuotes &&
      !_isEditing &&
      !_isReorderingHoldings &&
      !_isAdding &&
      !_isAddingHolding &&
      !_isProcessingBackup &&
      _quotes.isNotEmpty;

  Widget _buildConfigurationTab(BuildContext context) {
    final isLoading = _isLoadingQuotes || _isLoadingHoldings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
          child: Text(
            'Configuration',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                shrinkWrap: true,
                children: [
                  Text(
                    'Move your tracked quotes and holdings between devices '
                    'with a portable Stocktrack JSON v1 file. API credentials '
                    'are not included. Importing replaces your current data. '
                    'Yahoo Finance provides daily history; its latest value is '
                    'a daily close, not a real-time quote.',
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: const Color(0xFFB4B8BB)),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: isLoading || _isProcessingBackup
                        ? null
                        : _exportConfiguration,
                    icon: const Icon(Icons.file_upload_outlined),
                    label: const Text('Export configuration'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: isLoading || _isProcessingBackup
                        ? null
                        : _importConfiguration,
                    icon: const Icon(Icons.file_download_outlined),
                    label: const Text('Import configuration'),
                  ),
                  if (_isProcessingBackup) ...[
                    const SizedBox(height: 24),
                    const Center(child: CircularProgressIndicator()),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHoldingTable() {
    final quotesBySymbol = {for (final quote in _quotes) quote.symbol: quote};
    var marketValueUsd = 0.0;
    var costBasisUsd = 0.0;
    var dailyChangeUsd = 0.0;
    var marketValueUsdAvailable = true;
    var costBasisUsdAvailable = true;
    var dailyChangeUsdAvailable = true;
    for (final holding in _holdings) {
      final quote = quotesBySymbol[holding.symbol];
      final rate = _usdToEurRate;
      final nativeToUsd = holding.currency == HoldingCurrency.usd
          ? 1.0
          : rate == null
          ? null
          : 1 / rate;

      if (quote != null) {
        if (nativeToUsd == null) {
          marketValueUsdAvailable = false;
          dailyChangeUsdAvailable = false;
        } else {
          marketValueUsd += quote.currentPrice * holding.shares * nativeToUsd;
          dailyChangeUsd += quote.change * holding.shares * nativeToUsd;
        }
      } else if (nativeToUsd != null) {
        marketValueUsd += holding.averagePrice * holding.shares * nativeToUsd;
      } else {
        marketValueUsdAvailable = false;
      }

      if (nativeToUsd != null) {
        costBasisUsd += holding.averagePrice * holding.shares * nativeToUsd;
      } else {
        costBasisUsdAvailable = false;
      }
    }

    final totalMarketValueUsd = marketValueUsdAvailable ? marketValueUsd : null;
    final totalCostBasisUsd = costBasisUsdAvailable ? costBasisUsd : null;
    final totalChangeUsd =
        totalMarketValueUsd == null || totalCostBasisUsd == null
        ? null
        : totalMarketValueUsd - totalCostBasisUsd;
    final totalPercent = totalCostBasisUsd == null || totalCostBasisUsd == 0
        ? null
        : totalChangeUsd! / totalCostBasisUsd * 100;
    final totalDailyChangeUsd = dailyChangeUsdAvailable ? dailyChangeUsd : null;
    final dailyPercent =
        totalMarketValueUsd == null ||
            totalDailyChangeUsd == null ||
            totalMarketValueUsd - totalDailyChangeUsd == 0
        ? null
        : totalDailyChangeUsd /
              (totalMarketValueUsd - totalDailyChangeUsd) *
              100;

    return LayoutBuilder(
      builder: (context, constraints) {
        final tableWidth = constraints.maxWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            child: Column(
              children: [
                const _HoldingTableHeader(),
                Expanded(
                  child: ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: _holdings.length,
                    onReorderItem: _reorderHolding,
                    itemBuilder: (context, index) {
                      final holding = _holdings[index];
                      return _HoldingRow(
                        key: ValueKey(holding.symbol),
                        holding: holding,
                        quote: quotesBySymbol[holding.symbol],
                        usdToEurRate: _usdToEurRate,
                        index: index,
                        isReordering: _isReorderingHoldings,
                        onLongPress: _isReorderingHoldings
                            ? null
                            : (rowContext) =>
                                  _showHoldingActions(holding, rowContext),
                      );
                    },
                  ),
                ),
                _HoldingTotals(
                  marketValueUsd: totalMarketValueUsd,
                  costBasisUsd: totalCostBasisUsd,
                  dailyChangeUsd: totalDailyChangeUsd,
                  dailyPercent: dailyPercent,
                  totalChangeUsd: totalChangeUsd,
                  totalPercent: totalPercent,
                  usdToEurRate: _usdToEurRate,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildQuoteTable(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tableWidth = constraints.maxWidth < 195
            ? 195.0
            : constraints.maxWidth;
        final compactPhoneLayout = tableWidth <= 500;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            child: Column(
              children: [
                _QuoteTableHeader(
                  isEditing: _isEditing,
                  sortColumn: _sortColumn,
                  sortAscending: _sortAscending,
                  onSort: _isEditing ? null : _sortBy,
                  compactPhoneLayout: compactPhoneLayout,
                ),
                Expanded(
                  child: _quotes.isEmpty
                      ? const _EmptyQuotes()
                      : ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          itemCount: _displayQuotes.length,
                          onReorderItem: _reorder,
                          itemBuilder: (context, index) {
                            final quote = _displayQuotes[index];
                            return GestureDetector(
                              key: ValueKey(quote.symbol),
                              onLongPress: _isEditing ? null : _enterEditMode,
                              child: _QuoteRow(
                                quote: quote,
                                index: index,
                                isEditing: _isEditing,
                                compactPhoneLayout: compactPhoneLayout,
                                onDelete: () => _deleteQuote(quote),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

enum SortColumn { ticker, price, change }

class _AddQuoteDialog extends StatefulWidget {
  const _AddQuoteDialog();

  @override
  State<_AddQuoteDialog> createState() => _AddQuoteDialogState();
}

class _AddQuoteDialogState extends State<_AddQuoteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add ticker'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        autocorrect: false,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Ticker symbol',
          hintText: 'AAPL',
        ),
        onSubmitted: (_) => Navigator.of(context).pop(_controller.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _AddHoldingDialog extends StatefulWidget {
  const _AddHoldingDialog({this.initialHolding});

  final Holding? initialHolding;

  @override
  State<_AddHoldingDialog> createState() => _AddHoldingDialogState();
}

class _AddHoldingDialogState extends State<_AddHoldingDialog> {
  final _formKey = GlobalKey<FormState>();
  late HoldingCurrency _currency =
      widget.initialHolding?.currency ?? HoldingCurrency.usd;
  late final _symbolController = TextEditingController(
    text: widget.initialHolding?.symbol,
  );
  late final _sharesController = TextEditingController(
    text: widget.initialHolding == null
        ? null
        : _shares(widget.initialHolding!.shares),
  );
  late final _priceController = TextEditingController(
    text: widget.initialHolding?.averagePrice.toString(),
  );

  @override
  void dispose() {
    _symbolController.dispose();
    _sharesController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(
        widget.initialHolding == null ? 'Add holding' : 'Edit holding',
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _symbolController,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Stock ticker',
                hintText: 'AAPL',
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a stock ticker.'
                  : null,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _sharesController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Shares'),
                    validator: (value) {
                      final shares = double.tryParse(value ?? '');
                      return shares == null || !shares.isFinite || shares <= 0
                          ? 'Enter a number greater than zero.'
                          : null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<HoldingCurrency>(
                    initialValue: _currency,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Currency'),
                    items: const [
                      DropdownMenuItem(
                        value: HoldingCurrency.usd,
                        child: Text('USD (\$)'),
                      ),
                      DropdownMenuItem(
                        value: HoldingCurrency.eur,
                        child: Text('EUR (€)'),
                      ),
                    ],
                    onChanged: (currency) {
                      if (currency != null) {
                        setState(() => _currency = currency);
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            TextFormField(
              controller: _priceController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                labelText:
                    'Average price per share (${_currency.name.toUpperCase()})',
                prefixText: _currency == HoldingCurrency.usd ? '\$' : '€',
              ),
              validator: (value) {
                final price = double.tryParse(value ?? '');
                return price == null || !price.isFinite || price <= 0
                    ? 'Enter a price greater than zero.'
                    : null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.of(context).pop(
              Holding(
                symbol: _symbolController.text.trim().toUpperCase(),
                shares: double.parse(_sharesController.text),
                averagePrice: double.parse(_priceController.text),
                currency: _currency,
              ),
            );
          },
          child: Text(widget.initialHolding == null ? 'Add' : 'Save'),
        ),
      ],
    );
  }
}

class Quote {
  const Quote({
    required this.symbol,
    required this.currentPrice,
    required this.change,
    required this.percentChange,
    required this.previousClose,
    required this.timestamp,
    this.companyName,
    this.provider,
  });

  final String symbol;
  final double currentPrice;
  final double change;
  final double percentChange;
  final double previousClose;
  final DateTime? timestamp;
  final String? companyName;
  final QuoteProvider? provider;

  Quote copyWith({String? companyName, QuoteProvider? provider}) => Quote(
    symbol: symbol,
    currentPrice: currentPrice,
    change: change,
    percentChange: percentChange,
    previousClose: previousClose,
    timestamp: timestamp,
    companyName: companyName ?? this.companyName,
    provider: provider ?? this.provider,
  );

  factory Quote.fromJson(String symbol, Map<String, dynamic> json) {
    double value(String key) => (json[key] as num?)?.toDouble() ?? 0;
    final epoch = (json['t'] as num?)?.toInt() ?? 0;

    return Quote(
      symbol: symbol,
      currentPrice: value('c'),
      change: value('d'),
      percentChange: value('dp'),
      previousClose: value('pc'),
      timestamp: epoch > 0
          ? DateTime.fromMillisecondsSinceEpoch(epoch * 1000).toLocal()
          : null,
      provider: QuoteProvider.finnhub,
    );
  }

  factory Quote.fromTwelveDataJson(
    String requestedSymbol,
    Map<String, dynamic> json,
  ) {
    if (json['status'] == 'error' || json['code'] != null) {
      final message = json['message'];
      throw QuoteException(
        message is String && message.isNotEmpty
            ? 'Twelve Data: $message'
            : 'Twelve Data rejected the quote request.',
      );
    }

    double value(String key) {
      final raw = json[key];
      final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw');
      if (parsed == null || !parsed.isFinite) {
        throw QuoteException('Twelve Data returned an invalid $key value.');
      }
      return parsed;
    }

    final symbol = json['symbol'];
    if (symbol is! String || symbol.trim().isEmpty) {
      throw const QuoteException('Twelve Data returned an invalid symbol.');
    }
    final close = value('close');
    if (close <= 0) {
      throw QuoteException(
        'Twelve Data returned no quote for $requestedSymbol.',
      );
    }
    final name = json['name'];
    final datetime = json['datetime'];
    final rawTimestamp = json['timestamp'];
    final epoch = rawTimestamp is num
        ? rawTimestamp.toInt()
        : int.tryParse('$rawTimestamp') ?? 0;
    final timestamp = epoch > 0
        ? DateTime.fromMillisecondsSinceEpoch(epoch * 1000).toLocal()
        : datetime is String
        ? DateTime.tryParse(datetime)?.toLocal()
        : null;

    return Quote(
      symbol: symbol.trim().toUpperCase(),
      currentPrice: close,
      change: value('change'),
      percentChange: value('percent_change'),
      previousClose: value('previous_close'),
      timestamp: timestamp,
      companyName: name is String && name.trim().isNotEmpty
          ? name.trim()
          : null,
      provider: QuoteProvider.twelveData,
    );
  }

  factory Quote.fromYahooFinanceResponse(
    String requestedSymbol,
    YahooFinanceResponse response,
  ) {
    if (response.candlesData.isEmpty) {
      throw QuoteException(
        'Yahoo Finance returned no daily history for $requestedSymbol.',
      );
    }

    final candles = [...response.candlesData]
      ..sort((first, second) => first.date.compareTo(second.date));
    final latest = candles.last;
    final close = latest.close;
    if (!close.isFinite || close <= 0) {
      throw QuoteException(
        'Yahoo Finance returned an invalid daily close for $requestedSymbol.',
      );
    }

    final previousClose = candles.length > 1
        ? candles[candles.length - 2].close
        : close;
    if (!previousClose.isFinite || previousClose <= 0) {
      throw QuoteException(
        'Yahoo Finance returned an invalid previous close for $requestedSymbol.',
      );
    }

    final change = close - previousClose;
    return Quote(
      symbol: requestedSymbol,
      currentPrice: close,
      change: change,
      percentChange: change / previousClose * 100,
      previousClose: previousClose,
      timestamp: latest.date,
      provider: QuoteProvider.yahooFinance,
    );
  }

  factory Quote.fromStorageJson(Map<String, dynamic> json) {
    final symbol = json['symbol'];
    final timestamp = json['timestamp'];
    if (symbol is! String || symbol.isEmpty) {
      throw const FormatException('Saved quote has an invalid symbol.');
    }
    if (timestamp != null && timestamp is! String) {
      throw const FormatException('Saved quote has an invalid timestamp.');
    }
    final companyName = json['companyName'];
    if (companyName != null && companyName is! String) {
      throw const FormatException('Saved quote has an invalid company name.');
    }
    final providerName = json['provider'];
    if (providerName != null && providerName is! String) {
      throw const FormatException('Saved quote has an invalid provider.');
    }
    final provider = switch (providerName) {
      null => null,
      'finnhub' => QuoteProvider.finnhub,
      'twelveData' => QuoteProvider.twelveData,
      'yahooFinance' => QuoteProvider.yahooFinance,
      _ => throw const FormatException('Saved quote has an unknown provider.'),
    };
    double value(String key) {
      final raw = json[key];
      if (raw is! num) {
        throw FormatException('Saved quote has an invalid $key value.');
      }
      return raw.toDouble();
    }

    return Quote(
      symbol: symbol,
      currentPrice: value('currentPrice'),
      change: value('change'),
      percentChange: value('percentChange'),
      previousClose: value('previousClose'),
      timestamp: timestamp == null ? null : DateTime.parse(timestamp),
      companyName: companyName as String?,
      provider: provider,
    );
  }

  Map<String, Object?> toStorageJson() => {
    'symbol': symbol,
    'currentPrice': currentPrice,
    'change': change,
    'percentChange': percentChange,
    'previousClose': previousClose,
    'timestamp': timestamp?.toIso8601String(),
    'companyName': companyName,
    'provider': provider?.name,
  };
}

class QuoteException implements Exception {
  const QuoteException(this.message);

  final String message;
}

class _QuoteTableHeader extends StatelessWidget {
  const _QuoteTableHeader({
    required this.isEditing,
    required this.sortColumn,
    required this.sortAscending,
    required this.onSort,
    required this.compactPhoneLayout,
  });

  final bool isEditing;
  final SortColumn? sortColumn;
  final bool sortAscending;
  final ValueChanged<SortColumn>? onSort;
  final bool compactPhoneLayout;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('quotes-table-header'),
      height: 54,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF34383B))),
      ),
      child: Row(
        children: [
          if (isEditing) const SizedBox(width: 44),
          Expanded(
            flex: compactPhoneLayout ? 4 : 2,
            child: _SortHeading(
              label: 'Ticker',
              column: SortColumn.ticker,
              activeColumn: sortColumn,
              ascending: sortAscending,
              onTap: onSort,
              alignRight: false,
            ),
          ),
          Expanded(
            flex: compactPhoneLayout ? 2 : 3,
            child: _SortHeading(
              label: 'Last Price',
              column: SortColumn.price,
              activeColumn: sortColumn,
              ascending: sortAscending,
              onTap: onSort,
              alignRight: true,
            ),
          ),
          Expanded(
            flex: compactPhoneLayout ? 2 : 3,
            child: _SortHeading(
              label: 'Change',
              column: SortColumn.change,
              activeColumn: sortColumn,
              ascending: sortAscending,
              onTap: onSort,
              alignRight: true,
            ),
          ),
          if (isEditing) const SizedBox(width: 44),
        ],
      ),
    );
  }
}

class _SortHeading extends StatelessWidget {
  const _SortHeading({
    required this.label,
    required this.column,
    required this.activeColumn,
    required this.ascending,
    required this.onTap,
    required this.alignRight,
  });

  final String label;
  final SortColumn column;
  final SortColumn? activeColumn;
  final bool ascending;
  final ValueChanged<SortColumn>? onTap;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    final isActive = activeColumn == column;
    return InkWell(
      onTap: onTap == null ? null : () => onTap!(column),
      child: Row(
        mainAxisAlignment: alignRight
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isActive ? Colors.white : const Color(0xFF9B9FA3),
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(width: 3),
          Icon(
            isActive
                ? ascending
                      ? Icons.arrow_upward
                      : Icons.arrow_downward
                : Icons.unfold_more,
            size: 15,
            color: isActive ? const Color(0xFF58D6A0) : const Color(0xFF85898D),
          ),
        ],
      ),
    );
  }
}

class _QuoteRow extends StatelessWidget {
  const _QuoteRow({
    required this.quote,
    required this.index,
    required this.isEditing,
    required this.compactPhoneLayout,
    required this.onDelete,
  });

  final Quote quote;
  final int index;
  final bool isEditing;
  final bool compactPhoneLayout;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isPositive = quote.change >= 0;
    final movementColor = isPositive
        ? const Color(0xFF159447)
        : const Color(0xFFB52E38);
    final time = quote.timestamp;
    final dragHandle = const Icon(Icons.drag_handle, color: Color(0xFF777C80));
    final dragListener = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia =>
        ReorderableDelayedDragStartListener(index: index, child: dragHandle),
      _ => ReorderableDragStartListener(index: index, child: dragHandle),
    };

    return Container(
      height: 46,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF202326))),
      ),
      child: Row(
        children: [
          if (isEditing)
            SizedBox(
              width: 44,
              child: IconButton(
                tooltip: 'Remove ${quote.symbol}',
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.remove_circle,
                  color: Color(0xFFEA454D),
                  size: 28,
                ),
              ),
            ),
          Expanded(
            flex: compactPhoneLayout ? 4 : 2,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    quote.symbol,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600, height: 1),
                  ),
                  if (quote.companyName != null)
                    SizedBox(
                      width: double.infinity,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          quote.companyName!,
                          maxLines: 1,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: const Color(0xFF92969A),
                                fontSize: 11,
                                height: 1,
                              ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: compactPhoneLayout ? 2 : 3,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('\$${quote.currentPrice.toStringAsFixed(2)}'),
                ),
                if (time != null)
                  Text(
                    quote.provider == QuoteProvider.yahooFinance
                        ? time.toIso8601String().substring(0, 10)
                        : TimeOfDay.fromDateTime(time).format(context),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: const Color(0xFF92969A)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: compactPhoneLayout ? 2 : 3,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: movementColor,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${isPositive ? '+' : ''}${quote.change.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${isPositive ? '+' : ''}${quote.percentChange.toStringAsFixed(2)}%',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isEditing) SizedBox(width: 44, child: dragListener),
        ],
      ),
    );
  }
}

class _EmptyQuotes extends StatelessWidget {
  const _EmptyQuotes();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.show_chart, size: 34, color: Color(0xFF777C80)),
          const SizedBox(height: 12),
          Text(
            'No quotes yet',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(color: const Color(0xFFCFD2D4)),
          ),
          const SizedBox(height: 4),
          const Text(
            'Add a ticker to start tracking.',
            style: TextStyle(color: Color(0xFF85898D)),
          ),
        ],
      ),
    );
  }
}

enum HoldingCurrency { usd, eur }

class Holding {
  const Holding({
    required this.symbol,
    required this.shares,
    required this.averagePrice,
    this.currency = HoldingCurrency.usd,
  });

  final String symbol;
  final double shares;
  final double averagePrice;
  final HoldingCurrency currency;

  factory Holding.fromJson(Map<String, dynamic> json) {
    final symbol = json['symbol'];
    final shares = json['shares'];
    final averagePrice = json['averagePrice'];
    final currencyName = json['currency'];
    if (symbol is! String || symbol.isEmpty) {
      throw const FormatException('Saved holding has an invalid ticker.');
    }
    if (shares is! num || !shares.toDouble().isFinite || shares <= 0) {
      throw const FormatException('Saved holding has an invalid share count.');
    }
    if (averagePrice is! num ||
        !averagePrice.toDouble().isFinite ||
        averagePrice <= 0) {
      throw const FormatException(
        'Saved holding has an invalid average price.',
      );
    }
    if (currencyName != null &&
        (currencyName is! String ||
            !HoldingCurrency.values.any(
              (currency) => currency.name == currencyName,
            ))) {
      throw const FormatException('Saved holding has an invalid currency.');
    }
    return Holding(
      symbol: symbol,
      shares: shares.toDouble(),
      averagePrice: averagePrice.toDouble(),
      currency: currencyName == 'eur'
          ? HoldingCurrency.eur
          : HoldingCurrency.usd,
    );
  }

  Map<String, Object?> toJson() => {
    'symbol': symbol,
    'shares': shares,
    'averagePrice': averagePrice,
    'currency': currency.name,
  };
}

enum _HoldingAction { edit, delete, reorder }

class _HoldingTableHeader extends StatelessWidget {
  const _HoldingTableHeader();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Color(0xFF9B9FA3),
      fontWeight: FontWeight.w500,
    );
    return Container(
      key: const ValueKey('holdings-table-header'),
      height: 54,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF34383B))),
      ),
      child: const Row(
        children: [
          Expanded(flex: 3, child: Text('Ticker', style: style)),
          Expanded(
            flex: 3,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Value', style: style, maxLines: 1),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Cost basis', style: style, maxLines: 1),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Text('Daily', style: style, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 3,
            child: Text('Total', style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

class _HoldingRow extends StatelessWidget {
  const _HoldingRow({
    super.key,
    required this.holding,
    required this.quote,
    required this.usdToEurRate,
    required this.index,
    required this.isReordering,
    required this.onLongPress,
  });

  final Holding holding;
  final Quote? quote;
  final double? usdToEurRate;
  final int index;
  final bool isReordering;
  final ValueChanged<BuildContext>? onLongPress;

  @override
  Widget build(BuildContext context) {
    final currentQuote = quote;
    final rate = usdToEurRate;
    final isEur = holding.currency == HoldingCurrency.eur;
    final price = currentQuote?.currentPrice ?? holding.averagePrice;
    final quotePriceUsd = isEur
        ? rate == null
              ? null
              : price / rate
        : price;
    final marketValue = price * holding.shares;
    final costBasis = holding.averagePrice * holding.shares;
    final dailyChange = currentQuote == null
        ? 0.0
        : currentQuote.change * holding.shares;
    final totalChange = marketValue - costBasis;
    final totalChangeUsd = isEur
        ? rate == null
              ? null
              : totalChange / rate
        : totalChange;
    final totalChangeEur = isEur
        ? totalChange
        : totalChangeUsd == null || rate == null
        ? null
        : totalChangeUsd * rate;
    final totalPercent = costBasis == 0 ? 0.0 : totalChange / costBasis * 100;

    final dragHandle = const Icon(Icons.drag_handle, color: Color(0xFF777C80));
    final dragListener = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia =>
        ReorderableDelayedDragStartListener(index: index, child: dragHandle),
      _ => ReorderableDragStartListener(index: index, child: dragHandle),
    };

    return GestureDetector(
      onLongPress: onLongPress == null ? null : () => onLongPress!(context),
      child: Container(
        constraints: const BoxConstraints(minHeight: 54),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF202326))),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    holding.symbol,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontSize: 15,
                      height: 1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  _holdingPriceText(
                    price,
                    holding.currency,
                    usdEquivalent: quotePriceUsd,
                  ),
                  Text(
                    '${_shares(holding.shares)} shares',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF92969A),
                      fontSize: 11,
                      height: 1,
                    ),
                  ),
                  _holdingPriceText(
                    holding.averagePrice,
                    holding.currency,
                    usdEquivalent: isEur && rate != null
                        ? holding.averagePrice / rate
                        : isEur
                        ? null
                        : holding.averagePrice,
                    muted: true,
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _moneyOrDash(marketValue, holding.currency),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _moneyForCurrency(costBasis, holding.currency),
                      style: const TextStyle(color: Color(0xFF92969A)),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: _HoldingMetric(
                amount: dailyChange,
                percent: quote?.percentChange,
                currency: holding.currency,
              ),
            ),
            Expanded(
              flex: 3,
              child: _HoldingMetric(
                amount: totalChangeUsd,
                percent: totalPercent,
                eurAmount: totalChangeEur,
                showEurAmount: true,
              ),
            ),
            if (isReordering) SizedBox(width: 36, child: dragListener),
          ],
        ),
      ),
    );
  }
}

class _HoldingMetric extends StatelessWidget {
  const _HoldingMetric({
    required this.amount,
    required this.percent,
    this.eurAmount,
    this.currency = HoldingCurrency.usd,
    this.showEurAmount = false,
    this.compact = false,
  });

  final double? amount;
  final double? percent;
  final double? eurAmount;
  final HoldingCurrency currency;
  final bool showEurAmount;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final positive = (amount ?? eurAmount ?? 0) >= 0;
    final changePercent = percent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: compact ? 0 : 3),
        decoration: BoxDecoration(
          color: positive ? const Color(0xFF159447) : const Color(0xFFB52E38),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _signedMoney(amount, currency),
                style: const TextStyle(fontWeight: FontWeight.w600, height: 1),
              ),
            ),
            if (showEurAmount || eurAmount != null)
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _signedMoney(eurAmount, HoldingCurrency.eur),
                  style: const TextStyle(fontSize: 11, height: 1),
                ),
              )
            else
              const SizedBox(height: 11),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                changePercent == null
                    ? '--%'
                    : '${changePercent >= 0 ? '+' : '-'}${changePercent.abs().toStringAsFixed(2)}%',
                style: const TextStyle(fontSize: 12, height: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HoldingTotals extends StatelessWidget {
  const _HoldingTotals({
    required this.marketValueUsd,
    required this.costBasisUsd,
    required this.dailyChangeUsd,
    required this.dailyPercent,
    required this.totalChangeUsd,
    required this.totalPercent,
    required this.usdToEurRate,
  });

  final double? marketValueUsd;
  final double? costBasisUsd;
  final double? dailyChangeUsd;
  final double? dailyPercent;
  final double? totalChangeUsd;
  final double? totalPercent;
  final double? usdToEurRate;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('holding-totals-row'),
      height: 88,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFF34383B))),
      ),
      child: Row(
        children: [
          const Expanded(
            flex: 3,
            child: Text('TOTAL', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          Expanded(
            flex: 3,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _moneyOrDash(marketValueUsd, HoldingCurrency.usd),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _moneyOrDash(
                      marketValueUsd == null || usdToEurRate == null
                          ? null
                          : marketValueUsd! * usdToEurRate!,
                      HoldingCurrency.eur,
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _moneyOrDash(costBasisUsd, HoldingCurrency.usd),
                    style: const TextStyle(color: Color(0xFF92969A)),
                  ),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _moneyOrDash(
                      costBasisUsd == null || usdToEurRate == null
                          ? null
                          : costBasisUsd! * usdToEurRate!,
                      HoldingCurrency.eur,
                    ),
                    style: const TextStyle(color: Color(0xFF92969A)),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: _HoldingMetric(
              amount: dailyChangeUsd,
              percent: dailyPercent,
              eurAmount: usdToEurRate == null || dailyChangeUsd == null
                  ? null
                  : dailyChangeUsd! * usdToEurRate!,
              showEurAmount: true,
              compact: true,
            ),
          ),
          Expanded(
            flex: 3,
            child: _HoldingMetric(
              amount: totalChangeUsd,
              percent: totalPercent,
              eurAmount: usdToEurRate == null
                  ? null
                  : totalChangeUsd == null
                  ? null
                  : totalChangeUsd! * usdToEurRate!,
              showEurAmount: true,
              compact: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyHoldings extends StatelessWidget {
  const _EmptyHoldings();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.account_balance_wallet_outlined,
            size: 34,
            color: Color(0xFF777C80),
          ),
          SizedBox(height: 12),
          Text(
            'No holdings yet',
            style: TextStyle(
              color: Color(0xFFCFD2D4),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Add a holding to track your portfolio.',
            style: TextStyle(color: Color(0xFF85898D)),
          ),
        ],
      ),
    );
  }
}

String _money(double value) => '\$${value.toStringAsFixed(2)}';

String _moneyForCurrency(double value, HoldingCurrency currency) =>
    currency == HoldingCurrency.usd
    ? _money(value)
    : '€${value.toStringAsFixed(2)}';

String _moneyOrDash(double? value, HoldingCurrency currency) => value == null
    ? (currency == HoldingCurrency.usd ? '\$--' : '€--')
    : _moneyForCurrency(value, currency);

String _signedMoney(double? value, HoldingCurrency currency) {
  if (value == null) return _moneyOrDash(null, currency);
  return '${value >= 0 ? '+' : '-'}${_moneyForCurrency(value.abs(), currency)}';
}

Widget _holdingPriceText(
  double? price,
  HoldingCurrency currency, {
  required double? usdEquivalent,
  bool muted = false,
}) {
  final mutedColor = muted ? const Color(0xFF92969A) : null;
  return FittedBox(
    alignment: Alignment.centerLeft,
    fit: BoxFit.scaleDown,
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: _moneyOrDash(price, currency),
            style: TextStyle(fontWeight: FontWeight.w600, color: mutedColor),
          ),
          if (currency == HoldingCurrency.eur)
            TextSpan(
              text: ' (${_moneyOrDash(usdEquivalent, HoldingCurrency.usd)})',
              style: TextStyle(
                color: mutedColor ?? const Color(0xFF92969A),
                fontSize: 9,
              ),
            ),
        ],
      ),
      maxLines: 1,
      style: const TextStyle(fontSize: 11, height: 1),
    ),
  );
}

String _shares(double value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';
