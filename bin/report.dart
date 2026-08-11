import 'dart:io';
import 'dart:typed_data';

import 'package:benchmark_harness/src/profiles/perf/perf_data.dart';
import 'package:benchmark_harness/src/profiles/symbols.dart';

class SymbolsIndex {
  final symbols = <({String binaryPath, String symbolName})>[];
}

/// Lazily populated mapping between file offsets in a binary and profile
/// location ids.
///
/// This class handles convertion of the file offset to the corresponding
/// symbol name and futher into corresponding location id inside the profile.
final class SymbolsIndex {
  final ProfileBuilder profileBuilder;

  final Symbols symbols;
  final List<Int64?> ids;

  SymbolsIndex(this.profileBuilder, this.symbols)
      : ids = List<Int64?>.filled(symbols.fileOffsets.length, null);

  static final lineRe =
      RegExp(r"^(?<addr>[0-9a-f]+)\s+(?<typ>\w+)\s+(?<name>.*)$");

  /// Return location id corresponding to the given [fileOffset].
  ///
  /// This function will lazily allocate new ids as necessary by
  /// calling [ProfileBuilder.addSymbol].
  Int64? symbolId(int fileOffset) {
    final index = symbols.symbolIndex(fileOffset);
    if (index != null) {
      return (ids[index] ??= profileBuilder.addSymbol(symbols.names[index]));
    }
    return null;
  }
}

final class Mapping {
  final int baseAddress;
  final int length;
  final String path;
  final int offset;

  Mapping({
    required this.baseAddress,
    required this.length,
    required this.path,
    required this.offset,
  });
}

/// Symbols information for the whole address space.
final class AddressSpaceSymbols {
  /// Base addresses for mapping ranges.
  ///
  /// To simplify search we also add ranges that don't have any symbols here.
  /// Consider for example that we have two mappings `[A, A')` and `[B, B')`
  /// with symbols (`Sym(A)` and `Sym(B)` respectively). In this case:
  ///   * [baseAddresses] will contain `[0, A, A', B, B']` and
  ///   * [symbolsIndexes] will contain `[null, SA, null, SymB, null]`.
  final Int64List baseAddresses;

  /// Symbol indexes corresponding to mappings in [baseAddresses].
  final List<SymbolsIndex?> symbolsIndexes;

  /// File offsets corresponding to mappings in [baseAddresses].
  final Int64List fileOffsets;

  AddressSpaceSymbols._(
      this.baseAddresses, this.symbolsIndexes, this.fileOffsets);

  Int64? symbolId(int address) {
    // We use linear search because we assume the number of mappings
    // is very small (~2).
    final limit = baseAddresses.length - 1;
    for (var i = 0; i < limit; i++) {
      final start = baseAddresses[i];
      final end = baseAddresses[i + 1];
      if (start <= address && address < end) {
        final fileOffset = address - start + fileOffsets[i];
        return symbolsIndexes[i]?.symbolId(fileOffset);
      }
    }
    return null;
  }

  /// Construct [AddressSpaceSymbols] from [Mapping] records loaded from
  /// `perf.data`.
  static AddressSpaceSymbols fromMappings(
      List<Mapping> mappings, ProfileBuilder profileBuilder) {
    // Try loading symbols for each mapping and keep those that
    // actually have symbols. Sort resulting list by base address.
    final mappingsWithSymbols = <(Mapping, SymbolsIndex)>[];
    for (var event in mappings) {
      final symbolsIndex = profileBuilder.symbolsIndexFor(event.path);
      if (symbolsIndex != null) {
        mappingsWithSymbols.add((event, symbolsIndex));
      }
    }
    mappingsWithSymbols
        .sort((a, b) => a.$1.baseAddress.compareTo(b.$1.baseAddress));

    // Build `AddressSpaceSymbols` from mappings with symbols.
    //
    // Note: we need to accomodate for a situation when two mappings are
    // adjacent. However we assume that number of mappings is rather small
    // so we don't optimize this code too much.
    final result = <({int baseAddress, SymbolsIndex? index, int fileOffset})>[];
    void addEntry({
      required int baseAddress,
      required SymbolsIndex? index,
      required int fileOffset,
    }) {
      if (result.isNotEmpty && result.last.baseAddress == baseAddress) {
        // Collapse end of the previous mapping and the start of the new
        // mapping.
        if (result.last.index != null) {
          throw StateError('Unexpected intersection of address ranges');
        }
        result.removeLast();
      }
      result.add(
          (baseAddress: baseAddress, index: index, fileOffset: fileOffset));
    }

    addEntry(baseAddress: 0, index: null, fileOffset: 0);
    for (var e in mappingsWithSymbols) {
      addEntry(
        baseAddress: e.$1.baseAddress,
        index: e.$2,
        fileOffset: e.$1.offset,
      );
      addEntry(
        baseAddress: e.$1.baseAddress + e.$1.length,
        index: null,
        fileOffset: 0,
      );
    }

    // Split result into individual components.
    return AddressSpaceSymbols._(
      Int64List.fromList(
        result.map((e) => e.baseAddress).toList(growable: false),
      ),
      result.map((e) => e.index).toList(growable: false),
      Int64List.fromList(
        result.map((e) => e.fileOffset).toList(growable: false),
      ),
    );
  }
}

void loadProfile(String path) {
  final raf = File(path).openSync();
  final perfData = PerfData(raf);

  // Check that input file has expected format.
  final allAttrs = perfData.readAttrs();
  if (allAttrs.length != 1) {
    perfData.reportError(
        'Expected single perf_event_attrs structure, got ${allAttrs.length}');
  }

  final attrs = allAttrs.first;
  if (attrs.type != TypeId.tracepoint) {
    perfData.reportError(
        'Expected to find a file with tracepoint events, got ${attrs.type}');
  }

  const expectedSampleFormat = SampleFormat.ip |
      SampleFormat.tid |
      SampleFormat.time |
      SampleFormat.callchain |
      SampleFormat.cpu |
      SampleFormat.period |
      SampleFormat.raw;
  if (attrs.sampleType != expectedSampleFormat) {
    perfData.reportError(
        'Expected to sample format ${SampleFormat.format(expectedSampleFormat)}'
        ' got ${SampleFormat.format(attrs.sampleType)}: difference '
        '${SampleFormat.format(attrs.sampleType ^ expectedSampleFormat)}');
  }

  final mappings = <Mapping>[];
  perfData.readEvents((type, chunk, pos) {
    if (type == EventType.mmap2) {
      final event = Struct.create<Mmap2Event>(chunk, pos);
      mappings.add(Mapping(
        baseAddress: event.addr,
        length: event.len,
        path: event.filename.toStringFromZeroTerminated(),
        offset: event.pgoffs,
      ));
    } else if (type == EventType.sample && mappings.isNotEmpty) {
      // TODO: we miss one sample here.
      return false; // Break iteration.
    }
    return true;
  });

  final syms = AddressSpaceSymbols.fromMappings(mappings, profileBuilder);
  final stack = SymbolizedCallStackBuilder(profileBuilder);
  perfData.readEvents((type, chunk, pos) {
    if (type == EventType.sample) {
      final sample = Struct.create<SampleEvent>(chunk, pos);
      final probeData = Struct.create<ProbeData>(
          chunk, pos + sizeOf<SampleEvent>() + sample.nr * 8);

      for (var i = sample.nr - 1; i > 1; i--) {
        stack.add(sample.ips[i], syms);
      }
      if (stack.depth > 0) {
        // Accumulate [totalBytes] in the last node.
        stack.last.totalBytes += probeData.top - probeData.addr - 1;
      }

      // Reset the stack for the next sample.
      stack.reset(profileBuilder);
    }

    return true;
  });

  print('All data loaded - creating profile.');
  return profileBuilder.finishProfile();
}

void main() {}
