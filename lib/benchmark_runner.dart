/// Library for running benchmarks through benchmark_harness CLI.
import 'dart:convert' show jsonEncode;
import 'dart:io' show Platform;

import 'package:benchmark_harness/src/simpleperf/profiling_session.dart';
import 'package:stats/stats.dart';

export 'package:dart_internal/dart_internal.dart' show reachabilityFence;

class BenchmarkResult {
  final String name;
  final List<int> measurements;
  final int numIterations;

  late Stats stats =
      Stats.fromData([for (var v in measurements) v / numIterations]);

  BenchmarkResult({
    required this.name,
    required this.measurements,
    required this.numIterations,
  });

  BenchmarkResult.fromJson(Map<String, dynamic> result)
      : this(
          name: result['name'] as String,
          measurements: (result['measurements'] as List).cast<int>(),
          numIterations: result['iterations'] as int,
        );

  Map<String, dynamic> toJson() => {
        'name': name,
        'measurements': measurements,
        'iterations': numIterations,
      };
}

int _measure(void Function(int) loop, int n) {
  final sw = Stopwatch()..start();
  loop(n);
  sw.stop();
  return sw.elapsedMilliseconds;
}

/// Runs the given measured [loop] function with an exponentially increasing
/// parameter values until it finds one that causes [loop] to run for at
/// least [thresholdMilliseconds] and returns [BenchmarkResult] describing
/// that run.
BenchmarkResult measure(void Function(int) loop,
    {required String name, int thresholdMilliseconds = 2000}) {
  var n = 2;
  var elapsed = 0;
  do {
    n *= 2;
    elapsed = _measure(loop, n);
  } while (elapsed < thresholdMilliseconds);

  return BenchmarkResult(
    name: name,
    measurements: [elapsed],
    numIterations: n,
  );
}

Future<void> runBenchmarks(Map<String, void Function(int)> benchmarks) async {
  _event('benchmark.running');
  final profiler = Platform.isAndroid ? ProfilingSession() : null;
  for (var entry in benchmarks.entries) {
    final loop = entry.value;
    final result = measure(entry.value, name: entry.key);
    final results =
        List.generate(10, (_) => _measure(loop, result.numIterations));
    _event(
        'benchmark.result',
        BenchmarkResult(
          name: entry.key,
          measurements: results,
          numIterations: result.numIterations,
        ));

    if (profiler != null) {
      // Run benchmark for the same amount of iterations and profile it.
      await profiler.start(
          options: RecordingOptions(outputFilename: 'perf-${entry.key}.data'));
      entry.value(result.numIterations);
      await profiler.stop();
    }
  }
  _event('benchmark.done');
}

void _event(String event, [dynamic params]) {
  final encoded = jsonEncode({
    'event': event,
    if (params != null) 'params': params,
  });
  print('benchmark_harness[$encoded]');
}
