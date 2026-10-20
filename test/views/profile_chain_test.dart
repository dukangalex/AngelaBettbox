import 'dart:io';

import 'package:bett_box/clash/core.dart';
import 'package:bett_box/clash/interface.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/profile_chain.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/profile_chain.dart';
import 'package:bett_box/widgets/list.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ChainValidator extends ClashHandlerInterface {
  String message = '';
  SetupParams? received;
  @override
  Future<String> validateConfig(
    String data, {
    String? ageSecretKey,
    SetupParams? setup,
  }) async {
    received = setup;
    return message;
  }

  @override
  Future<bool> preload() async => true;
  @override
  void reStart() {}
  @override
  bool destroy() => true;
  @override
  Future<Object?> sendMessage(String message) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  final handler = _ChainValidator();
  const profile = Profile(
    id: 'chain-page',
    autoUpdateDuration: Duration(hours: 1),
  );
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    ClashCore.setHandlerForTesting(handler);
    home = await Directory.systemTemp.createTemp('bettbox_chain_page_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => home.path,
        );
    final path = await appPath.getProfilePath(profile.id);
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(
      'proxies:\n  - {name: Entry, type: http, server: 127.0.0.1, port: 10001}\n  - {name: Exit, type: http, server: 127.0.0.1, port: 10002}\n',
    );
    await ProfileChainStore.instance.ensureLoaded();
  });
  tearDownAll(() => home.delete(recursive: true));
  setUp(() {
    handler.message = '';
    handler.received = null;
    ProfileChainStore.instance.byProfile.clear();
    globalState.config = Config(themeProps: defaultThemeProps);
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
  });
  Future<void> open(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: [AppLocalizations.delegate],
            home: ProfileChainPage(profile: profile),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
  }

  void enable(WidgetTester tester, bool value) {
    final item = tester.widget<ListItem>(
      find.byWidgetPredicate(
        (w) => w is ListItem && w.delegate is SwitchDelegate,
      ),
    );
    (item.delegate as SwitchDelegate).onChanged!(value);
  }

  testWidgets('incomplete selection is explained and remains disabled', (
    tester,
  ) async {
    await open(tester);
    enable(tester, true);
    await tester.pumpAndSettle();
    expect(
      find.text('Choose both an entry and an exit before enabling the chain.'),
      findsOneWidget,
    );
    expect(ProfileChainStore.instance.of(profile.id).enabled, isFalse);
    expect(handler.received, isNull);
  });
  testWidgets(
    'cycle validation error is visible and last saved choice survives',
    (tester) async {
      final original = ProfileChain(entry: 'Entry', landing: 'Exit');
      ProfileChainStore.instance.byProfile[profile.id] = original;
      handler.message = 'circular dialer-proxy fixture';
      await open(tester);
      await tester.runAsync(() async {
        enable(tester, true);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(find.text('circular dialer-proxy fixture'), findsOneWidget);
      expect(ProfileChainStore.instance.of(profile.id), same(original));
      expect(handler.received?.patch?['chain-policy'], {
        'enabled': true,
        'entry': 'Entry',
        'landing': 'Exit',
      });
      handler.message = '';
      await tester.runAsync(() async {
        enable(tester, true);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(ProfileChainStore.instance.of(profile.id).enabled, isTrue);
      expect(find.text('circular dialer-proxy fixture'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('profile_chain_v1'), contains('"enabled":true'));
    },
  );
  testWidgets(
    'removed nodes are explained and the chain can still be disabled',
    (tester) async {
      ProfileChainStore.instance.byProfile[profile.id] = ProfileChain(
        enabled: true,
        entry: 'Entry',
        landing: 'Removed',
      );
      await open(tester);
      expect(
        find.textContaining('A selected node is unavailable.'),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        enable(tester, false);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(ProfileChainStore.instance.of(profile.id).enabled, isFalse);
      expect(handler.received, isNull);
    },
  );
}
