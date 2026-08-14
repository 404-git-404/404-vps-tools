package main

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/404-git-404/404notfound/internal/domaincheck"
)

var version = "dev"
var commit = "unknown"
var buildDate = "unknown"

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, outputColorEnabled(os.Stdout)))
}

func run(args []string, stdout, stderr io.Writer, color bool) int {
	if len(args) == 1 && args[0] == "--version" {
		fmt.Fprintf(stdout, "domain-check Go %s (commit %s, built %s)\n", version, commit, buildDate)
		return 0
	}
	if len(args) != 1 {
		fmt.Fprintln(stderr, domaincheck.Usage)
		return 2
	}
	domains, err := domaincheck.ParseDomains(args[0])
	if err != nil {
		fmt.Fprintln(stderr, domaincheck.Usage)
		return 2
	}
	cfg, err := domaincheck.ConfigFromEnv(os.Getenv)
	if err != nil {
		fmt.Fprintf(stderr, "domain-check: %v\n", err)
		return 2
	}
	detector, err := domaincheck.New(cfg)
	if err != nil {
		fmt.Fprintf(stderr, "domain-check: %v\n", err)
		return 2
	}
	results := detector.Run(context.Background(), domains, func(done, total int, domain string) {
		fmt.Fprintf(stderr, "[%d/%d] %s\n", done, total, domain)
	})
	domaincheck.PrintTable(stdout, results, color)
	if path, err := domaincheck.WriteHTMLLog(os.Getenv("HOME"), args[0], results, cfg.Now()); err != nil {
		fmt.Fprintf(stderr, "domain-check: WARN: unable to write HTML log: %v\n", err)
	} else {
		fmt.Fprintf(stderr, "HTML log: %s\n", path)
	}
	for _, result := range results {
		if result.Result == domaincheck.Fail {
			return 1
		}
	}
	return 0
}

func outputColorEnabled(file *os.File) bool {
	_, noColor := os.LookupEnv("NO_COLOR")
	info, err := file.Stat()
	return err == nil && colorEnabled(info.Mode(), noColor)
}

func colorEnabled(mode os.FileMode, noColor bool) bool {
	return mode&os.ModeCharDevice != 0 && !noColor
}
