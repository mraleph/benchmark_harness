//
// CLI for running lightweight microbenchmarks using Flutter tooling.
//
// Usage:
//
//     flutter pub run benchmark_harness [measure|report]
//

import 'package:ansicolor/ansicolor.dart';
import 'package:dcli/dcli.dart';

import 'package:benchmark_harness/src/cli/cli.dart' as cli;

void main(List<String> args) async {
  // Ansi support detection does not work when running from `pub run`
  // force it to be always on for now.
  Ansi.isSupported = true;
  ansiColorDisabled = false;
  await cli.runner.run(args);
}
