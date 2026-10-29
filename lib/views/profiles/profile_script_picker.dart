import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';

/// The script choice for one profile: whether script override is on for
/// the profile, and if so which script applies. A null [scriptId] means
/// the profile follows the global current script.
typedef ProfileScriptSelection = ({bool useScriptOverride, String? scriptId});

/// Lets the user pick which script a single profile uses: no script,
/// the global current script, or any specific script.
class ProfileScriptPickerPage extends StatelessWidget {
  final bool useScriptOverride;
  final String? scriptId;
  final ScriptProps scriptProps;

  const ProfileScriptPickerPage({
    super.key,
    required this.useScriptOverride,
    required this.scriptId,
    required this.scriptProps,
  });

  bool get _followGlobalSelected =>
      useScriptOverride &&
      (scriptId == null || scriptProps.scriptById(scriptId!) == null);

  Widget _option({
    required BuildContext context,
    required String title,
    String? subtitle,
    required bool selected,
    required ProfileScriptSelection value,
  }) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: () {
        Navigator.of(context).pop(value);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentScript = scriptProps.currentScript;
    return CommonScaffold(
      title: appLocalizations.script,
      body: ListView(
        children: [
          _option(
            context: context,
            title: appLocalizations.scriptNotUsed,
            selected: !useScriptOverride,
            value: (useScriptOverride: false, scriptId: null),
          ),
          _option(
            context: context,
            title: appLocalizations.followGlobalScript,
            subtitle: currentScript?.label ?? appLocalizations.none,
            selected: _followGlobalSelected,
            value: (useScriptOverride: true, scriptId: null),
          ),
          if (scriptProps.scripts.isNotEmpty) const Divider(),
          for (final script in scriptProps.scripts)
            _option(
              context: context,
              title: script.label,
              selected: useScriptOverride && scriptId == script.id,
              value: (useScriptOverride: true, scriptId: script.id),
            ),
        ],
      ),
    );
  }
}
