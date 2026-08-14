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

type blockingResolver struct {
	active  atomic.Int32
	maximum atomic.Int32
	started chan struct{}
	release <-chan struct{}
}

func (resolver *blockingResolver) wait(ctx context.Context) error {
	current := resolver.active.Add(1)
	for {
		old := resolver.maximum.Load()
		if current <= old || resolver.maximum.CompareAndSwap(old, current) {
			break
		}
	}
	defer resolver.active.Add(-1)
	select {
	case resolver.started <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	}
	select {
	case <-resolver.release:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (resolver *blockingResolver) LookupIP(ctx context.Context, network, _ string) ([]net.IP, error) {
	if err := resolver.wait(ctx); err != nil {
		return nil, err
	}
	if network == "ip4" {
		return []net.IP{net.ParseIP("127.0.0.1")}, nil
	}
	return nil, nil
}

func (resolver *blockingResolver) LookupCNAME(ctx context.Context, _ string) (string, error) {
	if err := resolver.wait(ctx); err != nil {
		return "", err
	}
	return "", nil
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
	return startTLSServerWithALPN(t, domain, curves, []string{"h2", "http/1.1"}, handler)
}

func startTLSServerWithALPN(t *testing.T, domain string, curves []tls.CurveID, nextProtos []string, handler http.Handler) *localTLSServer {
	t.Helper()
	certificate, roots, _ := certificateFor(t, domain, 45*24*time.Hour)
	local := &localTLSServer{root: roots}
	server := httptest.NewUnstartedServer(handler)
	server.EnableHTTP2 = true
	server.TLS = &tls.Config{
		Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS13,
		MaxVersion: tls.VersionTLS13, CurvePreferences: curves,
		NextProtos: nextProtos,
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
		switch key {
		case "DOMAIN_CHECK_CONCURRENCY":
			return "12"
		case "DOMAIN_CHECK_READY_CONCURRENCY":
			return "3"
		}
		return ""
	})
	if err != nil || cfg.Concurrency != 12 || cfg.ReadyConcurrency != 3 {
		t.Fatalf("unexpected concurrency: workers=%d ready=%d err=%v", cfg.Concurrency, cfg.ReadyConcurrency, err)
	}
	for _, invalid := range []string{"0", "-1", "x", "257"} {
		if _, err := ConfigFromEnv(func(key string) string {
			if key == "DOMAIN_CHECK_CONCURRENCY" {
				return invalid
			}
			return ""
		}); err == nil {
			t.Errorf("accepted invalid concurrency %q", invalid)
		}
		if _, err := ConfigFromEnv(func(key string) string {
			if key == "DOMAIN_CHECK_READY_CONCURRENCY" {
				return invalid
			}
			return ""
		}); err == nil {
			t.Errorf("accepted invalid READY concurrency %q", invalid)
		}
	}
	defaultConfig, err := ConfigFromEnv(func(string) string { return "" })
	if err != nil || defaultConfig.Concurrency != 24 || defaultConfig.DNSConcurrency != 24 || defaultConfig.ReadyConcurrency != 4 {
		t.Fatalf("default concurrency: workers=%d dns=%d ready=%d err=%v", defaultConfig.Concurrency, defaultConfig.DNSConcurrency, defaultConfig.ReadyConcurrency, err)
	}
	if defaultConfig.ResponseHeaderTimeout != 2*time.Second || defaultConfig.HTTPTimeout != 2500*time.Millisecond {
		t.Fatalf("unexpected HTTP budgets: headers=%v overall=%v", defaultConfig.ResponseHeaderTimeout, defaultConfig.HTTPTimeout)
	}
	if defaultConfig.TCPTimeout != 2500*time.Millisecond {
		t.Fatalf("unexpected TCP timeout: %v", defaultConfig.TCPTimeout)
	}
	invalidDNSConfig := DefaultConfig()
	invalidDNSConfig.DNSConcurrency = 0
	if _, err := New(invalidDNSConfig); err == nil {
		t.Fatal("accepted zero DNS concurrency")
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
	cfg := configForServer(server, resolver)
	realDial := (&net.Dialer{}).DialContext
	var dials atomic.Int32
	cfg.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		dials.Add(1)
		return realDial(ctx, network, address)
	}
	detector, _ := New(cfg)
	result := detector.Check(context.Background(), domain)
	if result.TLS13 != Pass || result.H2 != Pass || result.CertDays == "FAIL" || result.X25519 != Fail || result.ReadyMS != "-" || result.HTTP != "204" || result.Result != Fail {
		t.Fatalf("fallback diagnostic granularity changed: %+v", result)
	}
	if !containsReason(result, "强制 X25519 握手失败") || containsReason(result, "TLS 1.3 握手失败") {
		t.Fatalf("unexpected fallback reasons: %+v", result.Reasons)
	}
	if containsReason(result, "连接就绪计时样本不足") {
		t.Fatalf("known X25519 failure retained a meaningless READY warning: %+v", result.Reasons)
	}
	if dials.Load() != 4 {
		t.Fatalf("X25519 failure invoked READY probes: dials=%d, want TCP + PRIMARY + fallback + HTTP", dials.Load())
	}
}

func TestH2FailureSkipsReadyButKeepsHTTPDiagnostics(t *testing.T) {
	const domain = "no-h2.test"
	server := startTLSServerWithALPN(t, domain, []tls.CurveID{tls.X25519}, []string{"http/1.1"}, http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusNoContent)
	}))
	cfg := configForServer(server, &fakeResolver{ipv4: []net.IP{net.ParseIP("127.0.0.1")}})
	realDial := (&net.Dialer{}).DialContext
	var dials atomic.Int32
	cfg.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		dials.Add(1)
		return realDial(ctx, network, address)
	}
	detector, _ := New(cfg)
	result := detector.Check(context.Background(), domain)

	if result.TLS13 != Pass || result.X25519 != Pass || result.H2 != Fail || result.CertDays == "FAIL" || result.ReadyMS != "-" || result.HTTP != "204" || result.Result != Fail {
		t.Fatalf("H2 failure diagnostics changed: %+v", result)
	}
	if !containsReason(result, "ALPN 未协商 h2") || containsReason(result, "连接就绪计时样本不足") {
		t.Fatalf("unexpected H2 failure reasons: %+v", result.Reasons)
	}
	if dials.Load() != 3 {
		t.Fatalf("H2 failure invoked READY probes: dials=%d, want TCP + PRIMARY + HTTP", dials.Load())
	}
}

func TestCertificateFailureSkipsReadyButKeepsHTTPDiagnostics(t *testing.T) {
	const domain = "expired-for-detector.test"
	server := startTLSServer(t, domain, []tls.CurveID{tls.X25519}, http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusNoContent)
	}))
	cfg := configForServer(server, &fakeResolver{ipv4: []net.IP{net.ParseIP("127.0.0.1")}})
	cfg.Now = func() time.Time { return time.Now().Add(90 * 24 * time.Hour) }
	realDial := (&net.Dialer{}).DialContext
	var dials atomic.Int32
	cfg.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		dials.Add(1)
		return realDial(ctx, network, address)
	}
	detector, _ := New(cfg)
	result := detector.Check(context.Background(), domain)

	if result.TLS13 != Pass || result.X25519 != Pass || result.H2 != Pass || result.CertDays != "FAIL" || result.ReadyMS != "-" || result.HTTP != "204" || result.Result != Fail {
		t.Fatalf("certificate failure diagnostics changed: %+v", result)
	}
	if !containsReason(result, "证书链、有效期或主机名验证失败") || containsReason(result, "连接就绪计时样本不足") {
		t.Fatalf("unexpected certificate failure reasons: %+v", result.Reasons)
	}
	if dials.Load() != 3 {
		t.Fatalf("certificate failure invoked READY probes: dials=%d, want TCP + PRIMARY + HTTP", dials.Load())
	}
}

func TestDNSConcurrencyLimiter(t *testing.T) {
	const domainWorkers = 24
	domains := make([]string, domainWorkers)
	for index := range domains {
		domains[index] = fmt.Sprintf("dns-%d.test", index)
	}

	for _, limit := range []int{1, 8, DefaultConfig().DNSConcurrency} {
		t.Run(fmt.Sprintf("limit_%d", limit), func(t *testing.T) {
			release := make(chan struct{})
			var releaseOnce sync.Once
			t.Cleanup(func() { releaseOnce.Do(func() { close(release) }) })
			resolver := &blockingResolver{
				started: make(chan struct{}, 3*domainWorkers),
				release: release,
			}
			cfg := DefaultConfig()
			cfg.DNSConcurrency = limit
			cfg.DNSTimeout = 2 * time.Second
			cfg.Resolver = resolver
			detector, err := New(cfg)
			if err != nil {
				t.Fatal(err)
			}

			done := make(chan []Result, 1)
			go func() {
				done <- runPool(context.Background(), domains, domainWorkers, func(ctx context.Context, domain string) Result {
					target, resolveErr := detector.resolve(ctx, domain)
					status := Pass
					if resolveErr != nil || target.IP == nil {
						status = Fail
					}
					return Result{Domain: domain, Result: status}
				}, nil)
			}()

			for range limit {
				select {
				case <-resolver.started:
				case <-time.After(time.Second):
					t.Fatalf("DNS limiter did not fill %d slots", limit)
				}
			}
			select {
			case <-resolver.started:
				t.Errorf("DNS concurrency exceeded limit %d", limit)
			case <-time.After(30 * time.Millisecond):
			}
			releaseOnce.Do(func() { close(release) })

			select {
			case results := <-done:
				if len(results) != len(domains) {
					t.Fatalf("DNS run returned %d results, want %d", len(results), len(domains))
				}
				for index, result := range results {
					if result.Domain != domains[index] || result.Result != Pass {
						t.Fatalf("DNS result %d changed: %+v", index, result)
					}
				}
			case <-time.After(2 * time.Second):
				t.Fatal("DNS-limited run did not finish")
			}
			if resolver.maximum.Load() != int32(limit) || resolver.active.Load() != 0 {
				t.Fatalf("DNS concurrency max=%d active=%d, want max=%d active=0", resolver.maximum.Load(), resolver.active.Load(), limit)
			}
		})
	}
}

func TestDNSLimiterWaitHonorsCancellation(t *testing.T) {
	cfg := DefaultConfig()
	cfg.DNSConcurrency = 1
	resolver := &fakeResolver{ipv4: []net.IP{net.ParseIP("127.0.0.1")}}
	cfg.Resolver = resolver
	detector, _ := New(cfg)
	detector.dnsSlots <- struct{}{}
	defer func() { <-detector.dnsSlots }()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	started := time.Now()
	if _, err := detector.resolve(ctx, "dns-cancel.test"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("DNS wait cancellation error = %v", err)
	}
	if elapsed := time.Since(started); elapsed < 20*time.Millisecond || elapsed > 200*time.Millisecond {
		t.Fatalf("DNS wait cancellation elapsed=%v", elapsed)
	}
	time.Sleep(10 * time.Millisecond)
	resolver.mu.Lock()
	calls := len(resolver.calls)
	resolver.mu.Unlock()
	if calls != 0 {
		t.Fatalf("resolver was called without a DNS slot: %d calls", calls)
	}
}

func TestDNSLimiterQueueDoesNotConsumeLookupTimeout(t *testing.T) {
	cfg := DefaultConfig()
	cfg.DNSConcurrency = 1
	cfg.DNSTimeout = 40 * time.Millisecond
	resolver := &fakeResolver{ipv4: []net.IP{net.ParseIP("127.0.0.1")}}
	cfg.Resolver = resolver
	detector, _ := New(cfg)
	detector.dnsSlots <- struct{}{}
	var releaseOnce sync.Once
	releaseSlot := func() { releaseOnce.Do(func() { <-detector.dnsSlots }) }
	defer releaseSlot()

	type resolution struct {
		target resolvedTarget
		err    error
	}
	done := make(chan resolution, 1)
	go func() {
		target, err := detector.resolve(context.Background(), "dns-queued.test")
		done <- resolution{target: target, err: err}
	}()

	select {
	case result := <-done:
		t.Fatalf("DNS queue wait consumed lookup timeout: %+v", result)
	case <-time.After(100 * time.Millisecond):
	}
	releaseSlot()
	select {
	case result := <-done:
		if result.err != nil || result.target.IP == nil {
			t.Fatalf("DNS lookup failed after queue released: %+v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("DNS lookup did not run after queue released")
	}
	resolver.mu.Lock()
	calls := len(resolver.calls)
	resolver.mu.Unlock()
	if calls != 3 {
		t.Fatalf("DNS lookup calls=%d, want A + AAAA + CNAME", calls)
	}
}

func TestDNSLookupExecutionStillHasTimeout(t *testing.T) {
	release := make(chan struct{})
	defer close(release)
	resolver := &blockingResolver{started: make(chan struct{}, 3), release: release}
	cfg := DefaultConfig()
	cfg.DNSConcurrency = 3
	cfg.DNSTimeout = 40 * time.Millisecond
	cfg.Resolver = resolver
	detector, _ := New(cfg)

	started := time.Now()
	if target, err := detector.resolve(context.Background(), "dns-timeout.test"); err == nil || target.IP != nil {
		t.Fatalf("stalled DNS lookup unexpectedly succeeded: target=%+v err=%v", target, err)
	}
	if elapsed := time.Since(started); elapsed < 30*time.Millisecond || elapsed > 250*time.Millisecond {
		t.Fatalf("DNS execution timeout elapsed=%v", elapsed)
	}
	if resolver.maximum.Load() != 3 || resolver.active.Load() != 0 {
		t.Fatalf("stalled DNS lookup cleanup max=%d active=%d", resolver.maximum.Load(), resolver.active.Load())
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

func TestReadyConcurrencyLimiter(t *testing.T) {
	updateMaximum := func(maximum *atomic.Int32, current int32) {
		for {
			old := maximum.Load()
			if current <= old || maximum.CompareAndSwap(old, current) {
				return
			}
		}
	}

	for _, readyConcurrency := range []int{1, 2} {
		t.Run(fmt.Sprintf("limit_%d", readyConcurrency), func(t *testing.T) {
			cfg := DefaultConfig()
			cfg.ReadyConcurrency = readyConcurrency
			detector, err := New(cfg)
			if err != nil {
				t.Fatal(err)
			}

			const workers = 8
			var overallActive atomic.Int32
			var overallMaximum atomic.Int32
			var readyActive atomic.Int32
			var readyMaximum atomic.Int32
			var arrived sync.WaitGroup
			var finished sync.WaitGroup
			arrived.Add(workers)
			finished.Add(workers)
			start := make(chan struct{})
			for range workers {
				go func() {
					defer finished.Done()
					current := overallActive.Add(1)
					updateMaximum(&overallMaximum, current)
					arrived.Done()
					<-start
					samples := detector.collectReady(context.Background(), func(context.Context) (time.Duration, error) {
						current := readyActive.Add(1)
						updateMaximum(&readyMaximum, current)
						time.Sleep(5 * time.Millisecond)
						readyActive.Add(-1)
						return 7 * time.Millisecond, nil
					})
					overallActive.Add(-1)
					if len(samples) != 3 {
						t.Errorf("READY samples = %d, want 3", len(samples))
					}
				}()
			}
			arrived.Wait()
			close(start)
			finished.Wait()
			if overallMaximum.Load() != workers {
				t.Fatalf("overall concurrency = %d, want %d", overallMaximum.Load(), workers)
			}
			if readyMaximum.Load() != int32(readyConcurrency) {
				t.Fatalf("READY concurrency = %d, want %d", readyMaximum.Load(), readyConcurrency)
			}
		})
	}
}

func TestReadySlotCoversAllSamplesAndExcludesWait(t *testing.T) {
	cfg := DefaultConfig()
	cfg.ReadyConcurrency = 1
	detector, _ := New(cfg)

	var eventsMu sync.Mutex
	var events []string
	firstStarted := make(chan struct{})
	var firstCount atomic.Int32
	var secondCount atomic.Int32
	firstDone := make(chan []time.Duration, 1)
	secondDone := make(chan []time.Duration, 1)

	go func() {
		firstDone <- detector.collectReady(context.Background(), func(context.Context) (time.Duration, error) {
			attempt := firstCount.Add(1)
			eventsMu.Lock()
			events = append(events, fmt.Sprintf("a%d", attempt))
			eventsMu.Unlock()
			if attempt == 1 {
				close(firstStarted)
			}
			time.Sleep(10 * time.Millisecond)
			return 5 * time.Millisecond, nil
		})
	}()
	<-firstStarted
	waitStarted := time.Now()
	go func() {
		secondDone <- detector.collectReady(context.Background(), func(context.Context) (time.Duration, error) {
			attempt := secondCount.Add(1)
			eventsMu.Lock()
			events = append(events, fmt.Sprintf("b%d", attempt))
			eventsMu.Unlock()
			return 7 * time.Millisecond, nil
		})
	}()

	firstSamples := <-firstDone
	secondSamples := <-secondDone
	if len(firstSamples) != 3 || len(secondSamples) != 3 {
		t.Fatalf("unexpected sample counts: first=%d second=%d", len(firstSamples), len(secondSamples))
	}
	if waited := time.Since(waitStarted); waited < 15*time.Millisecond {
		t.Fatalf("second domain did not wait for the first READY group: %v", waited)
	}
	eventsMu.Lock()
	sequence := strings.Join(events, ",")
	eventsMu.Unlock()
	if sequence != "a1,a2,a3,b1,b2,b3" {
		t.Fatalf("READY samples interleaved across domains: %s", sequence)
	}
	if readyMS, ok := aggregateReady(secondSamples); !ok || readyMS != 7 {
		t.Fatalf("semaphore wait contaminated READY: %d,%v", readyMS, ok)
	}
}

func TestReadySlotReleaseAndWaitCancellation(t *testing.T) {
	cfg := DefaultConfig()
	cfg.ReadyConcurrency = 1
	detector, _ := New(cfg)

	failed := detector.collectReady(context.Background(), func(context.Context) (time.Duration, error) {
		return 0, errors.New("READY failed")
	})
	if len(failed) != 0 {
		t.Fatalf("failed READY samples = %v", failed)
	}
	succeeded := detector.collectReady(context.Background(), func(context.Context) (time.Duration, error) {
		return time.Millisecond, nil
	})
	if len(succeeded) != 3 {
		t.Fatalf("READY slot was not released after failure: %v", succeeded)
	}

	detector.readySlots <- struct{}{}
	defer func() { <-detector.readySlots }()
	var probeCalls atomic.Int32
	probe := func(context.Context) (time.Duration, error) {
		probeCalls.Add(1)
		return time.Millisecond, nil
	}

	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	started := time.Now()
	if samples := detector.collectReady(canceled, probe); len(samples) != 0 {
		t.Fatalf("canceled READY wait returned samples: %v", samples)
	}
	if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
		t.Fatalf("canceled READY wait was delayed: %v", elapsed)
	}

	deadline, cancelDeadline := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancelDeadline()
	started = time.Now()
	if samples := detector.collectReady(deadline, probe); len(samples) != 0 {
		t.Fatalf("expired domain wait returned samples: %v", samples)
	}
	if elapsed := time.Since(started); elapsed < 20*time.Millisecond || elapsed > 200*time.Millisecond {
		t.Fatalf("domain deadline while waiting elapsed=%v", elapsed)
	}
	if probeCalls.Load() != 0 {
		t.Fatalf("READY probe ran without acquiring a slot: %d", probeCalls.Load())
	}
}

func TestReadyLimiterDoesNotAffectPrimaryTLSOrHTTP(t *testing.T) {
	const domain = "ready-isolation.test"
	server := startTLSServer(t, domain, []tls.CurveID{tls.X25519}, http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusNoContent)
	}))
	cfg := configForServer(server, &fakeResolver{})
	cfg.ReadyConcurrency = 1
	detector, _ := New(cfg)
	detector.readySlots <- struct{}{}
	defer func() { <-detector.readySlots }()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	tlsResult, tlsOK := detector.probeTLSWithFallback(ctx, domain, net.ParseIP("127.0.0.1"))
	if !tlsOK || !tlsResult.TLS13 || !tlsResult.X25519 || !tlsResult.H2 || !tlsResult.Cert {
		t.Fatalf("READY limiter affected PRIMARY TLS: %+v ok=%v", tlsResult, tlsOK)
	}
	httpResult := detector.probeHTTP(ctx, domain, net.ParseIP("127.0.0.1"))
	if !httpResult.OK || httpResult.Code != http.StatusNoContent || httpResult.Attempts != 1 {
		t.Fatalf("READY limiter affected HTTP: %+v", httpResult)
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

func TestHTTPBashCompatibleRequestAndNoRedirectFollow(t *testing.T) {
	const domain = "request.test"
	const expectedUserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0 Safari/537.36"
	type observedRequest struct {
		userAgent      string
		accept         string
		acceptEncoding string
		host           string
		path           string
		protoMajor     int
	}
	observed := make(chan observedRequest, 2)
	server := startTLSServer(t, domain, []tls.CurveID{tls.X25519}, http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		observed <- observedRequest{
			userAgent:      request.Header.Get("User-Agent"),
			accept:         request.Header.Get("Accept"),
			acceptEncoding: request.Header.Get("Accept-Encoding"),
			host:           request.Host,
			path:           request.URL.Path,
			protoMajor:     request.ProtoMajor,
		}
		writer.Header().Set("Location", "/followed")
		writer.WriteHeader(http.StatusFound)
	}))
	cfg := configForServer(server, &fakeResolver{})
	realDial := (&net.Dialer{}).DialContext
	var addressesMu sync.Mutex
	var addresses []string
	cfg.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		addressesMu.Lock()
		addresses = append(addresses, address)
		addressesMu.Unlock()
		return realDial(ctx, network, address)
	}
	detector, _ := New(cfg)
	outcome := detector.probeHTTP(context.Background(), domain, net.ParseIP("127.0.0.1"))
	if !outcome.OK || outcome.Code != http.StatusFound || outcome.Attempts != 1 || outcome.Location != "/followed" {
		t.Fatalf("redirect handling changed: %+v", outcome)
	}

	request := <-observed
	if request.userAgent != expectedUserAgent {
		t.Errorf("User-Agent = %q, want %q", request.userAgent, expectedUserAgent)
	}
	if request.accept != "*/*" {
		t.Errorf("Accept = %q, want */*", request.accept)
	}
	if request.acceptEncoding != "" {
		t.Errorf("automatic compression was enabled: Accept-Encoding=%q", request.acceptEncoding)
	}
	if request.host != domain || request.path != "/" {
		t.Errorf("HTTP authority/path changed: host=%q path=%q", request.host, request.path)
	}
	if request.protoMajor != 2 {
		t.Errorf("HTTP/2 behavior changed: protocol major=%d", request.protoMajor)
	}
	select {
	case followed := <-observed:
		t.Fatalf("redirect was followed: %+v", followed)
	default:
	}
	addressesMu.Lock()
	defer addressesMu.Unlock()
	if len(addresses) != 1 || addresses[0] != net.JoinHostPort("127.0.0.1", server.port) {
		t.Fatalf("HTTP escaped pinned IP: %v", addresses)
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

func TestTCPTimeoutAndCancellation(t *testing.T) {
	t.Run("stalled target stops at TCP timeout", func(t *testing.T) {
		cfg := DefaultConfig()
		cfg.Resolver = &fakeResolver{ipv4: []net.IP{net.ParseIP("192.0.2.10")}}
		cfg.TCPTimeout = 50 * time.Millisecond
		var calls atomic.Int32
		cfg.DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
			calls.Add(1)
			<-ctx.Done()
			return nil, ctx.Err()
		}
		detector, _ := New(cfg)
		started := time.Now()
		result := detector.Check(context.Background(), "tcp-timeout.test")
		elapsed := time.Since(started)
		if elapsed < 40*time.Millisecond || elapsed > 250*time.Millisecond {
			t.Fatalf("TCP timeout elapsed=%v, want approximately %v", elapsed, cfg.TCPTimeout)
		}
		if result.Result != Fail || calls.Load() != 1 || !containsReason(result, "TCP 443 不可达") {
			t.Fatalf("TCP timeout did not fail fast before TLS/READY/HTTP: %+v calls=%d", result, calls.Load())
		}
	})

	t.Run("fast failure returns immediately", func(t *testing.T) {
		cfg := DefaultConfig()
		cfg.Resolver = &fakeResolver{ipv4: []net.IP{net.ParseIP("192.0.2.11")}}
		var calls atomic.Int32
		cfg.DialContext = func(context.Context, string, string) (net.Conn, error) {
			calls.Add(1)
			return nil, syscall.ECONNREFUSED
		}
		detector, _ := New(cfg)
		started := time.Now()
		result := detector.Check(context.Background(), "tcp-refused.test")
		if elapsed := time.Since(started); elapsed > 250*time.Millisecond {
			t.Fatalf("fast TCP failure waited for timeout: %v", elapsed)
		}
		if result.Result != Fail || calls.Load() != 1 || !containsReason(result, "TCP 443 不可达") {
			t.Fatalf("TCP fast failure changed: %+v calls=%d", result, calls.Load())
		}
	})

	t.Run("successful connection is accepted", func(t *testing.T) {
		cfg := DefaultConfig()
		cfg.DialContext = func(context.Context, string, string) (net.Conn, error) {
			client, server := net.Pipe()
			go func() { _ = server.Close() }()
			return client, nil
		}
		detector, _ := New(cfg)
		if err := detector.probeTCP(context.Background(), net.ParseIP("192.0.2.12")); err != nil {
			t.Fatalf("healthy TCP connection rejected: %v", err)
		}
	})

	t.Run("parent cancellation wins", func(t *testing.T) {
		cfg := DefaultConfig()
		cfg.TCPTimeout = time.Second
		cfg.DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
			<-ctx.Done()
			return nil, ctx.Err()
		}
		detector, _ := New(cfg)
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		started := time.Now()
		err := detector.probeTCP(ctx, net.ParseIP("192.0.2.13"))
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("probeTCP cancellation error = %v", err)
		}
		if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
			t.Fatalf("parent cancellation was delayed: %v", elapsed)
		}
	})
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

func TestMixedBatch100TargetsBoundedOrderedAndComplete(t *testing.T) {
	const (
		total   = 100
		workers = 24
	)
	domains := make([]string, total)
	indices := make(map[string]int, total)
	for index := range domains {
		domains[index] = fmt.Sprintf("mixed-%03d.test", index)
		indices[domains[index]] = index
	}

	var active atomic.Int32
	var maximum atomic.Int32
	var entered atomic.Int32
	var progressCalls atomic.Int32
	var firstWave sync.WaitGroup
	firstWave.Add(workers)
	start := make(chan struct{})
	var seenMu sync.Mutex
	seen := make(map[string]int, total)

	check := func(_ context.Context, domain string) Result {
		current := active.Add(1)
		for {
			old := maximum.Load()
			if current <= old || maximum.CompareAndSwap(old, current) {
				break
			}
		}
		defer active.Add(-1)
		if entered.Add(1) <= workers {
			firstWave.Done()
			<-start
		}
		seenMu.Lock()
		seen[domain]++
		seenMu.Unlock()

		index := indices[domain]
		switch index % 5 {
		case 0: // Fast PASS target.
			return Result{Domain: domain, TLS13: Pass, X25519: Pass, H2: Pass, ReadyMS: "5", CertDays: "30", HTTP: "200", Result: Pass}
		case 1: // Immediate TLS failure.
			return Result{Domain: domain, ReadyMS: "-", Result: Fail, Reasons: []Reason{{Fail, "TLS 1.3 握手失败"}}}
		case 2: // Conclusive X25519 failure; READY must remain absent.
			return Result{Domain: domain, TLS13: Pass, X25519: Fail, H2: Pass, ReadyMS: "-", CertDays: "30", HTTP: "204", Result: Fail, Reasons: []Reason{{Fail, "强制 X25519 握手失败"}}}
		case 3: // One bounded slow timeout, not three sequential READY waits.
			time.Sleep(25 * time.Millisecond)
			return Result{Domain: domain, ReadyMS: "-", Result: Fail, Reasons: []Reason{{Fail, "TCP 443 不可达"}}}
		default: // DNS failure.
			return Result{Domain: domain, ReadyMS: "-", Result: Fail, Reasons: []Reason{{Fail, "DNS 无法解析"}}}
		}
	}

	done := make(chan []Result, 1)
	started := time.Now()
	go func() {
		done <- runPool(context.Background(), domains, workers, check, func(_, _ int, _ string) {
			progressCalls.Add(1)
		})
	}()
	firstWave.Wait()
	if maximum.Load() != workers {
		t.Fatalf("mixed batch worker concurrency=%d, want %d", maximum.Load(), workers)
	}
	close(start)

	var results []Result
	select {
	case results = <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("100-target mixed batch exceeded its bounded runtime")
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("100-target mixed batch took %v", elapsed)
	}
	if active.Load() != 0 || entered.Load() != total || progressCalls.Load() != total {
		t.Fatalf("worker shutdown/completion mismatch: active=%d entered=%d progress=%d", active.Load(), entered.Load(), progressCalls.Load())
	}
	if len(results) != total || len(seen) != total {
		t.Fatalf("missing results: results=%d unique=%d", len(results), len(seen))
	}
	for index, result := range results {
		if result.Domain != domains[index] || seen[result.Domain] != 1 {
			t.Fatalf("result ordering/duplication changed at %d: %+v seen=%d", index, result, seen[result.Domain])
		}
		if index%5 == 2 && (result.Result != Fail || result.ReadyMS != "-") {
			t.Fatalf("X25519 failure classification/READY changed at %d: %+v", index, result)
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
	PrintTable(&output, results, false)
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
	if strings.Contains(text, "\x1b[") {
		t.Fatal("non-TTY terminal output contains ANSI color")
	}
}

func TestTerminalTableColorsEveryStatusCell(t *testing.T) {
	results := []Result{{
		Domain: "color.example", IP: "203.0.113.8", TLS13: Pass, X25519: Warn, H2: Fail,
		ReadyMS: "42", CertDays: "FAIL", CDN: "-", HTTP: "200", Redirect: "-", Result: Warn,
	}}
	var output bytes.Buffer
	PrintTable(&output, results, true)
	text := output.String()
	for sequence, count := range map[string]int{
		"\x1b[32mPASS\x1b[0m": 1,
		"\x1b[33mWARN\x1b[0m": 2,
		"\x1b[31mFAIL\x1b[0m": 2,
	} {
		if strings.Count(text, sequence) != count {
			t.Fatalf("color sequence %q count = %d, want %d", sequence, strings.Count(text, sequence), count)
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
