import 'package:args/command_runner.dart';

import 'package:benchmark_harness/src/cli/measure.dart';
import 'package:benchmark_harness/src/cli/report.dart';

final runner = CommandRunner('benchmark_harness', 'CLI for running benchmarks')
  ..argParser.addFlag('verbose', abbr: 'v')
  ..addCommand(MeasureCommand())
  ..addCommand(ReportCommand());
