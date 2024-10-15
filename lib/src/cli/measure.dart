/// Implementation of `measure` command.
///
/// Builds, runs and collects information about all benchmarks in the
/// current Flutter project.
library benchmark_harness.cli.measure;

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:benchmark_harness/src/cli/results.dart';
import 'package:benchmark_harness/src/cli/utils.dart';
import 'package:dcli/dcli.dart';
import 'package:path/path.dart' as p;

import 'package:benchmark_harness/benchmark_runner.dart';
import 'package:benchmark_harness/src/cli/report.dart';

class MeasureCommand extends Command {
  // The [name] and [description] properties must be defined by every
  // subclass.
  @override
  final name = 'measure';
  @override
  final description = 'Run benchmarks and report results';

  MeasureCommand() {
    argParser.addOption('local-engine');
  }

  @override
  Future<void> run() async {
    final localEngine = argResults!['local-engine'] as String;

    // Check that the app is marked as profilable.
    if (!File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync()
        .contains(RegExp(r'<profileable\s*android:shell="true"\s*/>'))) {
      print(red('''
Error: Can't locate <profileable android:shell="true" /> in AndroidManifest.xml
  '''));
      exit(1);
    }

    // Prepare device for profiling (assumes Android).
    print(blue('Preparing device for profiling'));
    await ndk.apiProfilerPrepare();

    // Generate benchmark wrapper scripts.
    print(blue('Generating benchmark wrappers'));
    'flutter pub run build_runner build --delete-conflicting-outputs'
        .start(progress: Progress.devNull());

    // Run all generated benchmarks.
    final results = Results(localEngine: localEngine);
    var id = 0;
    for (var file in find('*.benchmark.dart').toList().map(p.relative)) {
      results.data[file] =
          await _runBenchmarksIn(id++, file, localEngine: localEngine);
    }
    await File('build/benchmarks/results.json')
        .writeAsString(jsonEncode(results));

    // Report results.
    print('');
    print('-' * 80);
    print('');
    await reportResults(results, verbose: globalResults['verbose'] as bool);
  }
}

/// Runs all benchmarks in `.benchmark.dart` [file] one by one and collects
/// their results.
Future<Map<String, BenchmarkResult>> _runBenchmarksIn(int id, String file,
    {String? localEngine}) async {
  final results = <String, BenchmarkResult>{};

  final benchmarks = _benchmarkListPattern
      .firstMatch(File(file).readAsStringSync())!
      .namedGroup('list')!
      .split(',');
  print(blue('Found ${benchmarks.length} benchmarks in $file'
      '($benchmarks)'));
  final outDir = 'build/benchmarks/artifacts$id';
  await Directory(outDir).create(recursive: true);
  for (var name in benchmarks) {
    results[name] =
        await _runBenchmark(file, name, outDir, localEngine: localEngine);
    await File(
            './build/app/intermediates/merged_native_libs/release/out/lib/arm64-v8a/libapp.so')
        .copy(p.join(outDir, 'libapp-$name.so'));
  }
  print(blue('  fetching profiles'));
  await ndk.apiProfilerCollect(
    app: applicationId,
    outDir: outDir,
  );
  return results;
}

/// Runs benchmark with the given [name] defined in the given [file] and
/// collects its result.
Future<BenchmarkResult> _runBenchmark(String file, String name, String outDir,
    {String? localEngine}) async {
  final commentsFile = p.join(outDir, 'code-comments-$name');
  print(blue('  build $name'));

  final localEngineOption =
      localEngine == null ? '' : '--local-engine $localEngine';
  final extraGenSnapshotOptions = '--extra-gen-snapshot-options=' +
      [
        '--dwarf-stack-traces',
        '--no-strip',
        '--code-comments',
        '--write-code-comments-as-synthetic-source-to=$commentsFile',
        '--ignore_unrecognized_flags'
      ].join(',');
  'flutter build apk --release $extraGenSnapshotOptions $localEngineOption  --dart-define targetBenchmark=$name -t $file'
      .run;
  print(blue('  measuring $name'));
  final process = await Process.start('flutter', [
    'run',
    '--release',
    '--machine',
    '--use-application-binary=build/app/outputs/flutter-apk/app-release.apk',
    '-t',
    file,
  ]);

  late BenchmarkResult result;
  late String appId;

  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {});

  // Process JSON-RPC events from the flutter run command.
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    Map<String, dynamic>? event;
    if (line.startsWith('[') && line.endsWith(']')) {
      event = jsonDecode(line)[0] as Map<String, dynamic>;
    } else {
      final m = _benchmarkHarnessMessagePattern.firstMatch(line);
      if (m != null) {
        event = jsonDecode(m.namedGroup('event')!) as Map<String, dynamic>;
      }
    }
    if (event == null) {
      return;
    }

    switch (event['event'] as String) {
      case 'app.started':
        appId = event['params']['appId'] as String;
        break;
      case 'benchmark.running':
        print(blue('    benchmark is running'));
        break;
      case 'benchmark.done':
        print(blue('      done'));
        process.stdin.writeln(jsonEncode([
          {
            'id': 0,
            'method': 'app.stop',
            'params': {'appId': appId}
          },
        ]));
        break;
      case 'benchmark.result':
        result =
            BenchmarkResult.fromJson(event['params'] as Map<String, dynamic>);
        break;
    }
  });
  await process.exitCode;
  return result;
}

final _benchmarkListPattern =
    RegExp(r'^// BENCHMARKS: (?<list>.*)$', multiLine: true);
final _benchmarkHarnessMessagePattern =
    RegExp(r'benchmark_harness\[(?<event>.*)\]$');
