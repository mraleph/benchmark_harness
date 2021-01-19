import 'package:benchmark_harness/benchmark_runner.dart';

class Results {
  final String? localEngine;
  final Map<String, Map<String, BenchmarkResult>> data;

  Results({this.localEngine}) : data = {};

  Results.fromJson(Map<String, dynamic> json)
      : data = {
          for (var fileEntry in (json['data'] as Map<String, dynamic>).entries)
            fileEntry.key: {
              for (var benchmarkEntry
                  in (fileEntry.value as Map<String, dynamic>).entries)
                benchmarkEntry.key: BenchmarkResult.fromJson(
                    benchmarkEntry.value as Map<String, dynamic>),
            }
        },
        localEngine = json['localEngine'] as String?;

  Object toJson() =>
      {if (localEngine != null) 'localEngine': localEngine, 'data': data};
}
