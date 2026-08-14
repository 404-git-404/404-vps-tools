package domaincheck

import (
	"errors"
	"fmt"
	"html/template"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var headers = []string{"DOMAIN", "IP", "TLS1.3", "X25519", "H2", "READY(ms)", "CERT(d)", "CDN", "HTTP", "REDIRECT", "RESULT"}

func PrintTable(writer io.Writer, results []Result, color bool) {
	rows := make([][]string, len(results))
	widths := make([]int, len(headers))
	for index, header := range headers {
		widths[index] = len(header)
	}
	for index, result := range results {
		rows[index] = []string{result.Domain, result.IP, string(result.TLS13), string(result.X25519), string(result.H2), result.ReadyMS, result.CertDays, result.CDN, result.HTTP, result.Redirect, string(result.Result)}
		for column, value := range rows[index] {
			if len(value) > widths[column] {
				widths[column] = len(value)
			}
		}
	}
	border := func() {
		fmt.Fprint(writer, "+")
		for _, width := range widths {
			fmt.Fprint(writer, strings.Repeat("-", width+2), "+")
		}
		fmt.Fprintln(writer)
	}
	printRow := func(values []string) {
		fmt.Fprint(writer, "|")
		for index, value := range values {
			fmt.Fprintf(writer, " %s%s |", terminalValue(value, color), strings.Repeat(" ", widths[index]-len(value)))
		}
		fmt.Fprintln(writer)
	}
	border()
	printRow(headers)
	border()
	for _, row := range rows {
		printRow(row)
	}
	border()
	fmt.Fprintln(writer, "DETAILS")
	for _, result := range results {
		if len(result.Reasons) == 0 {
			continue
		}
		fmt.Fprintf(writer, "%s:\n", result.Domain)
		for _, reason := range result.Reasons {
			fmt.Fprintf(writer, "  - %s\n", reason.Text)
		}
	}
}

func terminalValue(value string, color bool) string {
	if !color {
		return value
	}
	switch value {
	case string(Pass):
		return "\x1b[32m" + value + "\x1b[0m"
	case string(Warn):
		return "\x1b[33m" + value + "\x1b[0m"
	case string(Fail):
		return "\x1b[31m" + value + "\x1b[0m"
	default:
		return value
	}
}

type reportData struct {
	Time, Input               string
	Targets, Pass, Warn, Fail int
	Results                   []Result
}

var reportTemplate = template.Must(template.New("report").Funcs(template.FuncMap{
	"statusClass": func(status Status) string { return strings.ToLower(string(status)) },
	"valueClass": func(value string) string {
		switch value {
		case "PASS":
			return "pass"
		case "FAIL":
			return "fail"
		case "WARN":
			return "warn"
		case "HIGH":
			return "high"
		case "-":
			return "muted"
		}
		if len(value) == 3 && value[0] >= '2' && value[0] <= '5' {
			return "http-" + value[:1] + "xx"
		}
		return ""
	},
}).Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Domain Check Report</title><style>
:root{color-scheme:light dark;--bg:#f7f8fa;--fg:#20242b;--panel:#fff;--border:#9aa4b2;--pass:#17803d;--fail:#c62828;--warn:#a85b00;--high:#067a8b;--domain:#007f91;--ip:#a03c91;--muted:#7b8490}
@media(prefers-color-scheme:dark){:root{--bg:#101419;--fg:#dce3ea;--panel:#161c23;--border:#53606f;--pass:#58d68d;--fail:#ff6b6b;--warn:#ffc857;--high:#4dd0e1;--domain:#52d6e8;--ip:#f08bd8;--muted:#7e8997}}
*{box-sizing:border-box}body{margin:18px;background:var(--bg);color:var(--fg);font:13px/1.35 ui-monospace,SFMono-Regular,Consolas,monospace}h1{font-size:21px;margin:0 0 8px}.meta{display:flex;flex-wrap:wrap;gap:6px 18px;margin-bottom:12px}.summary{font-weight:700}.table-wrap{overflow:auto;background:var(--panel)}table{border-collapse:collapse;width:100%;white-space:nowrap}th,td{border:1px solid var(--border);padding:4px 7px;text-align:left}th{background:color-mix(in srgb,var(--panel),var(--fg) 9%)}td.domain{color:var(--domain)}td.ip{color:var(--ip)}.pass,.http-2xx{color:var(--pass);font-weight:700}.fail,.http-5xx{color:var(--fail);font-weight:700}.warn,.http-4xx{color:var(--warn);font-weight:700}.high,.http-3xx{color:var(--high);font-weight:700}.muted{color:var(--muted)}h2{font-size:17px;margin:16px 0 7px}.detail{border-left:3px solid var(--border);padding:3px 9px;margin:6px 0}.detail h3{font-size:14px;color:var(--domain);margin:0 0 2px}.detail ul{margin:0;padding-left:20px}.detail li.pass{font-weight:400}
</style></head><body><h1>Domain Check Report</h1><div class="meta"><span>Time: {{.Time}}</span><span>Input: {{.Input}}</span><span>Targets: {{.Targets}}</span><span class="summary pass">PASS: {{.Pass}}</span><span class="summary warn">WARN: {{.Warn}}</span><span class="summary fail">FAIL: {{.Fail}}</span></div>
<div class="table-wrap"><table><thead><tr>{{range $header := .Headers}}<th>{{$header}}</th>{{end}}</tr></thead><tbody>
{{range .Results}}<tr><td class="domain">{{.Domain}}</td><td class="ip">{{.IP}}</td><td class="{{valueClass (printf "%s" .TLS13)}}">{{.TLS13}}</td><td class="{{valueClass (printf "%s" .X25519)}}">{{.X25519}}</td><td class="{{valueClass (printf "%s" .H2)}}">{{.H2}}</td><td>{{.ReadyMS}}</td><td class="{{valueClass .CertDays}}">{{.CertDays}}</td><td class="{{valueClass .CDN}}">{{.CDN}}</td><td class="{{valueClass .HTTP}}">{{.HTTP}}</td><td class="{{valueClass .Redirect}}">{{.Redirect}}</td><td class="{{statusClass .Result}}">{{.Result}}</td></tr>{{end}}
</tbody></table></div><h2>DETAILS</h2>{{range .Results}}{{if .Reasons}}<section class="detail"><h3>{{.Domain}}</h3><ul>{{range .Reasons}}<li class="{{statusClass .Status}}">{{.Text}}</li>{{end}}</ul></section>{{end}}{{end}}</body></html>`))

func RenderHTML(writer io.Writer, input string, results []Result, generated time.Time) error {
	data := reportData{Time: generated.UTC().Format("2006-01-02 15:04:05 UTC"), Input: input, Targets: len(results), Results: results}
	for _, result := range results {
		switch result.Result {
		case Pass:
			data.Pass++
		case Warn:
			data.Warn++
		case Fail:
			data.Fail++
		}
	}
	return reportTemplate.Execute(writer, struct {
		reportData
		Headers []string
	}{data, headers})
}

func WriteHTMLLog(home, input string, results []Result, now time.Time) (string, error) {
	if !filepath.IsAbs(home) {
		return "", errors.New("HOME is not absolute")
	}
	directory := filepath.Join(home, "domain-check-logs")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return "", err
	}
	stamp := now.Format("20060102-150405")
	for suffix := 0; suffix < 1000; suffix++ {
		name := fmt.Sprintf("domain-check-%s.html", stamp)
		if suffix > 0 {
			name = fmt.Sprintf("domain-check-%s-%d.html", stamp, suffix)
		}
		path := filepath.Join(directory, name)
		file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		if err != nil {
			return "", err
		}
		renderErr := RenderHTML(file, input, results, now)
		closeErr := file.Close()
		if renderErr != nil || closeErr != nil {
			_ = os.Remove(path)
			if renderErr != nil {
				return "", renderErr
			}
			return "", closeErr
		}
		absolute, err := filepath.Abs(path)
		return absolute, err
	}
	return "", errors.New("unable to reserve a unique HTML log")
}
