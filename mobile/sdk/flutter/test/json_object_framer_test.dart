import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/src/at/json_object_framer.dart';

void main() {
  group('JsonObjectFramer', () {
    test('reassembles a single complete object', () {
      final framer = JsonObjectFramer();
      final out = framer.feed('{"ok":true}').toList();
      expect(out, ['{"ok":true}']);
    });

    test('reassembles chunked JSON across feeds', () {
      final framer = JsonObjectFramer();
      expect(framer.feed('{"ok":').toList(), isEmpty);
      final out = framer.feed('true,"session":"abc"}').toList();
      expect(out, ['{"ok":true,"session":"abc"}']);
    });

    test('skips garbage before object start', () {
      final framer = JsonObjectFramer();
      final out = framer.feed('noise {"a":1}').toList();
      expect(out, ['{"a":1}']);
    });

    test('handles escaped quotes inside strings', () {
      final framer = JsonObjectFramer();
      final json = r'{"msg":"say \"hi\"","n":1}';
      final out = framer.feed(json).toList();
      expect(out, [json]);
    });

    test('emits multiple objects in one feed', () {
      final framer = JsonObjectFramer();
      final out = framer.feed('{"a":1}{"b":2}').toList();
      expect(out, ['{"a":1}', '{"b":2}']);
    });
  });
}
