// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io' as io;

import 'package:stats/stats.dart';

import 'cli/ascii_table.dart';

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
  final String key;
  final String name;
  final Map<String, Object?> parameters;
  final Measurements measurements;

  BenchmarkResult({
    required this.key,
    required this.name,
    required this.parameters,
    required this.measurements,
  });

  BenchmarkResult.fromJson(Map<String, dynamic> m)
      : key = m['key'] as String,
        name = m['name'] as String,
        parameters = (m['parameters'] as Map<String, dynamic>).cast(),
        measurements =
            Measurements.fromJson(m['measurements'] as Map<String, dynamic>);

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'name': name,
      'parameters': parameters,
      'measurements': measurements.toJson(),
    };
  }
}

abstract class BenchmarkListener {
  Future<void> start();
  Future<void> startSuite(String suiteName);
  Future<void> result(BenchmarkResult result);
  Future<void> endSuite();
  Future<void> stop();
}

enum BenchmarkEvent {
  start,
  suiteStart,
  result,
  suiteEnd,
  stop;

  static final byName = BenchmarkEvent.values.asNameMap();
}

final class JsonReporter implements BenchmarkListener {
  final io.IOSink output;

  JsonReporter(this.output);

  @override
  Future<void> start() => _event(BenchmarkEvent.start);

  @override
  Future<void> startSuite(String suiteName) =>
      _event(BenchmarkEvent.suiteStart, {'name': suiteName});

  @override
  Future<void> result(BenchmarkResult result) =>
      _event(BenchmarkEvent.result, result.toJson());

  @override
  Future<void> endSuite() => _event(BenchmarkEvent.suiteEnd);

  @override
  Future<void> stop() async {
    await _event(BenchmarkEvent.stop);
    await output.close();
  }

  Future<void> _event(BenchmarkEvent event, [dynamic params]) async {
    final encoded = jsonEncode({
      'event': event.name,
      if (params != null) 'params': params,
    });
    output.writeln(encoded);
    await output.flush();
  }

  static Future<void> parseEvents(
      Stream<List<int>> input, BenchmarkListener listener) async {
    await for (final msg in const Utf8Decoder()
        .bind(input)
        .transform(const LineSplitter())
        .map(jsonDecode)
        .cast<Map<String, dynamic>>()) {
      msg['event'] = BenchmarkEvent.byName[msg['event'] as String];
      switch (msg) {
        case {'event': BenchmarkEvent.start}:
          await listener.start();
        case {
            'event': BenchmarkEvent.suiteStart,
            'params': {'name': final String suiteName}
          }:
          await listener.startSuite(suiteName);
        case {
            'event': BenchmarkEvent.result,
            'params': final Map<String, dynamic> result,
          }:
          await listener.result(BenchmarkResult.fromJson(result));
        case {
            'event': BenchmarkEvent.suiteEnd,
          }:
          await listener.endSuite();
        case {'event': BenchmarkEvent.stop}:
          await listener.stop();
        case _:
          throw StateError('Protocol error: $msg');
      }
    }
  }
}

class CliReportingListener extends BenchmarkListener {
  static void reportResults(List<BenchmarkResult> suiteResults) {
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
        Text(result.measurements.stats.average.toStringAsFixed(2)),
      ]);
    }

    table.render();
  }

  @override
  Future<void> endSuite() {
    currentSuite = null;
    return Future.value();
  }

  String? currentSuite;
  final results = <String, List<BenchmarkResult>>{};

  @override
  Future<void> result(BenchmarkResult result) {
    results.putIfAbsent(currentSuite!, () => []).add(result);
    return Future.value();
  }

  @override
  Future<void> start() {
    print('starting benchmarks');
    return Future.value();
  }

  @override
  Future<void> startSuite(String suiteName) {
    print('starting suite $suiteName');
    currentSuite = suiteName;
    return Future.value();
  }

  @override
  Future<void> stop() {
    print('done with all benchmarks');
    return Future.value();
  }
}
