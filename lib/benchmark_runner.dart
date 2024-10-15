/// Library for running benchmarks through benchmark_harness CLI.
import 'dart:convert' show jsonEncode;
import 'dart:io' show Platform;

import 'package:benchmark_harness/src/simpleperf/profiling_session.dart';
import 'package:stats/stats.dart';

import 'src/cli/ascii_table.dart';
import 'src/benchmark_base.dart' show Measurement, measureForImpl;

export 'package:dart_internal/dart_internal.dart' show reachabilityFence;

import 'dart:ffi' as ffi;

class Measurements {
  final List<int> values;
  final int numIterations;

  late Stats stats = Stats.fromData([for (var v in values) v / numIterations]);

  Measurements({
    required this.values,
    required this.numIterations,
  });

  Measurements.fromJson(Map<String, dynamic> result)
      : this(
          values: (result['values'] as List).cast<int>(),
          numIterations: result['iterations'] as int,
        );

  Map<String, dynamic> toJson() => {
        'values': values,
        'iterations': numIterations,
      };
}

class BenchmarkResult {
  final String name;
  final Map<String, Object?> parameters;
  final Measurements measurements;

  BenchmarkResult({
    required this.name,
    required this.parameters,
    required this.measurements,
  });
}

int _measure(void Function(int) loop, int n) {
  final sw = Stopwatch()..start();
  loop(n);
  sw.stop();
  return sw.elapsedMilliseconds;
}

/*
/// Runs the given measured [loop] function with an exponentially increasing
/// parameter values until it finds one that causes [loop] to run for at
/// least [thresholdMilliseconds] and returns [BenchmarkResult] describing
/// that run.
Measurements measure(void Function(int) loop, {int thresholdMicros = 2000}) {
  var n = 2;
  Measurement measurement;
  do {
    n *= 2;
    measurement = _measure(loop, n);
  } while (measurement.elapsedMicros < thresholdMicros);

  return Measurements(
    values: [elapsed],
    numIterations: n,
  );
}*/

class Benchmark {
  final String name;
  final List<({Map<String, Object?> parameters, void Function(int) body})>
      variants;

  const Benchmark({
    required this.name,
    required this.variants,
  });
}

abstract class BenchmarkListener {
  void start();
  void startSuite(String suiteName);
  void result(BenchmarkResult result);
  void endSuite();
  void stop();
}

Future<void> runBenchmarks(Map<String, List<Benchmark>> benchmarks,
    {BenchmarkListener? listener}) async {
  listener ??= _CliReportingListener();

  listener.start();
  //_event('benchmark.running');
//  final profiler = Platform.isAndroid ? ProfilingSession() : null;
  for (final MapEntry(key: suiteName, value: suiteBenchmarks)
      in benchmarks.entries) {
    listener.startSuite(suiteName);
    for (var benchmark in suiteBenchmarks) {
      for (var (:parameters, :body) in benchmark.variants) {
        final numIterations = measureForImpl(body, 1000).iterations;
        final results = List.generate(1, (_) => _measure(body, numIterations));
        listener.result(
          BenchmarkResult(
            name: benchmark.name,
            parameters: parameters,
            measurements: Measurements(
              values: results,
              numIterations: numIterations,
            ),
          ),
        );

/*
      if (profiler != null) {
        // Run benchmark for the same amount of iterations and profile it.
        await profiler.start(
            options:
                RecordingOptions(outputFilename: 'perf-${entry.key}.data'));
        entry.value(result.numIterations);
        await profiler.stop();
      }
*/
      }
    }
    listener.endSuite();
  }
  listener.stop();
}

class _CliReportingListener extends BenchmarkListener {
  @override
  void endSuite() {
    print('Results for suite $currentSuite');

    final parameterNames =
        suiteResults.first.parameters.keys.toList(growable: false);

    final table = AsciiTable(header: [
      Text('Benchmark'),
      for (var name in parameterNames) Text.right(name),
      Text('ns/op'),
    ]);

    for (var result in suiteResults) {
      table.addRow([
        Text(result.name),
        for (var name in parameterNames) Text('${result.parameters[name]}'),
        Text(result.measurements.stats.average.toString()),
      ]);
    }

    table.render();

    currentSuite = null;
    suiteResults.clear();
  }

  String? currentSuite;
  final suiteResults = <BenchmarkResult>[];

  @override
  void result(BenchmarkResult result) {
    suiteResults.add(result);
  }

  @override
  void start() {
    print('starting benchmarks');
  }

  @override
  void startSuite(String suiteName) {
    print('starting suite $suiteName');
    currentSuite = suiteName;
  }

  @override
  void stop() {
    print('done with all benchmarks');
  }
}

/*
void _event(String event, [dynamic params]) {
  final encoded = jsonEncode({
    'event': event,
    if (params != null) 'params': params,
  });
  print('benchmark_harness[$encoded]');
}*/
