/// Implementation of `report` command.
///
/// Pretty prints results from a previous `measure` run.
library benchmark_harness.cli.report;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ansicolor/ansicolor.dart';
import 'package:args/command_runner.dart';
import 'package:benchmark_harness/src/cli/utils.dart';
import 'package:dcli/dcli.dart';
import 'package:ffi/ffi.dart';
import 'package:native_stack_traces/native_stack_traces.dart';
import 'package:native_stack_traces/src/elf.dart' as elf_lib;
import 'package:path/path.dart' as p;

import 'package:benchmark_harness/src/simpleperf/generated/report_lib.dart'
    as report_bindings;
import 'package:benchmark_harness/src/simpleperf/flutter_symbols.dart';
import 'package:benchmark_harness/src/simpleperf/ndk.dart';
import 'package:benchmark_harness/src/cli/results.dart';

class ReportCommand extends Command {
  // The [name] and [description] properties must be defined by every
  // subclass.
  @override
  final name = 'report';
  @override
  final description = 'Report results without running';

  @override
  Future<void> run() async {
    final results = Results.fromJson(
        jsonDecode(await File('build/benchmarks/results.json').readAsString())
            as Map<String, dynamic>);
    await reportResults(results, verbose: globalResults['verbose'] as bool);
  }
}

String formatMilliseconds(double v, double pm) {
  var suffix = 'ms';
  for (var s in ['ms', 'us', 'ns', 'ps']) {
    suffix = s;
    if (v >= 1.0 || s == 'ps') {
      break;
    }
    v *= 1000;
    pm *= 1000;
  }
  return '${v.toStringAsFixed(3)} (±${pm.toStringAsFixed(3)}) $suffix';
}

Future<void> reportResults(Results byFile, {bool verbose = false}) async {
  var id = 0;
  for (var entry in byFile.data.entries) {
    final file = entry.key;
    final results = entry.value;
    print('Results for $file');
    final scores = {for (var r in results.values) r.name: r.stats};
    final fastest = results.keys
        .reduce((a, b) => scores[a]!.average < scores[b]!.average ? a : b);

    for (var result in results.values) {
      var suffix = '';
      if (result.name == fastest) {
        suffix = green('(fastest)');
      } else {
        final factor = scores[result.name]!.average / scores[fastest]!.average;
        suffix = red('(${factor.toStringAsFixed(1)} times as slow)');
      }
      final stats = scores[result.name]!;
      final avg = stats.average.toDouble();
      final stdDev = stats.standardDeviation.toDouble();
      print(
          '${result.name}: ${formatMilliseconds(avg, stdDev)}/iteration $suffix');
    }

    for (var result in results.values) {
      print('');
      print('Hot methods when running ${blue(result.name)}:');
      final profileData =
          'build/benchmarks/artifacts$id/perf-${result.name}.data';
      final appSo = 'build/benchmarks/artifacts$id/libapp-${result.name}.so';
      await withTemporaryDir((tempDir) async {
        await _printProfile(tempDir, profileData, appSo,
            localEngine: byFile.localEngine, verbose: verbose);
      }, prefix: 'symfs');
    }
    id++;
  }
}

final reportLib = report_bindings.NativeLibrary(
    ffi.DynamicLibrary.open(ndk.simpleperfReportLib));

Future<void> _printProfile(String tempDir, String profileData, String appSo,
    {String? localEngine, bool verbose = false}) async {
  final libflutterSymbols = localEngine != null
      ? localEnginePath(localEngine)
      : await flutterSymbolsCache.get(EngineBuild(
          engineHash: flutterEngineHash,
          variant: EngineVariant(
            os: 'android',
            arch: 'arm64',
            mode: 'release',
          ),
        ));

  await Link(p.join(tempDir, 'libflutter.so'))
      .create(p.absolute(p.join(libflutterSymbols, 'libflutter.so')));
  await Link(p.join(tempDir, 'libapp.so')).create(p.absolute(appSo));

  final session = reportLib.CreateReportLib();
  reportLib.SetRecordFile(session, Utf8.toUtf8(profileData).cast());
  reportLib.SetSymfs(session, Utf8.toUtf8(tempDir).cast());

  final hitMap = <Symbol, ProfileData>{};
  var total = 0;
  for (;;) {
    final sample = reportLib.GetNextSample(session);
    if (sample == ffi.nullptr) {
      break;
    }
    total += sample.ref.period;

    final symbol = reportLib.GetSymbolOfCurrentSample(session);
    final dsoName = Utf8.fromUtf8(symbol.ref.dso_name.cast());

    final symbolName = Utf8.fromUtf8(symbol.ref.symbol_name.cast());

    final sym = Symbol(dso: dsoName, name: symbolName);

    final perSymbol = hitMap.putIfAbsent(
      sym,
      () => ProfileData(
        sym: sym,
      ),
    );
    final offset = symbol.ref.vaddr_in_file - symbol.ref.symbol_addr;
    perSymbol.hitMap[offset] =
        (perSymbol.hitMap[offset] ?? 0) + sample.ref.period;
    perSymbol.total += sample.ref.period;
  }

  final symbols = hitMap.keys.toList()
    ..sort((a, b) => -hitMap[a]!.total.compareTo(hitMap[b]!.total));

  final elf = elf_lib.Elf.fromFile(appSo)!;
  final dwarf = Dwarf.fromFile(appSo)!;

  var haveMoreToDisassemble = false;
  for (var sym in symbols.take(10)) {
    final info = hitMap[sym]!;
    final fraction = info.total / total;
    if (fraction < 0.01) {
      // Ignore everything that contributes less than a 1%
      continue;
    }
    final cleanPath = p.basename(info.sym.dso);
    final isMeasuredLoop = info.sym.name.contains('measuredLoop');

    final prettyName = _userFriendlyName(dwarf, elf, sym.name);

    print(
        '${pct(info.total, total).padLeft(7)} ${isMeasuredLoop ? black(prettyName) : prettyName} ($cleanPath)');
    if (info.sym.dso.endsWith('libapp.so') && (info.total / total > 0.02)) {
      if (verbose || isMeasuredLoop) {
        print(await _disassemble(
          ndk,
          appSo,
          info.sym.name,
          info,
          total,
          elf,
          dwarf,
        ));
      } else {
        haveMoreToDisassemble = true;
      }
    }
  }

  if (haveMoreToDisassemble) {
    print('  ..(run with -v to disassemble all hot methods in libapp.so)..');
  }

  reportLib.DestroyReportLib(session);
}

extension on elf_lib.Elf {
  elf_lib.Symbol? staticSymbolFor(String name) {
    for (final section in namedSections('.symtab')) {
      final symtab = section as elf_lib.SymbolTable;
      if (symtab.containsKey(name)) return symtab[name];
    }
    return null;
  }
}

Iterable<MapEntry<String, String>> _lexArmAssembly(String line) sync* {
  final patterns = {
    'comment': RegExp(r';.*$'),
    'literal': RegExp(r'#-?\d+'),
    'word': RegExp(r'[\w:\.]+'),
    'jump': RegExp(r'->[\da-f]+'),
    'space': RegExp(r'\s+'),
    'rest': RegExp(r'[^\w#\s]+'),
  };
  var index = 0;
  outer:
  while (index < line.length) {
    for (var entry in patterns.entries) {
      final m = entry.value.matchAsPrefix(line, index);
      if (m != null) {
        final type = (index == 0 && entry.key == 'word') ? 'op' : entry.key;
        yield MapEntry(type, m[0]!);
        index = m.end;
        continue outer;
      }
    }
    throw 'Failed to lex: ${line.substring(index)}';
  }
}

Future<String> _pygmentize(List<String> text) async {
  final result = <String>[];

  final pens = {
    'comment': AnsiPen()..blue(),
    'literal': AnsiPen()..green(),
    'word': AnsiPen()..magenta(),
    'op': AnsiPen()..yellow(bold: true),
    'jump': AnsiPen()..black(bold: true),
    'space': AnsiPen(),
    'rest': AnsiPen(),
  };

  for (var line in text) {
    result.add(_lexArmAssembly(line).map((v) => pens[v.key]!(v.value)).join());
  }
  return result.join('\n');
}

String _userFriendlyName(Dwarf dwarf, elf_lib.Elf elf, String symbol) {
  final elfSymbol = elf.staticSymbolFor(symbol);
  if (elfSymbol != null) {
    final callInfo = dwarf.callInfoFor(elfSymbol.value);
    if (callInfo != null && callInfo.isNotEmpty) {
      final lastInfo = callInfo.last;
      if (lastInfo is DartCallInfo) {
        return lastInfo.function
            .replaceFirst(r'_$measuredLoop$', 'measured loop for ');
      }
      return lastInfo.toString();
    }
  }
  return symbol.replaceFirst('Precompiled_Stub__iso_stub_', 'Stub::');
}

Future<String> _disassemble(
  Ndk ndk,
  String path,
  String sym,
  ProfileData profile,
  int totalSamples,
  elf_lib.Elf elf,
  Dwarf dwarf,
) async {
  final addressPattern = RegExp(
      r'0x(?<address>[a-f0-9]+) <(?<target>(?<symbol>[^>+]+)(?:\+0x(?<offset>[a-f0-9]+))?)>');
  final registerPattern = RegExp(r'\bx\d{1,2}\b');
  final reservedRegisters = {
    'x15': 'sp',
    'x22': 'null',
    'x26': 'thr',
    'x27': 'pp',
    'x28': 'barrierMask',
    'x29': 'fp',
    'x30': 'lr',
    'x31': 'csp',
  };

  // Use Dart VM specific register names when disassembling.
  String rewriteRegister(Match m) {
    final reg = m[0]!;
    return reservedRegisters[reg] ?? reg;
  }

  // Change addresses to user friendly symbols where appropriate.
  String rewriteAddress(Match m) {
    final match = m as RegExpMatch;
    final symbol = match.namedGroup('symbol')!;
    final offset = int.parse(match.namedGroup('offset') ?? '0', radix: 16);
    if (symbol == sym) {
      return '->${offset.toRadixString(16)}';
    }

    final name = _userFriendlyName(dwarf, elf, symbol);
    return offset == 0 ? name : '$name+$offset';
  }

  String fixDisassembly(String s) {
    if (s.startsWith(';')) {
      // Remove useless range information from comments.
      return s.replaceAll(' [-9223372036854775808, 9223372036854775807]', '');
    }
    // In disassembly lines prettyfy symbol names and register names.
    return s
        .replaceAllMapped(registerPattern, rewriteRegister)
        .replaceAllMapped(addressPattern, rewriteAddress);
  }

  // We split disassembly into two columns: one for perf counter hits and
  // offsets (prefixes) and one for actual disassembly.
  final disassembly = <String>[];
  final prefixes = <String>[];

  const hitsWidth = 6;
  const offsetWidth = 6;

  var offset = 0; // Current offset from the start of the disassembly.
  await for (var line in ndk
      .objdump(object: path, arch: 'arm64', options: [
        '-dS', // Disassemble with source
        '--disassemble-symbols=$sym',
        '--no-leading-headers',
      ])
      .skip(7)
      .map(fixDisassembly)) {
    if (line.startsWith(';')) {
      // Realign comment
      disassembly.add(';$line');
      prefixes.add('${''.padLeft(hitsWidth + 1 + offsetWidth + 2)}');
      continue;
    }
    line = line.substring(line.indexOf(':') + 13).trim();
    disassembly.add('$line');
    final hitsPct = pct(profile.hitMap[offset], totalSamples);
    final hitsColor = pctColor(profile.hitMap[offset], totalSamples);

    prefixes.add('${hitsColor(hitsPct.padLeft(hitsWidth))} '
        '${offset.toRadixString(16).padLeft(offsetWidth)}: ');
    offset += 4; // ARM instructions are 4 bytes.
  }
  // Pygmentize the diassembly.
  final text = (await _pygmentize(disassembly)).trimRight().split('\n');
  disassembly.clear();
  for (var i = 0; i < text.length; i++) {
    disassembly.add((' ' * 10) + prefixes[i] + text[i]);
  }
  return disassembly.join('\n');
}

String Function(String) pctColor(int? a, int total, {double threshold = 5}) {
  if (a != null) {
    final p = a * 100 / total;
    if (p > (2 * threshold)) {
      return red;
    } else if (p > threshold) {
      return (v) => orange(v, bold: false);
    }
  }
  return (v) => v;
}

String pct(int? a, int total) {
  if (a != null) {
    final p = a * 100 / total;
    return '${p.toStringAsFixed(2)}%';
  }
  return '';
}

class Symbol {
  final String dso;
  final String name;
  Symbol({required this.dso, required this.name});

  @override
  bool operator ==(Object other) {
    return other is Symbol && other.dso == dso && other.name == name;
  }

  @override
  int get hashCode => (dso.hashCode + name.hashCode) & 0xFFFFFFFF;
}

class ProfileData {
  final Symbol sym;
  final hitMap = <int, int>{};
  int total = 0;
  ProfileData({required this.sym});
}
