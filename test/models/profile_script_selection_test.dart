import 'dart:convert';

import 'package:bett_box/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const scriptA = Script(id: 'a', label: 'Script A');
  const scriptB = Script(id: 'b', label: 'Script B');
  const props = ScriptProps(currentId: 'a', scripts: [scriptA, scriptB]);

  group('ScriptProps.resolveScript', () {
    test('override off means no script, even with a chosen scriptId', () {
      expect(
        props.resolveScript(useScriptOverride: false, scriptId: 'b'),
        isNull,
      );
      expect(props.resolveScript(useScriptOverride: false), isNull);
    });

    test('override on without a scriptId follows the global script', () {
      expect(props.resolveScript(useScriptOverride: true), scriptA);
    });

    test('override on with a scriptId picks that script', () {
      expect(
        props.resolveScript(useScriptOverride: true, scriptId: 'b'),
        scriptB,
      );
      expect(
        props.resolveScript(useScriptOverride: true, scriptId: 'a'),
        scriptA,
      );
    });

    test('a deleted chosen script falls back to the global script', () {
      expect(
        props.resolveScript(useScriptOverride: true, scriptId: 'gone'),
        scriptA,
      );
    });

    test('no global script and no choice resolves to null', () {
      const empty = ScriptProps(scripts: [scriptA, scriptB]);
      expect(empty.resolveScript(useScriptOverride: true), isNull);
      expect(
        empty.resolveScript(useScriptOverride: true, scriptId: 'b'),
        scriptB,
      );
    });
  });

  group('Profile scriptId persistence', () {
    test('scriptId round-trips through JSON and defaults to null', () {
      Profile decode(Profile profile) => Profile.fromJson(
        jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
      );
      final profile = Profile.normal(label: 'x').copyWith(scriptId: 'b');
      expect(decode(profile).scriptId, 'b');
      expect(Profile.normal(label: 'y').scriptId, isNull);
      final legacyJson =
          jsonDecode(jsonEncode(Profile.normal(label: 'z').toJson()))
              as Map<String, dynamic>
            ..remove('scriptId');
      final legacy = Profile.fromJson(legacyJson);
      expect(legacy.scriptId, isNull);
      expect(legacy.useScriptOverride, isTrue);
    });
  });
}
