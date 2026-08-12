package domaincheck

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

type fakeResolver struct {
	ipv4, ipv6 []net.IP
	cname      string
	mu         sync.Mutex
	calls      []string
}

func (resolver *fakeResolver) LookupIP(_ context.Context, network, host string) ([]net.IP, error) {
	resolver.mu.Lock()
	resolver.calls = append(resolver.calls, network+":"+host)
	resolver.mu.Unlock()
	if network == "ip4" {
		return resolver.ipv4, nil
	}
	return resolver.ipv6, nil
}

func (resolver *fakeResolver) LookupCNAME(_ context.Context, host string) (string, error) {
	resolver.mu.Lock()
	resolver.calls = append(resolver.calls, "cname:"+host)
	resolver.mu.Unlock()
	return resolver.cname, nil
}

func certificateFor(t *testing.T, domain string, validFor time.Duration) (tls.Certificate, *x509.CertPool, time.Time) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: domain},
		DNSNames: []string{domain}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(validFor),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true, IsCA: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := tls.X509KeyPair(
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}),
	)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	parsed, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	roots.AddCert(parsed)
	return certificate, roots, now
}

type localTLSServer struct {
	server *httptest.Server
	port   string
	root   *x509.CertPool
	snis   []string
	mu     sync.Mutex
}

func startTLSServer(t *testing.T, domain string, curves []tls.CurveID, handler http.Handler) *localTLSServer {
	t.Helper()
	certificate, roots, _ := certificateFor(t, domain, 45*24*time.Hour)
	local := &localTLSServer{root: roots}
	server := httptest.NewUnstartedServer(handler)
	server.EnableHTTP2 = true
	server.TLS = &tls.Config{
		Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS13,
		MaxVersion: tls.VersionTLS13, CurvePreferences: curves,
		NextProtos: []string{"h2", "http/1.1"},
		GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
			local.mu.Lock()
			local.snis = append(local.snis, hello.ServerName)
			local.mu.Unlock()
			return nil, nil
		},
	}
	server.StartTLS()
	local.server = server
	_, local.port, _ = net.SplitHostPort(server.Listener.Addr().String())
	t.Cleanup(server.Close)
	return local
}

func configForServer(server *localTLSServer, resolver Resolver) Config {
	cfg := DefaultConfig()
	cfg.Port = server.port
	cfg.RootCAs = server.root
	cfg.Resolver = resolver
	cfg.DomainTimeout = 5 * time.Second
	return cfg
}

func TestParseDomainsAndConcurrency(t *testing.T) {
	domains, err := ParseDomains("EXAMPLE.com/example.com/test.example")
	if err != nil || strings.Join(domains, ",") != "example.com,test.example" {
		t.Fatalf("unexpected domains: %v, %v", domains, err)
	}
	for _, invalid := range []string{"", "/example.com", "example.com/", "example.com//test.com", "1.1.1.1", "-bad.example"} {
		if _, err := ParseDomains(invalid); err == nil {
			t.Errorf("accepted invalid input %q", invalid)
		}
	}
	cfg, err := ConfigFromEnv(func(key string) string {
		if key == "DOMAIN_CHECK_CONCURRENCY" {
			return "12"
		}
		return ""
	})
	if err != nil || cfg.Concurrency != 12 {
		t.Fatalf("unexpected concurrency: %d, %v", cfg.Concurrency, err)
	}
	for _, invalid := range []string{"0", "-1", "x", "257"} {
		if _, err := ConfigFromEnv(func(string) string { return invalid }); err == nil {
			t.Errorf("accepted invalid concurrency %q", invalid)
		}
	}
	defaultConfig, err := ConfigFromEnv(func(string) string { return "" })
	if err != nil || defaultConfig.Concurrency != 8 {
		t.Fatalf("default concurrency = %d, %v", defaultConfig.Concurrency, err)
	}
	if defaultConfig.ResponseHeaderTimeout != 2*time.Second || defaultConfig.HTTPTimeout != 2500*time.Millisecond {
		t.Fatalf("unexpected HTTP budgets: headers=%v overall=%v", defaultConfig.ResponseHeaderTimeout, defaultConfig.HTTPTimeout)
	}
}

func TestNativeDetectorPrimaryReadyHTTPAndPinning(t *testing.T) {
	const domain = "example.test"
	var hostsMu sync.Mutex
	var hosts []string
	server := startTLSServer(t, domain, []tls.CurveID{tls.X25519}, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		hostsMu.Lock()
		hosts = append(hosts, request.Host)
		hostsMu.Unlock()
		writer.Header().Set("CF-Ray", "offline-SIN")
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write([]byte("body must not affect detection"))
	}))
	resolver := &fakeResolver{ipv4: []net.IP{net.ParseIP("127.0.0.1")}, ipv6: []net.IP{net.ParseIP("::1")}, cname: "edge.cloudflare.net."}
	cfg := configForServer(server, resolver)
	realDial := (&net.Dialer{}).DialContext
	var dialMu sync.Mutex
	var addresses []string
	cfg.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		dialMu.Lock()
		addresses = append(addresses, address)
		dialMu.Unlock()
		return realDial(ctx, network, address)
	}
	detector, _ := New(cfg)
	result := detector.Check(context.Background(), domain)
	if result.Result != Pass || result.TLS13 != Pass || result.X25519 != Pass || result.H2 != Pass || result.CertDays == "FAIL" || result.HTTP != "200" || result.CDN != "HIGH" {
		t.Fatalf("unexpected result: %+v", result)
	}
	if result.ReadyMS == "-" {
		t.Fatal("READY did not collect native TLS samples")
	}
	for _, address := range addresses {
		if address != net.JoinHostPort("127.0.0.1", server.port) {
			t.Fatalf("network phase escaped pinned IP: %s", address)
		}
	}
	if len(addresses) != 6 {
		t.Fatalf("expected TCP + PRIMARY + READYx3 + HTTP dials, got %d", len(addresses))
	}
	resolver.mu.Lock()
	calls := strings.Join(resolver.calls, ",")
	resolver.mu.Unlock()
	for _, expected := range []string{"ip4:" + domain, "ip6:" + domain, "cname:" + domain} {
		if !strings.Contains(calls, expected) {
			t.Errorf("missing DNS lookup %s in %s", expected, calls)
		}
	}
	server.mu.Lock()
	for _, sni := range server.snis {
		if sni != domain {
			t.Errorf("unexpected SNI %q", sni)
		}
	}
	server.mu.Unlock()
	hostsMu.Lock()
	if len(hosts) != 1 || hosts[0] != domain {
		t.Errorf("HTTP Host was not preserved: %v", hosts)
	}
	hostsMu.Unlock()
}

func TestPrimaryFallbackPreservesTLSH2AndCert(t *testing.T) {
	const domain = "fallback.test"
	server := startTLSServer(t, domain, []tls.CurveID{tls.CurveP256}, http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusNoContent)
	}))
	resolver := &fakeResolver{ipv4: []net.IP{net.ParseIP("127.0.0.1")}}
	detector, _ := New(configForServer(server, resolver))
	result := detector.Check(context.Background(), domain)
	if result.TLS13 != Pass || result.H2 != Pass || result.CertDays == "FAIL" || result.X25519 != Fail || result.Result != Fail {
		t.Fatalf("fallback diagnostic granularity changed: %+v", result)
	}
	if !containsReason(result, "强制 X25519 握手失败") || containsReason(result, "TLS 1.3 握手失败") {
		t.Fatalf("unexpected fallback reasons: %+v", result.Reasons)
	}
}

func TestReadyAggregation(t *testing.T) {
	tests := []struct {
		values []time.Duration
		want   int64
		ok     bool
	}{
		{[]time.Duration{30 * time.Millisecond, 10 * time.Millisecond, 20 * time.Millisecond}, 20, true},
		{[]time.Duration{10 * time.Millisecond, 21 * time.Millisecond}, 16, true},
		{[]time.Duration{17 * time.Millisecond}, 17, true},
		{nil, 0, false},
	}
	for _, test := range tests {
		got, ok := aggregateReady(test.values)
		if got != test.want || ok != test.ok {
			t.Errorf("aggregateReady(%v) = %d,%v", test.values, got, ok)
		}
	}
}

func TestHTTPHeadersOnlyRetryRedirectAndCDN(t *testing.T) {
	const domain = "http.test"
	var attempts atomic.Int32
	server := startTLSServer(t, domain, []tls.CurveID{tls.X25519}, http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		attempt := attempts.Add(1)
		if attempt == 1 {
			writer.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		writer.Header().Set("Location", "https://www.http.test/login")
		writer.Header().Set("X-Served-By", "cache-test")
		writer.Header().Set("X-Cache", "HIT")
		writer.WriteHeader(http.StatusFound)
		if flusher, ok := writer.(http.Flusher); ok {
			flusher.Flush()
		}
		time.Sleep(800 * time.Millisecond)
		_, _ = writer.Write([]byte(strings.Repeat("x", 1<<20)))
	}))
	detector, _ := New(configForServer(server, &fakeResolver{}))
	started := time.Now()
	outcome := detector.probeHTTP(context.Background(), domain, net.ParseIP("127.0.0.1"))
	if elapsed := time.Since(started); elapsed > 500*time.Millisecond {
		t.Fatalf("HTTP waited for response body: %v", elapsed)
	}
	if !outcome.OK || outcome.Code != http.StatusFound || outcome.Attempts != 2 || attempts.Load() != 2 {
		t.Fatalf("unexpected HTTP retry outcome: %+v attempts=%d", outcome, attempts.Load())
	}
	status, code, _ := classifyRedirect(domain, outcome)
	if status != Warn || code != "WWW" {
		t.Fatalf("unexpected redirect: %s %s", status, code)
	}
	cdn, _ := detectCDN("", outcome.Header)
	if cdn != "HIGH" {
		t.Fatalf("unexpected CDN result: %s", cdn)
	}
}

func TestFailFastAndDomainTimeout(t *testing.T) {
	resolver := &fakeResolver{ipv4: []net.IP{net.ParseIP("192.0.2.10")}}
	cfg := DefaultConfig()
	cfg.Resolver = resolver
	var calls atomic.Int32
	cfg.DialContext = func(context.Context, string, string) (net.Conn, error) {
		calls.Add(1)
		return nil, errors.New("offline")
	}
	detector, _ := New(cfg)
	result := detector.Check(context.Background(), "fail.test")
	if result.Result != Fail || calls.Load() != 1 || !containsReason(result, "TCP 443 不可达") {
		t.Fatalf("TCP fail-fast failed: %+v calls=%d", result, calls.Load())
	}

	cfg.DomainTimeout = 50 * time.Millisecond
	cfg.TCPTimeout = time.Second
	cfg.DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	detector, _ = New(cfg)
	started := time.Now()
	results := detector.Run(context.Background(), []string{"timeout.test"}, nil)
	if time.Since(started) > 300*time.Millisecond || results[0].Result != Fail {
		t.Fatalf("domain deadline failed: elapsed=%v result=%+v", time.Since(started), results[0])
	}
}

func TestDNSAndCertificateFailFast(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Resolver = &fakeResolver{}
	var calls atomic.Int32
	cfg.DialContext = func(context.Context, string, string) (net.Conn, error) {
		calls.Add(1)
		return nil, errors.New("must not dial")
	}
	detector, _ := New(cfg)
	result := detector.Check(context.Background(), "dns-fail.test")
	if result.Result != Fail || calls.Load() != 0 || !containsReason(result, "DNS 无法解析") {
		t.Fatalf("DNS fail-fast failed: %+v calls=%d", result, calls.Load())
	}

	server := startTLSServer(t, "certificate.test", []tls.CurveID{tls.X25519}, http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Error("HTTP must be skipped after strict certificate failure")
	}))
	cfg = configForServer(server, &fakeResolver{ipv4: []net.IP{net.ParseIP("127.0.0.1")}})
	detector, _ = New(cfg)
	result = detector.Check(context.Background(), "wrong-host.test")
	if result.Result != Fail || result.CertDays != "FAIL" || result.ReadyMS != "-" || result.HTTP != "-" || !containsReason(result, "证书链、有效期或主机名验证失败") {
		t.Fatalf("strict certificate fail-fast failed: %+v", result)
	}
}

func TestWorkerPoolConcurrencyCap(t *testing.T) {
	var active atomic.Int32
	var maximum atomic.Int32
	domains := make([]string, 24)
	for index := range domains {
		domains[index] = fmt.Sprintf("d%d.test", index)
	}
	results := runPool(context.Background(), domains, 4, func(_ context.Context, domain string) Result {
		current := active.Add(1)
		for {
			old := maximum.Load()
			if current <= old || maximum.CompareAndSwap(old, current) {
				break
			}
		}
		time.Sleep(15 * time.Millisecond)
		active.Add(-1)
		return Result{Domain: domain, Result: Pass}
	}, nil)
	if len(results) != len(domains) || maximum.Load() != 4 {
		t.Fatalf("worker cap = %d, results=%d", maximum.Load(), len(results))
	}
	for index, result := range results {
		if result.Domain != domains[index] {
			t.Fatalf("result order changed at %d: %s", index, result.Domain)
		}
	}
}

func TestHTTPTransportFailuresStopAfterOneAttempt(t *testing.T) {
	tests := []struct {
		name string
		dial func(context.Context, string, string) (net.Conn, error)
	}{
		{"immediate transport error", func(context.Context, string, string) (net.Conn, error) {
			return nil, errors.New("transport offline")
		}},
		{"connection reset", func(context.Context, string, string) (net.Conn, error) {
			return nil, syscall.ECONNRESET
		}},
		{"EOF before response", func(context.Context, string, string) (net.Conn, error) {
			return nil, io.EOF
		}},
		{"context deadline", func(ctx context.Context, _, _ string) (net.Conn, error) {
			<-ctx.Done()
			return nil, ctx.Err()
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := DefaultConfig()
			cfg.HTTPTimeout = 25 * time.Millisecond
			var attempts atomic.Int32
			cfg.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
				attempts.Add(1)
				return test.dial(ctx, network, address)
			}
			detector, _ := New(cfg)
			outcome := detector.probeHTTP(context.Background(), "http-fail.test", net.ParseIP("192.0.2.20"))
			if outcome.OK || outcome.Attempts != 1 || attempts.Load() != 1 || classifyHTTP(outcome) != "HTTP 请求失败" {
				t.Fatalf("transport failure was retried: %+v dials=%d", outcome, attempts.Load())
			}
		})
	}
}

func TestHTTPResponseHeaderTimeoutStopsAfterOneAttempt(t *testing.T) {
	const domain = "header-timeout.test"
	var attempts atomic.Int32
	server := startTLSServer(t, domain, []tls.CurveID{tls.X25519}, http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		attempts.Add(1)
		time.Sleep(150 * time.Millisecond)
		writer.WriteHeader(http.StatusOK)
	}))
	cfg := configForServer(server, &fakeResolver{})
	cfg.ResponseHeaderTimeout = 30 * time.Millisecond
	cfg.HTTPTimeout = 100 * time.Millisecond
	detector, _ := New(cfg)
	started := time.Now()
	outcome := detector.probeHTTP(context.Background(), domain, net.ParseIP("127.0.0.1"))
	if elapsed := time.Since(started); elapsed > 120*time.Millisecond {
		t.Fatalf("response-header timeout exceeded one attempt: %v", elapsed)
	}
	if outcome.OK || outcome.Attempts != 1 || attempts.Load() != 1 {
		t.Fatalf("response-header timeout was retried: %+v handlers=%d", outcome, attempts.Load())
	}
}

func TestHTTPRetriesOnlyReceived5xx(t *testing.T) {
	for _, status := range []int{http.StatusInternalServerError, http.StatusBadGateway, http.StatusServiceUnavailable} {
		t.Run(fmt.Sprintf("status_%d", status), func(t *testing.T) {
			const domain = "retry.test"
			var attempts atomic.Int32
			server := startTLSServer(t, domain, []tls.CurveID{tls.X25519}, http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
				attempts.Add(1)
				writer.WriteHeader(status)
			}))
			detector, _ := New(configForServer(server, &fakeResolver{}))
			outcome := detector.probeHTTP(context.Background(), domain, net.ParseIP("127.0.0.1"))
			if !outcome.OK || outcome.Code != status || outcome.Attempts != 2 || attempts.Load() != 2 {
				t.Fatalf("5xx retry policy changed: %+v handlers=%d", outcome, attempts.Load())
			}
		})
	}

	for _, status := range []int{http.StatusOK, http.StatusFound, http.StatusForbidden, http.StatusNotFound} {
		t.Run(fmt.Sprintf("status_%d", status), func(t *testing.T) {
			const domain = "no-retry.test"
			var attempts atomic.Int32
			server := startTLSServer(t, domain, []tls.CurveID{tls.X25519}, http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
				attempts.Add(1)
				writer.WriteHeader(status)
			}))
			detector, _ := New(configForServer(server, &fakeResolver{}))
			outcome := detector.probeHTTP(context.Background(), domain, net.ParseIP("127.0.0.1"))
			if !outcome.OK || outcome.Code != status || outcome.Attempts != 1 || attempts.Load() != 1 {
				t.Fatalf("non-5xx response was retried: %+v handlers=%d", outcome, attempts.Load())
			}
		})
	}
}

func TestHTTPTimeoutWarnPreservesCoreTLSResults(t *testing.T) {
	const domain = "timeout-warn.test"
	var attempts atomic.Int32
	server := startTLSServer(t, domain, []tls.CurveID{tls.X25519}, http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		attempts.Add(1)
		time.Sleep(150 * time.Millisecond)
		writer.WriteHeader(http.StatusOK)
	}))
	resolver := &fakeResolver{ipv4: []net.IP{net.ParseIP("127.0.0.1")}}
	cfg := configForServer(server, resolver)
	cfg.ResponseHeaderTimeout = 30 * time.Millisecond
	cfg.HTTPTimeout = 100 * time.Millisecond
	detector, _ := New(cfg)
	result := detector.Check(context.Background(), domain)
	if result.Result != Warn || result.TLS13 != Pass || result.X25519 != Pass || result.H2 != Pass || result.CertDays == "FAIL" || result.HTTP != "-" {
		t.Fatalf("HTTP timeout damaged core TLS result: %+v", result)
	}
	if attempts.Load() != 1 || !containsReason(result, "HTTP 请求失败") {
		t.Fatalf("HTTP timeout retry/warning changed: handlers=%d reasons=%+v", attempts.Load(), result.Reasons)
	}
}

func TestHTMLIsEscapedAndUnique(t *testing.T) {
	results := []Result{{
		Domain: "safe.example", IP: "203.0.113.1", TLS13: Pass, X25519: Pass, H2: Pass,
		ReadyMS: "20", CertDays: "30", CDN: "HIGH", HTTP: "302", Redirect: "CROSS", Result: Warn,
		Reasons: []Reason{{Warn, `remote & <tag> "quote" 'apostrophe'`}},
	}}
	var buffer bytes.Buffer
	if err := RenderHTML(&buffer, `safe.example/<input>&"'`, results, time.Unix(0, 0)); err != nil {
		t.Fatal(err)
	}
	html := buffer.String()
	for _, escaped := range []string{"&amp;", "&lt;tag&gt;", "&#34;quote&#34;", "&#39;apostrophe&#39;"} {
		if !strings.Contains(html, escaped) {
			t.Errorf("HTML missing escaped value %s", escaped)
		}
	}
	if strings.Contains(html, "remote & <tag>") {
		t.Fatal("HTML contains unescaped dynamic content")
	}
	home := t.TempDir()
	first, err := WriteHTMLLog(home, "safe.example", results, time.Unix(0, 0))
	if err != nil {
		t.Fatal(err)
	}
	second, err := WriteHTMLLog(home, "safe.example", results, time.Unix(0, 0))
	if err != nil || first == second {
		t.Fatalf("HTML logs are not unique: %q %q %v", first, second, err)
	}
	if _, err := os.Stat(filepath.Clean(first)); err != nil {
		t.Fatal(err)
	}
}

func TestTerminalTableContainsStableFieldsAndDetails(t *testing.T) {
	results := []Result{{
		Domain: "table.example", IP: "203.0.113.7", TLS13: Pass, X25519: Pass, H2: Pass,
		ReadyMS: "42", CertDays: "30", CDN: "-", HTTP: "200", Redirect: "-", Result: Warn,
		Reasons: []Reason{{Warn, "HTTP detail"}},
	}}
	var output bytes.Buffer
	PrintTable(&output, results)
	text := output.String()
	for _, field := range headers {
		if !strings.Contains(text, field) {
			t.Errorf("terminal table missing %s", field)
		}
	}
	for _, value := range []string{"table.example", "203.0.113.7", "42", "DETAILS", "HTTP detail"} {
		if !strings.Contains(text, value) {
			t.Errorf("terminal output missing %s", value)
		}
	}
}

func TestResultAndAuxiliaryClassifiers(t *testing.T) {
	result := Result{TLS13: Pass, X25519: Pass, H2: Pass, CertDays: "30", Reasons: []Reason{{Warn, "HTTP 403"}}}
	if finalStatus(result) != Warn {
		t.Fatal("auxiliary HTTP warning should produce WARN")
	}
	result.X25519 = Fail
	if finalStatus(result) != Fail {
		t.Fatal("core X25519 failure should produce FAIL")
	}
	if status, code, _ := classifyRedirect("example.com", httpOutcome{OK: true, Code: 301, Location: "/login"}); status != Warn || code != "RELATIVE" {
		t.Fatalf("relative redirect classification changed: %s %s", status, code)
	}
	if status, code, _ := classifyRedirect("example.com", httpOutcome{OK: true, Code: 301}); status != Warn || code != "NO-LOC" {
		t.Fatalf("missing Location classification changed: %s %s", status, code)
	}
	if cdn, detail := detectCDN("asset.b-cdn.net", nil); cdn != "HIGH" || !strings.Contains(detail, "Bunny") {
		t.Fatalf("CNAME CDN detection changed: %s %s", cdn, detail)
	}
}

func containsReason(result Result, text string) bool {
	for _, reason := range result.Reasons {
		if reason.Text == text {
			return true
		}
	}
	return false
}
