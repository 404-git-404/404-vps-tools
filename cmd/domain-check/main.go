package main

import (
	"context"
	"fmt"
	"os"

	"github.com/404-git-404/404notfound/internal/domaincheck"
)

func main() {
	os.Exit(run())
}

func run() int {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, domaincheck.Usage)
		return 2
	}
	domains, err := domaincheck.ParseDomains(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, domaincheck.Usage)
		return 2
	}
	cfg, err := domaincheck.ConfigFromEnv(os.Getenv)
	if err != nil {
		fmt.Fprintf(os.Stderr, "domain-check: %v\n", err)
		return 2
	}
	detector, err := domaincheck.New(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "domain-check: %v\n", err)
		return 2
	}
	results := detector.Run(context.Background(), domains, func(done, total int, domain string) {
		fmt.Fprintf(os.Stderr, "[%d/%d] %s\n", done, total, domain)
	})
	domaincheck.PrintTable(os.Stdout, results)
	if path, err := domaincheck.WriteHTMLLog(os.Getenv("HOME"), os.Args[1], results, cfg.Now()); err != nil {
		fmt.Fprintf(os.Stderr, "domain-check: WARN: unable to write HTML log: %v\n", err)
	} else {
		fmt.Fprintf(os.Stderr, "HTML log: %s\n", path)
	}
	for _, result := range results {
		if result.Result == domaincheck.Fail {
			return 1
		}
	}
	return 0
}
