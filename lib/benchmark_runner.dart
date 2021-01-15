/// Library for running benchmarks through benchmark_harness CLI.
import 'dart:convert' show jsonEncode;
import 'dart:io' show Platform;

import 'package:benchmark_harness/src/simpleperf/profiling_session.dart';

class BenchmarkResult {
  final String name;
  final int elapsedMilliseconds;
  final int numIterations;

  BenchmarkResult({
    required this.name,
    required this.elapsedMilliseconds,
    required this.numIterations,
  });

  BenchmarkResult.fromJson(Map<String, dynamic> result)
      : this(
          name: result['name'] as String,
          elapsedMilliseconds: result['elapsed'] as int,
          numIterations: result['iterations'] as int,
        );

  Map<String, dynamic> toJson() => {
        'name': name,
        'elapsed': elapsedMilliseconds,
        'iterations': numIterations,
      };
}

/// Runs the given measured [loop] function with an exponentially increasing
/// parameter values until it finds one that causes [loop] to run for at
/// least [thresholdMilliseconds] and returns [BenchmarkResult] describing
/// that run.
BenchmarkResult measure(void Function(int) loop,
    {required String name, int thresholdMilliseconds = 2000}) {
  var n = 2;
  final sw = Stopwatch();
  do {
    n *= 2;
    sw.reset();
    sw.start();
    loop(n);
    sw.stop();
  } while (sw.elapsedMilliseconds < thresholdMilliseconds);

  return BenchmarkResult(
    name: name,
    elapsedMilliseconds: sw.elapsedMilliseconds,
    numIterations: n,
  );
}

Future<void> runBenchmarks(Map<String, void Function(int)> benchmarks) async {
  _event('benchmark.running');
  final profiler = Platform.isAndroid ? ProfilingSession() : null;
  for (var entry in benchmarks.entries) {
    final result = measure(entry.value, name: entry.key);
    _event('benchmark.result', result);

    // Run benchmark for the same amount of iterations and profile it.
    await profiler?.start(
        options: RecordingOptions(outputFilename: 'perf-${entry.key}.data'));
    entry.value(result.numIterations);
    await profiler?.stop();
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
