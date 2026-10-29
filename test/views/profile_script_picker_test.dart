import 'package:bett_box/common/common.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/profiles/profile_script_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppLocalizations.load(const Locale('en'));
  });

  setUp(() {
    globalState.config = Config(themeProps: defaultThemeProps);
    globalState.appState = AppState(
      brightness: Brightness.dark,
      version: 0,
      viewSize: Size.zero,
      requests: FixedList(maxLength),
      logs: FixedList(maxLogLength),
      traffics: FixedList(30),
      totalTraffic: Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
  });

  const props = ScriptProps(
    currentId: 's1',
    scripts: [Script(id: 's1', label: 'HiClash')],
  );

  Future<ProfileScriptSelection?> openAndPick(
    WidgetTester tester, {
    required bool useScriptOverride,
    required String? scriptId,
    required String pickLabel,
  }) async {
    ProfileScriptSelection? result;
    var popped = false;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.of(context)
                    .push<ProfileScriptSelection>(
                      MaterialPageRoute(
                        builder: (_) => ProfileScriptPickerPage(
                          useScriptOverride: useScriptOverride,
                          scriptId: scriptId,
                          scriptProps: props,
                        ),
                      ),
                    );
                popped = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The page must render its options; a build failure here is what
    // turned the page into a blank grey screen on device.
    expect(tester.takeException(), isNull);
    expect(find.text('Do Not Use a Script'), findsOneWidget);
    expect(find.text('Follow Global Script'), findsOneWidget);
    expect(find.text('HiClash'), findsWidgets);
    // 'HiClash' also appears as the follow-global row's subtitle (the
    // current script's label); the last match is the script option row.
    final target = pickLabel == 'HiClash'
        ? find.text(pickLabel).last
        : find.text(pickLabel);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(popped, isTrue);
    return result;
  }

  testWidgets('renders options and returns the tapped script', (tester) async {
    final result = await openAndPick(
      tester,
      useScriptOverride: true,
      scriptId: null,
      pickLabel: 'HiClash',
    );
    expect(result, (useScriptOverride: true, scriptId: 's1'));
  });

  testWidgets('returns no-script when the first option is tapped', (
    tester,
  ) async {
    final result = await openAndPick(
      tester,
      useScriptOverride: true,
      scriptId: 's1',
      pickLabel: 'Do Not Use a Script',
    );
    expect(result, (useScriptOverride: false, scriptId: null));
  });
}
