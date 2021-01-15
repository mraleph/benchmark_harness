// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import '../annotations.dart';

class BenchmarkGenerator extends GeneratorForAnnotation<Benchmark> {
  @override
  FutureOr<String> generate(LibraryReader library, BuildStep buildStep) async {
    final wrappers = await super.generate(library, buildStep);
    if (wrappers.isEmpty) return wrappers;

    final names = library.annotatedWith(typeChecker).map((v) => v.element.name);
    // benchmark_harness CLI uses BENCHMARKS line to extract the list of
    // benchmarks contained in this file.
    final defines = [
      '''
// BENCHMARKS: ${names.join(',')}
const _targetBenchmark =
  String.fromEnvironment('targetBenchmark', defaultValue: 'all');
const _shouldMeasureAll = _targetBenchmark == 'all';
''',
      for (var name in names)
        '''
const _shouldMeasure\$$name = _shouldMeasureAll || _targetBenchmark == '$name';
''',
    ].join('\n');
    final benchmarks = [
      for (var name in names)
        '''
if (_shouldMeasure\$$name)
  '$name': ${loopFunctionNameFor(name)},
''',
    ].join('\n');
    return '''
import 'package:benchmark_harness/benchmark_runner.dart' as benchmark_runner;

import '${library.element.source.uri}' as lib;

$wrappers

$defines

void main() async {
  await benchmark_runner.runBenchmarks(const {
    $benchmarks
  });
}
''';
  }

  static String loopFunctionNameFor(String name) {
    return '_\$measuredLoop\$$name';
  }

  @override
  String generateForAnnotatedElement(
      Element element, ConstantReader annotation, BuildStep buildStep) {
    return '''
void ${loopFunctionNameFor(element.name)}(int numIterations) {
  while (numIterations-- > 0) {
    lib.${element.name}();
  }
}
''';
  }
}
