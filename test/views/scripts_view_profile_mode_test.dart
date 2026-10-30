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
    scripts: [Script(id: 's1', label: 'HiClash')],
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

  testWidgets('profile mode renders management list with mode options', (
    tester,
  ) async {
    ProfileScriptSelection? captured;
    await openPage(
      tester,
      page: ScriptsView(
        profileSelection: (useScriptOverride: true, scriptId: 's1'),
        onProfileSelectionChanged: (selection) => captured = selection,
      ),
    );
    expect(find.text('Do Not Use a Script'), findsOneWidget);
    expect(find.text('Follow Global Script'), findsOneWidget);
    expect(find.text('HiClash'), findsWidgets);
    // Switch order: no-script card, follow-global card, HiClash card.
    expect(switchValues(tester), [false, false, true]);

    // Choosing the follow-global card reports the follow selection.
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    expect(captured, (useScriptOverride: true, scriptId: null));
    expect(switchValues(tester), [false, true, false]);

    // Choosing the no-script card reports override off.
    await tester.tap(find.byType(Switch).at(0));
    await tester.pumpAndSettle();
    expect(captured, (useScriptOverride: false, scriptId: null));
    expect(switchValues(tester), [true, false, false]);

    // Choosing the script card reports that specific script.
    await tester.tap(find.byType(Switch).at(2));
    await tester.pumpAndSettle();
    expect(captured, (useScriptOverride: true, scriptId: 's1'));
    expect(switchValues(tester), [false, false, true]);
  });

  testWidgets('global mode keeps the plain management list', (tester) async {
    await openPage(tester, page: const ScriptsView());
    expect(find.text('Do Not Use a Script'), findsNothing);
    expect(find.text('Follow Global Script'), findsNothing);
    expect(find.text('HiClash'), findsOneWidget);
    // The single switch reflects the global current script.
    expect(switchValues(tester), [true]);
  });
}
