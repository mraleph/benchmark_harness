/// Library for running benchmarks through benchmark_harness CLI.
import 'dart:convert' show jsonEncode;

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
    {required String name, int thresholdMilliseconds = 5000}) {
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

void runBenchmarks(Map<String, void Function(int)> benchmarks) {
  _event('benchmark.running');
  for (var entry in benchmarks.entries) {
    _event('benchmark.result', measure(entry.value, name: entry.key));
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
