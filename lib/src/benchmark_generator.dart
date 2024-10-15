// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:convert';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_system.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'package:source_gen/src/output_helpers.dart';

import '../annotations.dart';

/// All of the declarations in this library annotated with [checker].
extension<T extends Element> on Iterable<T> {
  Iterable<({ConstantReader annotation, T element})> annotatedWith(
    TypeChecker checker, {
    bool throwOnUnresolved = true,
  }) sync* {
    for (final element in this) {
      final annotation = checker.firstAnnotationOf(
        element,
        throwOnUnresolved: throwOnUnresolved,
      );
      if (annotation != null) {
        yield (annotation: ConstantReader(annotation), element: element);
      }
    }
  }
}

typedef BenchmarkParameter = ({String name, List<Object?> values});

class BenchmarkGenerator extends Generator {
  TypeChecker get typeChecker => const TypeChecker.fromRuntime(Benchmark);

  List<BenchmarkParameter> parametersOf(
      TypeSystem typeSystem, ClassElement cls) {
    final params = <BenchmarkParameter>[];
    for (var (:annotation, :element)
        in cls.fields.annotatedWith(const TypeChecker.fromRuntime(Parameter))) {
      final values = <Object?>[];
      for (var value in annotation.peek('values')!.listValue) {
        final valueType = value.type!;
        if (!typeSystem.isSubtypeOf(valueType, element.type)) {
          throw InvalidGenerationSource(
              'specified parameter is not a subtype of field type',
              element: element);
        }

        if (valueType.isDartCoreInt) {
          values.add(value.toIntValue()!);
        } else if (valueType.isDartCoreBool) {
          values.add(value.toBoolValue()!);
        } else if (valueType.isDartCoreDouble) {
          values.add(value.toDoubleValue()!);
        } else if (valueType.isDartCoreString) {
          values.add(value.toStringValue()!);
        } else if (valueType.isDartCoreNull) {
          values.add(null);
        } else {
          throw InvalidGenerationSource(
              'only int,String,bool,double values are supported',
              element: element);
        }
      }
      params.add((name: element.name, values: values));
    }
    return params;
  }

  Iterable<Map<String, Object?>> allVariants(
      List<BenchmarkParameter> parameters) sync* {
    if (parameters.isEmpty) {
      yield {};
      return;
    }

    final current = List<int>.filled(parameters.length, 0);
    while (current.last < parameters.last.values.length) {
      yield {
        for (var i = 0; i < parameters.length; i++)
          parameters[i].name: parameters[i].values[current[i]],
      };
      var j = 0;
      while (++current[j] == parameters[j].values.length) {
        current[j++] = 0;
        if (j == parameters.length) {
          return;
        }
      }
    }
  }

  @override
  FutureOr<String> generate(LibraryReader library, BuildStep buildStep) async {
    // final wrappers = await super.generate(library, buildStep);
    //if (wrappers.isEmpty) return wrappers;

    final typeSystem = library.element.typeSystem;

    final values = <String>{};
    Future<void> emit(Object? value) async {
      await for (var value in normalizeGeneratorOutput(value)) {
        assert(value.length == value.trim().length);
        values.add(value);
      }
    }

    final suites =
        <String, List<({String name, List<Map<String, Object?>> variants})>>{};

    for (var cls in library.allElements.whereType<ClassElement>()) {
      final benchmarkMethods =
          cls.methods.annotatedWith(typeChecker).toList(growable: false);

      if (benchmarkMethods.isEmpty) {
        continue;
      }

      final params = parametersOf(typeSystem, cls);
      final variants = allVariants(params).toList(growable: false);

      for (var (:annotation, :element) in benchmarkMethods) {
        await emit(_generateForMethod(
          cls,
          element,
          annotation,
          buildStep,
        ));

        suites
            .putIfAbsent(cls.name, () => [])
            .add((name: element.name, variants: variants));

        for (var i = 0; i < variants.length; i++) {
          await emit(
              _generateMethodVariant(cls.name, element.name, i, variants[i]));
        }
      }
    }

    for (var (:annotation, :element) in library.allElements
        .whereType<FunctionElement>()
        .annotatedWith(typeChecker)) {
      // TODO: support variants here.
      await emit(_generateForFunction(
        element,
        annotation,
        buildStep,
      ));
      suites
          .putIfAbsent('_', () => [])
          .add((name: element.name, variants: [{}]));
    }

    final wrappers = values.join('\n\n');

    String benchmarksArray(String suite) {
      final allBenchmarks = [
        for (var (:name, :variants) in suites[suite]!) ...[
          '\$b.Benchmark(name: \'$name\', variants: [',
          for (var (id, parameters) in variants.indexed)
            '''
            (
              parameters: ${jsonEncode(parameters)},
              body: ${variantFunctionNameFor(suite, name, id)},
            ),
''',
          ']),'
        ],
      ].join('\n');
      return '[$allBenchmarks]';
    }

    final allSuites = [
      for (var suite in suites.keys)
        '''
  '$suite': ${benchmarksArray(suite)},
''',
    ].join('\n');
    return '''
import 'package:benchmark_harness/benchmark_runner.dart' as \$b;

import '${library.pathToElement(library.element)}' as lib;

$wrappers


void main() async {
  await \$b.runBenchmarks(const {
    $allSuites
  });
}
''';
  }

  static String loopFunctionNameFor(String suite, String name) {
    return '_\$measuredLoop\$$suite\$$name';
  }

  static String variantFunctionNameFor(String suite, String name, int id) {
    return '${loopFunctionNameFor(suite, name)}\$v$id';
  }

  Future<String> _generateMethodVariant(String suite, String name, int id,
      Map<String, Object?> parameters) async {
    final parametersString = [
      for (var e in parameters.entries) '${e.key}: ${jsonEncode(e.value)},',
    ].join('\n');
    return '''
@pragma('vm:never-inline')
@pragma('vm:unsafe:no-interrupts')
void ${variantFunctionNameFor(suite, name, id)}(int numIterations) {
  final state = lib.$suite($parametersString);
  ${loopFunctionNameFor(suite, name)}(numIterations, state);
}
''';
  }

  Future<String> _generateForMethod(ClassElement cls, MethodElement method,
      ConstantReader annotation, BuildStep buildStep) async {
    final returnType = method.returnType;
    final needsBlackhole = returnType is! VoidType;
    return '''
@pragma('vm:never-inline')
@pragma('vm:unsafe:no-interrupts')
void ${loopFunctionNameFor(cls.name, method.name)}(int numIterations, lib.${cls.name} state) {
  while (numIterations-- > 0) {
    ${needsBlackhole ? '\$b.reachabilityFence' : ''} (state.${method.name}());
  }
}
''';
  }

  Future<String> _generateForFunction(FunctionElement element,
      ConstantReader annotation, BuildStep buildStep) async {
    final returnType = element.returnType;
    final needsBlackhole = returnType is! VoidType;
    return '''
@pragma('vm:never-inline')
@pragma('vm:unsafe:no-interrupts')
void ${loopFunctionNameFor('_', element.name)}(int numIterations) {
  while (numIterations-- > 0) {
    ${needsBlackhole ? '\$b.reachabilityFence' : ''} (lib.${element.name}());
  }
}
''';
  }
}
