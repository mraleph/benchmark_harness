// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:convert';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_system.dart';

import '../annotations.dart';

//typedef ElementPredicate = bool Function(Element);

abstract interface class AnnotationExtractor {
  List<Object?>? isParameter(FieldElement element);
  bool isBenchmark(Element element);
}

/*
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
}*/

typedef BenchmarkParameter = ({String name, List<Object?> values});

class BenchmarkGenerator /* extends Generator */ {
  final LibraryElement library;
  final AnnotationExtractor extractor;
  final TypeSystem typeSystem;
  final String pathToLibrary;

  BenchmarkGenerator(this.library, this.extractor, this.pathToLibrary)
      : typeSystem = library.typeSystem;

  List<BenchmarkParameter> parametersOf(
    ClassElement cls,
  ) {
    final params = <BenchmarkParameter>[];
    for (var field in cls.fields) {
      final parameterValues = extractor.isParameter(field);
      if (parameterValues == null) continue;

      /*
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
      }*/
      params.add((name: field.name, values: parameterValues));
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

  FutureOr<String> generate() async {
    final values = <String>{};
    Future<void> emit(Future<String> value) async {
      values.add((await value).trim());
    }

    final suites =
        <String, List<({String name, List<Map<String, Object?>> variants})>>{};

    for (var cls in library.topLevelElements.whereType<ClassElement>()) {
      final benchmarkMethods =
          cls.methods.where(extractor.isBenchmark).toList(growable: false);

      if (benchmarkMethods.isEmpty) {
        continue;
      }

      final params = parametersOf(cls);
      final variants = allVariants(params).toList(growable: false);

      for (var method in benchmarkMethods) {
        await emit(_generateForMethod(cls, method));

        suites
            .putIfAbsent(cls.name, () => [])
            .add((name: method.name, variants: variants));

        for (var i = 0; i < variants.length; i++) {
          await emit(_generateMethodVariant(
              cls.name, method.name, method.returnType, i, variants[i]));
        }
      }
    }

    for (var element in library.topLevelElements
        .whereType<FunctionElement>()
        .where(extractor.isBenchmark)) {
      // TODO: support variants here.
      await emit(_generateForFunction(element));
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

import '$pathToLibrary' as lib;

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

  Future<String> _generateMethodVariant(
      String suite,
      String name,
      DartType methodReturnType,
      int id,
      Map<String, Object?> parameters) async {
    final (prefix: _, :returnType, :modifier) =
        _checkReturnType(methodReturnType);
    final parametersString = [
      for (var e in parameters.entries) '${e.key}: ${jsonEncode(e.value)},',
    ].join('\n');
    return '''
@pragma('vm:never-inline')
@pragma('vm:unsafe:no-interrupts')
$returnType ${variantFunctionNameFor(suite, name, id)}(int numIterations) $modifier {
  final state = lib.$suite($parametersString);
  return ${loopFunctionNameFor(suite, name)}(numIterations, state);
}
''';
  }

  ({String prefix, String returnType, String modifier}) _checkReturnType(
      DartType type) {
    return switch (type) {
      VoidType() => (prefix: '', returnType: 'void', modifier: ''),
      DartType(isDartAsyncFuture: true) ||
      DartType(isDartAsyncFutureOr: true) =>
        (prefix: 'await', returnType: 'Future<void>', modifier: 'async'),
      _ => (prefix: '\$b.reachabilityFence', returnType: 'void', modifier: ''),
    };
  }

  Future<String> _generateForMethod(
      ClassElement cls, MethodElement method) async {
    final (:prefix, :returnType, :modifier) =
        _checkReturnType(method.returnType);
    return '''
@pragma('vm:never-inline')
@pragma('vm:unsafe:no-interrupts')
$returnType ${loopFunctionNameFor(cls.name, method.name)}(int numIterations, lib.${cls.name} state) $modifier {
  while (numIterations-- > 0) {
    $prefix (state.${method.name}());
  }
}
''';
  }

  Future<String> _generateForFunction(FunctionElement element) async {
    final (:prefix, :returnType, :modifier) =
        _checkReturnType(element.returnType);
    return '''
@pragma('vm:never-inline')
@pragma('vm:unsafe:no-interrupts')
$returnType ${variantFunctionNameFor('_', element.name, 0)}(int numIterations) $modifier {
  while (numIterations-- > 0) {
    $prefix (lib.${element.name}());
  }
}
''';
  }
}
