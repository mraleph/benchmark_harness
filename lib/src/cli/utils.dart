import 'dart:io';

import 'package:dcli/dcli.dart';
import 'package:path/path.dart' as p;

import 'package:benchmark_harness/src/simpleperf/flutter_symbols.dart';
import 'package:benchmark_harness/src/simpleperf/ndk.dart';

final ndk = Ndk.fromEnvironment();
final flutterSymbolsCache = SymbolsCache(
  ndk: ndk,
  path: 'build/flutter-symbols-cache',
);

final applicationId = _applicationIdPattern
    .firstMatch(File('android/app/build.gradle').readAsStringSync())!
    .namedGroup('appId')!;

final String flutterBin = p.dirname(which('flutter').path!);

final String flutterEngineHash =
    File(p.join(flutterBin, 'internal', 'engine.version'))
        .readAsStringSync()
        .trim();

String localEnginePath(String localEngine) {
  return p.absolute(
      flutterBin, '..', '..', 'engine', 'src', 'out', localEngine);
}

Future<void> withTemporaryDir(Future<void> Function(String path) body,
    {required String prefix}) async {
  final tempDir = await Directory.systemTemp.createTemp(prefix);
  try {
    await body(tempDir.path);
  } finally {
    await tempDir.delete(recursive: true);
  }
}

void runCommand(String command) {
  final [cmd, ...args] = command.split(' ');
  final result = Process.runSync(cmd, args);
  if (result.exitCode != 0) {
    throw ProcessException(command, args, 'Failed to run', result.exitCode);
  }
}

final _applicationIdPattern = RegExp(
    r'''^\s*applicationId\s+['"](?<appId>.*)['"]\s*$''',
    multiLine: true);
