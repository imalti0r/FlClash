import 'dart:convert';

import 'package:fl_clash/common/yaml.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:yaml/yaml.dart';

import 'print.dart';

/// Filters a Clash subscription by node name, rewriting the whole document so
/// mihomo can still load it. See `.agents/architecture.md`, "Profile Filtering",
/// for why the groups and rules have to move with the proxies.
class ProfileFilter {
  const ProfileFilter._();

  static bool _isRegex(String pattern) {
    return pattern.length >= 2 &&
        pattern.startsWith('/') &&
        pattern.endsWith('/');
  }

  /// Throws [FormatException] on a malformed regex, so a caller can surface it
  /// instead of silently dropping every node. Null when [pattern] is blank.
  static bool Function(String name)? buildMatcher(String pattern) {
    final trimmed = pattern.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (_isRegex(trimmed)) {
      final regExp = RegExp(trimmed.substring(1, trimmed.length - 1));
      return (name) => regExp.hasMatch(name);
    }
    final lower = trimmed.toLowerCase();
    return (name) => name.toLowerCase().contains(lower);
  }

  /// Returns [bytes] unchanged when nothing matches: an empty profile is worse
  /// than an unfiltered one, and the user can clear the pattern.
  static List<int> apply(List<int> bytes, String pattern) {
    final matcher = buildMatcher(pattern);
    if (matcher == null) {
      return bytes;
    }
    final Object? document;
    try {
      document = loadYaml(utf8.decode(bytes, allowMalformed: true));
    } catch (e) {
      commonPrint.log(
        'profile filter: subscription is not readable YAML: $e',
        logLevel: LogLevel.warning,
      );
      return bytes;
    }
    final config = _deepConvert(document);
    if (config is! Map) {
      return bytes;
    }
    final proxies = config['proxies'];
    if (proxies is! List) {
      return bytes;
    }
    final keptNames = <String>{};
    final keptProxies = <Object?>[];
    for (final proxy in proxies) {
      if (proxy is! Map) {
        continue;
      }
      final name = proxy['name'];
      if (name is! String || !matcher(name)) {
        continue;
      }
      keptNames.add(name);
      keptProxies.add(proxy);
    }
    if (keptProxies.isEmpty) {
      commonPrint.log(
        'profile filter: "$pattern" matched no node, keeping the original subscription',
        logLevel: LogLevel.warning,
      );
      return bytes;
    }
    config['proxies'] = keptProxies;
    final keptGroups = _pruneGroups(config['proxy-groups'], keptNames);
    config['proxy-groups'] = keptGroups;
    config['rules'] = _pruneRules(config['rules'], keptNames, keptGroups);
    return utf8.encode(yaml.encode(config));
  }

  /// Removes references to deleted nodes, then drops any group left naming
  /// nothing. Dropping a group can empty the one that referenced it, so the
  /// passes repeat until the set is stable.
  static List<Object?> _pruneGroups(Object? groups, Set<String> keptNames) {
    if (groups is! List) {
      return const [];
    }
    var current = <Map>[
      for (final group in groups)
        if (group is Map) group,
    ];
    while (true) {
      final names = <String>{
        for (final group in current)
          if (group['name'] is String) group['name'] as String,
      };
      final next = <Map>[];
      for (final group in current) {
        final proxies = _stringList(group['proxies']);
        final pruned = proxies == null
            ? null
            : [
                for (final ref in proxies)
                  if (keptNames.contains(ref) || names.contains(ref)) ref,
              ];
        if (pruned != null) {
          group['proxies'] = pruned;
        }
        final uses = _stringList(group['use']);
        if ((pruned?.isEmpty ?? true) && (uses?.isEmpty ?? true)) {
          continue;
        }
        next.add(group);
      }
      if (next.length == current.length) {
        return next;
      }
      current = next;
    }
  }

  /// Redirects a rule that targeted a removed node or group to `DIRECT`,
  /// keeping its match condition. Dropping the rule would change routing
  /// silently; `DIRECT` is a target mihomo always defines.
  static List<Object?> _pruneRules(
    Object? rules,
    Set<String> keptNames,
    List<Object?> keptGroups,
  ) {
    if (rules is! List) {
      return const [];
    }
    final groupNames = <String>{
      for (final group in keptGroups)
        if (group is Map && group['name'] is String) group['name'] as String,
    };
    return [
      for (final rule in rules)
        if (rule is! String)
          rule
        else
          _rewriteRule(rule, keptNames, groupNames),
    ];
  }

  static String _rewriteRule(
    String rule,
    Set<String> keptNames,
    Set<String> groupNames,
  ) {
    final fields = rule.split(',');
    // The target is the last field, but `no-resolve` and `src` may follow it.
    var last = fields.length - 1;
    while (last >= 0 && _ruleParams.contains(fields[last].trim())) {
      last--;
    }
    if (last < 1) {
      return rule;
    }
    final target = fields[last].trim();
    final survives =
        keptNames.contains(target) ||
        groupNames.contains(target) ||
        _builtInTargets.contains(target.toUpperCase());
    if (survives) {
      return rule;
    }
    final rewritten = List<String>.from(fields);
    rewritten[last] = 'DIRECT';
    return rewritten.join(',');
  }

  static const _ruleParams = {'no-resolve', 'src'};

  static const _builtInTargets = {
    'DIRECT',
    'REJECT',
    'REJECT-DROP',
    'PASS',
    'COMPATIBLE',
  };

  static List<String>? _stringList(Object? value) {
    if (value is! List) {
      return null;
    }
    return [
      for (final item in value)
        if (item is String) item,
    ];
  }

  static Object? _deepConvert(Object? value) {
    if (value is Map) {
      return {
        for (final MapEntry(:key, :value) in value.entries)
          key: _deepConvert(value),
      };
    }
    if (value is List) {
      return [for (final item in value) _deepConvert(item)];
    }
    return value;
  }
}
