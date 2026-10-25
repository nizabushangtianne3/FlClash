package core

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/tunnel"
)

func probeServer(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return server
}

// countingListener answers the question the pooled transport is judged by:
// how many connections the peer had to accept.
type countingListener struct {
	net.Listener
	accepted *atomic.Int32
}

func (l countingListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err == nil {
		l.accepted.Add(1)
	}
	return conn, err
}

func probeConnectionServer(t *testing.T, handler http.HandlerFunc) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	accepted := &atomic.Int32{}
	server := &httptest.Server{
		Listener: countingListener{Listener: listener, accepted: accepted},
		Config:   &http.Server{Handler: handler},
	}
	server.Start()
	t.Cleanup(server.Close)
	return server, accepted
}

func withProbeProxies(t *testing.T, names ...string) {
	t.Helper()
	proxies := make(map[string]constant.Proxy, len(names))
	for _, name := range names {
		proxies[name] = namedProxy(name)
	}
	tunnel.UpdateProxies(proxies, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
}

func TestHandleProbePinsTheNamedProxy(t *testing.T) {
	var userAgent string
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		userAgent = r.UserAgent()
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte("ip=203.0.113.7\nloc=US\n"))
	})
	withProbeProxies(t, "node-a")

	result := handleProbe(&ProbeParams{
		Url:       server.URL + "/trace",
		ProxyName: "node-a",
		Headers:   map[string]string{"User-Agent": "probe-test"},
		Timeout:   2000,
		MaxBody:   1024,
	})

	if result == nil {
		t.Fatal("handleProbe = nil, want a result")
	}
	if result.Error != "" {
		t.Fatalf("error = %q (%s), want none", result.Error, result.Message)
	}
	if result.StatusCode != http.StatusForbidden {
		t.Errorf("status = %d, want 403", result.StatusCode)
	}
	if result.Body != "ip=203.0.113.7\nloc=US\n" {
		t.Errorf("body = %q", result.Body)
	}
	if !slices.Equal(result.Chains, []string{"node-a"}) {
		t.Errorf("chains = %v, want [node-a]", result.Chains)
	}
	if result.Url != server.URL+"/trace" {
		t.Errorf("url = %q", result.Url)
	}
	if userAgent != "probe-test" {
		t.Errorf("user agent = %q, want the header the caller passed", userAgent)
	}
}

func TestHandleProbeFollowsRedirectsAndCapsTheBody(t *testing.T) {
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/final", http.StatusFound)
			return
		}
		_, _ = w.Write([]byte(strings.Repeat("x", 100)))
	})
	withProbeProxies(t, "node-a")

	result := handleProbe(&ProbeParams{Url: server.URL, ProxyName: "node-a", Timeout: 2000, MaxBody: 8})

	if result == nil || result.Error != "" {
		t.Fatalf("result = %+v, want a success", result)
	}
	if result.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200 after the redirect", result.StatusCode)
	}
	if result.Url != server.URL+"/final" {
		t.Errorf("url = %q, want the redirect target", result.Url)
	}
	if len(result.Body) != 8 {
		t.Errorf("body length = %d, want the cap", len(result.Body))
	}
}

func TestReadProbeBodyStopsOnceTheMarkerArrives(t *testing.T) {
	marker := "\"currentTerritory\":\"JP\""
	page := strings.Repeat("x", probeScanChunk-10) + marker + strings.Repeat("y", 4*probeScanChunk)
	var seen int

	body := readProbeBody(strings.NewReader(page), int64(len(page)), func(tail string) bool {
		seen++
		return strings.Contains(tail, marker)
	})

	if !strings.Contains(body, marker) {
		t.Fatalf("body lost the marker that straddled two chunks")
	}
	if len(body) >= len(page) || seen != 2 {
		t.Errorf("read %d of %d bytes in %d chunks, want it to stop at the marker", len(body), len(page), seen)
	}
}

func TestReadProbeBodyKeepsOnlyTheWindowWhenTheMarkerIsDeep(t *testing.T) {
	marker := `"currentTerritory":"JP"`
	page := strings.Repeat("x", 4*probeScanChunk) + marker + strings.Repeat("y", 4*probeScanChunk)

	body := readProbeBody(strings.NewReader(page), int64(len(page)), func(tail string) bool {
		return strings.Contains(tail, marker)
	})

	if !strings.Contains(body, marker) {
		t.Fatal("a marker that sat four chunks in was lost")
	}
	if len(body) > probeScanChunk+probeScanOverlap {
		t.Errorf("body length = %d, want no more than one chunk plus its overlap", len(body))
	}
}

func TestReadProbeBodyKeepsTheCapWithoutAMarker(t *testing.T) {
	page := strings.Repeat("x", 3*probeScanChunk)

	body := readProbeBody(strings.NewReader(page), probeScanChunk+5, func(string) bool { return false })

	if len(body) != probeScanChunk+5 {
		t.Errorf("body length = %d, want the cap", len(body))
	}
}

func TestHandleProbeSkipsTheBodyWhenNotAsked(t *testing.T) {
	server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	withProbeProxies(t, "node-a")

	result := handleProbe(&ProbeParams{Url: server.URL, ProxyName: "node-a", Timeout: 2000})

	if result == nil || result.Error != "" {
		t.Fatalf("result = %+v, want a success", result)
	}
	if result.StatusCode != http.StatusNoContent || result.Body != "" {
		t.Errorf("status = %d body = %q, want 204 with no body", result.StatusCode, result.Body)
	}
}

func TestHandleProbeReportsATimeout(t *testing.T) {
	addr := blackHoleServer(t)
	withProbeProxies(t, "node-a")

	start := time.Now()
	result := handleProbe(&ProbeParams{Url: "http://" + addr.String(), ProxyName: "node-a", Timeout: 200})

	if result == nil {
		t.Fatal("handleProbe = nil, want a result")
	}
	if result.Error != probeErrorTimeout {
		t.Errorf("error = %q (%s), want timeout", result.Error, result.Message)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Errorf("took %s, want the caller's budget", elapsed)
	}
}

func TestHandleProbeReportsARefusedConnection(t *testing.T) {
	server := probeServer(t, func(http.ResponseWriter, *http.Request) {})
	url := server.URL
	server.Close()
	withProbeProxies(t, "node-a")

	result := handleProbe(&ProbeParams{Url: url, ProxyName: "node-a", Timeout: 2000})

	if result == nil || result.Error != probeErrorFailed {
		t.Fatalf("result = %+v, want a failed probe", result)
	}
	if result.StatusCode != 0 || result.Message == "" {
		t.Errorf("status = %d message = %q, want no status and a reason", result.StatusCode, result.Message)
	}
}

func TestHandleProbeRejectsAnUnknownProxyWithoutWaitingForASlot(t *testing.T) {
	for i := 0; i < probeConcurrency; i++ {
		probeSlots <- struct{}{}
	}
	t.Cleanup(func() {
		for i := 0; i < probeConcurrency; i++ {
			<-probeSlots
		}
	})

	done := make(chan *ProbeResult, 1)
	go func() {
		done <- handleProbe(&ProbeParams{Url: "http://example.invalid", ProxyName: "missing", Timeout: 1})
	}()

	select {
	case result := <-done:
		if result == nil || result.Error != probeErrorFailed {
			t.Errorf("result = %+v, want a failed probe", result)
		}
	case <-time.After(time.Second):
		t.Fatal("an unknown proxy queued behind a saturated probe semaphore")
	}
}

func TestHandleProbeGivesUpQueueingOnTheDeadline(t *testing.T) {
	for i := 0; i < probeConcurrency; i++ {
		probeSlots <- struct{}{}
	}
	t.Cleanup(func() {
		for i := 0; i < probeConcurrency; i++ {
			<-probeSlots
		}
	})
	withProbeProxies(t, "node-a")

	if result := handleProbe(&ProbeParams{Url: "http://example.invalid", ProxyName: "node-a", Timeout: 50}); result != nil {
		t.Errorf("result = %+v, want nil when no slot was granted", result)
	}
}

func TestHandleProbeRoutesThroughTheTunnel(t *testing.T) {
	server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("routed"))
	})
	withProbeProxies(t, "DIRECT")
	tunnel.OnRunning()
	t.Cleanup(tunnel.OnSuspend)

	result := handleProbe(&ProbeParams{Url: server.URL, Timeout: 2000, MaxBody: 64})

	if result == nil || result.Error != "" {
		t.Fatalf("result = %+v, want a success", result)
	}
	if result.StatusCode != http.StatusOK || result.Body != "routed" {
		t.Errorf("status = %d body = %q", result.StatusCode, result.Body)
	}
	if !slices.Equal(result.Chains, []string{"DIRECT"}) {
		t.Errorf("chains = %v, want the outbound the tunnel picked", result.Chains)
	}
}

// earlyDataProxy stands in for vmess, vless, Shadowsocks and the others whose
// handshake carries the client's first bytes; the tunnel waits 200ms for them.
type earlyDataProxy struct {
	constant.Proxy
	handshake chan []byte
}

func (p *earlyDataProxy) DialContext(ctx context.Context, metadata *constant.Metadata) (constant.Conn, error) {
	conn, err := p.Proxy.DialContext(ctx, metadata)
	if err != nil {
		return nil, err
	}
	return &earlyDataConn{Conn: conn, handshake: p.handshake}, nil
}

type earlyDataConn struct {
	constant.Conn
	handshake chan []byte
	sent      atomic.Bool
}

func (c *earlyDataConn) NeedHandshake() bool {
	return !c.sent.Load()
}

func (c *earlyDataConn) Write(b []byte) (int, error) {
	if !c.sent.Swap(true) {
		c.handshake <- slices.Clone(b)
	}
	return c.Conn.Write(b)
}

func TestHandleProbeSendsTheRequestWithTheHandshake(t *testing.T) {
	server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("routed"))
	})
	handshake := make(chan []byte, 1)
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"DIRECT": &earlyDataProxy{Proxy: namedProxy("DIRECT"), handshake: handshake},
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
	tunnel.OnRunning()
	t.Cleanup(tunnel.OnSuspend)

	result := handleProbe(&ProbeParams{Url: server.URL, Timeout: 2000, MaxBody: 64})

	if result == nil || result.Error != "" {
		t.Fatalf("result = %+v, want a success", result)
	}
	if first := <-handshake; len(first) == 0 {
		t.Error("the handshake went out empty: the request waited on the route while the tunnel waited on the request")
	}
	if !slices.Equal(result.Chains, []string{"DIRECT"}) {
		t.Errorf("chains = %v, want the outbound the tunnel picked", result.Chains)
	}
}

func TestHandleProbeWaitsOutASuspendedTunnel(t *testing.T) {
	server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("resumed"))
	})
	withProbeProxies(t, "DIRECT")
	tunnel.OnSuspend()
	t.Cleanup(tunnel.OnSuspend)
	time.AfterFunc(150*time.Millisecond, tunnel.OnRunning)

	result := handleProbe(&ProbeParams{Url: server.URL, Timeout: 2000, MaxBody: 64})

	if result == nil || result.Error != "" {
		t.Fatalf("result = %+v, want the answer once the tunnel runs again", result)
	}
	if result.Body != "resumed" {
		t.Errorf("body = %q", result.Body)
	}
}

func TestHandleProbeTimesOutWhileTheTunnelStaysSuspended(t *testing.T) {
	server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("unreachable"))
	})
	withProbeProxies(t, "DIRECT")
	tunnel.OnSuspend()

	result := handleProbe(&ProbeParams{Url: server.URL, Timeout: 200})

	if result == nil || result.Error != probeErrorTimeout {
		t.Fatalf("result = %+v, want a timeout", result)
	}
}

func TestProbeRequestsShareTheConnectionOfAServiceCheck(t *testing.T) {
	server, accepted := probeConnectionServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("region"))
	})
	withProbeProxies(t, "node-pool")
	forgetProbeConnections()
	t.Cleanup(forgetProbeConnections)

	// A check walks the same host in sequence: register a device, exchange the
	// assertion, ask the session. Each step is its own probe request.
	requests := []*ProbeParams{
		{Url: server.URL + "/devices", ProxyName: "node-pool", Timeout: 2000, MaxBody: 64},
		{Url: server.URL + "/token", ProxyName: "node-pool", Timeout: 2000, MaxBody: 64},
		{Url: server.URL + "/graphql", ProxyName: "node-pool", Timeout: 2000, MaxBody: 64},
	}
	for index, params := range requests {
		result := handleProbe(params)
		if result == nil || result.Error != "" {
			t.Fatalf("probe %d = %+v, want a success", index, result)
		}
		if result.Body != "region" {
			t.Errorf("probe %d body = %q", index, result.Body)
		}
		if !slices.Equal(result.Chains, []string{"node-pool"}) {
			t.Errorf("probe %d chains = %v, want the proxy it went through", index, result.Chains)
		}
	}

	if got := accepted.Load(); got != 1 {
		t.Errorf("connections accepted = %d, want the requests after the first to reuse it", got)
	}
}

func TestProbeConnectionsAreKeyedByTheTrustTheyCarry(t *testing.T) {
	forgetProbeConnections()
	t.Cleanup(forgetProbeConnections)

	plain, err := probeConnsFor(probeConnsKey{})
	if err != nil {
		t.Fatalf("probeConnsFor: %v", err)
	}
	zeroTrust, err := probeConnsFor(probeConnsKey{tls: ca.Option{ZeroTrust: true}})
	if err != nil {
		t.Fatalf("probeConnsFor zero trust: %v", err)
	}
	if plain == zeroTrust {
		t.Error("a differing trust was answered with the same transport, so it inherited the other handshakes")
	}
}

func TestProbeConnectionsPoolStaysBounded(t *testing.T) {
	forgetProbeConnections()
	t.Cleanup(forgetProbeConnections)

	for index := 0; index < probeConnsPoolSize+2; index++ {
		proxy := namedProxy(fmt.Sprintf("pool-%d", index))
		if _, err := probeConnsFor(probeConnsKey{proxy: proxy}); err != nil {
			t.Fatalf("probeConnsFor %d: %v", index, err)
		}
	}

	probeConnsMu.Lock()
	size := len(probeConnsPool)
	probeConnsMu.Unlock()
	if size > probeConnsPoolSize {
		t.Errorf("pool size = %d, want at most %d", size, probeConnsPoolSize)
	}
}
