import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/path_guard.dart';
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
  var _note = '';
  var _applyError = '';

  @override
  void initState() {
    super.initState();
    _note = PathGuard.instance.note.value;
    PathGuard.instance.note.addListener(_onNote);
    SystemExplicitStore.instance.ensureLoaded().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    PathGuard.instance.note.removeListener(_onNote);
    super.dispose();
  }

  void _onNote() {
    if (!mounted) return;
    setState(() => _note = PathGuard.instance.note.value);
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
    await PathGuard.instance.sync(
      running: globalState.isStart,
      change: (group, proxy) => globalState.appController.changeProxy(
        groupName: group,
        proxyName: proxy,
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
          ListItem.switchItem(
            title: Text(appLocalizations.systemExplicitAdapt),
            subtitle: Text(appLocalizations.systemExplicitAdaptDesc),
            delegate: SwitchDelegate(
              value: value.adapt,
              onChanged: (on) {
                value.adapt = on;
                _commit();
              },
            ),
          ),
          ListItem(
            title: Text(appLocalizations.systemExplicitLastSwitch),
            subtitle: Text(
              _note.isEmpty ? appLocalizations.systemExplicitNoneYet : _note,
            ),
          ),
          ListItem.switchItem(
            title: Text(appLocalizations.systemExplicitPrivacy),
            subtitle: Text(appLocalizations.systemExplicitPrivacyDesc),
            delegate: SwitchDelegate(
              value: value.privacy,
              onChanged: (on) =>
                  _setRuleOption(on, (valueOn) => value.privacy = valueOn),
            ),
          ),
          ListItem.switchItem(
            title: Text(appLocalizations.systemExplicitChinaDirect),
            subtitle: Text(appLocalizations.systemExplicitChinaDirectDesc),
            delegate: SwitchDelegate(
              value: value.chinaDirect,
              onChanged: (on) =>
                  _setRuleOption(on, (valueOn) => value.chinaDirect = valueOn),
            ),
          ),
          ListItem.switchItem(
            title: Text(appLocalizations.systemExplicitChinaDnsDirect),
            subtitle: Text(appLocalizations.systemExplicitChinaDnsDirectDesc),
            delegate: SwitchDelegate(
              value: value.chinaPublicDnsDirect,
              onChanged: (on) => _setRuleOption(
                on,
                (valueOn) => value.chinaPublicDnsDirect = valueOn,
              ),
            ),
          ),
          ListItem.switchItem(
            title: Text(appLocalizations.systemExplicitLanDirect),
            subtitle: Text(appLocalizations.systemExplicitLanDirectDesc),
            delegate: SwitchDelegate(
              value: value.lanDirect,
              onChanged: (on) =>
                  _setRuleOption(on, (valueOn) => value.lanDirect = valueOn),
            ),
          ),
          ListItem.switchItem(
            title: Text(appLocalizations.systemExplicitBlockWebRtc),
            subtitle: Text(appLocalizations.systemExplicitBlockWebRtcDesc),
            delegate: SwitchDelegate(
              value: value.blockCommonWebRtc,
              onChanged: (on) => _setRuleOption(
                on,
                (valueOn) => value.blockCommonWebRtc = valueOn,
              ),
            ),
          ),
          ListItem.switchItem(
            title: Text(appLocalizations.systemExplicitBlockAds),
            subtitle: Text(appLocalizations.systemExplicitBlockAdsDesc),
            delegate: SwitchDelegate(
              value: value.blockAds,
              onChanged: (on) =>
                  _setRuleOption(on, (valueOn) => value.blockAds = valueOn),
            ),
          ),
          if (system.isAndroid)
            ListItem.switchItem(
              title: Text(appLocalizations.systemExplicitBlockTunUdp),
              subtitle: Text(appLocalizations.systemExplicitBlockTunUdpDesc),
              delegate: SwitchDelegate(
                value: value.blockTunUdp,
                onChanged: (on) {
                  setState(() => value.blockTunUdp = on);
                  _commit();
                },
              ),
            ),
          ListItem(
            title: Text(appLocalizations.systemExplicitLimits),
            subtitle: Text(appLocalizations.systemExplicitLimitsDesc),
          ),
        ],
      ),
    );
  }
}
