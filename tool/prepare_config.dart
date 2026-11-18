import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  const localConfigPath = 'assets/config.local.json';
  const exampleConfigPath = 'assets/config.example.json';
  const buildConfigPath = 'assets/config.json';

  final localConfig = File(localConfigPath);
  final source = localConfig.existsSync()
      ? localConfig
      : File(exampleConfigPath);
  final decoded = jsonDecode(await source.readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('${source.path} must contain a JSON object.');
  }

  await File(buildConfigPath)
      .writeAsString(const JsonEncoder.withIndent('  ').convert(decoded));
  stdout.writeln(
    localConfig.existsSync()
        ? 'Prepared assets/config.json from assets/config.local.json.'
        : 'Prepared assets/config.json with empty keys. '
              'Add private keys to assets/config.local.json and run this '
              'command again.',
  );
}
