package domaincheck

import (
	"context"
	"crypto/x509"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type Status string

const (
	Pass Status = "PASS"
	Warn Status = "WARN"
	Fail Status = "FAIL"
)

const Usage = "Usage: domain-check domain1.com/domain2.com/domain3.com"

type Reason struct {
	Status Status
	Text   string
}

type Result struct {
	Domain   string
	IP       string
	TLS13    Status
	X25519   Status
	H2       Status
	ReadyMS  string
	CertDays string
	CDN      string
	HTTP     string
	Redirect string
	Result   Status
	Reasons  []Reason
}

type Resolver interface {
	LookupIP(context.Context, string, string) ([]net.IP, error)
	LookupCNAME(context.Context, string) (string, error)
}

type Config struct {
	Concurrency           int
	DNSConcurrency        int
	ReadyConcurrency      int
	Port                  string
	DNSTimeout            time.Duration
	TCPTimeout            time.Duration
	TLSTimeout            time.Duration
	ReadyTimeout          time.Duration
	HTTPTimeout           time.Duration
	ResponseHeaderTimeout time.Duration
	DomainTimeout         time.Duration
	Resolver              Resolver
	RootCAs               *x509.CertPool
	DialContext           func(context.Context, string, string) (net.Conn, error)
	Now                   func() time.Time
}

func DefaultConfig() Config {
	dialer := &net.Dialer{}
	return Config{
		Concurrency:           24,
		DNSConcurrency:        24,
		ReadyConcurrency:      4,
		Port:                  "443",
		DNSTimeout:            6 * time.Second,
		TCPTimeout:            2500 * time.Millisecond,
		TLSTimeout:            4 * time.Second,
		ReadyTimeout:          3 * time.Second,
		HTTPTimeout:           2500 * time.Millisecond,
		ResponseHeaderTimeout: 2 * time.Second,
		DomainTimeout:         30 * time.Second,
		Resolver:              net.DefaultResolver,
		DialContext:           dialer.DialContext,
		Now:                   time.Now,
	}
}

func ConfigFromEnv(getenv func(string) string) (Config, error) {
	cfg := DefaultConfig()
	variables := []struct {
		name   string
		target *int
	}{
		{"DOMAIN_CHECK_CONCURRENCY", &cfg.Concurrency},
		{"DOMAIN_CHECK_READY_CONCURRENCY", &cfg.ReadyConcurrency},
	}
	for _, variable := range variables {
		raw := strings.TrimSpace(getenv(variable.name))
		if raw == "" {
			continue
		}
		workers, err := strconv.Atoi(raw)
		if err != nil || workers < 1 || workers > 256 {
			return Config{}, fmt.Errorf("%s must be an integer from 1 to 256", variable.name)
		}
		*variable.target = workers
	}
	return cfg, nil
}

type resolvedTarget struct {
	IPv4  []net.IP
	IPv6  []net.IP
	CNAME string
	IP    net.IP
}

type tlsOutcome struct {
	TLS13    bool
	X25519   bool
	H2       bool
	Cert     bool
	CertDays int
	CertWarn string
}

type httpOutcome struct {
	OK       bool
	Code     int
	Location string
	Header   http.Header
	Attempts int
}

func ParseDomains(argument string) ([]string, error) {
	if argument == "" || strings.TrimSpace(argument) != argument ||
		strings.HasPrefix(argument, "/") || strings.HasSuffix(argument, "/") ||
		strings.Contains(argument, "//") {
		return nil, fmt.Errorf("invalid domain list")
	}
	seen := make(map[string]bool)
	domains := make([]string, 0)
	for _, segment := range strings.Split(argument, "/") {
		domain := strings.ToLower(segment)
		if !validDomain(domain) {
			return nil, fmt.Errorf("invalid domain: %s", segment)
		}
		if !seen[domain] {
			seen[domain] = true
			domains = append(domains, domain)
		}
	}
	return domains, nil
}

func validDomain(domain string) bool {
	if len(domain) < 3 || len(domain) > 253 || !strings.Contains(domain, ".") ||
		strings.HasPrefix(domain, ".") || strings.HasSuffix(domain, ".") ||
		strings.Contains(domain, "..") {
		return false
	}
	allNumeric := true
	for _, r := range domain {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '.' && r != '-' {
			return false
		}
		if r < '0' || r > '9' {
			if r != '.' {
				allNumeric = false
			}
		}
	}
	if allNumeric {
		return false
	}
	for _, label := range strings.Split(domain, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
	}
	return true
}
