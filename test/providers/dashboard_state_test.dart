import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAppSetting extends AppSetting {
  _FakeAppSetting(this.widgets);

  final List<DashboardWidget> widgets;

  @override
  AppSettingProps build() => AppSettingProps(
    mobileDashboardWidgets: widgets,
    desktopDashboardWidgets: widgets,
  );
}

DashboardState _readState(List<DashboardWidget> widgets) {
  final container = ProviderContainer(
    overrides: [
      appSettingProvider.overrideWith(() => _FakeAppSetting(widgets)),
      viewWidthProvider.overrideWith((ref) => 400),
    ],
  );
  addTearDown(container.dispose);
  return container.read(dashboardStateProvider);
}

void main() {
  group('dashboardState', () {
    test('keeps traffic usage and network speed as separate tiles', () {
      final state = _readState([
        DashboardWidget.networkSpeed,
        DashboardWidget.trafficUsage,
      ]);
      expect(
        state.dashboardWidgets,
        containsAll([
          DashboardWidget.networkSpeed,
          DashboardWidget.trafficUsage,
        ]),
      );
      expect(
        state.dashboardWidgets
            .where((w) => w == DashboardWidget.networkSpeed)
            .length,
        1,
      );
      expect(
        state.dashboardWidgets
            .where((w) => w == DashboardWidget.trafficUsage)
            .length,
        1,
      );
    });

    test('appends the start button when missing', () {
      final state = _readState([DashboardWidget.trafficUsage]);
      expect(state.dashboardWidgets.last, DashboardWidget.startButton);
    });

    test('does not duplicate the start button', () {
      final state = _readState([
        DashboardWidget.startButton,
        DashboardWidget.trafficUsage,
      ]);
      expect(
        state.dashboardWidgets
            .where((w) => w == DashboardWidget.startButton)
            .length,
        1,
      );
    });
  });
}
