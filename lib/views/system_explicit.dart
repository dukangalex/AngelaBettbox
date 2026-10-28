import 'package:bett_box/common/path_guard.dart';
import 'package:bett_box/common/system.dart';
import 'package:bett_box/common/system_explicit.dart';
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

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';

  String _t(String zh, String en) => _zh ? zh : en;

  Future<void> _setRuleOption(bool on, void Function(bool) update) async {
    final mode = ref.read(patchClashConfigProvider).mode;
    if (on && mode != Mode.rule) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(_t('切换到规则模式？', 'Switch to rule mode?')),
          content: Text(
            _t(
              '此选项需要规则模式。切换后会恢复已保存的系统显式路由选项。',
              'This option needs rule mode. Switching restores saved explicit routing choices.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(_t('取消', 'Cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(_t('切换', 'Switch')),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      await globalState.appController.changeMode(Mode.rule);
      if (!mounted) return;
      if (ref.read(patchClashConfigProvider).mode != Mode.rule) {
        setState(
          () => _applyError = _t(
            '未切换到规则模式，选项未启用。',
            'Rule mode was not applied; option not enabled.',
          ),
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
          () => _applyError = _t(
            '无法确认设置已应用到当前配置：$error',
            'Could not confirm these settings were applied to the current profile: $error',
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
        title: _t(
          '写在脚本和配置之后，不改订阅原文。全局或直连模式会暂停规则选项，切回规则模式时恢复已保存的选择。',
          'Applied after scripts and the profile without editing it. Routing options pause in global or direct mode and saved choices resume in rule mode.',
        ),
        items: [
          if (incompatible)
            ListItem(
              title: Text(_t('当前路由选项未生效', 'Routing options are not active')),
              subtitle: Text(
                _t(
                  '当前模式绕过这些规则，已保存的选择将在规则模式恢复；隐私通知隐藏仍保留。',
                  'The current mode bypasses these rules. Saved choices resume in rule mode; notification privacy remains enabled.',
                ),
              ),
            ),
          if (_applyError.isNotEmpty)
            ListItem(
              title: Text(_t('设置应用状态待确认', 'Settings application unconfirmed')),
              subtitle: Text(_applyError),
            ),
          ListItem.switchItem(
            title: Text(_t('自适应通路', 'Adaptive path')),
            subtitle: Text(
              _t(
                '发出数据却收不到回包时会立刻复查。只切换正在走流量的手动组。连续两次、并且换过探测地址仍测不通，才换节点，并放开旧节点上卡住的连接。自动测速组不再把直连当作失败后的退路。不改订阅。',
                'If traffic stalls, check immediately and only switch the manual group carrying it. Two failures on different check addresses are required, then stuck connections are released. Automatic groups can no longer fall back to direct. The subscription is not edited.',
              ),
            ),
            delegate: SwitchDelegate(
              value: value.adapt,
              onChanged: (on) {
                value.adapt = on;
                _commit();
              },
            ),
          ),
          ListItem(
            title: Text(_t('最近一次切换', 'Last switch')),
            subtitle: Text(_note.isEmpty ? _t('还没有切换', 'None yet') : _note),
          ),
          ListItem.switchItem(
            title: Text(_t('防隐私', 'Privacy')),
            subtitle: Text(
              _t(
                '通知不显示配置名，并阻断局域网发现。',
                'Hides the profile name in notifications and blocks local discovery.',
              ),
            ),
            delegate: SwitchDelegate(
              value: value.privacy,
              onChanged: (on) =>
                  _setRuleOption(on, (valueOn) => value.privacy = valueOn),
            ),
          ),
          ListItem.switchItem(
            title: Text(_t('中国 IP 和域名直连', 'China IPs and domains direct')),
            subtitle: Text(
              _t(
                '按 Mihomo 的 GEOIP/GEOSITE 中国规则直连；仅替换配置中同类中国 IP/域名规则，其它规则保留。',
                'Uses Mihomo GEOIP/GEOSITE China rules. Replaces only same-category China IP/domain rules; unrelated rules remain.',
              ),
            ),
            delegate: SwitchDelegate(
              value: value.chinaDirect,
              onChanged: (on) =>
                  _setRuleOption(on, (valueOn) => value.chinaDirect = valueOn),
            ),
          ),
          ListItem.switchItem(
            title: Text(
              _t(
                '中国公共 DNS 直连（隐私例外）',
                'China public DNS direct (privacy exception)',
              ),
            ),
            subtitle: Text(
              _t(
                '默认关闭。仅列出的中国公共 DNS IP/域名走直连，可能暴露 DNS 查询给本地网络/运营商；中国直连也可能覆盖这些地址，即使本项关闭。',
                'Off by default. Listed Chinese public DNS endpoints bypass the proxy and may expose queries to the local network/provider. China-direct can also match these endpoints even if this switch is off.',
              ),
            ),
            delegate: SwitchDelegate(
              value: value.chinaPublicDnsDirect,
              onChanged: (on) => _setRuleOption(
                on,
                (valueOn) => value.chinaPublicDnsDirect = valueOn,
              ),
            ),
          ),
          ListItem.switchItem(
            title: Text(_t('局域网 IP 和域名直连', 'LAN IPs and domains direct')),
            subtitle: Text(
              _t(
                '仅匹配私网/本机/链路本地网段及 .local、.lan、home.arpa；直连流量不经过代理。',
                'Matches private, loopback and link-local ranges plus .local, .lan and home.arpa; direct traffic bypasses proxies.',
              ),
            ),
            delegate: SwitchDelegate(
              value: value.lanDirect,
              onChanged: (on) =>
                  _setRuleOption(on, (valueOn) => value.lanDirect = valueOn),
            ),
          ),
          ListItem.switchItem(
            title: Text(
              _t(
                '阻断 WebRTC/STUN/TURN',
                'Block WebRTC/STUN/TURN',
              ),
            ),
            subtitle: Text(
              _t(
                '默认关闭。按域名阻断含 stun/turn 的主机名与 Google STUN，并阻断 UDP 3478-3480、5349-5355、19302-19305；可能影响语音/视频，伪装流量不在覆盖内，不能保证阻断所有 WebRTC。',
                'Off by default. Rejects hostnames containing stun/turn and Google STUN by domain, plus UDP 3478-3480, 5349-5355 and 19302-19305. May disrupt calls; disguised traffic is not covered, so it cannot block all WebRTC.',
              ),
            ),
            delegate: SwitchDelegate(
              value: value.blockCommonWebRtc,
              onChanged: (on) => _setRuleOption(
                on,
                (valueOn) => value.blockCommonWebRtc = valueOn,
              ),
            ),
          ),
          ListItem.switchItem(
            title: Text(_t('广告拦截', 'Block ads')),
            subtitle: Text(
              _t(
                '默认关闭。按 Mihomo 的 GEOSITE category-ads-all 分类阻断广告域名；仅替换配置中同类广告规则，其它规则保留。',
                'Off by default. Rejects ad domains via the Mihomo GEOSITE category-ads-all category. Replaces only same-category ad rules in the profile; unrelated rules remain.',
              ),
            ),
            delegate: SwitchDelegate(
              value: value.blockAds,
              onChanged: (on) =>
                  _setRuleOption(on, (valueOn) => value.blockAds = valueOn),
            ),
          ),
          if (system.isAndroid)
            ListItem.switchItem(
              title: Text(_t('阻断 VPN 内全部 UDP', 'Block all UDP inside VPN')),
              subtitle: Text(
                _t(
                  '默认关闭。仅阻断进入本应用 TUN 的 IPv4/IPv6 UDP，包括 UDP DNS，不受路由模式影响；可能影响通话、视频、QUIC、游戏和 DNS。TCP/TLS、伪装流量与 VPN 之外不受此项保护；未启动 VPN 时不生效。',
                  'Off by default. Drops IPv4/IPv6 UDP entering this app’s TUN, including UDP DNS, regardless of routing mode. Calls, video, QUIC, games and DNS may fail. TCP/TLS, disguised traffic and traffic outside the VPN are not covered; inactive when VPN is stopped.',
                ),
              ),
              delegate: SwitchDelegate(
                value: value.blockTunUdp,
                onChanged: (on) {
                  setState(() => value.blockTunUdp = on);
                  _commit();
                },
              ),
            ),
          ListItem(
            title: Text(
              _t('DNS 与 VPN 断开保护范围', 'DNS and VPN-disconnect limits'),
            ),
            subtitle: Text(
              _t(
                'DNS 仅在流量经过本应用 TUN 且被 DNS 劫持/核心处理时受控；系统绕过 VPN、应用排除项及应用自行加密的 DoH/DoT 不在通用保证内。断开保护需在 Android 系统 VPN 设置中启用“始终开启”和“阻止未使用 VPN 的连接”（若系统提供）；本应用不能代替系统锁定。',
                'DNS is handled only for traffic routed through this app’s TUN and core DNS hijack. System VPN exclusions/bypass and app-encrypted DoH/DoT are not universally covered. VPN-disconnect lockdown must be enabled in Android system VPN settings (“Always-on” and “Block connections without VPN”, if offered); this app cannot enforce that system lock.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
