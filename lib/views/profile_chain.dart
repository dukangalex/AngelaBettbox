import 'package:bett_box/clash/core.dart';
import 'package:bett_box/common/path_score.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/profile_chain.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaml/yaml.dart';

class ProfileChainPage extends ConsumerStatefulWidget {
  final Profile profile;

  const ProfileChainPage({super.key, required this.profile});

  @override
  ConsumerState<ProfileChainPage> createState() => _ProfileChainPageState();
}

class _ProfileChainPageState extends ConsumerState<ProfileChainPage> {
  var _ready = false;
  var _saving = false;
  String? _error;
  List<String> _names = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';

  String _t(String zh, String en) => _zh ? zh : en;

  Future<void> _load() async {
    await ProfileChainStore.instance.ensureLoaded();
    final names = await _nodeNames();
    if (!mounted) return;
    setState(() {
      _names = names;
      _ready = true;
    });
  }

  Future<List<String>> _nodeNames() async {
    final names = <String>[];
    try {
      final file = await widget.profile.getFile();
      if (await file.exists()) {
        final doc = loadYaml(await file.readAsString());
        if (doc is YamlMap && doc['proxies'] is YamlList) {
          for (final item in doc['proxies'] as YamlList) {
            if (item is! YamlMap) continue;
            final name = item['name']?.toString() ?? '';
            if (name.isNotEmpty && !reservedPathNames.contains(name)) {
              names.add(name);
            }
          }
        }
      }
    } catch (_) {}
    final current = globalState.config.currentProfile?.id == widget.profile.id;
    if (current && globalState.isStart) {
      try {
        final groups = await clashCore.getProxiesGroups();
        for (final group in groups) {
          for (final proxy in group.all) {
            if (!isLeafPath(proxy.type)) continue;
            if (reservedPathNames.contains(proxy.name)) continue;
            names.add(proxy.name);
          }
        }
      } catch (_) {}
    }
    final seen = <String>{};
    return [
      for (final name in names)
        if (seen.add(name)) name,
    ];
  }

  String _issueMessage(ProfileChainIssue issue) => switch (issue) {
    ProfileChainIssue.incomplete => _t(
      '请先选择入口和出口，再启用链式代理。',
      'Choose both an entry and an exit before enabling the chain.',
    ),
    ProfileChainIssue.sameNode => _t(
      '入口和出口不能是同一个节点。',
      'Entry and exit must be different nodes.',
    ),
    ProfileChainIssue.unavailable => _t(
      '所选节点已不可用，请重新选择；订阅节点需要先启动这份配置。',
      'A selected node is unavailable. Choose again; start this profile to load subscription nodes.',
    ),
  };

  Future<void> _commit(ProfileChain candidate) async {
    if (_saving) return;
    final issue = candidate.selectionIssue(_names);
    if (issue != null) {
      setState(() => _error = _issueMessage(issue));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final store = ProfileChainStore.instance;
    final previous = store.of(widget.profile.id);
    try {
      if (candidate.enabled) {
        final setup = await globalState.buildSetupParams(
          patchConfig: globalState.config.patchClashConfig,
          profile: widget.profile,
        );
        final message = await clashCore.validateConfig(
          '',
          setup: setup.copyWith(
            patch: {...?setup.patch, 'chain-policy': candidate.toJson()},
          ),
        );
        if (message.isNotEmpty) throw message;
      }
      // Do not replace the last saved choice on validation or storage failure.
      store.byProfile[widget.profile.id] = candidate;
      try {
        await store.save();
      } catch (_) {
        store.byProfile[widget.profile.id] = previous;
        rethrow;
      }
      if (globalState.config.currentProfile?.id == widget.profile.id) {
        // Chain policy lives in SetupParams.patch, not UpdateParams.
        globalState.appController.applyProfileDebounce();
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.formatError);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chain = ProfileChainStore.instance.of(widget.profile.id);
    final label = widget.profile.label ?? widget.profile.id;
    return CommonScaffold(
      title: _t('链式代理', 'Chain'),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : generateListView(
              generateSection(
                title: label,
                items: [
                  ListItem.switchItem(
                    title: Text(_t('启用', 'Enable')),
                    subtitle: Text(
                      _t(
                        '出口经由入口连出。只作用于这份配置，不改订阅原文。',
                        'The exit node dials through the entry. This profile only. The subscription is not edited.',
                      ),
                    ),
                    delegate: SwitchDelegate(
                      value: chain.enabled,
                      onChanged: _saving
                          ? null
                          : (on) => _commit(chain.copyWith(enabled: on)),
                    ),
                  ),
                  if (_error != null || chain.selectionIssue(_names) != null)
                    ListItem(
                      title: Text(
                        _t('链式设置未就绪', 'Chain settings need attention'),
                      ),
                      subtitle: Text(
                        _error ?? _issueMessage(chain.selectionIssue(_names)!),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_names.isEmpty)
                    ListItem(
                      title: Text(_t('没有可选节点', 'No nodes')),
                      subtitle: Text(
                        _t(
                          '这份配置里没有写明的节点。先启用这份配置，订阅节点才会出现在这里。',
                          'This profile has no inline nodes. Start it and subscription nodes will appear here.',
                        ),
                      ),
                    )
                  else ...[
                    ListItem<String>.options(
                      title: Text(_t('入口', 'Entry')),
                      subtitle: Text(
                        chain.entry.isEmpty
                            ? _t('从这份配置里选择', 'Choose from this profile')
                            : chain.entry,
                      ),
                      delegate: OptionsDelegate<String>(
                        title: _t('入口', 'Entry'),
                        options: _names,
                        value: _names.contains(chain.entry)
                            ? chain.entry
                            : _names.first,
                        textBuilder: (value) => value,
                        onChanged: (value) {
                          if (_saving || value == null) return;
                          if (value == chain.landing) {
                            setState(
                              () => _error = _issueMessage(
                                ProfileChainIssue.sameNode,
                              ),
                            );
                            return;
                          }
                          _commit(chain.copyWith(entry: value));
                        },
                      ),
                    ),
                    ListItem<String>.options(
                      title: Text(_t('出口', 'Exit')),
                      subtitle: Text(
                        chain.landing.isEmpty
                            ? _t('从这份配置里选择', 'Choose from this profile')
                            : chain.landing,
                      ),
                      delegate: OptionsDelegate<String>(
                        title: _t('出口', 'Exit'),
                        options: _names,
                        value: _names.contains(chain.landing)
                            ? chain.landing
                            : _names.first,
                        textBuilder: (value) => value,
                        onChanged: (value) {
                          if (_saving || value == null) return;
                          if (value == chain.entry) {
                            setState(
                              () => _error = _issueMessage(
                                ProfileChainIssue.sameNode,
                              ),
                            );
                            return;
                          }
                          _commit(chain.copyWith(landing: value));
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
