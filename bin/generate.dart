import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:benchmark_harness/src/benchmark_listener.dart';
import 'package:benchmark_harness/src/source_generator.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;

class FuzzyAnnotationExtractor implements AnnotationExtractor {
  final ResolvedLibraryResult result;

  FuzzyAnnotationExtractor(this.result);

  @override
  bool isBenchmark(Element element) {
    if (element.metadata.isEmpty) {
      return false;
    }

    final node = result.getElementDeclaration(element);
    if (node == null) {
      return false;
    }

    final astNode = node.node;
    if (astNode case FunctionDeclaration() || MethodDeclaration()) {
      for (var metadata in (astNode as AnnotatedNode).metadata) {
        if (metadata.name.name == 'benchmark') {
          return true;
        }
      }
    }
    return false;
  }

  @override
  List<Object?>? isParameter(FieldElement element) {
    for (var metadata in element.metadata) {
      final value = metadata.computeConstantValue();
      if (value == null || value.type == null) {
        continue;
      }

      if (value.type case final InterfaceType it
          when it.element.name == 'Parameter' &&
              it.element.librarySource.uri ==
                  Uri.parse('package:benchmark_harness/annotations.dart')) {
        final typeSystem = element.library.typeSystem;
        final result = <Object?>[];
        for (var value in value.getField('values')!.toListValue()!) {
          final valueType = value.type!;
          if (!typeSystem.isSubtypeOf(valueType, element.type)) {
            throw 'TODO';
            // throw InvalidGenerationSource(
            //    'specified parameter is not a subtype of field type',
            //    element: element);
          }

          if (valueType.isDartCoreInt) {
            result.add(value.toIntValue()!);
          } else if (valueType.isDartCoreBool) {
            result.add(value.toBoolValue()!);
          } else if (valueType.isDartCoreDouble) {
            result.add(value.toDoubleValue()!);
          } else if (valueType.isDartCoreString) {
            result.add(value.toStringValue()!);
          } else if (valueType.isDartCoreNull) {
            result.add(null);
          } else {
            throw 'TODO';
            //throw InvalidGenerationSource(
            //    'only int,String,bool,double values are supported',
            //    element: element);
          }
        }
        return result;
      }
    }

    return null;
  }
}

String prefix(String prefix, String multiline) {
  return multiline.split('\n').map((line) => '$prefix$line').join('\n');
}

void exec(String executable, List<String> args) {
  final result = Process.runSync(executable, args);
  if (result.exitCode != 0) {
    stderr.writeln("""
running: $executable ${args.join(' ')}
failed with exit code ${result.exitCode}
${prefix('stderr: ', result.stderr.toString())}
${prefix('stdout: ', result.stdout.toString())}
""");
    exit(1);
  }
}

Future<void> pipe(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
  void Function(String)? processLine,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    environment: environment,
  );

  process.stdout.listen(stdout.add).asFuture<void>().ignore();
  process.stderr.listen(stderr.add).asFuture<void>().ignore();

  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    stderr.write(
        'running: $executable ${arguments.join(' ')} failed with $exitCode');
    exit(1);
  }
}

final sdkRepoPath = Platform.environment['DART_SDK_SRC'] ??
    (throw StateError('Unable to locate Dart SDK'));

final class _PipingSink implements Sink<Uint8List> {
  final Sink<List<int>> sink;

  _PipingSink(this.sink);

  @override
  void add(Uint8List data) => sink.add(data);

  @override
  void close() => sink.close();
}

Future<void> runBenchmark(String entryPoint,
    {required PackageConfig? packageConfig}) async {
  final syntheticPackageConfigLocation = '$entryPoint.json';
  final output = File(syntheticPackageConfigLocation).openWrite();
  final runnerConfig = PackageConfig.parseBytes(
    File.fromUri(Uri.parse(Platform.packageConfig!)).readAsBytesSync(),
    Uri.parse(Platform.packageConfig!),
  );

  final overridePackages = const {
    'benchmark_harness',
    'stats',
    'json_annotation',
    'dart_internal'
  };

  PackageConfig.writeBytes(
    PackageConfig([
      ...?packageConfig?.packages
          .where((package) => !overridePackages.contains(package.name)),
      ...runnerConfig.packages
          .where((package) => overridePackages.contains(package.name)),
    ]),
    _PipingSink(output),
  );
  await output.close();

  exec(p.join(sdkRepoPath, 'pkg/vm/tool/precompiler2'),
      ['--packages=$entryPoint.json', entryPoint, '$entryPoint.aot']);

  final controlSocket = File('/tmp/benchmark_runner');
  if (controlSocket.existsSync()) {
    controlSocket.deleteSync(recursive: true);
  }

  final logSocket = await ServerSocket.bind(
    InternetAddress(controlSocket.path, type: InternetAddressType.unix),
    0,
  );

  final listener = CliReportingListener();

  logSocket
      .listen((socket) async {
        await JsonReporter.parseEvents(socket, listener);
        socket.destroy();
      })
      .asFuture<void>()
      .ignore();

  await pipe(
    p.join(sdkRepoPath, 'out', 'ReleaseX64', 'dartaotruntime'),
    ['$entryPoint.aot'],
    environment: {
      'BENCHMARK_HARNESS_CONFIG': jsonEncode({'json': controlSocket.path}),
    },
  );

  await logSocket.close();

  // We have all results now run profiler.
  var idx = 0;
  for (var suite in listener.results.entries) {
    for (var result in suite.value) {
      print('profiling ${result.key} for ${result.measurements.numIterations}');
      await pipe(
        'perf',
        [
          'record',
          '-o',
          '/tmp/perf-${idx++}.data',
          '-g',
          p.join(sdkRepoPath, 'out', 'ReleaseX64', 'dartaotruntime'),
          '$entryPoint.aot',
        ],
        environment: {
          'BENCHMARK_HARNESS_CONFIG': jsonEncode({
            'run': {
              result.key: result.measurements.numIterations,
            }
          }),
        },
      );
    }

    CliReportingListener.reportResults(suite.value);
  }
}

void main(List<String> arguments) async {
  final inputDart = File(arguments[0]).absolute.path;

  final packageConfig = await findPackageConfig(File(inputDart).parent);

  final collection = AnalysisContextCollection(
    includedPaths: [inputDart],
    resourceProvider: PhysicalResourceProvider.INSTANCE,
  );
  final context = collection.contextFor(inputDart);
  final result = await context.currentSession.getResolvedLibrary(inputDart);
  if (result is ResolvedLibraryResult) {
    final library = result.element;
    final source = await BenchmarkGenerator(
      library,
      FuzzyAnnotationExtractor(result),
      File(inputDart).absolute.path,
    ).generate();
    final outputPath = p.join(Directory.systemTemp.path,
        '${p.basenameWithoutExtension(inputDart)}_benchmark.dart');
    File(outputPath).writeAsStringSync(source);
    print('Written $outputPath');
    await runBenchmark(outputPath, packageConfig: packageConfig);
  } else {
    print('Error: Could not parse the file.');
  }
}
