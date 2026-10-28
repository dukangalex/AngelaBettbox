import 'dart:async';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/controller.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/system_explicit.dart';
import 'package:bett_box/widgets/list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TimeoutController extends AppController {
  TimeoutController(super.context, super.ref);
  @override
  Future<bool> applyProfileChecked() async =>
      throw TimeoutException('setupConfig timeout');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('setup timeout produces unconfirmed status on saved toggle', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await SystemExplicitStore.instance.ensureLoaded();
    SystemExplicitStore.instance.value = SystemExplicitOptions();
    globalState.config = Config(
      themeProps: defaultThemeProps,
      patchClashConfig: defaultClashConfig.copyWith(mode: Mode.rule),
    );
    globalState.appState = AppState(
      brightness: Brightness.light,
      version: 0,
      viewSize: Size.zero,
      requests: FixedList(maxLength),
      logs: FixedList(maxLogLength),
      traffics: FixedList(30),
      totalTraffic: Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) {
                globalState.appController = TimeoutController(context, ref);
                return const Scaffold(body: SystemExplicitView());
              },
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 100));
    final item = tester.widget<ListItem>(
      find.byWidgetPredicate(
        (w) =>
            w is ListItem &&
            w.title is Text &&
            (w.title as Text).data == 'Adaptive path',
      ),
    );
    await tester.runAsync(() async {
      (item.delegate as SwitchDelegate).onChanged!(true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(find.text('Settings application unconfirmed'), findsOneWidget);
    expect(find.textContaining('setupConfig timeout'), findsOneWidget);
    expect(SystemExplicitStore.instance.value.adapt, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('system_explicit_v1'), contains('"adapt":true'));
  });
}
