package domaincheck

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

type Detector struct {
	cfg        Config
	dnsSlots   chan struct{}
	readySlots chan struct{}
}

const bashCompatibleUserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0 Safari/537.36"

func New(cfg Config) (*Detector, error) {
	if cfg.Concurrency < 1 || cfg.DNSConcurrency < 1 || cfg.ReadyConcurrency < 1 || cfg.Port == "" || cfg.Resolver == nil ||
		cfg.DialContext == nil || cfg.Now == nil {
		return nil, errors.New("invalid detector configuration")
	}
	return &Detector{
		cfg:        cfg,
		dnsSlots:   make(chan struct{}, cfg.DNSConcurrency),
		readySlots: make(chan struct{}, cfg.ReadyConcurrency),
	}, nil
}

func (d *Detector) Run(ctx context.Context, domains []string, progress func(int, int, string)) []Result {
	return runPool(ctx, domains, d.cfg.Concurrency, func(ctx context.Context, domain string) Result {
		domainCtx, cancel := context.WithTimeout(ctx, d.cfg.DomainTimeout)
		defer cancel()
		return d.Check(domainCtx, domain)
	}, progress)
}

func runPool(ctx context.Context, domains []string, workers int, check func(context.Context, string) Result, progress func(int, int, string)) []Result {
	type job struct {
		index  int
		domain string
	}
	type completed struct {
		index  int
		result Result
	}
	jobs := make(chan job)
	done := make(chan completed)
	var wg sync.WaitGroup
	if workers > len(domains) {
		workers = len(domains)
	}
	if workers < 1 {
		workers = 1
	}
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for item := range jobs {
				done <- completed{item.index, check(ctx, item.domain)}
			}
		}()
	}
	go func() {
		for index, domain := range domains {
			jobs <- job{index, domain}
		}
		close(jobs)
		wg.Wait()
		close(done)
	}()
	results := make([]Result, len(domains))
	count := 0
	for item := range done {
		results[item.index] = item.result
		count++
		if progress != nil {
			progress(count, len(domains), item.result.Domain)
		}
	}
	return results
}

func (d *Detector) Check(ctx context.Context, domain string) Result {
	result := Result{
		Domain: domain, IP: "-", TLS13: Fail, X25519: Fail, H2: Fail,
		ReadyMS: "-", CertDays: "-", CDN: "-", HTTP: "-", Redirect: "-", Result: Pass,
	}
	target, err := d.resolve(ctx, domain)
	if err != nil || target.IP == nil {
		result.Result = Fail
		result.Reasons = append(result.Reasons, Reason{Fail, "DNS 无法解析"})
		return result
	}
	result.IP = target.IP.String()
	if err := d.probeTCP(ctx, target.IP); err != nil {
		result.Result = Fail
		result.Reasons = append(result.Reasons, Reason{Fail, "TCP 443 不可达"})
		return result
	}

	tlsResult, tlsOK := d.probeTLSWithFallback(ctx, domain, target.IP)
	if tlsResult.TLS13 {
		result.TLS13 = Pass
	}
	if tlsResult.X25519 {
		result.X25519 = Pass
	}
	if tlsResult.H2 {
		result.H2 = Pass
	}
	if tlsResult.Cert {
		result.CertDays = fmt.Sprintf("%d", tlsResult.CertDays)
	} else {
		result.CertDays = "FAIL"
	}
	if !tlsOK {
		addCoreTLSReasons(&result, tlsResult)
		result.Result = Fail
		return result
	}

	if tlsResult.X25519 && tlsResult.H2 && tlsResult.Cert {
		ready := d.collectReady(ctx, func(ctx context.Context) (time.Duration, error) {
			return d.probeReady(ctx, domain, target.IP)
		})
		if milliseconds, ok := aggregateReady(ready); ok {
			result.ReadyMS = fmt.Sprintf("%d", milliseconds)
		}
		if len(ready) < 3 {
			result.Reasons = append(result.Reasons, Reason{Warn, fmt.Sprintf("连接就绪计时样本不足（%d/3）", len(ready))})
		}
	}

	httpResult := d.probeHTTP(ctx, domain, target.IP)
	if httpResult.OK {
		result.HTTP = fmt.Sprintf("%d", httpResult.Code)
	}
	redirectStatus, redirectCode, redirectDetail := classifyRedirect(domain, httpResult)
	result.Redirect = redirectCode
	if redirectStatus == Warn {
		result.Reasons = append(result.Reasons, Reason{Warn, "跳转：" + redirectDetail})
	}
	if reason := classifyHTTP(httpResult); reason != "" {
		result.Reasons = append(result.Reasons, Reason{Warn, reason})
	}
	var cdnReason string
	result.CDN, cdnReason = detectCDN(target.CNAME, httpResult.Header)
	if cdnReason != "" {
		result.Reasons = append(result.Reasons, Reason{Pass, "CDN " + result.CDN + ": " + cdnReason})
	}

	addCoreTLSReasons(&result, tlsResult)
	if tlsResult.Cert && tlsResult.CertWarn != "" {
		result.Reasons = append(result.Reasons, Reason{Warn, tlsResult.CertWarn})
	}
	result.Result = finalStatus(result)
	return result
}

func (d *Detector) resolve(ctx context.Context, domain string) (resolvedTarget, error) {
	type answer struct {
		kind string
		ips  []net.IP
		name string
	}
	answers := make(chan answer, 3)
	go func() { ips, _ := d.lookupIP(ctx, "ip4", domain); answers <- answer{kind: "a", ips: ips} }()
	go func() {
		ips, _ := d.lookupIP(ctx, "ip6", domain)
		answers <- answer{kind: "aaaa", ips: ips}
	}()
	go func() {
		name, _ := d.lookupCNAME(ctx, domain)
		answers <- answer{kind: "cname", name: strings.TrimSuffix(strings.ToLower(name), ".")}
	}()
	var target resolvedTarget
	for range 3 {
		select {
		case <-ctx.Done():
			return target, ctx.Err()
		case response := <-answers:
			switch response.kind {
			case "a":
				target.IPv4 = response.ips
			case "aaaa":
				target.IPv6 = response.ips
			case "cname":
				if response.name != domain {
					target.CNAME = response.name
				}
			}
		}
	}
	for _, ip := range target.IPv4 {
		if v4 := ip.To4(); v4 != nil {
			target.IP = v4
			return target, nil
		}
	}
	for _, ip := range target.IPv6 {
		if ip.To4() == nil && ip.To16() != nil {
			target.IP = ip
			return target, nil
		}
	}
	return target, errors.New("no usable address")
}

func (d *Detector) lookupIP(ctx context.Context, network, domain string) ([]net.IP, error) {
	select {
	case d.dnsSlots <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	defer func() { <-d.dnsSlots }()
	lookupCtx, cancel := context.WithTimeout(ctx, d.cfg.DNSTimeout)
	defer cancel()
	return d.cfg.Resolver.LookupIP(lookupCtx, network, domain)
}

func (d *Detector) lookupCNAME(ctx context.Context, domain string) (string, error) {
	select {
	case d.dnsSlots <- struct{}{}:
	case <-ctx.Done():
		return "", ctx.Err()
	}
	defer func() { <-d.dnsSlots }()
	lookupCtx, cancel := context.WithTimeout(ctx, d.cfg.DNSTimeout)
	defer cancel()
	return d.cfg.Resolver.LookupCNAME(lookupCtx, domain)
}

func (d *Detector) endpoint(ip net.IP) string {
	return net.JoinHostPort(ip.String(), d.cfg.Port)
}

func (d *Detector) probeTCP(ctx context.Context, ip net.IP) error {
	ctx, cancel := context.WithTimeout(ctx, d.cfg.TCPTimeout)
	defer cancel()
	conn, err := d.cfg.DialContext(ctx, "tcp", d.endpoint(ip))
	if err != nil {
		return err
	}
	return conn.Close()
}

func (d *Detector) tlsHandshake(ctx context.Context, domain string, ip net.IP, strict, x25519Only bool, timeout time.Duration) (tls.ConnectionState, time.Duration, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	started := time.Now()
	raw, err := d.cfg.DialContext(ctx, "tcp", d.endpoint(ip))
	if err != nil {
		return tls.ConnectionState{}, 0, err
	}
	defer raw.Close()
	config := &tls.Config{
		ServerName: domain, MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		NextProtos: []string{"h2", "http/1.1"}, RootCAs: d.cfg.RootCAs,
		InsecureSkipVerify: !strict, // READY-only; strict PRIMARY validates separately.
	}
	if x25519Only {
		config.CurvePreferences = []tls.CurveID{tls.X25519}
	}
	conn := tls.Client(raw, config)
	if err := conn.HandshakeContext(ctx); err != nil {
		return tls.ConnectionState{}, 0, err
	}
	return conn.ConnectionState(), time.Since(started), nil
}

func (d *Detector) probeTLSWithFallback(ctx context.Context, domain string, ip net.IP) (tlsOutcome, bool) {
	state, _, err := d.tlsHandshake(ctx, domain, ip, true, true, d.cfg.TLSTimeout)
	x25519 := err == nil && state.CurveID == tls.X25519
	if err != nil || !x25519 {
		state, _, err = d.tlsHandshake(ctx, domain, ip, true, false, d.cfg.TLSTimeout)
	}
	if err != nil {
		return tlsOutcome{X25519: x25519}, false
	}
	out := tlsOutcome{
		TLS13:  state.Version == tls.VersionTLS13,
		X25519: x25519,
		H2:     state.NegotiatedProtocol == "h2",
		Cert:   len(state.VerifiedChains) > 0 && len(state.PeerCertificates) > 0,
	}
	if out.Cert {
		leaf := state.PeerCertificates[0]
		now := d.cfg.Now()
		if now.Before(leaf.NotBefore) || !now.Before(leaf.NotAfter) {
			out.Cert = false
		} else {
			out.CertDays = int(leaf.NotAfter.Sub(now).Hours() / 24)
			if out.CertDays <= 7 {
				out.CertWarn = fmt.Sprintf("证书仅剩 %d 个完整日", out.CertDays)
			}
		}
	}
	return out, out.TLS13
}

func (d *Detector) probeReady(ctx context.Context, domain string, ip net.IP) (time.Duration, error) {
	_, elapsed, err := d.tlsHandshake(ctx, domain, ip, false, true, d.cfg.ReadyTimeout)
	return elapsed, err
}

func (d *Detector) collectReady(ctx context.Context, probe func(context.Context) (time.Duration, error)) []time.Duration {
	// Limit only timing probes. Waiting happens before probeReady starts its
	// timer, and one domain keeps its slot across all three samples so a busy
	// batch neither inflates READY nor interleaves a domain's sample group.
	select {
	case d.readySlots <- struct{}{}:
	case <-ctx.Done():
		return nil
	}
	defer func() { <-d.readySlots }()

	samples := make([]time.Duration, 0, 3)
	for range 3 {
		if elapsed, err := probe(ctx); err == nil {
			samples = append(samples, elapsed)
		}
	}
	return samples
}

func aggregateReady(samples []time.Duration) (int64, bool) {
	if len(samples) == 0 {
		return 0, false
	}
	values := make([]int64, len(samples))
	for index, sample := range samples {
		values[index] = sample.Milliseconds()
	}
	sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
	switch len(values) {
	case 1:
		return values[0], true
	case 2:
		return (values[0] + values[1] + 1) / 2, true
	default:
		return values[len(values)/2], true
	}
}

func (d *Detector) probeHTTP(ctx context.Context, domain string, ip net.IP) httpOutcome {
	var outcome httpOutcome
	for attempt := 1; attempt <= 2; attempt++ {
		attemptCtx, cancel := context.WithTimeout(ctx, d.cfg.HTTPTimeout)
		transport := &http.Transport{
			Proxy: nil, DisableKeepAlives: true, DisableCompression: true, ForceAttemptHTTP2: true,
			ResponseHeaderTimeout: d.cfg.ResponseHeaderTimeout,
			TLSHandshakeTimeout:   d.cfg.TLSTimeout,
			TLSClientConfig: &tls.Config{
				ServerName: domain, MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
				RootCAs: d.cfg.RootCAs, NextProtos: []string{"h2", "http/1.1"},
			},
			DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
				return d.cfg.DialContext(ctx, network, d.endpoint(ip))
			},
		}
		client := &http.Client{
			Transport:     transport,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		}
		request, _ := http.NewRequestWithContext(attemptCtx, http.MethodGet, "https://"+domain+"/", nil)
		request.Host = domain
		request.Header.Set("User-Agent", bashCompatibleUserAgent)
		request.Header.Set("Accept", "*/*")
		response, err := client.Do(request)
		outcome.Attempts = attempt
		if err == nil {
			outcome.OK = true
			outcome.Code = response.StatusCode
			outcome.Location = response.Header.Get("Location")
			outcome.Header = response.Header.Clone()
			_ = response.Body.Close() // Headers are sufficient; never download the body.
		}
		transport.CloseIdleConnections()
		cancel()
		// Transport failures have no HTTP response to classify and are not
		// retried. HTTP is an auxiliary signal, so repeating the same connect or
		// response-header timeout would only extend the batch tail. A received
		// 5xx response may be transient and gets the one permitted retry.
		if err != nil || response.StatusCode < 500 {
			break
		}
	}
	return outcome
}

func classifyHTTP(outcome httpOutcome) string {
	if !outcome.OK {
		return "HTTP 请求失败"
	}
	switch outcome.Code {
	case 200, 204, 301, 302, 303, 307, 308, 404:
		return ""
	case 401, 403, 429:
		return fmt.Sprintf("HTTP %d", outcome.Code)
	default:
		return fmt.Sprintf("HTTP %d", outcome.Code)
	}
}

func classifyRedirect(domain string, outcome httpOutcome) (Status, string, string) {
	if !outcome.OK {
		return Pass, "-", "-"
	}
	location := strings.TrimSpace(outcome.Location)
	if location == "" {
		if outcome.Code == 301 || outcome.Code == 302 || outcome.Code == 303 || outcome.Code == 307 || outcome.Code == 308 {
			return Warn, "NO-LOC", "缺少 Location"
		}
		return Pass, "-", "-"
	}
	if strings.ContainsAny(location, "\r\n\t") {
		return Warn, "INVALID", "无法解析"
	}
	if strings.HasPrefix(location, "//") {
		location = "https:" + location
	} else if !strings.HasPrefix(strings.ToLower(location), "http://") && !strings.HasPrefix(strings.ToLower(location), "https://") {
		return Warn, "RELATIVE", "相对路径"
	}
	parsed, err := url.Parse(location)
	if err != nil || parsed.Hostname() == "" {
		return Warn, "INVALID", "无法解析"
	}
	if strings.EqualFold(parsed.Scheme, "http") {
		return Warn, "HTTP", "降级 HTTP"
	}
	host := strings.ToLower(parsed.Hostname())
	if host == domain {
		return Warn, "SAME", "同主机"
	}
	if (strings.HasPrefix(domain, "www.") && host == strings.TrimPrefix(domain, "www.")) ||
		(!strings.HasPrefix(domain, "www.") && host == "www."+domain) {
		return Warn, "WWW", "www 切换"
	}
	return Warn, "CROSS", "跨主机"
}

func detectCDN(cname string, header http.Header) (string, string) {
	lower := strings.ToLower(strings.TrimSuffix(cname, "."))
	providers := []struct{ suffix, name string }{
		{".cloudflare.net", "Cloudflare"}, {".cloudfront.net", "CloudFront"},
		{".akamai.net", "Akamai"}, {".akamaiedge.net", "Akamai"},
		{".akamaitechnologies.com", "Akamai"}, {".edgekey.net", "Akamai"},
		{".edgesuite.net", "Akamai"}, {".azurefd.net", "Azure Front Door"},
		{".fastly.net", "Fastly"}, {".fastlylb.net", "Fastly"},
		{".b-cdn.net", "Bunny CDN"}, {".gcdn.co", "Gcore"},
	}
	for _, provider := range providers {
		if strings.HasSuffix(lower, provider.suffix) {
			return "HIGH", fmt.Sprintf("%s（CNAME: %s）", provider.name, lower)
		}
	}
	checks := []struct{ key, provider string }{
		{"Cf-Ray", "Cloudflare（CF-Ray）"}, {"Cf-Cache-Status", "Cloudflare（CF-Cache-Status）"},
		{"X-Amz-Cf-Id", "CloudFront（X-Amz-Cf-Id）"}, {"X-Amz-Cf-Pop", "CloudFront（X-Amz-Cf-Pop）"},
		{"X-Akamai-Transformed", "Akamai（X-Akamai-Transformed）"}, {"Akamai-Grn", "Akamai（Akamai-GRN）"},
		{"X-Azure-Ref", "Azure Front Door（X-Azure-Ref）"},
	}
	for _, check := range checks {
		if header.Get(check.key) != "" {
			return "HIGH", check.provider
		}
	}
	served, cache, via := header.Get("X-Served-By") != "", header.Get("X-Cache") != "", header.Get("Via") != ""
	if served && cache {
		return "HIGH", "Fastly（x-served-by + x-cache）"
	}
	if served {
		return "MED", "Fastly（单一弱特征响应头）"
	}
	if via && cache {
		return "MED", "缓存代理（Via + X-Cache）"
	}
	return "-", ""
}

func addCoreTLSReasons(result *Result, outcome tlsOutcome) {
	if !outcome.TLS13 {
		result.Reasons = append(result.Reasons, Reason{Fail, "TLS 1.3 握手失败"})
	}
	if !outcome.X25519 {
		result.Reasons = append(result.Reasons, Reason{Fail, "强制 X25519 握手失败"})
	}
	if !outcome.H2 {
		result.Reasons = append(result.Reasons, Reason{Fail, "ALPN 未协商 h2"})
	}
	if !outcome.Cert {
		result.Reasons = append(result.Reasons, Reason{Fail, "证书链、有效期或主机名验证失败"})
	}
}

func finalStatus(result Result) Status {
	if result.TLS13 != Pass || result.X25519 != Pass || result.H2 != Pass || result.CertDays == "FAIL" {
		return Fail
	}
	for _, reason := range result.Reasons {
		if reason.Status == Fail {
			return Fail
		}
		if reason.Status == Warn {
			return Warn
		}
	}
	return Pass
}
