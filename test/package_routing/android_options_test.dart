import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:bett_box/models/core.dart';

void main() {
  Map<String, dynamic> input({Object? include, Object? exclude}) => {
    'enable': true, 'port': 7890, 'accessControl': null,
    'allowBypass': false, 'systemProxy': false, 'bypassDomain': <String>[],
    'ipv4Address': '172.19.0.1/30', 'ipv6Address': '',
    'routeAddress': <String>[], 'dnsServerAddress': '1.1.1.1',
    'includePackage': include, 'excludePackage': exclude,
  };
  test('package rules survive core json to native channel json', () {
    final value = AndroidVpnOptions.fromJson(input(include: ['a.example'], exclude: ['b.example']));
    final json = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
    expect(json['includePackage'], ['a.example']);
    expect(json['excludePackage'], ['b.example']);
  });
  test('null optional lists are safe defaults', () {
    final value = AndroidVpnOptions.fromJson(input());
    expect(value.includePackage, isEmpty);
    expect(value.excludePackage, isEmpty);
  });
}
