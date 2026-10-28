import 'dart:convert';
import 'package:bett_box/clash/message.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:flutter_test/flutter_test.dart';

class _Listener with AppMessageListener {
  final events = <Object>[];
  @override
  void onSpeedTest(SpeedTestState state) => events.add(state);
  @override
  void onStunTest(StunTestState state) => events.add(state);
  @override
  void onIperf(IperfState state) => events.add(state);
  @override
  void onLocalPing(LocalPingState state) => events.add(state);
}

void main() {
  test(
    'production notification bridge decodes all four native tool streams',
    () async {
      final listener = _Listener();
      clashMessage.addListener(listener);
      addTearDown(() => clashMessage.removeListener(listener));
      clashMessage.controller.add({
        'type': 'speedTest',
        'data': {'phase': 'done', 'download': 123.0},
      });
      clashMessage.controller.add({
        'type': 'stunTest',
        'data': {'phase': 'done', 'external-ip': '192.0.2.1'},
      });
      clashMessage.controller.add({
        'type': 'iperf',
        'data': {'phase': 'done', 'session': 42},
      });
      clashMessage.controller.add({
        'type': 'localPing',
        'data': {'phase': 'done', 'session': 43},
      });
      await Future<void>.delayed(Duration.zero);
      expect(listener.events, hasLength(4));
      expect((listener.events[0] as SpeedTestState).download, 123);
      expect((listener.events[1] as StunTestState).externalIp, '192.0.2.1');
      expect((listener.events[2] as IperfState).session, 42);
      expect((listener.events[3] as LocalPingState).session, 43);
    },
  );

  test(
    'removed notification listener does not receive later messages',
    () async {
      final listener = _Listener();
      clashMessage.addListener(listener);
      clashMessage.removeListener(listener);
      clashMessage.controller.add({
        'type': 'localPing',
        'data': {'phase': 'done'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(listener.events, isEmpty);
    },
  );

  test('speed settings round trip selected server and DNS policy', () {
    final data = SpeedTestSettings(
      provider: SpeedTestProvider.speedtest,
      useSystemDns: false,
      server: SpeedTestNode(
        host: 'speed.example:443',
        sponsor: 'local-fixture',
      ),
    );
    expect(SpeedTestSettings.fromJson(jsonDecode(jsonEncode(data))), data);
  });
}
