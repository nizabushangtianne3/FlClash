package core

import (
	"encoding/base64"
	"encoding/json"
	"net/url"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// linkShape is what a share link carries apart from the fragment: the pieces a
// reader has to hand back.
type linkShape struct {
	scheme string
	user   string
	host   string
	query  map[string]string
}

func parseLink(t *testing.T, link string) linkShape {
	t.Helper()
	// Split by hand: a port range such as hysteria2's is not a valid host port
	// for url.Parse, and it is exactly what has to reach the reader.
	scheme, rest, found := strings.Cut(link, "://")
	require.True(t, found, "%q has no scheme", link)
	authority, query, _ := strings.Cut(rest, "?")
	shape := linkShape{scheme: scheme, query: map[string]string{}}
	if at := strings.LastIndex(authority, "@"); at >= 0 {
		shape.user, shape.host = authority[:at], authority[at+1:]
	} else {
		shape.host = authority
	}
	if query != "" {
		parsed, err := url.ParseQuery(query)
		require.NoError(t, err, "parse %q", query)
		for key, values := range parsed {
			shape.query[key] = values[0]
		}
	}
	return shape
}

// The round-trip test reads a link back through the converter; this one pins
// what each encoder puts in the link, so an optional field that stops being
// carried fails here instead of being silently dropped on the way out.
func TestShareLinkEncodersCarryEveryField(t *testing.T) {
	for _, test := range []struct {
		name   string
		fields proxyFields
		want   linkShape
		absent []string
	}{
		{
			name: "shadowsocks with a v2ray plugin over tls",
			fields: proxyFields{
				"type": "ss", "server": "a.example", "port": "443",
				"cipher": "aes-128-gcm", "password": "pw", "plugin": "v2ray-plugin",
				"plugin-opts": map[string]any{
					"mode": "websocket", "host": "host.example", "path": "/p", "tls": true,
				},
			},
			want: linkShape{scheme: "ss", user: "aes-128-gcm:pw", host: "a.example:443",
				query: map[string]string{"plugin": "v2ray-plugin;mode=websocket;host=host.example;path=/p;tls"}},
		},
		{
			name: "shadowsocks with a plugin nobody reads",
			fields: proxyFields{
				"type": "ss", "server": "a.example", "port": "443",
				"cipher": "aes-128-gcm", "password": "pw", "plugin": "shadow-tls",
			},
			want: linkShape{},
		},
		{
			name: "vless reads reality from its opts",
			fields: proxyFields{
				"type": "vless", "server": "d.example", "port": "443", "uuid": "u",
				"tls": true, "servername": "sni.example", "flow": "xtls-rprx-vision",
				"encryption": "none", "client-fingerprint": "chrome", "alpn": []any{"h3", "h2"},
				"packet-addr": true, "network": "ws",
				"ws-opts": map[string]any{"path": "/ray", "max-early-data": "2048",
					"headers":                map[string]any{"Host": "ws.example"},
					"early-data-header-name": "cookie"},
				"reality-opts": map[string]any{"public-key": "PBK", "short-id": "ab12"},
			},
			want: linkShape{scheme: "vless", user: "u", host: "d.example:443", query: map[string]string{
				"security": "reality", "pbk": "PBK", "sid": "ab12", "fp": "chrome",
				"alpn": "h3,h2", "sni": "sni.example", "flow": "xtls-rprx-vision",
				"encryption": "none", "packetEncoding": "packet", "type": "ws",
				"path": "/ray", "ed": "2048", "host": "ws.example", "eh": "cookie",
			}},
		},
		{
			name: "vless keeps tls when reality has no public key",
			fields: proxyFields{
				"type": "vless", "server": "d.example", "port": "443", "uuid": "u", "tls": true,
				"client-fingerprint": "firefox", "alpn": []any{"h2"}, "xudp": false,
			},
			want: linkShape{scheme: "vless", user: "u", host: "d.example:443", query: map[string]string{
				"security": "tls", "fp": "firefox", "alpn": "h2", "packetEncoding": "none",
			}},
			absent: []string{"sni", "flow"},
		},
		{
			name: "vless over httpupgrade with fast open",
			fields: proxyFields{
				"type": "vless", "server": "d.example", "port": "443", "uuid": "u",
				"network": "httpupgrade", "ws-opts": map[string]any{
					"path": "/upgrade", "v2ray-http-upgrade-fast-open": true,
				},
			},
			want: linkShape{scheme: "vless", user: "u", host: "d.example:443", query: map[string]string{
				"type": "httpupgrade", "path": "/upgrade", "ed": "0", "packetEncoding": "none",
			}},
		},
		{
			name: "vless over grpc names its service",
			fields: proxyFields{
				"type": "vless", "server": "d.example", "port": "443", "uuid": "u",
				"network": "grpc", "grpc-opts": map[string]any{"grpc-service-name": "svc"},
			},
			want: linkShape{scheme: "vless", user: "u", host: "d.example:443", query: map[string]string{
				"type": "grpc", "serviceName": "svc", "packetEncoding": "none",
			}},
		},
		{
			name: "vless over http names its method and host",
			fields: proxyFields{
				"type": "vless", "server": "d.example", "port": "443", "uuid": "u",
				"network": "http", "http-opts": map[string]any{
					"path": []any{"/a", "/b"}, "method": "GET",
					"headers": map[string]any{"Host": []any{"h1.example", "h2.example"}},
				},
			},
			want: linkShape{scheme: "vless", user: "u", host: "d.example:443", query: map[string]string{
				"type": "tcp", "headerType": "http", "path": "/a", "host": "h1.example",
				"method": "GET", "packetEncoding": "none",
			}},
		},
		{
			name: "vless over h2 carries its host list and path",
			fields: proxyFields{
				"type": "vless", "server": "d.example", "port": "443", "uuid": "u",
				"network": "h2", "h2-opts": map[string]any{
					"path": "/h2", "host": []any{"h2.example"},
				},
			},
			want: linkShape{scheme: "vless", user: "u", host: "d.example:443", query: map[string]string{
				"type": "http", "path": "/h2", "host": "h2.example", "packetEncoding": "none",
			}},
		},
		{
			name: "vless over xhttp keeps its own type",
			fields: proxyFields{
				"type": "vless", "server": "d.example", "port": "443", "uuid": "u",
				"network": "xhttp", "xhttp-opts": map[string]any{"path": "/xh"},
			},
			want: linkShape{scheme: "vless", user: "u", host: "d.example:443", query: map[string]string{
				"type": "xhttp", "path": "/xh", "packetEncoding": "none",
			}},
		},
		{
			name: "vless over a network the link format does not name keeps its own type",
			fields: proxyFields{
				"type": "vless", "server": "d.example", "port": "443", "uuid": "u",
				"network": "kcp",
			},
			want: linkShape{scheme: "vless", user: "u", host: "d.example:443", query: map[string]string{
				"type": "kcp", "packetEncoding": "none",
			}},
		},
		{
			name: "trojan over websocket with a host cannot be read back",
			fields: proxyFields{
				"type": "trojan", "server": "e.example", "port": "443", "password": "pw",
				"network": "ws", "ws-opts": map[string]any{
					"path": "/t", "headers": map[string]any{"Host": "ws.example"},
				},
			},
			want: linkShape{},
		},
		{
			name: "trojan over grpc with a fingerprint",
			fields: proxyFields{
				"type": "trojan", "server": "e.example", "port": "443", "password": "pw",
				"skip-cert-verify": true, "sni": "sni.example", "alpn": []any{"h2"},
				"network": "grpc", "grpc-opts": map[string]any{"grpc-service-name": "svc"},
				"client-fingerprint": "chrome", "fingerprint": "pin",
			},
			want: linkShape{scheme: "trojan", user: "pw", host: "e.example:443", query: map[string]string{
				"allowInsecure": "1", "sni": "sni.example", "alpn": "h2",
				"type": "grpc", "serviceName": "svc", "fp": "chrome", "pcs": "pin",
			}},
		},
		{
			name: "hysteria carries both spellings of the auth string",
			fields: proxyFields{
				"type": "hysteria", "server": "f.example", "port": "443", "auth_str": "auth",
				"sni": "peer.example", "obfs": "x", "protocol": "udp", "up": "100",
				"down": "200", "skip-cert-verify": true, "alpn": []any{"h3"},
			},
			want: linkShape{scheme: "hysteria", host: "f.example:443", query: map[string]string{
				"peer": "peer.example", "obfs": "x", "auth": "auth", "protocol": "udp",
				"up": "100", "down": "200", "insecure": "1", "alpn": "h3",
			}},
		},
		{
			name: "hysteria2 walks a port range instead of a realm hop",
			fields: proxyFields{
				"type": "hysteria2", "server": "g.example", "port": "443", "ports": "2000-3000",
				"password": "pw", "sni": "sni.example", "obfs": "x", "obfs-password": "opw",
				"skip-cert-verify": true, "alpn": []any{"h3"}, "fingerprint": "pin",
				"up": "10", "down": "20",
			},
			want: linkShape{scheme: "hysteria2", user: "pw", host: "g.example:2000-3000",
				query: map[string]string{
					"sni": "sni.example", "obfs": "x", "obfs-password": "opw", "insecure": "1",
					"alpn": "h3", "pinSHA256": "pin", "up": "10", "down": "20",
				}},
		},
		{
			name: "hysteria2 with a realm hop has no link",
			fields: proxyFields{
				"type": "hysteria2", "server": "g.example", "port": "443",
				"realm-opts": map[string]any{"enable": true},
			},
			want: linkShape{},
		},
		{
			name: "tuic falls back to a token without a uuid",
			fields: proxyFields{
				"type": "tuic", "server": "h.example", "port": "443", "token": "tok",
				"congestion-controller": "bbr", "alpn": []any{"h3"}, "sni": "sni.example",
				"disable-sni": true, "udp-relay-mode": "native",
			},
			want: linkShape{scheme: "tuic", user: "tok", host: "h.example:443", query: map[string]string{
				"congestion_control": "bbr", "alpn": "h3", "sni": "sni.example",
				"disable_sni": "1", "udp_relay_mode": "native",
			}},
		},
		{
			name: "mieru brackets an ipv6 host and names its transport",
			fields: proxyFields{
				"type": "mieru", "server": "2001:db8::1", "port-range": "2000-3000",
				"username": "user", "password": "pw", "transport": "TCP",
				"multiplexing": "MULTIPLEXING_OFF", "handshake-mode": "HANDSHAKE_STANDARD",
			},
			want: linkShape{scheme: "mierus", user: "user:pw", host: "[2001:db8::1]", query: map[string]string{
				"port": "2000-3000", "protocol": "TCP", "multiplexing": "MULTIPLEXING_OFF",
				"handshake-mode": "HANDSHAKE_STANDARD",
			}},
		},
		{
			name: "mieru defaults to the single port and tcp",
			fields: proxyFields{
				"type": "mieru", "server": "i.example", "port": "443",
				"username": "user", "password": "pw",
			},
			want: linkShape{scheme: "mierus", user: "user:pw", host: "i.example", query: map[string]string{
				"port": "443", "protocol": "TCP",
			}},
			absent: []string{"multiplexing", "handshake-mode", "traffic-pattern"},
		},
		{
			name: "anytls carries its pin",
			fields: proxyFields{
				"type": "anytls", "server": "j.example", "port": "443", "password": "pw",
				"sni": "sni.example", "skip-cert-verify": true, "fingerprint": "pin",
			},
			want: linkShape{scheme: "anytls", user: "pw", host: "j.example:443", query: map[string]string{
				"sni": "sni.example", "insecure": "1", "hpkp": "pin",
			}},
		},
		{
			name: "socks over tls is an https link with its credentials",
			fields: proxyFields{
				"type": "http", "server": "k.example", "port": "1080", "tls": true,
				"username": "user", "password": "pw",
			},
			want: linkShape{scheme: "https", user: "user:pw", host: "k.example:1080", query: map[string]string{}},
		},
		{
			name: "socks without credentials carries no user info",
			fields: proxyFields{
				"type": "socks5", "server": "k.example", "port": "1080",
			},
			want: linkShape{scheme: "socks5", host: "k.example:1080", query: map[string]string{}},
		},
		{
			name: "socks in the clear is an http link",
			fields: proxyFields{
				"type": "http", "server": "k.example", "port": "1080",
			},
			want: linkShape{scheme: "http", host: "k.example:1080", query: map[string]string{}},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			link := encodeShareLink(test.fields)
			if test.want.scheme == "" {
				require.Empty(t, link, "this proxy has no share link")
				return
			}
			require.NotEmpty(t, link)
			shape := parseLink(t, link)
			require.Equal(t, test.want.scheme, shape.scheme)
			require.Equal(t, test.want.host, shape.host)
			require.Equal(t, test.want.user, shape.user)
			require.Equal(t, test.want.query, shape.query)
			for _, key := range test.absent {
				require.NotContains(t, shape.query, key, "%s must stay out of the link", key)
			}
		})
	}
}

// The fields a proxy carries arrive from JSON, so a missing one, a string and
// a native value all have to read the same way.
func TestProxyFieldsReadEveryShape(t *testing.T) {
	fields := proxyFields{
		"server": "a.example", "port": 443, "ratio": 1.5, "flag": true, "flagText": "true",
		"flagOff": "false", "names": []any{"a", 2}, "one": "solo", "empty": "",
		"opts": map[string]any{"port": "1080"},
	}

	require.Equal(t, "a.example", fields.str("server"))
	require.Equal(t, "443", fields.str("port"))
	require.Equal(t, "1.5", fields.str("ratio"))
	require.Empty(t, fields.str("missing"))

	require.True(t, fields.flag("flag"))
	require.True(t, fields.flag("flagText"))
	require.False(t, fields.flag("flagOff"))
	require.False(t, fields.flag("missing"))

	require.Equal(t, []string{"a", "2"}, fields.list("names"))
	require.Equal(t, []string{"solo"}, fields.list("one"))
	require.Empty(t, fields.list("empty"))
	require.Empty(t, fields.list("missing"))
	require.Equal(t, "solo", fields.first("one"))
	require.Empty(t, fields.first("missing"))

	require.Equal(t, "1080", fields.sub("opts").str("port"))
	require.Empty(t, fields.sub("missing").str("port"))
}

func TestWsEarlyDataPathLeavesAPathItCannotExtend(t *testing.T) {
	opts := proxyFields{}
	require.Equal(t, "/ray", wsEarlyDataPath("/ray", opts))
	require.Equal(t, "/ray", wsEarlyDataPath("/ray", proxyFields{"max-early-data": "0"}))
	require.Equal(t, "/ray?ed=2048", wsEarlyDataPath("/ray", proxyFields{"max-early-data": "2048"}))
	require.Equal(t, "/ray?ed=2048", wsEarlyDataPath("/ray?ed=2048", proxyFields{"max-early-data": "2048"}))
	// A path the URL parser refuses is carried as it came rather than dropped.
	require.Equal(t, "/ray%zz", wsEarlyDataPath("/ray%zz", proxyFields{"max-early-data": "2048"}))
}

// A legacy alterId has no Xray share form, so the link falls back to the v2rayN
// JSON; every network the JSON carries has to reach it.
func TestVmessJSONLinkCarriesTheLegacyFields(t *testing.T) {
	link := encodeShareLink(proxyFields{
		"type": "vmess", "server": "c.example", "port": "443", "uuid": "u", "alterId": "64",
		"cipher": "aes-128-gcm", "name": "legacy", "network": "h2",
		"tls": true, "servername": "sni.example", "alpn": []any{"h2", "h3"},
		"client-fingerprint": "chrome",
		"h2-opts":            map[string]any{"host": []any{"h2.example"}, "path": "/h2"},
	})

	body, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(link, "vmess://"))
	require.NoError(t, err, "decode %q", link)

	var payload struct {
		Ps   string `json:"ps"`
		Add  string `json:"add"`
		Port string `json:"port"`
		ID   string `json:"id"`
		Net  string `json:"net"`
		Host string `json:"host"`
		Path string `json:"path"`
		Tls  string `json:"tls"`
		Sni  string `json:"sni"`
		Alpn string `json:"alpn"`
		Fp   string `json:"fp"`
	}
	require.NoError(t, json.Unmarshal(body, &payload))
	require.Equal(t, "legacy", payload.Ps)
	require.Equal(t, "c.example", payload.Add)
	require.Equal(t, "443", payload.Port)
	require.Equal(t, "u", payload.ID)
	require.Equal(t, "h2", payload.Net)
	require.Equal(t, "h2.example", payload.Host)
	require.Equal(t, "/h2", payload.Path)
	require.Equal(t, "tls", payload.Tls)
	require.Equal(t, "sni.example", payload.Sni)
	require.Equal(t, "h2,h3", payload.Alpn)
	require.Equal(t, "chrome", payload.Fp)
}

// The v2rayN JSON has a field per network option, and each network writes a
// different one, so the link is only right if every network reaches it.
func TestVmessLegacyLinkCarriesEveryNetwork(t *testing.T) {
	for _, test := range []struct {
		name   string
		fields proxyFields
		want   map[string]any
	}{
		{
			name: "ws folds its early data into the path",
			fields: proxyFields{
				"type": "vmess", "server": "c.example", "port": "443", "uuid": "u", "alterId": "8",
				"network": "ws", "ws-opts": map[string]any{
					"path": "/ray", "max-early-data": "2048",
					"headers": map[string]any{"Host": "ws.example"},
				},
			},
			want: map[string]any{"net": "ws", "host": "ws.example", "path": "/ray?ed=2048", "tls": ""},
		},
		{
			name: "grpc names its service",
			fields: proxyFields{
				"type": "vmess", "server": "c.example", "port": "443", "uuid": "u", "alterId": "8",
				"network": "grpc", "grpc-opts": map[string]any{"grpc-service-name": "svc"},
			},
			want: map[string]any{"net": "grpc", "path": "svc", "tls": ""},
		},
		{
			name: "http reads its first host and path",
			fields: proxyFields{
				"type": "vmess", "server": "c.example", "port": "443", "uuid": "u", "alterId": "8",
				"network": "http", "http-opts": map[string]any{
					"path":    []any{"/a", "/b"},
					"headers": map[string]any{"Host": []any{"h1.example", "h2.example"}},
				},
			},
			want: map[string]any{"type": "http", "host": "h1.example", "path": "/a", "net": "tcp"},
		},
		{
			name: "a cipher that is not auto rides along",
			fields: proxyFields{
				"type": "vmess", "server": "c.example", "port": "443", "uuid": "u",
				"cipher": "aes-128-gcm", "tls": true, "servername": "sni.example",
			},
			want: map[string]any{},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			link := encodeShareLink(test.fields)
			// The plain Xray form names the uuid in the user info; the legacy
			// one is a base64 body with no @ in it.
			if strings.Contains(link, "@") {
				shape := parseLink(t, link)
				require.Equal(t, "u", shape.user)
				require.Equal(t, "aes-128-gcm", shape.query["encryption"])
				return
			}
			body, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(link, "vmess://"))
			require.NoError(t, err, "decode %q", link)
			var payload map[string]any
			require.NoError(t, json.Unmarshal(body, &payload))
			for key, want := range test.want {
				require.Equal(t, want, payload[key], "%s in %s", key, test.name)
			}
		})
	}
}
