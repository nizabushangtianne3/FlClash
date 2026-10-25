package core

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"go.yaml.in/yaml/v3"
)

const baseProfile = `x-defaults: &socks {type: socks5, server: 127.0.0.1, port: 1080}
mixed-port: 7000
dns:
  enable: true
  nameserver: [223.5.5.5]
proxies:
  - {<<: *socks, name: a}
  - name: b
    type: vless
    server: 127.0.0.1
    port: 443
    uuid: 2a70e3a9-b4ce-4f20-908d-e99950a0a611
    network: tcp
    tls: true
    reality-opts: {public-key: SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc, short-id: 0123}
proxy-groups:
  - {name: g, type: select, proxies: [a, b]}
sub-rules:
  sub: ["MATCH,g"]
rules:
  - DOMAIN-SUFFIX,example.com,g
  - match,DIRECT
  - MATCH,g
`

func writeBaseProfile(t *testing.T, profile string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "profile.yaml")
	if err := os.WriteFile(path, []byte(profile), 0o600); err != nil {
		t.Fatalf("write profile: %v", err)
	}
	return path
}

// The base trims the sections it returns, so the parse the next read reuses
// has to keep them: getProfileOutbounds reads exactly what the base dropped.
func TestProfileBaseLeavesTheSharedParseWhole(t *testing.T) {
	t.Cleanup(forgetProfileRaw)
	path := writeBaseProfile(t, baseProfile)

	base, err := handleGetProfileBase(path)
	if err != nil {
		t.Fatalf("getProfileBase: %v", err)
	}
	if base.Proxies != 2 || base.ProxyGroups != 1 {
		t.Fatalf("base = %d proxies, %d groups, want 2 and 1", base.Proxies, base.ProxyGroups)
	}

	outbounds, err := handleGetProfileOutbounds(path)
	if err != nil {
		t.Fatalf("getProfileOutbounds: %v", err)
	}
	if len(outbounds.Proxies) != 2 {
		t.Errorf("outbounds = %v, want the two proxies the base reported", outbounds.Proxies)
	}
	if len(outbounds.ProxyGroups) != 1 {
		t.Errorf("outbound groups = %v, want the one group the base reported", outbounds.ProxyGroups)
	}
}

func TestReadRawConfigReusesTheParse(t *testing.T) {
	t.Cleanup(forgetProfileRaw)
	path := writeBaseProfile(t, baseProfile)

	first, _, err := readRawConfig(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	second, _, err := readRawConfig(path)
	if err != nil {
		t.Fatalf("read again: %v", err)
	}
	if first != second {
		t.Error("an unchanged profile was parsed again")
	}

	changed := strings.Replace(baseProfile, "mixed-port: 7000", "mixed-port: 7001", 1)
	third, _, err := readRawConfig(writeBaseProfile(t, changed))
	if err != nil {
		t.Fatalf("read changed: %v", err)
	}
	if third == first {
		t.Error("a changed profile was answered from the cache")
	}

	forgetProfileRaw()
	fourth, _, err := readRawConfig(path)
	if err != nil {
		t.Fatalf("read after forgetting: %v", err)
	}
	if fourth == first {
		t.Error("a forgotten profile was still answered from the cache")
	}
}

func TestSha256SumIsTheDigestItNames(t *testing.T) {
	buf := []byte("a profile the host reads twice in one edit")

	sum := sha256Sum(buf)

	if len(sum) != sha256.Size {
		t.Fatalf("length = %d, want %d", len(sum), sha256.Size)
	}
	if want := sha256.Sum256(buf); !bytes.Equal(sum, want[:]) {
		t.Errorf("sum = %x, want %x", sum, want)
	}
}

// The overlay is the host's patch of what getProfileBase returned.
func overlayOf(t *testing.T, base *ProfileBase, rules []string, patch map[string]any) string {
	t.Helper()
	data, err := json.Marshal(base.Config)
	if err != nil {
		t.Fatalf("marshal base: %v", err)
	}
	var overlay map[string]any
	if err := json.Unmarshal(data, &overlay); err != nil {
		t.Fatalf("unmarshal base: %v", err)
	}
	delete(overlay, "rule")
	overlay["rules"] = rules
	for key, value := range patch {
		overlay[key] = value
	}
	data, err = json.Marshal(overlay)
	if err != nil {
		t.Fatalf("marshal overlay: %v", err)
	}
	return string(data)
}

func ruleStrings(cfg *config.Config) []string {
	rules := make([]string, 0, len(cfg.Rules))
	for _, rule := range cfg.Rules {
		rules = append(rules, rule.RuleType().String()+","+rule.Payload()+","+rule.Adapter())
	}
	return rules
}

func TestHandleGetProfileBaseLeavesTheBulkSectionsInTheCore(t *testing.T) {
	path := writeBaseProfile(t, baseProfile)

	base, err := handleGetProfileBase(path)

	if err != nil {
		t.Fatalf("handleGetProfileBase = %v", err)
	}
	raw := base.Config
	if raw.Proxy != nil || raw.ProxyGroup != nil || raw.Rule != nil || raw.SubRules != nil {
		t.Errorf("config kept a bulk section: %+v", raw)
	}
	if raw.MixedPort != 7000 || !raw.DNS.Enable {
		t.Errorf("config dropped a section the host patches: mixed-port %d, dns %t", raw.MixedPort, raw.DNS.Enable)
	}
	if base.Proxies != 2 || base.ProxyGroups != 1 || base.Rules != 3 {
		t.Errorf("counts = %d/%d/%d, want 2/1/3", base.Proxies, base.ProxyGroups, base.Rules)
	}
	if want := []string{"match,DIRECT", "MATCH,g"}; !reflect.DeepEqual(base.MatchRules, want) {
		t.Errorf("match rules = %v, want %v", base.MatchRules, want)
	}
	digest := sha256.Sum256([]byte(baseProfile))
	if base.Digest != hex.EncodeToString(digest[:]) {
		t.Errorf("digest = %s, want the sha256 of the file", base.Digest)
	}
}

func TestHandleGetProfileOutboundsListsOnlyNamesAndTypes(t *testing.T) {
	path := writeBaseProfile(t, baseProfile)

	outbounds, err := handleGetProfileOutbounds(path)

	if err != nil {
		t.Fatalf("handleGetProfileOutbounds = %v", err)
	}
	want := &ProfileOutbounds{
		Proxies:     []ProfileOutbound{{Name: "a", Type: "socks5"}, {Name: "b", Type: "vless"}},
		ProxyGroups: []ProfileOutbound{{Name: "g", Type: "select"}},
	}
	if !reflect.DeepEqual(outbounds, want) {
		t.Errorf("outbounds = %+v, want %+v", outbounds, want)
	}
}

func TestHandleBuildProfileWritesTheMergedConfigWhereTheHostReadsSpills(t *testing.T) {
	withSpillHome(t, responseSpillThreshold)
	path := writeBaseProfile(t, baseProfile)
	base, err := handleGetProfileBase(path)
	if err != nil {
		t.Fatalf("handleGetProfileBase = %v", err)
	}
	overlay := overlayOf(t, base, []string{"DOMAIN,added.test,DIRECT"}, nil)

	built, err := handleBuildProfile(&SetupBase{Path: path, Overlay: overlay})

	if err != nil {
		t.Fatalf("handleBuildProfile = %v", err)
	}
	if filepath.Dir(built) != spilledResponseDir() {
		t.Errorf("built %s, want it in %s", built, spilledResponseDir())
	}
	cfg, err := loadConfig(built)
	if err != nil {
		t.Fatalf("loadConfig(built) = %v", err)
	}
	if got := ruleStrings(cfg); len(got) != 4 || got[0] != "Domain,added.test,DIRECT" {
		t.Errorf("rules = %v, want the added rule before the profile's three", got)
	}
}

func TestLoadConfigWithBasePutsTheAddedRulesFirstAndTheOverlayOverTheRest(t *testing.T) {
	path := writeBaseProfile(t, baseProfile)
	base, err := handleGetProfileBase(path)
	if err != nil {
		t.Fatalf("handleGetProfileBase = %v", err)
	}
	overlay := overlayOf(t, base, []string{"DOMAIN,added.test,DIRECT"}, map[string]any{
		"mixed-port": 7890,
		"dns":        map[string]any{"enable": true, "nameserver": []string{"1.1.1.1"}},
	})
	configPath := filepath.Join(t.TempDir(), "config.yaml")

	cfg, err := loadConfigWithBase(&SetupBase{Path: path, Overlay: overlay}, configPath)

	if err != nil {
		t.Fatalf("loadConfigWithBase = %v", err)
	}
	want := []string{
		"Domain,added.test,DIRECT",
		"DomainSuffix,example.com,g",
		"Match,,DIRECT",
		"Match,,g",
	}
	if got := ruleStrings(cfg); !reflect.DeepEqual(got, want) {
		t.Errorf("rules = %v, want %v", got, want)
	}
	if cfg.General.MixedPort != 7890 {
		t.Errorf("mixed-port = %d, want the overlay's", cfg.General.MixedPort)
	}
	if len(cfg.DNS.NameServer) != 1 || !strings.Contains(cfg.DNS.NameServer[0].Addr, "1.1.1.1") {
		t.Errorf("nameservers = %+v, want only the overlay's", cfg.DNS.NameServer)
	}
	for _, name := range []string{"a", "b", "g"} {
		if cfg.Proxies[name] == nil {
			t.Errorf("proxy %s is missing", name)
		}
	}
	if len(cfg.SubRules["sub"]) != 1 {
		t.Errorf("sub-rules = %v, want the profile's", cfg.SubRules)
	}
}

// The Android service and mihomo's controller reload config.yaml without the
// profile, and the anchor it was written with sits in a section the overlay drops.
func TestLoadConfigWithBaseWritesAConfigThatLoadsAlone(t *testing.T) {
	path := writeBaseProfile(t, baseProfile)
	base, err := handleGetProfileBase(path)
	if err != nil {
		t.Fatalf("handleGetProfileBase = %v", err)
	}
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	cfg, err := loadConfigWithBase(
		&SetupBase{Path: path, Overlay: overlayOf(t, base, []string{"DOMAIN,added.test,DIRECT"}, nil)},
		configPath,
	)
	if err != nil {
		t.Fatalf("loadConfigWithBase = %v", err)
	}

	reloaded, err := loadConfig(configPath)

	if err != nil {
		t.Fatalf("loadConfig(config.yaml) = %v", err)
	}
	if got, want := ruleStrings(reloaded), ruleStrings(cfg); !reflect.DeepEqual(got, want) {
		t.Errorf("reloaded rules = %v, want %v", got, want)
	}
	if len(reloaded.Proxies) != len(cfg.Proxies) {
		t.Errorf("reloaded %d proxies, want %d", len(reloaded.Proxies), len(cfg.Proxies))
	}
	raw, err := handleGetConfig(configPath)
	if err != nil {
		t.Fatalf("handleGetConfig(config.yaml) = %v", err)
	}
	for _, proxy := range raw.Proxy {
		if proxy["name"] != "b" {
			continue
		}
		if got := proxy["reality-opts"].(map[string]any)["short-id"]; got != "0123" {
			t.Errorf("short-id = %#v, want the literal 0123", got)
		}
	}
}

func TestLoadConfigWithBaseKeepsAnEmptyProfileOnTheDefaults(t *testing.T) {
	path := writeBaseProfile(t, "")

	cfg, err := loadConfigWithBase(
		&SetupBase{Path: path, Overlay: `{"rules": ["MATCH,DIRECT"]}`},
		filepath.Join(t.TempDir(), "config.yaml"),
	)

	if err != nil {
		t.Fatalf("loadConfigWithBase = %v", err)
	}
	if got := ruleStrings(cfg); !reflect.DeepEqual(got, []string{"Match,,DIRECT"}) {
		t.Errorf("rules = %v, want the added rule alone", got)
	}
}

func TestLoadConfigWithBaseRejectsAProfileThatIsNotAMapping(t *testing.T) {
	path := writeBaseProfile(t, "- a\n- b\n")
	configPath := filepath.Join(t.TempDir(), "config.yaml")

	if _, err := loadConfigWithBase(&SetupBase{Path: path, Overlay: "{}"}, configPath); err == nil {
		t.Fatal("loadConfigWithBase accepted a list as a config")
	}
	if _, err := os.Stat(configPath); !os.IsNotExist(err) {
		t.Errorf("stat config.yaml = %v, want the failed apply to leave it alone", err)
	}
}

func TestLoadSetupConfigReadsConfigYamlWithoutABase(t *testing.T) {
	home := t.TempDir()
	previous := constant.Path.HomeDir()
	constant.SetHomeDir(home)
	t.Cleanup(func() { constant.SetHomeDir(previous) })
	profile := "rules:\n  - MATCH,REJECT\n"
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), []byte(profile), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := loadSetupConfig(defaultSetupParams())

	if err != nil {
		t.Fatalf("loadSetupConfig = %v", err)
	}
	if got := ruleStrings(cfg); !reflect.DeepEqual(got, []string{"Match,,REJECT"}) {
		t.Errorf("rules = %v, want config.yaml's", got)
	}
}

func TestEncodeConfigMappingKeepsEveryKeyAfterAnOpenEndedScalar(t *testing.T) {
	rules := make([]string, encodeSliceLength*2+1)
	for i := range rules {
		rules[i] = fmt.Sprintf("DOMAIN,%d.test,DIRECT", i)
	}
	var mapping yaml.Node
	if err := mapping.Encode(map[string]any{"rules": rules}); err != nil {
		t.Fatalf("encode rules: %v", err)
	}
	note := []*yaml.Node{
		{Kind: yaml.ScalarNode, Tag: "!!str", Value: "a-note"},
		{Kind: yaml.ScalarNode, Tag: "!!str", Value: "kept\n\n", Style: yaml.LiteralStyle},
	}
	mapping.Content = append(note, mapping.Content...)
	var out bytes.Buffer

	if err := encodeConfigMapping(&out, &mapping); err != nil {
		t.Fatalf("encodeConfigMapping = %v", err)
	}

	var decoded struct {
		Note  string   `yaml:"a-note"`
		Rules []string `yaml:"rules"`
	}
	if err := yaml.Unmarshal(out.Bytes(), &decoded); err != nil {
		t.Fatalf("decode = %v", err)
	}
	if decoded.Note != "kept\n\n" {
		t.Errorf("note = %q, want its trailing lines kept", decoded.Note)
	}
	if !reflect.DeepEqual(decoded.Rules, rules) {
		t.Errorf("decoded %d rules, want all %d in order", len(decoded.Rules), len(rules))
	}
}

// The merge reads a document the previous merge already let the writer inline
// and retag, so a merge has to be a pure function of its inputs no matter how
// often it has been through the writer.
func TestMergeProfileBaseProducesTheSameDocumentTwice(t *testing.T) {
	path := writeBaseProfile(t, baseProfile)
	base, err := handleGetProfileBase(path)
	if err != nil {
		t.Fatalf("handleGetProfileBase = %v", err)
	}
	overlay := overlayOf(t, base, []string{"DOMAIN,added.test,DIRECT"}, nil)

	encode := func() []byte {
		t.Helper()
		document, err := mergeProfileBase(&SetupBase{Path: path, Overlay: overlay})
		if err != nil {
			t.Fatalf("mergeProfileBase = %v", err)
		}
		inlineAliases(document)
		var encoded bytes.Buffer
		if err := encodeConfigMapping(&encoded, document.Content[0]); err != nil {
			t.Fatalf("encode = %v", err)
		}
		return encoded.Bytes()
	}

	first := encode()
	if !bytes.Contains(first, []byte("0123")) {
		t.Errorf("first merge dropped the short-id: %s", first)
	}
	if !bytes.Contains(first, []byte("type: socks5")) {
		t.Errorf("first merge left the anchor un-inlined: %s", first)
	}
	for attempt := 2; attempt <= 3; attempt++ {
		again := encode()
		if !bytes.Equal(first, again) {
			t.Errorf("merge %d = %s, want %s", attempt, again, first)
		}
	}
}

func profileDocument(proxyCount int) []byte {
	var document strings.Builder
	document.WriteString("proxies:\n")
	for index := range proxyCount {
		fmt.Fprintf(&document,
			"  - name: node-%04d\n    type: ss\n    server: 10.%d.%d.1\n    port: 443\n    cipher: aes-128-gcm\n    password: password\n",
			index, index>>8, index&0xff)
	}
	document.WriteString("proxy-groups:\n  - name: Proxy\n    type: select\n    proxies: [DIRECT]\nrules:\n  - MATCH,DIRECT\n")
	return []byte(document.String())
}

// The host merges a profile once to build it and again to apply it, and each
// merge parses the whole profile document, so this is what one of them costs.
// The merge reads the profile document back in every time, so the cost of
// parsing it is the part worth knowing apart from the merge around it.
func BenchmarkUnmarshalProfileDocument(b *testing.B) {
	for _, proxyCount := range []int{200, 800} {
		b.Run(fmt.Sprintf("proxies=%d", proxyCount), func(b *testing.B) {
			buf := profileDocument(proxyCount)

			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				var document yaml.Node
				if err := yaml.Unmarshal(buf, &document); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

// The host merges the same profile twice per edit, once to build it and once to
// apply it, so the merge that runs on the second call is the one that repeats.
func BenchmarkMergeProfileBaseCached(b *testing.B) {
	for _, proxyCount := range []int{200, 800} {
		b.Run(fmt.Sprintf("proxies=%d", proxyCount), func(b *testing.B) {
			path := filepath.Join(b.TempDir(), "profile.yaml")
			if err := os.WriteFile(path, profileDocument(proxyCount), 0o644); err != nil {
				b.Fatal(err)
			}
			base := &SetupBase{Path: path, Overlay: "rules:\n  - MATCH,DIRECT\n"}
			if _, err := mergeProfileBase(base); err != nil {
				b.Fatal(err)
			}

			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := mergeProfileBase(base); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkMergeProfileBase(b *testing.B) {
	for _, proxyCount := range []int{200, 800} {
		b.Run(fmt.Sprintf("proxies=%d", proxyCount), func(b *testing.B) {
			path := filepath.Join(b.TempDir(), "profile.yaml")
			base := &SetupBase{Path: path, Overlay: "rules:\n  - MATCH,DIRECT\n"}

			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				b.StopTimer()
				document := profileDocument(proxyCount)
				document = append(document, []byte(fmt.Sprintf("# round %d\n", i))...)
				if err := os.WriteFile(path, document, 0o644); err != nil {
					b.Fatal(err)
				}
				b.StartTimer()

				if _, err := mergeProfileBase(base); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
