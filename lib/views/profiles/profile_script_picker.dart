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
///
/// Rows are built with the app's ListItem radio variant: the stock
/// Material ListTile cannot find a Material ancestor inside this app's
/// component-library tree and fails to build, which is why this page
/// must not use it.
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

  /// The selection the radio group shows as current. A stored [scriptId]
  /// whose script was deleted resolves to follow-global.
  ProfileScriptSelection get _currentSelection {
    if (!useScriptOverride) {
      return (useScriptOverride: false, scriptId: null);
    }
    if (scriptId == null || scriptProps.scriptById(scriptId!) == null) {
      return (useScriptOverride: true, scriptId: null);
    }
    return (useScriptOverride: true, scriptId: scriptId);
  }

  Widget _option({
    required BuildContext context,
    required String title,
    String? subtitle,
    required ProfileScriptSelection value,
  }) {
    return ListItem<ProfileScriptSelection>.radio(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      delegate: RadioDelegate<ProfileScriptSelection>(
        value: value,
        groupValue: _currentSelection,
        onChanged: (_) => Navigator.of(context).pop(value),
      ),
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
            value: (useScriptOverride: false, scriptId: null),
          ),
          _option(
            context: context,
            title: appLocalizations.followGlobalScript,
            subtitle: currentScript?.label ?? appLocalizations.none,
            value: (useScriptOverride: true, scriptId: null),
          ),
          for (final script in scriptProps.scripts)
            _option(
              context: context,
              title: script.label,
              value: (useScriptOverride: true, scriptId: script.id),
            ),
        ],
      ),
    );
  }
}
