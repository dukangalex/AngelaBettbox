import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SystemExplicitView extends ConsumerStatefulWidget {
  const SystemExplicitView({super.key});

  @override
  ConsumerState<SystemExplicitView> createState() => _SystemExplicitViewState();
}

class _SystemExplicitViewState extends ConsumerState<SystemExplicitView> {
  var _ready = false;
  var _applyError = '';

  @override
  void initState() {
    super.initState();
    SystemExplicitStore.instance.ensureLoaded().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
    });
  }

  Future<void> _setRuleOption(bool on, void Function(bool) update) async {
    final mode = ref.read(patchClashConfigProvider).mode;
    if (on && mode != Mode.rule) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(appLocalizations.systemExplicitRuleModeTitle),
          content: Text(appLocalizations.systemExplicitRuleModeDesc),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(appLocalizations.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(appLocalizations.systemExplicitSwitch),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      await globalState.appController.changeMode(Mode.rule);
      if (!mounted) return;
      if (ref.read(patchClashConfigProvider).mode != Mode.rule) {
        setState(
          () => _applyError = appLocalizations.systemExplicitRuleModeNotApplied,
        );
        return;
      }
    }
    if (!mounted) return;
    setState(() => update(on));
    await _commit();
  }

  Future<void> _commit() async {
    try {
      await saveAndReloadSystemExplicit(
        save: SystemExplicitStore.instance.save,
        // Rule changes need a full profile setup, not updateConfig, which only
        // updates general settings and leaves the existing rules untouched.
        reload: () => globalState.appController.applyProfileChecked(),
      );
    } on Object catch (error) {
      // Saved choices can differ from the running configuration after failure.
      if (mounted) {
        setState(
          () => _applyError = appLocalizations.systemExplicitApplyUnconfirmed(
            '$error',
          ),
        );
      }
      return;
    }
    if (mounted) setState(() => _applyError = '');
  }

  /// Descriptions stay collapsed until the row is tapped, so the page reads
  /// as a compact list of switches; the explanation is one tap away.
  final _expanded = <String>{};

  void _toggleExpanded(String id) {
    setState(() {
      if (!_expanded.remove(id)) _expanded.add(id);
    });
  }

  Widget _optionItem({
    required String id,
    required String title,
    required String desc,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final expanded = _expanded.contains(id);
    // Built with ListItem.switchItem like every other settings page, so the
    // switch is the component library's own and follows the app theme.
    // The chevron stays separately tappable: tapping the row toggles the
    // switch (the switchItem convention), tapping the chevron expands the
    // description. A plain GestureDetector is used on purpose: stock
    // Material buttons need a Material ancestor this tree does not have.
    return ListItem.switchItem(
      padding: const EdgeInsets.only(left: 16, right: 8),
      title: Text(title),
      subtitle: expanded ? Text(desc) : null,
      trailing: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggleExpanded(id),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            size: 20,
            color: context.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      delegate: SwitchDelegate(value: value, onChanged: onChanged),
    );
  }

  Widget _infoItem({
    required String id,
    required String title,
    required String desc,
  }) {
    final expanded = _expanded.contains(id);
    return ListItem(
      padding: const EdgeInsets.only(left: 16, right: 8),
      title: Text(title),
      subtitle: expanded ? Text(desc) : null,
      onTap: () => _toggleExpanded(id),
      trailing: Icon(
        expanded ? Icons.expand_less : Icons.expand_more,
        size: 20,
        color: context.colorScheme.onSurfaceVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(child: CircularProgressIndicator());
    }
    final value = SystemExplicitStore.instance.value;
    final mode = ref.watch(
      patchClashConfigProvider.select((state) => state.mode),
    );
    final incompatible = !systemExplicitModeCompatible(value, mode);
    return generateListView(
      generateSection(
        title: appLocalizations.systemExplicitIntro,
        items: [
          if (incompatible)
            ListItem(
              title: Text(appLocalizations.systemExplicitInactive),
              subtitle: Text(appLocalizations.systemExplicitInactiveDesc),
            ),
          if (_applyError.isNotEmpty)
            ListItem(
              title: Text(appLocalizations.systemExplicitApplyState),
              subtitle: Text(_applyError),
            ),
          _optionItem(
            id: 'privacy',
            title: appLocalizations.systemExplicitPrivacy,
            desc: appLocalizations.systemExplicitPrivacyDesc,
            value: value.privacy,
            onChanged: (on) =>
                _setRuleOption(on, (valueOn) => value.privacy = valueOn),
          ),
          _optionItem(
            id: 'chinaDirect',
            title: appLocalizations.systemExplicitChinaDirect,
            desc: appLocalizations.systemExplicitChinaDirectDesc,
            value: value.chinaDirect,
            onChanged: (on) =>
                _setRuleOption(on, (valueOn) => value.chinaDirect = valueOn),
          ),
          _optionItem(
            id: 'chinaDnsDirect',
            title: appLocalizations.systemExplicitChinaDnsDirect,
            desc: appLocalizations.systemExplicitChinaDnsDirectDesc,
            value: value.chinaPublicDnsDirect,
            onChanged: (on) => _setRuleOption(
              on,
              (valueOn) => value.chinaPublicDnsDirect = valueOn,
            ),
          ),
          _optionItem(
            id: 'lanDirect',
            title: appLocalizations.systemExplicitLanDirect,
            desc: appLocalizations.systemExplicitLanDirectDesc,
            value: value.lanDirect,
            onChanged: (on) =>
                _setRuleOption(on, (valueOn) => value.lanDirect = valueOn),
          ),
          _optionItem(
            id: 'blockWebRtc',
            title: appLocalizations.systemExplicitBlockWebRtc,
            desc: appLocalizations.systemExplicitBlockWebRtcDesc,
            value: value.blockCommonWebRtc,
            onChanged: (on) => _setRuleOption(
              on,
              (valueOn) => value.blockCommonWebRtc = valueOn,
            ),
          ),
          _optionItem(
            id: 'blockAds',
            title: appLocalizations.systemExplicitBlockAds,
            desc: appLocalizations.systemExplicitBlockAdsDesc,
            value: value.blockAds,
            onChanged: (on) =>
                _setRuleOption(on, (valueOn) => value.blockAds = valueOn),
          ),
          _infoItem(
            id: 'limits',
            title: appLocalizations.systemExplicitLimits,
            desc: appLocalizations.systemExplicitLimitsDesc,
          ),
        ],
      ),
    );
  }
}
