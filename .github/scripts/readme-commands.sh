#!/usr/bin/env bash
# Print the copy-and-paste commands of a README, one per line: LANGUAGE<TAB>COMMAND.
# A command is the single line inside a fenced code block that is tagged with a language.
set -Eeuo pipefail

readme=${1:-README.md}
test -s "$readme"
awk '
  /^```[a-z]+$/ { lang = substr($0, 4); count = 0; next }
  /^```$/ { if (lang != "" && count != 1) { print "README code block is not a single command" > "/dev/stderr"; exit 1 } lang = ""; next }
  lang != "" { count++; if (count == 1) printf "%s\t%s\n", lang, $0 }
' "$readme"
