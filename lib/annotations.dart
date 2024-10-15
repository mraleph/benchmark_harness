// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class Benchmark {
  const Benchmark();
}

/// Marks top-level function as a benchmark which can be discovered and
/// run by benchmark_harness CLI tooling.
const benchmark = Benchmark();

class Parameter<T> {
  final List<T> values;

  const Parameter(this.values);
}
