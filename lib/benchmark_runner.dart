// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Library for running benchmarks through benchmark_harness CLI.
library;

import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io' as io;

import 'src/benchmark_base.dart' show asyncMeasureForImpl, measureForImpl;
//import 'package:benchmark_harness/src/simpleperf/profiling_session.dart';

import 'src/benchmark_listener.dart';

export 'package:dart_internal/dart_internal.dart' show reachabilityFence;

int _measure(void Function(int) loop, int n) {
  final sw = Stopwatch()..start();
  loop(n);
  sw.stop();
  return sw.elapsedMicroseconds * 1000;
}

Future<int> _asyncMeasure(Future<void> Function(int) loop, int n) async {
  final sw = Stopwatch()..start();
  await loop(n);
  sw.stop();
  return sw.elapsedMicroseconds * 1000;
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
  final List<
      ({
        Map<String, Object?> parameters,
        FutureOr<void> Function(int) body
      })> variants;

  const Benchmark({
    required this.name,
    required this.variants,
  });
}

class HarnessConfig {
  final String? controlSocket;
  final Set<String> benchmarksToRun;
  final Map<String, int> iterations;

  HarnessConfig._({
    required this.benchmarksToRun,
    required this.iterations,
    required this.controlSocket,
  });

  factory HarnessConfig() {
    final config = convert.jsonDecode(
            io.Platform.environment['BENCHMARK_HARNESS_CONFIG'] ?? '{}')
        as Map<String, dynamic>;
    final toRun = <String>{};
    final iterations = <String, int>{};
    if (config case {'run': final Map<String, dynamic> m}) {
      iterations.addAll(m.cast<String, int>());
      toRun.addAll(m.keys);
    }
    return HarnessConfig._(
      benchmarksToRun: toRun,
      iterations: iterations,
      controlSocket: config['json'] as String?,
    );
  }

  static String benchmarkKey(String suite, String benchmark, int id) =>
      '$suite.$benchmark.$id';

  int? iterationsFor(String suite, String benchmark, int id) =>
      iterations[benchmarkKey(suite, benchmark, id)];

  Map<String, List<Benchmark>> filter(Map<String, List<Benchmark>> suites) {
    if (benchmarksToRun.isEmpty) {
      return suites;
    }

    final result = <String, List<Benchmark>>{};
    for (final MapEntry(key: suite, value: benchmarks) in suites.entries) {
      for (var benchmark in benchmarks) {
        final filtered = Benchmark(name: benchmark.name, variants: [
          for (var (id, variant) in benchmark.variants.indexed)
            if (benchmarksToRun
                .contains(benchmarkKey(suite, benchmark.name, id)))
              variant,
        ]);

        if (filtered.variants.isNotEmpty) {
          result.putIfAbsent(suite, () => <Benchmark>[]).add(filtered);
        }
      }
    }

    return result;
  }

  Future<BenchmarkListener> createListener() async {
    if (controlSocket case final path?) {
      final sock = await io.Socket.connect(
          io.InternetAddress(path, type: io.InternetAddressType.unix), 0);
      unawaited(sock.drain());
      return JsonReporter(sock);
    }
    return CliReportingListener();
  }
}

Future<void> runBenchmarks(Map<String, List<Benchmark>> benchmarks,
    {BenchmarkListener? listener}) async {
  final harnessConfig = HarnessConfig();

  benchmarks = harnessConfig.filter(benchmarks);

  listener ??= await harnessConfig.createListener();

  await listener.start();
  for (final MapEntry(key: suiteName, value: suiteBenchmarks)
      in benchmarks.entries) {
    await listener.startSuite(suiteName);
    for (var benchmark in suiteBenchmarks) {
      for (var (id, (:parameters, :body)) in benchmark.variants.indexed) {
        final int numIterations;
        final List<int> results;
        const N = 1;

        if (body is Future<void> Function(int)) {
          numIterations =
              harnessConfig.iterationsFor(suiteName, benchmark.name, id) ??
                  (await asyncMeasureForImpl(body, 1000)).iterations;
          results = List.filled(N, 0);
          for (var i = 0; i < N; i++) {
            results[i] = await _asyncMeasure(body, numIterations);
          }
        } else {
          numIterations =
              harnessConfig.iterationsFor(suiteName, benchmark.name, id) ??
                  measureForImpl(body, 1000).iterations;
          results = List.generate(N, (_) => _measure(body, numIterations));
        }
        await listener.result(
          BenchmarkResult(
            key: HarnessConfig.benchmarkKey(suiteName, benchmark.name, id),
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
    await listener.endSuite();
  }
  await listener.stop();
}
