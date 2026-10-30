/// Runtime config changes. The saved subscription is not touched.
const explicitChainGroup = '链式落地';

/// Inline landing nodes get dialer-proxy. Provider node names, which are
/// not in the file, become a relay group the selectors can choose.
bool applyChainPolicy(
  Map<String, dynamic> raw, {
  required String entry,
  required String landing,
}) {
  final entryName = entry.trim();
  final landingName = landing.trim();
  if (entryName.isEmpty || landingName.isEmpty || entryName == landingName) {
    return false;
  }
  final proxies = raw['proxies'];
  Map? target;
  var hasEntry = false;
  if (proxies is List) {
    for (final proxy in proxies) {
      if (proxy is! Map) continue;
      if (proxy['name']?.toString() == entryName) hasEntry = true;
      if (proxy['name']?.toString() == landingName) target = proxy;
    }
  }
  if (hasEntry && target != null) {
    target['dialer-proxy'] = entryName;
    return true;
  }

  final groups = raw['proxy-groups'];
  final list = groups is List ? groups : <dynamic>[];
  final exists = list.any(
    (group) => group is Map && group['name']?.toString() == explicitChainGroup,
  );
  if (!exists) {
    list.add({
      'name': explicitChainGroup,
      'type': 'relay',
      'proxies': [entryName, landingName],
    });
  }
  var selectors = 0;
  for (final group in list) {
    if (group is! Map || group['type']?.toString() != 'select') continue;
    if (group['name']?.toString() == explicitChainGroup) continue;
    final members = group['proxies'];
    if (members is! List || members.contains(explicitChainGroup)) continue;
    selectors++;
    if (selectors == 1) {
      // The main selector lists the chain first so it is the default
      // choice once a chain is configured; other selectors keep the
      // chain as an extra option at the end.
      members.insert(0, explicitChainGroup);
    } else {
      members.add(explicitChainGroup);
    }
  }
  raw['proxy-groups'] = list;
  return true;
}
