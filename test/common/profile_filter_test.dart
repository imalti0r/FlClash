import 'dart:convert';

import 'package:fl_clash/common/profile_filter.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _subscription = '''
port: 7890
proxies:
  - name: HK-01
    type: ss
    server: hk1.example.com
    port: 443
  - name: HK-02
    type: ss
    server: hk2.example.com
    port: 443
  - name: SG-01
    type: vmess
    server: sg1.example.com
    port: 443
  - name: US-01
    type: trojan
    server: us1.example.com
    port: 443
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - HK-01
      - HK-02
      - SG-01
      - US-01
  - name: Overseas
    type: url-test
    proxies:
      - SG-01
      - US-01
  - name: Auto
    type: url-test
    use:
      - provider-a
rules:
  - MATCH,Proxy
''';

Map<String, dynamic> _decode(List<int> bytes) {
  return (loadYaml(utf8.decode(bytes)) as Map).cast<String, dynamic>();
}

List<String> _names(Object? proxies) {
  return [
    for (final proxy in proxies as List) (proxy as Map)['name'] as String,
  ];
}

List<String> _groupNames(Object? groups) {
  return [for (final group in groups as List) (group as Map)['name'] as String];
}

void main() {
  final bytes = utf8.encode(_subscription);

  group('ProfileFilter.buildMatcher', () {
    test('returns null for a blank pattern', () {
      expect(ProfileFilter.buildMatcher(''), isNull);
      expect(ProfileFilter.buildMatcher('   '), isNull);
    });

    test('matches a keyword case-insensitively as a substring', () {
      final matcher = ProfileFilter.buildMatcher('hk')!;
      expect(matcher('HK-01'), isTrue);
      expect(matcher('hk-02'), isTrue);
      expect(matcher('SG-01'), isFalse);
    });

    test('treats a slash-wrapped pattern as a regex', () {
      final matcher = ProfileFilter.buildMatcher(r'/^HK-\d+$/')!;
      expect(matcher('HK-01'), isTrue);
      expect(matcher('HK-99'), isTrue);
      expect(matcher('SG-01'), isFalse);
      expect(matcher('xHK-01'), isFalse);
    });

    test('throws on a malformed regex', () {
      expect(
        () => ProfileFilter.buildMatcher('/(/'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ProfileFilter.apply', () {
    test('keeps the bytes untouched when the pattern is blank', () {
      expect(ProfileFilter.apply(bytes, ''), bytes);
    });

    test('keeps only the matching proxies', () {
      final result = _decode(ProfileFilter.apply(bytes, 'HK'));

      expect(_names(result['proxies']), ['HK-01', 'HK-02']);
    });

    test('filters with a regex pattern', () {
      final result = _decode(ProfileFilter.apply(bytes, r'/(HK|SG)-01/'));

      expect(_names(result['proxies']), ['HK-01', 'SG-01']);
    });

    test('drops removed nodes from every group that referenced them', () {
      final result = _decode(ProfileFilter.apply(bytes, 'HK'));

      final proxyGroup = (result['proxy-groups'] as List).first as Map;
      expect(proxyGroup['name'], 'Proxy');
      expect(proxyGroup['proxies'], ['HK-01', 'HK-02']);
      // Overseas referenced only SG/US nodes and names no provider, so mihomo
      // would reject it; it is removed instead of left empty.
      expect(_groupNames(result['proxy-groups']), ['Proxy', 'Auto']);
    });

    test('keeps unrelated top-level keys and groups untouched', () {
      final result = _decode(ProfileFilter.apply(bytes, 'HK'));

      expect(result['port'], 7890);
      expect(result['rules'], isNotEmpty);
      final auto = (result['proxy-groups'] as List).cast<Map>().firstWhere(
        (group) => group['name'] == 'Auto',
      );
      // A provider-backed group names no proxy, so it survives untouched.
      expect(auto['use'], ['provider-a']);
    });

    test('returns the original bytes when nothing matches', () {
      expect(ProfileFilter.apply(bytes, 'NOPE'), bytes);
    });

    test('returns the original bytes when the document has no proxies', () {
      final other = utf8.encode('port: 7890\nrules:\n  - MATCH,DIRECT\n');
      expect(ProfileFilter.apply(other, 'HK'), other);
    });

    test('returns the original bytes when the document is not valid YAML', () {
      final broken = utf8.encode('proxies: [\n');
      expect(ProfileFilter.apply(broken, 'HK'), broken);
    });

    test('round-trips values that need quoting', () {
      const tricky = '''
proxies:
  - name: "HK: 01"
    type: ss
  - name: "SG-01"
    type: ss
''';
      final result = _decode(ProfileFilter.apply(utf8.encode(tricky), 'HK'));

      expect(_names(result['proxies']), ['HK: 01']);
    });

    test('drops a rule whose target was a removed proxy', () {
      const withRules = '''
proxies:
  - name: HK-01
    type: ss
  - name: US-01
    type: ss
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - HK-01
      - US-01
rules:
  - DOMAIN-SUFFIX,example.com,US-01
  - DOMAIN-SUFFIX,keep.com,HK-01
  - MATCH,Proxy
  - GEOIP,CN,DIRECT
''';
      final result = _decode(ProfileFilter.apply(utf8.encode(withRules), 'HK'));

      // A rule on a removed node keeps its match condition but falls back to
      // DIRECT, which mihomo always defines.
      expect(result['rules'], [
        'DOMAIN-SUFFIX,example.com,DIRECT',
        'DOMAIN-SUFFIX,keep.com,HK-01',
        'MATCH,Proxy',
        'GEOIP,CN,DIRECT',
      ]);
    });

    test('redirects a rule to DIRECT when its group was dropped', () {
      const groupOnly = '''
proxies:
  - name: HK-01
    type: ss
  - name: US-01
    type: ss
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - US-01
rules:
  - MATCH,Proxy
''';
      final result = _decode(ProfileFilter.apply(utf8.encode(groupOnly), 'HK'));

      // Proxy named only a removed node, so it is gone and its rule is
      // redirected rather than left dangling.
      expect(_groupNames(result['proxy-groups']), isEmpty);
      expect(result['rules'], ['MATCH,DIRECT']);
    });

    test('drops a group whose only reference was another dropped group', () {
      const chained = '''
proxies:
  - name: HK-01
    type: ss
  - name: US-01
    type: ss
proxy-groups:
  - name: Inner
    type: select
    proxies:
      - US-01
  - name: Outer
    type: select
    proxies:
      - Inner
  - name: Keep
    type: select
    proxies:
      - HK-01
rules:
  - MATCH,Keep
''';
      final result = _decode(ProfileFilter.apply(utf8.encode(chained), 'HK'));

      // Inner falls first, which empties Outer; both go, Keep stays.
      expect(_groupNames(result['proxy-groups']), ['Keep']);
      expect(result['rules'], ['MATCH,Keep']);
    });

    test('leaves a no-resolve rule targeting a surviving node untouched', () {
      const withParam = '''
proxies:
  - name: HK-01
    type: ss
  - name: US-01
    type: ss
rules:
  - IP-CIDR,10.0.0.0/8,HK-01,no-resolve
  - IP-CIDR,10.1.0.0/8,US-01,no-resolve
''';
      final result = _decode(ProfileFilter.apply(utf8.encode(withParam), 'HK'));

      expect(result['rules'], [
        'IP-CIDR,10.0.0.0/8,HK-01,no-resolve',
        'IP-CIDR,10.1.0.0/8,DIRECT,no-resolve',
      ]);
    });
  });
}
