import 'package:bett_box/common/common.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/profiles/scripts.dart';
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

  const props = ScriptProps(
    currentId: 's1',
    scripts: [
      Script(id: 's1', label: 'HiClash'),
      Script(id: 's2', label: 'SubScript'),
    ],
  );

  setUp(() {
    globalState.config = Config(
      themeProps: defaultThemeProps,
      scriptProps: props,
    );
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

  Future<void> openPage(
    WidgetTester tester, {
    required Widget page,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => page),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The page must render; a build failure here is what turned the
    // per-profile script page into a blank grey screen on device.
    expect(tester.takeException(), isNull);
  }

  List<bool> switchValues(WidgetTester tester) {
    return tester
        .widgetList<Switch>(find.byType(Switch))
        .map((item) => item.value)
        .toList();
  }

  testWidgets('profile mode: picking and unpicking scripts', (tester) async {
    ProfileScriptSelection? captured;
    await openPage(
      tester,
      page: ScriptsView(
        profileSelection: (useScriptOverride: true, scriptId: 's1'),
        onProfileSelectionChanged: (selection) => captured = selection,
      ),
    );
    // No separate mode options: the list itself is the choice.
    expect(find.text('Do Not Use a Script'), findsNothing);
    expect(find.text('Follow Global Script'), findsNothing);
    expect(find.text('HiClash'), findsOneWidget);
    expect(find.text('SubScript'), findsOneWidget);
    expect(switchValues(tester), [true, false]);

    // Picking the other script moves the choice.
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    expect(captured, (useScriptOverride: true, scriptId: 's2'));
    expect(switchValues(tester), [false, true]);

    // Unpicking it leaves the profile with no script.
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    expect(captured, (useScriptOverride: false, scriptId: null));
    expect(switchValues(tester), [false, false]);
  });

  testWidgets('profile mode: legacy follow-global shows its script', (
    tester,
  ) async {
    ProfileScriptSelection? captured;
    await openPage(
      tester,
      page: ScriptsView(
        profileSelection: (useScriptOverride: true, scriptId: null),
        onProfileSelectionChanged: (selection) => captured = selection,
      ),
    );
    // The stored follow-global state resolves to the old global
    // current script (s1), so its switch shows on.
    expect(switchValues(tester), [true, false]);
    await tester.tap(find.byType(Switch).at(0));
    await tester.pumpAndSettle();
    expect(captured, (useScriptOverride: false, scriptId: null));
  });

  testWidgets('global mode: management list without switches', (
    tester,
  ) async {
    await openPage(tester, page: const ScriptsView());
    expect(find.text('HiClash'), findsOneWidget);
    expect(find.text('SubScript'), findsOneWidget);
    // No switches in the list itself: enabling a script is a
    // per-profile act, reached through the settings entry.
    expect(find.byType(Switch), findsNothing);
    expect(find.byIcon(Icons.settings), findsOneWidget);
  });

  testWidgets('settings sheet switches a profile script and enters its page', (
    tester,
  ) async {
    globalState.config = Config(
      themeProps: defaultThemeProps,
      profiles: [
        Profile(
          id: 'p1',
          label: 'ProfA',
          url: '',
          autoUpdateDuration: Duration.zero,
          useScriptOverride: true,
          scriptId: 's2',
        ),
      ],
      scriptProps: const ScriptProps(
        currentId: 's1',
        scripts: [
          Script(id: 's1', label: 'HiClash'),
          Script(id: 's2', label: 'SubScript'),
        ],
      ),
    );
    await openPage(tester, page: const ScriptsView());

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('ProfA'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.text('SubScript'),
      ),
      findsOneWidget,
    );

    // The row switch turns the profile's own script off.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(globalState.config.profiles.single.useScriptOverride, isFalse);

    // Switching off only disables the pick, it is not dropped: the same
    // switch stays tappable and turns the same script back on.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(globalState.config.profiles.single.useScriptOverride, isTrue);
    expect(globalState.config.profiles.single.scriptId, 's2');

    // The row itself is the entry into that profile's script page.
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    expect(find.text('ProfA'), findsNothing);
    expect(find.byType(Switch), findsWidgets);
  });
}
