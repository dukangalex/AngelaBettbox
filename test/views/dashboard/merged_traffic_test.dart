import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/theme.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/dashboard/widgets/network_speed.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('merged card keeps traffic donut, totals, and speed chart', (
    tester,
  ) async {
    globalState.appState = AppState(
      brightness: Brightness.light,
      version: 0,
      viewSize: const Size(400, 800),
      requests: FixedList(maxLength),
      logs: FixedList(maxLogLength),
      traffics: FixedList(30),
      totalTraffic: Traffic(up: 1024, down: 2048),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    globalState.config = Config(themeProps: defaultThemeProps);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: const [AppLocalizations.delegate],
          home: Builder(
            builder: (context) {
              globalState.measure = Measure.of(context, 1);
              globalState.theme = CommonTheme.of(context, 1);
              return const Scaffold(
                body: SizedBox(width: 360, child: NetworkSpeed()),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DonutChart), findsOneWidget);
    expect(find.byType(LineChart), findsOneWidget);
    final donut = tester.widget<DonutChart>(find.byType(DonutChart));
    expect(donut.data.map((e) => e.value).toList(), [1025.0, 2049.0]);
    expect(
      find.textContaining(Traffic(up: 1024).up.toString()),
      findsOneWidget,
    );
    expect(
      find.textContaining(Traffic(down: 2048).down.toString()),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
