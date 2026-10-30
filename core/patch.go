package main

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"

	"github.com/dlclark/regexp2"
	"github.com/metacubex/mihomo/common/orderedmap"
	"github.com/metacubex/mihomo/common/yaml"
	"github.com/metacubex/mihomo/config"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/log"
)

type PatchHost struct {
	Key   string `json:"key"`
	Value any    `json:"value"`
}

type PatchRules struct {
	Override bool     `json:"override"`
	Rules    []string `json:"rules"`
}

type PatchChainPolicy struct {
	Enabled               bool                      `json:"enabled"`
	Entry                 string                    `json:"entry"`
	EntryKind             string                    `json:"entry-kind"`
	Landing               string                    `json:"landing"`
	LandingKind           string                    `json:"landing-kind"`
	ExternalProfile       string                    `json:"external-profile-id"`
	ExternalProvidersPath string                    `json:"external-providers-path"`
	ExternalTarget        string                    `json:"external-target"`
	ExternalKind          string                    `json:"external-target-kind"`
	ExternalProxies       []map[string]any          `json:"external-proxies"`
	ExternalGroups        []map[string]any          `json:"external-groups"`
	ExternalProviders     map[string]map[string]any `json:"external-providers"`
}

type PatchParams struct {
	General             json.RawMessage `json:"general"`
	GeoXUrl             json.RawMessage `json:"geox-url"`
	Hosts               []PatchHost     `json:"hosts"`
	OverrideDns         bool            `json:"override-dns"`
	DnsNodeOverride     bool            `json:"dns-node-override"`
	Dns                 json.RawMessage `json:"dns"`
	Ntp                 json.RawMessage `json:"ntp"`
	Sniffer             json.RawMessage `json:"sniffer"`
	Experimental        json.RawMessage `json:"experimental"`
	Tunnels             json.RawMessage `json:"tunnels"`
	ProvidersPath       string          `json:"providers-path"`
	NodeExcludeFilter   string          `json:"node-exclude-filter"`
	HealthCheckTimeout  int             `json:"health-check-timeout"`
	OverrideRules       *PatchRules     `json:"override-rules"`
	PrependRules        []string        `json:"prepend-rules"`
	SystemExplicitRules []string        `json:"system-explicit-rules"`
	DisabledGroups      []string        `json:"disabled-groups"`
	SelectGlobal        bool            `json:"select-global"`
	// AngelaMihomo fork: runtime policy ported from the fork's
	// SystemExplicitStore.apply / ProfileChainStore.apply, which used to
	// mutate the Dart-assembled full config before the Go patch pipeline
	// existed.
	ChainPolicy *PatchChainPolicy `json:"chain-policy"`
}

const defaultHealthCheckTimeout = 5000

const tunRouteExcludeSet = "bettbox-route-exclude"

var patchForAndroid = runtime.GOOS == "android"

var patchForLinux = runtime.GOOS == "linux"

var protectedProxyNames = []string{"DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE", "PASS"}

var commonDnsList = []string{
	"223.5.5.5", "223.6.6.6", "119.29.29.29", "1.12.12.12", "120.53.53.53",
	"114.114.114.114", "180.76.76.76", "1.2.4.8", "116.116.116.116",
	"101.226.4.6", "123.125.81.6", "180.184.1.1", "180.184.2.2",
	"1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112",
	"208.67.222.222", "208.67.220.220", "94.140.14.14", "94.140.15.15",
	"76.76.2.0", "76.76.10.0", "185.228.168.9", "185.228.169.9",
	"77.88.8.8", "77.88.8.1", "156.154.70.1", "156.154.71.1",
	"119.28.28.28", "101.6.6.6", "101.101.101.101", "101.102.103.104",
	"185.222.222.222", "45.11.45.11", "1.1.1.2", "1.0.0.2", "1.1.1.3", "1.0.0.3",
	"9.9.9.10", "9.9.9.11", "149.112.112.10", "149.112.112.11",
	"2400:3200::1", "2400:3200:baba::1", "2402:4e00::", "2400:da00::6666",
	"2606:4700:4700::1111", "2606:4700:4700::1001",
	"2001:4860:4860::8888", "2001:4860:4860::8844",
	"2620:fe::fe", "2620:fe::9", "2620:119:35::35", "2620:119:53::53",
	"2a10:50c0::bad1:ff", "2a10:50c0::bad2:ff", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff",
	"2a0d:2a00:1::2", "2a0d:2a00:2::2", "2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff",
	"2610:a1:1018::1", "2610:a1:1019::1",
	"alidns", "doh.pub", "dot.pub", "dns.pub", "dnspod", "dns.baidu",
	"dns.google", "dns.apple", "cloudflare", "one.one.one.one",
	"quad9", "opendns", "nextdns", "adguard",
	"dns.sb", "twnic", "mullvad", "controld", "cleanbrowsing", "yandex",
	"system",
}

var ruleActionsWithParams = map[string]bool{
	"GEOIP": true, "IP-ASN": true, "SRC-IP-ASN": true, "IP-CIDR": true,
	"IP-CIDR6": true, "IP-SUFFIX": true, "RULE-SET": true,
}

func hasPatchValue(data json.RawMessage) bool {
	return len(data) > 0 && string(data) != "null"
}

func applyPatch(raw *config.RawConfig, params *PatchParams) (string, error) {
	defaults := config.DefaultRawConfig()
	if hasPatchValue(params.General) {
		if err := yaml.Unmarshal(params.General, raw); err != nil {
			return "", fmt.Errorf("patch general: %w", err)
		}
		var nullable struct {
			GlobalUA *string `json:"global-ua"`
		}
		if err := json.Unmarshal(params.General, &nullable); err == nil && nullable.GlobalUA == nil {
			raw.GlobalUA = defaults.GlobalUA
		}
	}
	patchTunRouteExclude(raw)
	if hasPatchValue(params.GeoXUrl) {
		raw.GeoXUrl = defaults.GeoXUrl
		if err := yaml.Unmarshal(params.GeoXUrl, &raw.GeoXUrl); err != nil {
			return "", fmt.Errorf("patch geox-url: %w", err)
		}
	}
	patchProviderPaths(raw.ProxyProvider, params.ProvidersPath, "proxies")
	patchProviderPaths(raw.RuleProvider, params.ProvidersPath, "rules")
	hostOrder := patchHosts(raw, params.Hosts)
	if err := patchDns(raw, params, defaults, hostOrder); err != nil {
		return "", err
	}
	if hasPatchValue(params.Ntp) {
		raw.NTP = defaults.NTP
		if err := yaml.Unmarshal(params.Ntp, &raw.NTP); err != nil {
			return "", fmt.Errorf("patch ntp: %w", err)
		}
	}
	if patchForAndroid {
		raw.NTP.WriteToSystem = false
	}
	if hasPatchValue(params.Sniffer) {
		raw.Sniffer = defaults.Sniffer
		if err := yaml.Unmarshal(params.Sniffer, &raw.Sniffer); err != nil {
			return "", fmt.Errorf("patch sniffer: %w", err)
		}
	}
	if hasPatchValue(params.Tunnels) {
		var tunnels []LC.Tunnel
		if err := yaml.Unmarshal(params.Tunnels, &tunnels); err != nil {
			return "", fmt.Errorf("patch tunnels: %w", err)
		}
		raw.Tunnels = append(raw.Tunnels, tunnels...)
	}
	if hasPatchValue(params.Experimental) {
		raw.Experimental = defaults.Experimental
		if err := yaml.Unmarshal(params.Experimental, &raw.Experimental); err != nil {
			return "", fmt.Errorf("patch experimental: %w", err)
		}
	}
	patchProxyGroups(raw, params)

	// AngelaMihomo fork: per-profile chain proxy (was applyChainPolicy in
	// the fork's explicit_policy.dart).
	if err := patchChainPolicy(raw, params.ChainPolicy); err != nil {
		return "", fmt.Errorf("patch chain: %w", err)
	}

	rules := raw.Rule
	if params.OverrideRules != nil {
		if params.OverrideRules.Override {
			rules = append([]string{}, params.OverrideRules.Rules...)
		} else {
			rules = append(append([]string{}, params.OverrideRules.Rules...), rules...)
		}
	}
	if len(params.SystemExplicitRules) > 0 {
		rules = replaceExplicitRuleCategories(rules, params.SystemExplicitRules)
	}
	if len(params.PrependRules) > 0 {
		// These are app-generated rules, not profile-authored rules. An
		// enabled explicit setting replaces the same-category generated rule
		// even when that rule is a REJECT; unrelated guards remain ahead.
		prepend := removeGeneratedExplicitRuleCategories(params.PrependRules, params.SystemExplicitRules)
		rules = append(prepend, rules...)
	}

	patchProxies(raw)

	if len(params.DisabledGroups) > 0 {
		disabled := make(map[string]bool, len(params.DisabledGroups))
		for _, name := range params.DisabledGroups {
			disabled[name] = true
		}
		raw.ProxyGroup = disableGroups(raw.ProxyGroup, disabled)
		for i, rule := range rules {
			parsed := parseRule(rule)
			if parsed.hasTarget && disabled[parsed.target] {
				parsed.target = "PASS"
				rules[i] = parsed.String()
			}
		}
	}

	global := ""
	if params.SelectGlobal {
		global = selectGlobalTarget(raw.ProxyGroup, rules)
	}
	raw.ProxyGroup = filterGroups(raw.ProxyGroup, func(name string) bool {
		return name != "GLOBAL"
	})
	raw.Rule = rules
	return global, nil
}

// Explicit settings replace positive routes in known equivalent categories.
// Keep every profile-authored REJECT intact and before generated routes: without
// expanding geosite/rule-set data, a narrower deny cannot be assumed disjoint
// from a broad DIRECT rule. All other surviving profile rules keep their
// relative order after the explicit additions.
func replaceExplicitRuleCategories(rules, additions []string) []string {
	survivors := removeExplicitRuleCategories(rules, additions)
	blocks := make([]string, 0, len(survivors))
	remaining := make([]string, 0, len(survivors))
	for _, rule := range survivors {
		if explicitSafetyBlockRule(rule) {
			blocks = append(blocks, rule)
			continue
		}
		remaining = append(remaining, rule)
	}

	result := make([]string, 0, len(blocks)+len(additions)+len(remaining))
	result = append(result, blocks...)
	result = append(result, additions...)
	return append(result, remaining...)
}

func removeExplicitRuleCategories(rules, additions []string) []string {
	categories := make(map[string]bool)
	for _, addition := range additions {
		if category := explicitRuleCategory(addition); category != "" {
			categories[category] = true
		}
	}
	result := make([]string, 0, len(rules))
	for _, rule := range rules {
		category := explicitRuleCategory(rule)
		if category != "" && categories[category] && !explicitSafetyBlockRule(rule) {
			continue
		}
		result = append(result, rule)
	}
	return result
}

// App-generated prefix rules may be replaced in an equivalent category,
// including an app-owned REJECT that conflicts with an explicit route setting.
// This helper must not be used for profile rules, whose safety blocks are kept.
func removeGeneratedExplicitRuleCategories(rules, additions []string) []string {
	categories := make(map[string]bool)
	for _, addition := range additions {
		if category := explicitRuleCategory(addition); category != "" {
			categories[category] = true
		}
	}
	result := make([]string, 0, len(rules))
	for _, rule := range rules {
		if category := explicitRuleCategory(rule); category != "" && categories[category] {
			continue
		}
		result = append(result, rule)
	}
	return result
}

// explicitSafetyBlockRule keeps profile-authored deny rules even when their
// match category is also covered by an explicit direct-route setting. Route
// replacement must not turn a safety block into a bypass.
func explicitSafetyBlockRule(rule string) bool {
	parsed := parseRule(rule)
	if !parsed.hasTarget {
		return false
	}
	action := strings.ToUpper(strings.TrimSpace(parsed.target))
	return action == "REJECT" || strings.HasPrefix(action, "REJECT-")
}

func explicitRuleCategory(rule string) string {
	parts := strings.Split(rule, ",")
	if len(parts) < 2 {
		return ""
	}
	typ := strings.ToUpper(strings.TrimSpace(parts[0]))
	arg := strings.TrimSpace(parts[1])
	switch typ {
	case "GEOSITE":
		switch strings.ToLower(arg) {
		case "geolocation-cn":
			return "china-domain"
		case "private":
			return "lan-domain"
		case "category-ads-all":
			return "ads"
		}
	case "GEOIP":
		switch strings.ToLower(arg) {
		case "cn":
			return "china-ip"
		case "private":
			return "lan-ip"
		}
	case "IP-CIDR", "IP-CIDR6":
		if len(parts) < 3 {
			return ""
		}
		cidr := strings.TrimSpace(parts[1])
		if explicitChinaDnsCIDR(cidr) {
			return "china-public-dns-ip"
		}
		if explicitLanCIDR(cidr) {
			return "lan-ip"
		}
	case "DOMAIN", "DOMAIN-SUFFIX":
		switch strings.ToLower(arg) {
		case "alidns.com", "doh.pub", "dot.pub", "360.cn", "onedns.net":
			return "china-public-dns-domain"
		case "stun.l.google.com":
			return "webrtc-domain"
		case "local", "lan", "home.arpa":
			if typ == "DOMAIN-SUFFIX" {
				return "lan-domain"
			}
		}
	case "DOMAIN-KEYWORD":
		switch strings.ToLower(arg) {
		case "stun", "turn":
			return "webrtc-domain"
		}
	case "AND":
		if len(parts) < 3 {
			return ""
		}
		compact := strings.ToUpper(strings.Join(strings.Fields(rule), ""))
		last := strings.LastIndex(compact, "),")
		if last < len("AND,") {
			return ""
		}
		predicate := compact[len("AND,") : last+1]
		switch predicate {
		case "((NETWORK,UDP),(DST-PORT,3478))", "((NETWORK,TCP),(DST-PORT,3478))",
			"((NETWORK,UDP),(DST-PORT,5349))", "((NETWORK,TCP),(DST-PORT,5349))",
			"((NETWORK,UDP),(DST-PORT,3478-3480))",
			"((NETWORK,UDP),(DST-PORT,5349-5355))",
			"((NETWORK,UDP),(DST-PORT,19302-19305))":
			return "webrtc-common-ports"
		case "((NETWORK,UDP),(DST-PORT,5353))", "((NETWORK,UDP),(DST-PORT,5355))",
			"((NETWORK,UDP),(DST-PORT,1900))":
			return "privacy-discovery"
		}
	}
	return ""
}

func explicitChinaDnsCIDR(value string) bool {
	// Replace only the exact resolver host routes emitted by System Explicit;
	// a user's unrelated /32 or /128 must not be treated as this exception.
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "223.5.5.5/32", "223.6.6.6/32", "119.29.29.29/32", "1.12.12.12/32",
		"120.53.53.53/32", "180.76.76.76/32", "114.114.114.114/32",
		"114.114.115.115/32", "114.114.114.119/32", "114.114.115.119/32",
		"114.114.114.110/32", "114.114.115.110/32", "180.184.1.1/32",
		"180.184.2.2/32", "101.226.4.6/32", "218.30.118.6/32",
		"123.125.81.6/32", "140.207.198.6/32", "1.2.4.8/32", "210.2.4.8/32",
		"52.80.66.66/32", "117.50.22.22/32", "117.50.10.10/32",
		"52.80.52.52/32", "117.50.60.30/32", "52.80.60.30/32",
		"2400:3200::1/128", "2400:3200:baba::1/128", "2402:4e00::/128",
		"2402:4e00:1::/128", "2400:da00::6666/128",
		"2400:7fc0:849e:200::4/128", "2404:c2c0:85d8:901::4/128",
		"2400:7fc0:849e:200::8/128", "2404:c2c0:85d8:901::8/128":
		return true
	default:
		return false
	}
}

func explicitLanCIDR(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
		"127.0.0.0/8", "::1/128", "fc00::/7", "fe80::/10":
		return true
	default:
		return false
	}
}

func patchTunRouteExclude(raw *config.RawConfig) {
	tun := &raw.Tun
	if !patchForLinux || !tun.AutoRedirect || raw.RoutingMark != 0 || len(tun.RouteExcludeAddress) == 0 {
		return
	}
	payload := make([]any, 0, len(tun.RouteExcludeAddress))
	for _, prefix := range tun.RouteExcludeAddress {
		payload = append(payload, prefix.String())
	}
	if raw.RuleProvider == nil {
		raw.RuleProvider = map[string]map[string]any{}
	}
	raw.RuleProvider[tunRouteExcludeSet] = map[string]any{
		"type":     "inline",
		"behavior": "ipcidr",
		"payload":  payload,
	}
	tun.RouteExcludeAddressSet = append(tun.RouteExcludeAddressSet, tunRouteExcludeSet)
	tun.RouteExcludeAddress = nil
}

func patchProviderPaths(providers map[string]map[string]any, base string, kind string) {
	for _, provider := range providers {
		if provider["type"] != "http" {
			continue
		}
		url, ok := provider["url"].(string)
		if !ok {
			continue
		}
		sum := md5.Sum([]byte(url))
		provider["path"] = filepath.Join(base, kind, hex.EncodeToString(sum[:]))
	}
}

func patchHosts(raw *config.RawConfig, hosts []PatchHost) []string {
	if raw.Hosts == nil {
		raw.Hosts = map[string]any{}
	}
	order := make([]string, 0, len(raw.Hosts)+len(hosts))
	for key := range raw.Hosts {
		order = append(order, key)
	}
	sort.Strings(order)
	for _, host := range hosts {
		if _, exist := raw.Hosts[host.Key]; !exist {
			order = append(order, host.Key)
		}
		raw.Hosts[host.Key] = host.Value
	}
	return order
}

func patchDns(raw *config.RawConfig, params *PatchParams, defaults *config.RawConfig, hostOrder []string) error {
	enabled := raw.DNS.Enable
	if params.OverrideDns || !enabled {
		original := raw.DNS
		dns := defaults.DNS
		if hasPatchValue(params.Dns) {
			if err := yaml.Unmarshal(params.Dns, &dns); err != nil {
				return fmt.Errorf("patch dns: %w", err)
			}
		}
		if !enabled {
			dns.NameServer = append(append([]string{}, dns.NameServer...), "system://")
		}
		raw.DNS = dns
		if params.DnsNodeOverride {
			applyDnsNodeOverride(raw, &original, hostOrder)
		}
	}
	raw.DNS.FallbackFilter.GeoSite = []string{}

	if !patchForAndroid {
		return nil
	}
	listen := raw.DNS.Listen
	if strings.HasSuffix(listen, ":53") {
		raw.DNS.Listen = strings.ReplaceAll(listen, ":53", ":10053")
	}
	noProviders := raw.ProxyProvider == nil && raw.RuleProvider == nil
	hasLocalNameserver := false
	for _, nameserver := range raw.DNS.ProxyServerNameserver {
		if strings.HasPrefix(nameserver, "127.0.0.1") {
			hasLocalNameserver = true
			break
		}
	}
	if noProviders && hasLocalNameserver && strings.HasPrefix(listen, "0.0.0.0") {
		raw.DNS.Listen = "127.0.0.1" + strings.TrimPrefix(listen, "0.0.0.0")
	}
	return nil
}

func applyDnsNodeOverride(raw *config.RawConfig, original *config.RawDNS, hostOrder []string) {
	proxyServerNameservers := original.ProxyServerNameserver
	listen := original.Listen
	rewriteByHosts := false
	if len(proxyServerNameservers) == 1 && listen != "" {
		nameserver := strings.ToLower(proxyServerNameservers[0])
		rewriteByHosts = strings.Contains(nameserver, strings.ToLower(listen)) ||
			(strings.Contains(listen, "0.0.0.0") && strings.Contains(nameserver, "127.0.0.1"))
	}

	seenDomains := map[string]bool{}
	var proxyDomains []string
	collectServers := func() {
		for _, proxy := range raw.Proxy {
			server, ok := proxy["server"].(string)
			if !ok {
				continue
			}
			server = strings.ToLower(server)
			if !seenDomains[server] {
				seenDomains[server] = true
				proxyDomains = append(proxyDomains, server)
			}
		}
	}
	collectServers()
	if rewriteByHosts {
		applyHostsToProxies(raw.Proxy, raw.Hosts, hostOrder)
		collectServers()
	}

	commonDns := commonDnsList
	if rewriteByHosts {
		commonDns = append(append([]string{}, commonDnsList...), strings.ToLower(listen))
	}
	isCommonDns := func(dns string) bool {
		dns = strings.ToLower(dns)
		for _, item := range commonDns {
			if strings.Contains(dns, item) {
				return true
			}
		}
		return false
	}

	seenDns := map[string]bool{}
	var privateDns []string
	candidates := append([]string{}, original.NameServer...)
	if !rewriteByHosts {
		candidates = append(candidates, proxyServerNameservers...)
	}
	for _, dns := range candidates {
		stripped := stripDnsSuffix(dns)
		if stripped == "" || isCommonDns(stripped) || seenDns[stripped] {
			continue
		}
		seenDns[stripped] = true
		privateDns = append(privateDns, stripped)
	}

	originalPolicy := orderedmap.New[string, any]()
	for _, policy := range []*orderedmap.OrderedMap[string, any]{original.NameServerPolicy, original.ProxyServerNameserverPolicy} {
		if policy == nil {
			continue
		}
		for pair := policy.Oldest(); pair != nil; pair = pair.Next() {
			originalPolicy.Set(pair.Key, pair.Value)
		}
	}
	proxyServerPolicy := orderedmap.New[string, any]()
	for pair := originalPolicy.Oldest(); pair != nil; pair = pair.Next() {
		if !matchDomainPattern(pair.Key, proxyDomains) {
			continue
		}
		if list, ok := pair.Value.([]any); ok {
			stripped := make([]any, 0, len(list))
			for _, item := range list {
				if value := stripDnsSuffix(fmt.Sprint(item)); value != "" {
					stripped = append(stripped, value)
				}
			}
			if len(stripped) == 0 {
				continue
			}
			proxyServerPolicy.Set(pair.Key, stripped)
			continue
		}
		proxyServerPolicy.Set(pair.Key, stripDnsSuffix(fmt.Sprint(pair.Value)))
	}

	var proxyFakeIpFilter []string
	for _, pattern := range original.FakeIPFilter {
		if matchDomainPattern(pattern, proxyDomains) {
			proxyFakeIpFilter = append(proxyFakeIpFilter, pattern)
		}
	}

	if len(privateDns) > 0 {
		raw.DNS.ProxyServerNameserver = privateDns
	}
	if proxyServerPolicy.Len() > 0 {
		raw.DNS.ProxyServerNameserverPolicy = proxyServerPolicy
	}
	if len(proxyFakeIpFilter) > 0 {
		raw.DNS.FakeIPFilter = append(append([]string{}, raw.DNS.FakeIPFilter...), proxyFakeIpFilter...)
	}
	if rewriteByHosts || len(privateDns) > 0 || proxyServerPolicy.Len() > 0 || len(proxyFakeIpFilter) > 0 {
		log.Infoln("[APP] dns override: private dns %v, node policies %d, fake-ip filters %d, nodes rewritten by hosts: %t", privateDns, proxyServerPolicy.Len(), len(proxyFakeIpFilter), rewriteByHosts)
	}
}

func hostSpecificity(pattern string) int {
	if strings.HasPrefix(pattern, "+.") {
		return 2
	}
	if strings.HasPrefix(pattern, ".") {
		return 1
	}
	if strings.Contains(pattern, "*") {
		return 0
	}
	return 3
}

func matchDomainPattern(pattern string, domains []string) bool {
	pattern = strings.ToLower(pattern)
	if strings.HasPrefix(pattern, "+.") {
		suffix := pattern[2:]
		for _, domain := range domains {
			if domain == suffix || strings.HasSuffix(domain, "."+suffix) {
				return true
			}
		}
		return false
	}
	if strings.HasPrefix(pattern, ".") {
		suffix := pattern[1:]
		for _, domain := range domains {
			if domain != suffix && strings.HasSuffix(domain, "."+suffix) {
				return true
			}
		}
		return false
	}
	if !strings.Contains(pattern, "*") {
		for _, domain := range domains {
			if domain == pattern {
				return true
			}
		}
		return false
	}
	patternParts := strings.Split(pattern, ".")
	for _, domain := range domains {
		domainParts := strings.Split(domain, ".")
		if len(patternParts) != len(domainParts) {
			continue
		}
		matched := true
		for i, part := range patternParts {
			if part != "*" && part != domainParts[i] {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}

func stripDnsSuffix(dns string) string {
	index := strings.Index(dns, "#")
	if index == -1 {
		return dns
	}
	suffix := strings.TrimSpace(strings.ToLower(dns[index+1:]))
	if suffix == "direct" || strings.HasPrefix(suffix, "direct&") {
		return dns
	}
	if strings.Contains(suffix, "direct") || strings.Contains(suffix, "直连") {
		return strings.TrimSpace(dns[:index]) + "#DIRECT"
	}
	return dns[:index]
}

func hostTarget(value any) string {
	if list, ok := value.([]any); ok {
		for _, item := range list {
			if text, ok := item.(string); ok && text != "" {
				return text
			}
		}
		return ""
	}
	text, _ := value.(string)
	return text
}

func applyHostsToProxies(proxies []map[string]any, hosts map[string]any, hostOrder []string) {
	type hostEntry struct {
		pattern string
		target  string
	}
	entries := make([]hostEntry, 0, len(hostOrder))
	for _, key := range hostOrder {
		value := hosts[key]
		if list, ok := value.([]any); ok {
			if len(list) == 0 {
				continue
			}
		} else if text, ok := value.(string); !ok || text == "" {
			continue
		}
		entries = append(entries, hostEntry{pattern: key, target: hostTarget(value)})
	}
	if len(entries) == 0 {
		return
	}
	sort.SliceStable(entries, func(i, j int) bool {
		return hostSpecificity(entries[i].pattern) > hostSpecificity(entries[j].pattern)
	})

	cache := map[string]string{}
	resolve := func(server string) string {
		if cached, ok := cache[server]; ok {
			return cached
		}
		seen := map[string]bool{}
		current := strings.ToLower(server)
		result := server
		for !seen[current] {
			seen[current] = true
			target := ""
			for _, entry := range entries {
				if matchDomainPattern(entry.pattern, []string{current}) {
					target = entry.target
					break
				}
			}
			if target == "" {
				break
			}
			result = target
			current = strings.ToLower(target)
		}
		cache[server] = result
		return result
	}

	for _, proxy := range proxies {
		server, ok := proxy["server"].(string)
		if !ok {
			continue
		}
		if resolved := resolve(server); resolved != server {
			proxy["server"] = resolved
		}
	}
}

func groupName(group map[string]any) (string, bool) {
	name, ok := group["name"].(string)
	return name, ok
}

func filterGroups(groups []map[string]any, keep func(name string) bool) []map[string]any {
	filtered := groups[:0]
	for _, group := range groups {
		if name, ok := groupName(group); ok && !keep(name) {
			continue
		}
		filtered = append(filtered, group)
	}
	return filtered
}

func disableGroups(groups []map[string]any, disabled map[string]bool) []map[string]any {
	for changed := true; changed; {
		changed = false
		for _, group := range groups {
			name, ok := groupName(group)
			if !ok || disabled[name] {
				continue
			}
			proxies, ok := group["proxies"].([]any)
			if !ok || len(proxies) == 0 {
				continue
			}
			kept := make([]any, 0, len(proxies))
			for _, proxy := range proxies {
				if value, ok := proxy.(string); ok && disabled[value] {
					continue
				}
				kept = append(kept, proxy)
			}
			if len(kept) == len(proxies) {
				continue
			}
			group["proxies"] = kept
			if len(kept) == 0 && !hasGroupSource(group) {
				disabled[name] = true
				changed = true
			}
		}
	}
	return filterGroups(groups, func(name string) bool {
		return !disabled[name]
	})
}

func hasGroupSource(group map[string]any) bool {
	if use, ok := group["use"].([]any); ok && len(use) > 0 {
		return true
	}
	for _, key := range []string{"include-all", "include-all-proxies", "include-all-providers"} {
		if value, ok := group[key].(bool); ok && value {
			return true
		}
	}
	return false
}

func combineExcludeFilter(target map[string]any, filter string) {
	if existing, ok := target["exclude-filter"].(string); ok && existing != "" {
		target["exclude-filter"] = existing + "|" + filter
		return
	}
	target["exclude-filter"] = filter
}

func patchProxyGroups(raw *config.RawConfig, params *PatchParams) {
	filter := params.NodeExcludeFilter
	if raw.ProxyGroup != nil && (filter != "" || params.HealthCheckTimeout != defaultHealthCheckTimeout) {
		var filterRegex *regexp2.Regexp
		if filter != "" {
			filterRegex, _ = regexp2.Compile(filter, regexp2.ECMAScript)
		}
		protected := map[string]bool{}
		for _, name := range protectedProxyNames {
			protected[name] = true
		}
		for _, group := range raw.ProxyGroup {
			if name, ok := groupName(group); ok {
				protected[name] = true
			}
		}
		excluded := map[string]bool{}
		isExcluded := func(name string) bool {
			if result, exist := excluded[name]; exist {
				return result
			}
			matched, _ := filterRegex.MatchString(name)
			excluded[name] = matched
			return matched
		}
		for _, group := range raw.ProxyGroup {
			if group == nil {
				continue
			}
			use, hasUse := group["use"]
			hasUse = hasUse && use != nil
			if filterRegex != nil && hasUse {
				combineExcludeFilter(group, filter)
			}
			if proxies, ok := group["proxies"].([]any); ok && filterRegex != nil {
				filtered := make([]any, 0, len(proxies))
				for _, item := range proxies {
					name, isString := item.(string)
					if isString && !protected[name] && isExcluded(name) {
						continue
					}
					filtered = append(filtered, item)
				}
				useList, useIsList := use.([]any)
				if len(filtered) == 0 && (!hasUse || (useIsList && len(useList) == 0)) {
					filtered = append(filtered, "DIRECT")
				}
				group["proxies"] = filtered
			}
			if params.HealthCheckTimeout != defaultHealthCheckTimeout {
				if timeout, exist := group["timeout"]; !exist || timeout == nil {
					group["timeout"] = params.HealthCheckTimeout
				}
			}
		}
		if filterRegex != nil {
			for _, provider := range raw.ProxyProvider {
				if provider == nil {
					continue
				}
				combineExcludeFilter(provider, filter)
			}
		}
	}

	for _, group := range raw.ProxyGroup {
		switch tolerance := group["tolerance"].(type) {
		case float64:
			group["tolerance"] = int(tolerance)
		case string:
			if value, err := strconv.Atoi(strings.TrimSpace(tolerance)); err == nil {
				group["tolerance"] = value
			}
		}
	}
}

const explicitChainGroup = "链式落地"

// floorChainHealthCheck aligns health-check parameters on the runtime
// copy of a chain entry group with the subscription converter's chain
// parameters (2026-10-29 alignment, user directive): a 60-second
// interval floor so a dead hop is detected within about a minute, a
// 100 ms tolerance floor and a 5000 ms timeout floor because two-hop
// checks jitter far too much for tighter switching. The profile's lazy
// setting is left as-is (2026-10-29 power-saving decision, user
// directive): idle groups are not probed, which keeps background
// wake-ups down; checks resume with traffic. More generous source
// values are left untouched.
func floorChainHealthCheck(group map[string]any) {
	floor := func(key string, minimum float64) {
		var value float64
		switch v := group[key].(type) {
		case int:
			value = float64(v)
		case int64:
			value = float64(v)
		case float64:
			value = v
		default:
			return
		}
		if value < minimum {
			group[key] = int(minimum)
		}
	}
	floor("interval", 60)
	floor("tolerance", 100)
	floor("timeout", 5000)
}

// patchChainPolicy uses dialer-proxy, including for subscription nodes. Mihomo
// removed relay groups. Provider overrides run after name transforms, so match
// the displayed node name and leave every other node and override untouched.
func patchChainPolicy(raw *config.RawConfig, policy *PatchChainPolicy) error {
	if policy == nil || !policy.Enabled {
		return nil
	}
	entry := strings.TrimSpace(policy.Entry)
	landing := strings.TrimSpace(policy.Landing)
	entryKind := policy.EntryKind
	if entryKind == "" {
		entryKind = "proxy" // v1 settings stored nodes only.
	}
	landingKind := policy.LandingKind
	if landingKind == "" {
		landingKind = "proxy"
	}
	// Keep legacy same-profile node behavior for existing native callers;
	// the new UI requires an external exit profile.
	if policy.ExternalProfile == "" && entryKind == "proxy" && landingKind == "proxy" {
		return patchLegacyChainPolicy(raw, policy)
	}
	if entry == "" || landing == "" {
		return fmt.Errorf("choose both an entry and an exit before enabling the chain")
	}
	if entry == landing && policy.ExternalProfile == "" && entryKind == landingKind {
		return fmt.Errorf("chain entry and exit must be different nodes")
	}
	for _, name := range protectedProxyNames {
		if entry == name || landing == name {
			return fmt.Errorf("%q is not a chain node", name)
		}
	}

	// Cross-profile exits are copied into this runtime config only. The
	// original profile file and provider cache are not edited. Preserve the
	// active selectors so the user can explicitly choose the generated chain.
	originalGroups := append([]map[string]any(nil), raw.ProxyGroup...)
	// Snapshot current-profile providers before importing external ones. An
	// entry-node fallback must never resolve against the exit's providers.
	entryProviderNames := make([]string, 0, len(raw.ProxyProvider))
	for name := range raw.ProxyProvider {
		entryProviderNames = append(entryProviderNames, name)
	}
	sort.Strings(entryProviderNames)
	used := make(map[string]string)
	if policy.ExternalProfile != "" {
		if policy.ExternalTarget == "" || (policy.ExternalKind != "proxy" && policy.ExternalKind != "group") {
			return fmt.Errorf("external exit selection is incomplete")
		}
		if raw.ProxyProvider == nil {
			raw.ProxyProvider = make(map[string]map[string]any)
		}
		for _, proxy := range raw.Proxy {
			name, _ := proxy["name"].(string)
			if name != "" {
				used[name] = "proxy"
			}
		}
		for _, group := range raw.ProxyGroup {
			name, _ := group["name"].(string)
			if name != "" {
				used[name] = "group"
			}
		}
		for name := range raw.ProxyProvider {
			used[name] = "provider"
		}
		for _, proxy := range policy.ExternalProxies {
			name, _ := proxy["name"].(string)
			if name == "" || used[name] != "" {
				return fmt.Errorf("external proxy name %q is empty or conflicts with the active profile", name)
			}
			used[name] = "proxy"
			raw.Proxy = append(raw.Proxy, proxy)
		}
		for _, group := range policy.ExternalGroups {
			name, _ := group["name"].(string)
			if name == "" || used[name] != "" {
				return fmt.Errorf("external group name %q is empty or conflicts with the active profile", name)
			}
			used[name] = "group"
			raw.ProxyGroup = append(raw.ProxyGroup, group)
		}
		patchProviderPaths(policy.ExternalProviders, policy.ExternalProvidersPath, "proxies")
		for name, provider := range policy.ExternalProviders {
			if name == "" || used[name] != "" {
				return fmt.Errorf("external provider name %q is empty or conflicts with the active profile", name)
			}
			used[name] = "provider"
			raw.ProxyProvider[name] = provider
		}
		landing = policy.ExternalTarget
		landingKind = policy.ExternalKind
	}

	entryFound := false
	for _, proxy := range raw.Proxy {
		name, _ := proxy["name"].(string)
		if name == entry && entryKind == "proxy" {
			typ := strings.ToLower(fmt.Sprint(proxy["type"]))
			if typ == "direct" || typ == "pass" || typ == "compatible" {
				return fmt.Errorf("entry %q is a direct-capable adapter", entry)
			}
			entryFound = true
		}
	}
	for _, group := range raw.ProxyGroup {
		name, _ := group["name"].(string)
		if name == entry && entryKind == "group" {
			entryFound = true
		}
	}
	if !entryFound && entryKind == "proxy" && len(entryProviderNames) > 0 && policy.ExternalProfile != "" {
		// Live provider nodes are not present in raw.Proxy. Resolve their
		// exact display name through a private provider selector that fails
		// closed if refresh removes the node. Do not alter the source provider.
		providerEntry := uniqueChainGroupNameWithBase(used, "链式入口")
		raw.ProxyGroup = append(raw.ProxyGroup, map[string]any{
			"name": providerEntry, "type": "select", "use": entryProviderNames,
			"filter":       `\A` + strings.ReplaceAll(regexp.QuoteMeta(entry), "`", `\x60`) + `\z`,
			"exclude-type": "Direct|Compatible|Pass", "empty-fallback": "REJECT", "hidden": true,
		})
		entry = providerEntry
		entryFound = true
	}
	if !entryFound {
		return fmt.Errorf("entry %q is not a directly verifiable node or group in the active profile", entry)
	}
	if entryKind == "group" {
		if err := hardenChainEntryGroup(raw, entry); err != nil {
			return err
		}
		if err := validateChainEntryGroup(raw, entry); err != nil {
			return err
		}
	}
	if entryKind != "proxy" && entryKind != "group" {
		return fmt.Errorf("unsupported entry type %q", entryKind)
	}

	findProxy := func(name string) map[string]any {
		for _, proxy := range raw.Proxy {
			if proxyName, _ := proxy["name"].(string); proxyName == name {
				return proxy
			}
		}
		return nil
	}
	findGroup := func(name string) map[string]any {
		for _, group := range raw.ProxyGroup {
			if groupName, _ := group["name"].(string); groupName == name {
				return group
			}
		}
		return nil
	}
	appendDialer := func(provider map[string]any) error {
		override := map[string]any{}
		if value := provider["override"]; value != nil {
			old, ok := value.(map[string]any)
			if !ok {
				return fmt.Errorf("provider override must be a mapping")
			}
			for key, value := range old {
				override[key] = value
			}
		}
		var expressions []any
		switch old := override["override-expr"].(type) {
		case nil:
		case []any:
			for _, value := range old {
				if expression, ok := value.(string); ok && strings.Contains(expression, ".dialer-proxy") {
					if strings.HasPrefix(strings.TrimSpace(expression), ".dialer-proxy =") {
						continue // replace the same chain setting only.
					}
					return fmt.Errorf("provider chain override expression is too complex to safely replace")
				}
				expressions = append(expressions, value)
			}
		case []string:
			for _, value := range old {
				if strings.Contains(value, ".dialer-proxy") {
					if strings.HasPrefix(strings.TrimSpace(value), ".dialer-proxy =") {
						continue
					}
					return fmt.Errorf("provider chain override expression is too complex to safely replace")
				}
				expressions = append(expressions, value)
			}
		default:
			return fmt.Errorf("provider override-expr must be a list")
		}
		buf, _ := json.Marshal(entry)
		expressions = append(expressions, ".dialer-proxy = "+string(buf))
		override["override-expr"] = expressions
		provider["override"] = override
		return nil
	}

	if policy.ExternalProfile != "" {
		if landingKind == "proxy" {
			target := findProxy(landing)
			if target == nil {
				return fmt.Errorf("external exit %q was not imported", landing)
			}
			// The enabled app chain is the explicit chain choice. It replaces
			// only this selected exit's existing dialer-proxy on the runtime copy.
			// Only the selected exit's homologous chain setting is replaced;
			// all other profile-native rules and chains remain intact.
			target["dialer-proxy"] = entry
		} else if landingKind != "group" || findGroup(landing) == nil {
			return fmt.Errorf("external exit group %q was not imported", landing)
		}
		if landingKind == "group" && findGroup(landing) == nil {
			return fmt.Errorf("external exit group %q was not imported", landing)
		}
		if landingKind == "group" && len(policy.ExternalProxies) == 0 && len(policy.ExternalProviders) == 0 {
			return fmt.Errorf("external exit group %q has no usable proxy members", landing)
		}
		for _, proxy := range policy.ExternalProxies {
			// Explicit app chain wins for the imported exit graph only. These
			// are runtime copies; saved source-profile YAML remains untouched.
			proxy["dialer-proxy"] = entry
		}
		for _, provider := range policy.ExternalProviders {
			if err := appendDialer(provider); err != nil {
				return err
			}
		}
		chainGroup := uniqueChainGroupName(used)
		raw.ProxyGroup = append(raw.ProxyGroup, map[string]any{
			"name":    chainGroup,
			"type":    "select",
			"proxies": []any{landing},
		})
		// The chain must not be inserted into its own entry group or any
		// nested entry group: doing so would create a dialer cycle.
		entryGroups := make(map[string]bool)
		if entryKind == "group" {
			var visit func(string)
			visit = func(name string) {
				if entryGroups[name] {
					return
				}
				g := findGroup(name)
				if g == nil {
					return
				}
				entryGroups[name] = true
				for _, child := range anyStrings(g["proxies"]) {
					if n, ok := child.(string); ok {
						visit(n)
					}
				}
			}
			visit(entry)
		}
		selectors := 0
		for _, group := range originalGroups {
			if group == nil {
				continue
			}
			groupType, _ := group["type"].(string)
			groupName, _ := group["name"].(string)
			if groupType != "select" || entryGroups[groupName] {
				continue
			}
			selectors++
			members := anyStrings(group["proxies"])
			if selectors == 1 {
				// The main selector lists the chain first so it is the
				// default choice once a chain is configured; other
				// selectors keep the chain as an extra option at the end
				// without hijacking their own defaults.
				group["proxies"] = append([]any{chainGroup}, members...)
			} else {
				group["proxies"] = append(members, chainGroup)
			}
		}
		if selectors == 0 {
			return fmt.Errorf("the active profile has no manual selector to expose the chain")
		}
		return nil
	}

	if landingKind == "group" {
		return fmt.Errorf("strategy-group exits must be supplied as an isolated runtime overlay")
	}
	if landingKind != "proxy" {
		return fmt.Errorf("unsupported exit type %q", landingKind)
	}
	if entryKind == "proxy" {
		if target := findProxy(landing); target != nil {
			if findProxy(entry) == nil && len(raw.ProxyProvider) == 0 {
				return fmt.Errorf("entry %q not found in this profile", entry)
			}
			target["dialer-proxy"] = entry
			return nil
		}
	}
	// Nodes supplied by a proxy provider are selected by their displayed
	// name. The provider override keeps working after future refreshes.
	if len(raw.ProxyProvider) == 0 {
		return fmt.Errorf("exit %q not found in this profile", landing)
	}
	quote := func(value string) string { buf, _ := json.Marshal(value); return string(buf) }
	expr := "(select(.name == " + quote(landing) + ") | .dialer-proxy) = " + quote(entry)
	for name, provider := range raw.ProxyProvider {
		overrides := make(map[string]any)
		if value := provider["override"]; value != nil {
			old, ok := value.(map[string]any)
			if !ok {
				return fmt.Errorf("provider %q override must be a mapping", name)
			}
			for key, value := range old {
				overrides[key] = value
			}
		}
		var expressions []any
		switch old := overrides["override-expr"].(type) {
		case nil:
		case []any:
			expressions = append(expressions, old...)
		case []string:
			for _, value := range old {
				expressions = append(expressions, value)
			}
		default:
			return fmt.Errorf("provider %q override-expr must be a list", name)
		}
		overrides["override-expr"] = append(expressions, expr)
		provider["override"] = overrides
	}
	return nil
}

func patchLegacyChainPolicy(raw *config.RawConfig, policy *PatchChainPolicy) error {
	if policy == nil || !policy.Enabled {
		return nil
	}
	entry, landing := policy.Entry, policy.Landing
	if strings.TrimSpace(entry) == "" || strings.TrimSpace(landing) == "" {
		return fmt.Errorf("choose both an entry and an exit before enabling the chain")
	}
	if entry == landing {
		return fmt.Errorf("chain entry and exit must be different nodes")
	}
	names := make(map[string]bool)
	for _, name := range protectedProxyNames {
		names[name] = true
		if entry == name || landing == name {
			return fmt.Errorf("%q is not a chain node", name)
		}
	}
	var target map[string]any
	hasEntry := false
	for _, proxy := range raw.Proxy {
		name, _ := proxy["name"].(string)
		names[name] = true
		if name == entry {
			hasEntry = true
		}
		if name == landing {
			target = proxy
		}
	}
	for _, group := range raw.ProxyGroup {
		name, _ := group["name"].(string)
		names[name] = true
		if name == entry || name == landing {
			return fmt.Errorf("%q is a group, not a chain node", name)
		}
	}
	for name := range raw.ProxyProvider {
		names[name] = true
	}
	if (!hasEntry || target == nil) && len(raw.ProxyProvider) == 0 {
		return fmt.Errorf("entry %q or exit %q not found in this profile", entry, landing)
	}
	uniqueName := func(base string) string {
		name := base
		for i := 2; names[name]; i++ {
			name = fmt.Sprintf("%s %d", base, i)
		}
		names[name] = true
		return name
	}
	// Freeze the original list: helper groups must never contain one another.
	originalGroups := append([]map[string]any(nil), raw.ProxyGroup...)
	providerGroup := func(name, node string, hidden bool) map[string]any {
		return map[string]any{
			"name": name, "type": "select", "include-all-providers": true,
			"filter": `\A` + strings.ReplaceAll(regexp.QuoteMeta(node), "`", `\x60`) + `\z`,
			// Provider nodes can disappear on refresh. Never fall back to DIRECT.
			"empty-fallback": "REJECT", "hidden": hidden,
		}
	}
	dialer := entry
	if !hasEntry {
		dialer = uniqueName("链式入口")
		raw.ProxyGroup = append(raw.ProxyGroup, providerGroup(dialer, entry, true))
	}
	if target != nil {
		target["dialer-proxy"] = dialer
		return nil
	}
	quote := func(value string) string {
		buf, _ := json.Marshal(value)
		return string(buf)
	}
	expr := "(select(.name == " + quote(landing) + ") | .dialer-proxy) = " + quote(dialer)
	for name, provider := range raw.ProxyProvider {
		// Copy maps/lists to avoid modifying shared YAML anchors.
		overrides := make(map[string]any)
		if value := provider["override"]; value != nil {
			old, ok := value.(map[string]any)
			if !ok {
				return fmt.Errorf("provider %q override must be a mapping", name)
			}
			for key, value := range old {
				overrides[key] = value
			}
		}
		var expressions []any
		switch old := overrides["override-expr"].(type) {
		case nil:
		case []any:
			expressions = append(expressions, old...)
		case []string:
			for _, value := range old {
				expressions = append(expressions, value)
			}
		default:
			return fmt.Errorf("provider %q override-expr must be a list", name)
		}
		overrides["override-expr"] = append(expressions, expr)
		provider["override"] = overrides
	}
	chainGroup := uniqueName(explicitChainGroup)
	raw.ProxyGroup = append(raw.ProxyGroup, providerGroup(chainGroup, landing, false))
	selectors := 0
	for _, group := range originalGroups {
		if groupType, _ := group["type"].(string); groupType != "select" {
			continue
		}
		var members []any
		switch old := group["proxies"].(type) {
		case nil:
		case []any:
			members = append(members, old...)
		case []string:
			for _, value := range old {
				members = append(members, value)
			}
		}
		selectors++
		if selectors == 1 {
			// The main selector lists the chain first so it is the
			// default choice once a chain is configured; other
			// selectors keep the chain as an extra option at the end
			// without hijacking their own defaults. Mirrors the
			// cross-profile chain path.
			group["proxies"] = append([]any{chainGroup}, members...)
		} else {
			group["proxies"] = append(members, chainGroup)
		}
	}
	return nil
}

func anyStrings(value any) []any {
	switch values := value.(type) {
	case []any:
		return append([]any(nil), values...)
	case []string:
		result := make([]any, 0, len(values))
		for _, item := range values {
			result = append(result, item)
		}
		return result
	default:
		return nil
	}
}

func uniqueChainGroupName(used map[string]string) string {
	return uniqueChainGroupNameWithBase(used, explicitChainGroup)
}

func uniqueChainGroupNameWithBase(used map[string]string, base string) string {
	name := base
	for suffix := 2; used[name] != ""; suffix++ {
		name = fmt.Sprintf("%s %d", base, suffix)
	}
	used[name] = "group"
	return name
}

// Harden only the selected runtime entry graph. Subscription authors need not
// opt into our chain-specific fallback policy; never permit an empty group to
// silently become COMPATIBLE. Explicit DIRECT members still fail validation.
func hardenChainEntryGroup(raw *config.RawConfig, entry string) error {
	groups := make(map[string]map[string]any, len(raw.ProxyGroup))
	for _, group := range raw.ProxyGroup {
		if name, ok := groupName(group); ok {
			groups[name] = group
		}
	}
	seen := map[string]bool{}
	var walk func(string) error
	walk = func(name string) error {
		if seen[name] {
			return nil
		}
		seen[name] = true
		group := groups[name]
		if group == nil {
			return fmt.Errorf("entry group %q is unavailable", name)
		}
		group["empty-fallback"] = "REJECT"
		floorChainHealthCheck(group)
		// GroupBase treats exclude-type as a pipe-delimited list, not a regexp.
		if len(anyStrings(group["use"])) > 0 {
			old, _ := group["exclude-type"].(string)
			excluded := map[string]bool{}
			for _, typ := range strings.Split(old, "|") {
				excluded[strings.ToLower(strings.TrimSpace(typ))] = true
			}
			for _, typ := range []string{"Direct", "Compatible", "Pass"} {
				if !excluded[strings.ToLower(typ)] {
					if old != "" {
						old += "|"
					}
					old += typ
				}
			}
			group["exclude-type"] = old
		}
		for _, member := range anyStrings(group["proxies"]) {
			if child, ok := member.(string); ok && groups[child] != nil {
				if err := walk(child); err != nil {
					return err
				}
			}
		}
		return nil
	}
	return walk(entry)
}

// A chain entry must itself be a proxy path. Allow ordinary proxies and
// provider-backed groups, but reject choices that can bypass the selected
// entry by choosing DIRECT or a direct-capable nested strategy group.
func validateChainEntryGroup(raw *config.RawConfig, entry string) error {
	groups := make(map[string]map[string]any, len(raw.ProxyGroup))
	for _, group := range raw.ProxyGroup {
		if name, ok := groupName(group); ok {
			groups[name] = group
		}
	}
	visiting, visited := map[string]bool{}, map[string]bool{}
	var walk func(string) error
	walk = func(name string) error {
		if visited[name] {
			return nil
		}
		if visiting[name] {
			return fmt.Errorf("entry group %q contains a cycle", name)
		}
		group := groups[name]
		if group == nil {
			return fmt.Errorf("entry group %q is unavailable", name)
		}
		visiting[name] = true
		for _, key := range []string{"include-all", "include-all-proxies", "include-all-providers"} {
			if group[key] == true {
				return fmt.Errorf("entry group %q dynamically includes proxies and cannot guarantee chain safety", name)
			}
		}
		// Provider membership and filtered lists can become empty. Mihomo's
		// default empty fallback is COMPATIBLE, which can bypass the chain.
		use, _ := group["use"].([]any)
		members, _ := group["proxies"].([]any)
		excludeFilter, _ := group["exclude-filter"].(string)
		includeFilter, _ := group["filter"].(string)
		if len(use) > 0 || len(members) == 0 || excludeFilter != "" || includeFilter != "" {
			fallback, _ := group["empty-fallback"].(string)
			if fallback != "REJECT" && fallback != "REJECT-DROP" {
				return fmt.Errorf("entry group %q needs a reject empty-fallback to avoid direct bypass", name)
			}
		}
		if len(use) > 0 {
			exclude, _ := group["exclude-type"].(string)
			excluded := map[string]bool{}
			for _, typ := range strings.Split(exclude, "|") {
				excluded[strings.ToLower(strings.TrimSpace(typ))] = true
			}
			if !excluded["direct"] || !excluded["compatible"] || !excluded["pass"] {
				return fmt.Errorf("entry group %q uses a provider without excluding direct-capable adapters", name)
			}
		}
		if proxies, ok := group["proxies"]; ok && proxies != nil {
			items, ok := proxies.([]any)
			if !ok {
				return fmt.Errorf("entry group %q has an unsupported proxy list", name)
			}
			for _, value := range items {
				member, ok := value.(string)
				if !ok {
					return fmt.Errorf("entry group %q has an unsupported member", name)
				}
				switch member {
				case "DIRECT", "PASS", "COMPATIBLE":
					return fmt.Errorf("entry group %q can bypass the selected chain entry via %s", name, member)
				case "REJECT", "REJECT-DROP":
					continue
				}
				for _, proxy := range raw.Proxy {
					proxyName, _ := proxy["name"].(string)
					typ := strings.ToLower(fmt.Sprint(proxy["type"]))
					if proxyName == member && (typ == "direct" || typ == "pass" || typ == "compatible") {
						return fmt.Errorf("entry group %q contains direct-capable adapter %q", name, member)
					}
				}
				if groups[member] != nil {
					if err := walk(member); err != nil {
						return err
					}
				}
			}
		}
		if use, ok := group["use"].([]any); ok {
			for _, value := range use {
				provider, ok := value.(string)
				if !ok || raw.ProxyProvider[provider] == nil {
					return fmt.Errorf("entry group %q references unavailable provider", name)
				}
			}
		}
		visiting[name] = false
		visited[name] = true
		return nil
	}
	return walk(entry)
}

func patchProxies(raw *config.RawConfig) {
	fingerprint := raw.GlobalClientFingerprint
	for _, proxy := range raw.Proxy {
		if proxy == nil {
			continue
		}
		proxyType := ""
		if value, exist := proxy["type"]; exist && value != nil {
			proxyType = strings.ToLower(fmt.Sprint(value))
		}
		isTls := proxy["tls"] == true
		supportFingerprint := proxyType == "trojan" || proxyType == "anytls" ||
			((proxyType == "vmess" || proxyType == "vless") && isTls)
		if supportFingerprint {
			if value, exist := proxy["client-fingerprint"]; !exist || value == nil {
				proxy["client-fingerprint"] = fingerprint
			}
		}
		realityOpts, ok := proxy["reality-opts"].(map[string]any)
		if !ok {
			continue
		}
		switch shortId := realityOpts["short-id"].(type) {
		case int:
			realityOpts["short-id"] = strconv.Itoa(shortId)
		case int64:
			realityOpts["short-id"] = strconv.FormatInt(shortId, 10)
		case uint64:
			realityOpts["short-id"] = strconv.FormatUint(shortId, 10)
		}
	}
}

func selectGlobalTarget(groups []map[string]any, rules []string) string {
	for _, group := range groups {
		name, ok := groupName(group)
		if ok && name != "GLOBAL" && name != "DIRECT" && name != "REJECT" {
			return name
		}
	}
	names := map[string]bool{}
	for _, group := range groups {
		value, exist := group["name"]
		if !exist || value == nil {
			continue
		}
		name := fmt.Sprint(value)
		if name != "GLOBAL" && name != "DIRECT" && name != "REJECT" {
			names[name] = true
		}
	}
	for _, rule := range rules {
		parsed := parseRule(rule)
		if parsed.action == "MATCH" && parsed.hasTarget && parsed.target != "" &&
			parsed.target != "DIRECT" && parsed.target != "REJECT" && names[parsed.target] {
			return parsed.target
		}
	}
	return ""
}

type parsedRule struct {
	action    string
	content   string
	target    string
	hasTarget bool
	subRule   string
	noResolve bool
	src       bool
}

func parseRule(value string) parsedRule {
	raw := strings.TrimSpace(value)
	rule := parsedRule{}
	for {
		if strings.HasSuffix(raw, ",no-resolve") {
			rule.noResolve = true
			raw = strings.TrimSpace(strings.TrimSuffix(raw, ",no-resolve"))
		} else if strings.HasSuffix(raw, ",src") {
			rule.src = true
			raw = strings.TrimSpace(strings.TrimSuffix(raw, ",src"))
		} else {
			break
		}
	}
	firstComma := strings.Index(raw, ",")
	if firstComma == -1 {
		rule.action = raw
		return rule
	}
	rule.action = strings.TrimSpace(raw[:firstComma])
	rest := strings.TrimSpace(raw[firstComma+1:])
	if rule.action == "MATCH" {
		rule.target = rest
		rule.hasTarget = true
		return rule
	}
	lastComma := strings.LastIndex(rest, ",")
	if lastComma == -1 {
		rule.content = rest
		return rule
	}
	rule.content = strings.TrimSpace(rest[:lastComma])
	target := strings.TrimSpace(rest[lastComma+1:])
	if rule.action == "SUB-RULE" {
		rule.subRule = target
	} else {
		rule.target = target
		rule.hasTarget = true
	}
	return rule
}

func (r parsedRule) String() string {
	parts := []string{r.action}
	if r.action == "MATCH" {
		if r.target != "" {
			parts = append(parts, r.target)
		}
		return strings.Join(parts, ",")
	}
	if r.content != "" {
		parts = append(parts, r.content)
	}
	target := r.target
	if r.action == "SUB-RULE" {
		target = r.subRule
	}
	if target != "" {
		parts = append(parts, target)
	}
	if ruleActionsWithParams[r.action] {
		if r.src {
			parts = append(parts, "src")
		}
		if r.noResolve {
			parts = append(parts, "no-resolve")
		}
	}
	return strings.Join(parts, ",")
}
