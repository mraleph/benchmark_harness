import 'dart:io';
import 'dart:convert';

void main(List<String> args) {
  final bytes = File('/tmp/y.json').readAsBytesSync();
  final obj = const Utf8Decoder().fuse(JsonDecoder()).convert(bytes)
      as Map<String, dynamic>;
  print(obj.length);

  final bytes2 = File(args.first).readAsBytesSync();
  final snapshot =
      const Utf8Decoder().fuse(JsonDecoder()).convert(bytes2) as Map;
  final snapshotStrings = Set<String>.from(snapshot['strings'] as List);
  final found = <String>{}, notFound = <String>{};
  for (final key in obj.keys) {
    if (snapshotStrings.contains(key)) {
      found.add(key);
    } else if (key.contains('_')) {
      final parts = key.split('_');
      if (parts.every((p) => snapshotStrings.contains(p))) {
        print('$key is actually used');
        found.add(key);
      } else {
        notFound.add(key);
      }
    } else {
      notFound.add(key);
    }
  }
  print('found: ${found.length}');
  print('not found: ${notFound.length}');
}
