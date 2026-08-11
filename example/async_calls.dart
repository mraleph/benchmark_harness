import 'dart:io';

import 'package:benchmark_harness/annotations.dart';

@benchmark
class CostOfAsyncBenchmark {
  @Parameter([0, 1, 2, 3, 4])
  final int depth;

  CostOfAsyncBenchmark({required this.depth});

  @benchmark
  Future<int> fullyAsync() async {
    return await asyncFunction(depth) + 1;
  }

  @benchmark
  Future<int> asyncWithSyncIO() async {
    return await asyncFunctionSyncIO(depth) + 1;
  }

  @benchmark
  int fullySync() {
    return syncFunction(depth) + 1;
  }

  @pragma('vm:never-inline')
  int syncFunction(int depth) {
    if (depth <= 0) {
      return Directory('/tmp').existsSync() ? 0 : 1;
    }
    return syncFunction(depth - 1) + syncFunction(depth - 1);
  }

  @pragma('vm:never-inline')
  Future<int> asyncFunction(int depth) async {
    if (depth <= 0) {
      return await Directory('/tmp').exists() ? 0 : 1;
    }
    return await asyncFunction(depth - 1) + await asyncFunction(depth - 1);
  }

  @pragma('vm:never-inline')
  Future<int> asyncFunctionSyncIO(int depth) async {
    if (depth <= 0) {
      return Directory('/tmp').existsSync() ? 0 : 1;
    }
    return await asyncFunctionSyncIO(depth - 1) +
        await asyncFunctionSyncIO(depth - 1);
  }
}
