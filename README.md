# StockTrack

Stocktrack is a Flutter app for tracking stock quotes and a personal
investment portfolio. Maintain a watchlist, record holdings and their average
purchase prices, and review market value, cost basis, daily movement, and
overall gain or loss.

Quotes use Finnhub first and Yahoo Finance as a fallback. Yahoo Finance
supplies daily historical data, so its latest value is a daily closing price,
not a live or intraday quote. Holdings can be denominated in USD or EUR; the
portfolio summary displays values in both currencies using a fetched
USD-to-EUR exchange rate.

## API key configuration

The app loads API keys from `assets/config.json` when it runs. That file is a
generated build input, not where you should store your keys: it is ignored by
Git and can be deleted after use. Store private keys in
`assets/config.local.json`, which is also ignored by Git. The tracked
`assets/config.example.json` is a template containing empty values.

Run the preparation command before `flutter run`, `flutter test`, or a build:

```sh
# On a new clone, create your private config from the empty template:
cp assets/config.example.json assets/config.local.json
# Enter your keys in assets/config.local.json using an editor.

# Generate assets/config.json from your private config:
dart run tool/prepare_config.dart

# Now run or build the app:
flutter run
```

`dart run tool/prepare_config.dart` copies `assets/config.local.json` to
`assets/config.json`. If there is no local config, it copies the empty example
instead, so the app can still start and tell you which keys are missing. It
does not edit or overwrite your local config. Run it again whenever you change
your local keys or delete the generated `assets/config.json`; Flutter needs
that generated file because it is listed as an app asset.

The keys are still bundled in any built client app and can be extracted from
its binary. Git-ignoring them prevents committing them to GitHub, but does not
make client-side API keys secret. Use a backend proxy for credentials that
must remain private.

The app fetches the USD-to-EUR rate once at startup using
`free_currency_api_key`. Each holding's selected currency applies to its quote,
purchase price, market value, cost basis, and daily change. Existing holdings
without a saved currency default to USD. Portfolio totals are normalized and
shown in both currencies.

## Quote providers

Saved quotes associated with Yahoo Finance refresh from Yahoo Finance only;
if that request fails, the app reports the error rather than silently switching
providers. The Twelve Data implementation remains in the codebase for possible
future use but is not currently part of quote requests.
