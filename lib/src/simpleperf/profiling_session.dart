/// Port of simpleperf's app_api from C++ to Dart. Used to programmatically
/// start and stopped profiling.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

enum CallgraphKind {
  none,
  fp,
  dwarf,
}

class RecordingOptions {
  final String? outputFilename;
  final String event;
  final int frequency;
  final CallgraphKind callgraph;

  const RecordingOptions({
    this.outputFilename,
    this.event = 'cpu-cycles',
    this.frequency = 4000,
    this.callgraph = CallgraphKind.none,
  });
}

class ProfilingSession {
  final String appDataDir;
  final String simpleperfDataDir;

  Process? _simpleperf;

  factory ProfilingSession() {
    final appName = _getAppName();
    final uid = _getuid();
    final appDataDir = (uid >= _aidUserOffset)
        ? '/data/user/${uid ~/ _aidUserOffset}/$appName'
        : '/data/data/$appName';
    return ProfilingSession._(appDataDir);
  }

  ProfilingSession._(this.appDataDir)
      : simpleperfDataDir = '$appDataDir/simpleperf_data/';

  /// Start profiling of the application with the given [options].
  Future<void> start(
      {RecordingOptions options = const RecordingOptions()}) async {
    if (_simpleperf != null) {
      throw StateError('profiler already running');
    }
    await _ensureOutputDir();
    await _startSimpleperfProcess(options);
  }

  /// Stop profiling.
  Future<void> stop() async {
    final simpleperf = _simpleperf;
    if (simpleperf == null) {
      throw StateError('profiler is not running');
    }
    if (!simpleperf.kill(ProcessSignal.sigint)) {
      throw StateError('failed to stop simplperf process');
    }
    final exitCode = await simpleperf.exitCode;
    if (exitCode != 0) {
      throw StateError('simpleperf exited with error: $exitCode');
    }
    _simpleperf = null;
  }

  Future<void> _ensureOutputDir() async {
    final dir = Directory(simpleperfDataDir);
    if (!(await dir.exists())) {
      await dir.create();
    }
  }

  Future<String> _findSimpleperfBinary() async {
    final tempSimpleperf = '/data/local/tmp/simpleperf';
    if (await _isExecutable(tempSimpleperf)) {
      final copiedSimpleperf = '$appDataDir/simpleperf';
      try {
        await File(tempSimpleperf).copy(copiedSimpleperf);
        final result = await Process.run(tempSimpleperf, ['list', 'sw']);
        if (result.exitCode == 0 &&
            (result.stdout as String).contains('cpu-clock')) {
          return tempSimpleperf;
        }
      } catch (e) {
        // Ignore.
      }
    }
    final systemSimpleperf = '/system/bin/simpleperf';
    if (await _isExecutable(systemSimpleperf)) {
      return systemSimpleperf;
    }
    throw 'Could not find simpleperf on device.';
  }

  Future<void> _startSimpleperfProcess(RecordingOptions options) async {
    final simpleperfBinary = await _findSimpleperfBinary();
    final simpleperf = _simpleperf = await Process.start(
      simpleperfBinary,
      [
        'record',
        '--log-to-android-buffer',
        '--log',
        'debug',
        '--stdio-controls-profiling',
        '--in-app',
        '--tracepoint-events',
        '/data/local/tmp/tracepoint_events',
        '-o',
        options.outputFilename ?? _makeOutputFilename(),
        '-e',
        options.event,
        '-f',
        options.frequency.toString(),
        '-p',
        _getpid().toString(),
        ..._callgraphFlagsFrom(options),
      ],
      workingDirectory: simpleperfDataDir,
    );

    final started = Completer<void>();

    simpleperf.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((event) {
      if (event == 'started') {
        started.complete();
      }
    });

    simpleperf.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((event) {});

    await started.future;
  }

  static String _makeOutputFilename() {
    final now = DateTime.now();
    final timeString = [now.month, now.day, now.hour, now.minute, now.second]
        .map((int v) => v.toString().padLeft(2, '0'))
        .join('-');
    return 'perf-$timeString.data';
  }

  List<String> _callgraphFlagsFrom(RecordingOptions options) {
    switch (options.callgraph) {
      case CallgraphKind.dwarf:
        return const ['-g'];
      case CallgraphKind.fp:
        return const ['--call-graph', 'fp'];
      default:
        return const [];
    }
  }
}

Future<bool> _isExecutable(String path) async {
  final file = File(path);
  if (!(await file.exists())) {
    return false;
  }
  final stat = await file.stat();
  return stat.type == FileSystemEntityType.file && (stat.mode & 64) != 0;
}

String _getAppName() {
  final cmdline = File('/proc/self/cmdline').readAsBytesSync();
  return utf8.decode(cmdline.sublist(0, cmdline.indexOf(0)));
}

final _getpid = DynamicLibrary.process()
    .lookupFunction<Int32 Function(), int Function()>('getpid');
final _getuid = DynamicLibrary.process()
    .lookupFunction<Int32 Function(), int Function()>('getuid');
final _aidUserOffset = 100000;
