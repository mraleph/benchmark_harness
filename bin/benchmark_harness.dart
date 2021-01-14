// @dart=2.9
//
// CLI for running lightweight microbenchmarks using Flutter tooling.
//
// Usage:
//
//     flutter pub run benchmark_harness
//

import 'dart:convert';
import 'dart:io';

import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:dcli/dcli.dart';
import 'package:path/path.dart' as p;

void main() async {
  // Ansi support detection does not work when running from `pub run`
  // force it to be always on for now.
  Ansi.isSupported = true;

  // Generate benchmark wrapper scripts.
  print(red('Generating benchmark wrappers'));
  'flutter pub run build_runner build'.start(progress: Progress.devNull());

  // Run all generated benchmarks.
  final resultsByFile = <String, Map<String, BenchmarkResult>>{};
  for (var file in find('*.benchmark.dart').toList().map(p.relative)) {
    resultsByFile[file] = await runBenchmarksIn(file);
  }

  // Report results.
  print('');
  print('-' * 80);
  print('');
  resultsByFile.forEach((file, results) {
    print('Results for ${file}');
    final scores = {
      for (var r in results.values)
        r.name: r.elapsedMilliseconds / r.numIterations
    };
    final fastest =
        results.keys.reduce((a, b) => scores[a] < scores[b] ? a : b);

    for (var result in results.values) {
      String suffix = '';
      if (result.name == fastest) {
        suffix = red('(fastest)');
      } else {
        double factor = scores[result.name] / scores[fastest];
        suffix = red('(${factor.toStringAsFixed(1)} times as slow)');
      }
      print('${result.name}: ${scores[result.name]} ms/iteration ${suffix}');
    }
  });
}

/// Runs all benchmarks in `.benchmark.dart` [file] one by one and collects
/// their results.
Future<Map<String, BenchmarkResult>> runBenchmarksIn(String file) async {
  final results = <String, BenchmarkResult>{};

  final benchmarks = benchmarkListPattern
      .firstMatch(File(file).readAsStringSync())
      .namedGroup('list')
      .split(',');
  print(red('Found ${benchmarks.length} benchmarks in ${file}'
      '($benchmarks)'));
  for (var name in benchmarks) {
    results[name] = await runBenchmark(file, name);
  }
  return results;
}

/// Runs benchmark with the given [name] defined in the given [file] and
/// collects its result.
Future<BenchmarkResult> runBenchmark(String file, String name) async {
  print(red('  measuring ${name}'));
  final process = await Process.start('flutter', [
    'run',
    '--release',
    '--machine',
    '--dart-define',
    'targetBenchmark=$name',
    '-t',
    file,
  ]);

  BenchmarkResult result;
  String appId;

  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {});

  // Process JSON-RPC events from the flutter run command.
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    Map<String, dynamic> event;
    if (line.startsWith('[') && line.endsWith(']')) {
      event = jsonDecode(line)[0] as Map<String, dynamic>;
    } else {
      final m = benchmarkHarnessMessagePattern.firstMatch(line);
      if (m != null) {
        event = jsonDecode(m.namedGroup('event')) as Map<String, dynamic>;
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
        print(red('    benchmark is running'));
        break;
      case 'benchmark.done':
        print(red('      done'));
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

final benchmarkListPattern =
    RegExp(r'^// BENCHMARKS: (?<list>.*)$', multiLine: true);
final benchmarkHarnessMessagePattern =
    RegExp(r'benchmark_harness\[(?<event>.*)\]$');
