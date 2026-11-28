#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2317,SC2329,SC2034 # Subshell env isolation and mocks are intentional.
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

strip_ansi() {
  sed $'s/\033\\[[0-9;]*[A-Za-z]//g'
}

has_escape() {
  LC_ALL=C grep -q $'\033' "$1"
}

check_uniform_width() {
  local file=$1 expected=$2 line width
  while IFS= read -r line; do
    width=$(LC_ALL=C.UTF-8 wc -L <<<"$line")
    width=${width//[[:space:]]/}
    [[ "$width" == "$expected" ]] || fail "width mismatch in $file: expected $expected, got $width for [$line]"
  done <"$file"
}

# 1. Non-TTY output (redirected to file/pipe) must never emit any \033 escape codes.
(
  unset NO_COLOR
  export TERM=xterm-256color
  # shellcheck disable=SC1091
  source "$repo/debian-init.sh"
  trap - EXIT ERR HUP INT TERM
  ui_init
  [[ -z "$C_OUT_RESET" && -z "$C_ERR_RESET" ]] || fail 'non-TTY color vars not empty'
  log 'info line'
  warn 'warn line'
  INSTALL_MODE=quick BASE_ONLY=false PRESERVE_SSH=false REUSE_PUBLIC_KEY=false
  SSH_PORT=53651 KEEP_SSH_22=false NETWORK_REQUEST=auto DO_FULL_UPGRADE=true
  SWAP_CONFIRMED_MIB=0 AUTO_SECURITY=true IPV6_BOOT_STATE=on IPV6_RESTORE_CHOICE=''
  print_initialization_summary
  AUDIT_FINDINGS=(
    $'A\tkey\t/root/.ssh/authorized_keys\tSHA256:fixture'
    $'B\tservice\tcustom.service\t非软件包服务'
    $'C\tuid\textra\t额外 UID 0 用户'
  )
  AUDIT_SESSION_KEY='SHA256:session'
  print_security_audit full
  ssh_listener_addresses() { echo '0.0.0.0:53651'; }
  fail2ban_package_installed() { return 0; }
  ufw() { echo 'Status: active'; }
  smartdns() { echo 'smartdns fixture'; }
  sing-box() { echo 'sing-box fixture'; }
  sysctl() { if [[ "$2" == kernel.printk ]]; then printf '4\t4\t1\t7\n'; else echo bbr; fi; }
  security_updates_enabled() { return 1; }
  BOOT_REPORT=$'ssh.service: enabled / active \n'
  BACKUP_DIR='/root/vps-init-backups/fixture'
  NETWORK_STACK='dual'
  SMARTDNS_TRANSPORT='h2'
  SAFE_CLEANUP_RESULT='已完成'
  UI_WIDTH=72
  print_report
) >"$work/non-tty.out" 2>"$work/non-tty.err"

if has_escape "$work/non-tty.out"; then fail 'non-TTY stdout contained ANSI escapes'; fi
if has_escape "$work/non-tty.err"; then fail 'non-TTY stderr contained ANSI escapes'; fi
grep -Fxq '[INFO] info line' "$work/non-tty.out" || fail 'log prefix broken on non-TTY'
grep -Fxq '[WARN] warn line' "$work/non-tty.err" || fail 'warn prefix broken on non-TTY'
printk_row=$(grep -E '^│ 控制台日志    : 只显示错误及以上（UFW 拦截日志只记入 journal） +│$' "$work/non-tty.out") || fail 'console logging report must fit on one row at width 72'
ufw_row=$(grep -F 'UFW           : Status: active' "$work/non-tty.out")
[[ "$(LC_ALL=C.UTF-8 wc -L <<<"${printk_row%%:*}")" == "$(LC_ALL=C.UTF-8 wc -L <<<"${ufw_row%%:*}")" ]] || fail 'console logging and UFW colons must align'
# Audit headings: a title row with the count, then an indented description row (no brackets, no colon).
grep -Eq '^│ A 建议删除（1 项） +│$' "$work/non-tty.out" || fail 'A audit heading row wrong'
grep -Eq '^│   这些是登录钥匙或商家助手；确认不需要再处理，默认保留。 +│$' "$work/non-tty.out" || fail 'A audit description row wrong'
grep -Eq '^│ B 需要你看一眼（1 项） +│$' "$work/non-tty.out" || fail 'B audit heading row wrong'
grep -Eq '^│   这些有额外权限或后台行为；可能是你装的，只报告。 +│$' "$work/non-tty.out" || fail 'B audit description row wrong'
grep -Eq '^│ C 严重异常（1 项） +│$' "$work/non-tty.out" || fail 'C audit heading row wrong'
grep -Eq '^│   这些会改变系统或登录信任；只报告，建议用官方系统重装。 +│$' "$work/non-tty.out" || fail 'C audit description row wrong'
if grep -Fq '[A 建议删除' "$work/non-tty.out"; then fail 'audit heading still has brackets'; fi

# die on non-TTY stderr must start with [ERROR] and emit no escapes.
set +e
(
  unset NO_COLOR
  export TERM=xterm-256color
  # shellcheck disable=SC1091
  source "$repo/debian-init.sh"
  trap - EXIT ERR HUP INT TERM
  die 'fixture failure'
) >"$work/die.out" 2>"$work/die.err"
rc=$?
set -e
(( rc == 1 )) || fail "die exited with $rc"
if has_escape "$work/die.err"; then fail 'die emitted ANSI escapes on non-TTY stderr'; fi
grep -Eq '^\[ERROR\] ' "$work/die.err" || fail 'die output did not start with [ERROR]'

# 2. Chinese, English, and mixed lines inside a box all have identical display width (wc -L).
(
  export NO_COLOR=1 TERM=xterm-256color
  # shellcheck disable=SC1091
  source "$repo/debian-init.sh"
  trap - EXIT ERR HUP INT TERM
  ui_init
  UI_WIDTH=72
  ui_box_top "404-vps-tools · debian-init.sh v$SCRIPT_VERSION"
  ui_box_line '纯中文测试行：安全加固与初始化配置'
  ui_box_line 'Pure English test line 1234567890'
  ui_box_line '8. 安全加固（体检 → 建议 → 确认后执行）'
  ui_box_line 'SmartDNS 监听 : 127.0.0.1:53（UDP+TCP）'
  ui_box_line '  ▸ 登录公钥：中英混排 ABC-123 — 测试'
  ui_box_sep
  ui_box_bottom
) >"$work/width-72.out"
if has_escape "$work/width-72.out"; then fail 'NO_COLOR box contained ANSI escapes'; fi
check_uniform_width "$work/width-72.out" 72

# Narrow terminal width (e.g., 44 columns) also aligns uniformly.
(
  export NO_COLOR=1 TERM=xterm-256color
  # shellcheck disable=SC1091
  source "$repo/debian-init.sh"
  trap - EXIT ERR HUP INT TERM
  ui_init
  UI_WIDTH=44
  ui_box_top '本次执行配置'
  ui_box_line '纯中文宽度对齐'
  ui_box_line 'English width check'
  ui_box_line '中英 Mixed 44 列'
  ui_box_sep
  ui_box_bottom
) >"$work/width-44.out"
check_uniform_width "$work/width-44.out" 44

# 3. TERM=linux must use ASCII borders (+ - |) and no Unicode box characters.
(
  export NO_COLOR=1 TERM=linux
  # shellcheck disable=SC1091
  source "$repo/debian-init.sh"
  trap - EXIT ERR HUP INT TERM
  ui_init
  UI_WIDTH=72
  ui_box_top 'VPS 初始化完成'
  ui_box_line '1. 快速初始化'
  ui_box_line 'ASCII border check'
  ui_box_sep
  ui_box_bottom
) >"$work/ascii.out"
if has_escape "$work/ascii.out"; then fail 'TERM=linux with NO_COLOR emitted escapes'; fi
if grep -Eq '[╭╮╰╯│─├┤]' "$work/ascii.out"; then fail 'TERM=linux emitted Unicode box chars'; fi
grep -Eq '^\+- VPS 初始化完成 -+\+$' "$work/ascii.out" || fail 'TERM=linux top border wrong'
grep -Eq '^\| 1\. 快速初始化 +\|$' "$work/ascii.out" || fail 'TERM=linux content border wrong'
grep -Eq '^\+-+\+$' "$work/ascii.out" || fail 'TERM=linux separator/bottom border wrong'
check_uniform_width "$work/ascii.out" 72

# 4. Overlong lines wrap inside the box: every row has the same display width, no segment exceeds the
#    inner width, and no character is lost. Cases: Chinese, English, mixed, an unbroken hash, and an
#    indented line (continuation indent = leading spaces + 2).
long_zh='重启后恢复网络配置：写入脚本管理的覆盖文件，不修改原有文件；先备份再覆盖，验证失败时保留现状并给出警告，需要时请自行重启后再次检查。'
long_en='This is a deliberately long English status line that has to be wrapped inside the box without losing a single character at all.'
long_mix='1. 恢复 IPv6：写入脚本管理的 /etc/sysctl.d/99-vps-init-network.conf 覆盖上述设置（不修改原有文件）TAIL_MARKER_END'
long_hash='SHA256:0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz'
long_indent='      - /root/.ssh/authorized_keys — 这是一条带缩进的很长的明细说明，用来检查续行缩进是否等于开头空格数加二，并且不会丢字。'
for width in 72 44; do
  (
    export NO_COLOR=1 TERM=xterm-256color
    # shellcheck disable=SC1091
    source "$repo/debian-init.sh"
    trap - EXIT ERR HUP INT TERM
    ui_init
    UI_WIDTH=$width
    inner=$((UI_WIDTH - 4))
    : >"$work/wrap-$width.out"
    for text in "$long_zh" "$long_en" "$long_mix" "$long_hash" "$long_indent"; do
      # Function level: exact reassembly (trailing spaces included), widths within inner, indent.
      ui_wrap_text "$text" "$inner"
      (( ${#UI_WRAP_SEGS[@]} > 1 )) || fail "line did not wrap at width $width: $text"
      lead=${text%%[! ]*}
      indent=$(printf '%*s' $(( ${#lead} + 2 )) '')
      joined=''
      for idx in "${!UI_WRAP_SEGS[@]}"; do
        seg=${UI_WRAP_SEGS[idx]}
        (( UI_WRAP_WIDTHS[idx] <= inner )) || fail "segment wider than inner at width $width: [$seg]"
        [[ "$(ui_display_width "$seg")" == "${UI_WRAP_WIDTHS[idx]}" ]] || fail "segment width bookkeeping wrong: [$seg]"
        if (( idx > 0 )); then
          [[ "$seg" == "$indent"* ]] || fail "continuation indent wrong at width $width: [$seg]"
          seg=${seg#"$indent"}
        fi
        joined+=$seg
      done
      [[ "$joined" == "$text" ]] || fail "wrapped segments lost or changed characters at width $width: [$joined]"
      # Rendered level.
      ui_box_line "$text" >>"$work/wrap-$width.out"
    done
  )
  check_uniform_width "$work/wrap-$width.out" "$width"
  if has_escape "$work/wrap-$width.out"; then fail 'NO_COLOR wrapped box contained ANSI escapes'; fi
  # Padding and break spaces are indistinguishable once rendered, so compare with spaces removed.
  rendered=$(sed -e 's/^│ //' -e 's/ │$//' "$work/wrap-$width.out" | tr -d ' \n')
  expected=$(printf '%s' "$long_zh$long_en$long_mix$long_hash$long_indent" | tr -d ' ')
  [[ "$rendered" == "$expected" ]] || fail "rendered wrapped box lost characters at width $width"
done

# ui_box_line_color colors every wrapped segment; ui_box_line with partial color wraps without color.
(
  export TERM=xterm-256color
  unset NO_COLOR
  # shellcheck disable=SC1091
  source "$repo/debian-init.sh"
  trap - EXIT ERR HUP INT TERM
  ui_init
  UI_WIDTH=44
  UI_TARGET='tty'
  C_CYAN=$'\033[36m' C_RESET=$'\033[0m' C_YELLOW=$'\033[33m'
  ui_box_line_color "$C_YELLOW" "$long_zh" >"$work/color-line.out"
  ui_box_line "$long_zh" "${C_YELLOW}${long_zh}${C_RESET}" >"$work/partial-line.out"
  ui_box_line_color "$C_YELLOW" '短行' >"$work/color-short.out"
)
rows=$(grep -c '' "$work/color-line.out")
(( rows > 1 )) || fail 'colored long line did not wrap'
[[ "$(grep -c $'\033\\[33m.*\033\\[0m' "$work/color-line.out")" -eq "$rows" ]] || fail 'not every wrapped segment was colored and reset'
strip_ansi <"$work/color-line.out" >"$work/color-line.plain"
check_uniform_width "$work/color-line.plain" 44
# Borders keep their own color; the text itself must not be yellow when it had to wrap.
if grep -Fq $'\033[33m' "$work/partial-line.out"; then fail 'wrapped partial-color line kept its text color'; fi
strip_ansi <"$work/partial-line.out" >"$work/partial-line.plain"
check_uniform_width "$work/partial-line.plain" 44
grep -Fq $'\033[33m' "$work/color-short.out" || fail 'short colored line lost its color'

# 5. Real PTY checks: color enabled by default, disabled by NO_COLOR and TERM=dumb,
#    and colored box lines still align uniformly after stripping ANSI codes.
if [[ "$(uname -s)" == Linux ]] && command -v script >/dev/null 2>&1; then
  # NO_COLOR in a real PTY must emit zero \033 escapes.
  printf '0\n' | NO_COLOR=1 TERM=xterm-256color script -qec \
    "bash -c 'source \"$repo/debian-init.sh\"; log pty-info; warn pty-warn; select_install_mode'" \
    /dev/null >"$work/pty-nocolor.out"
  if has_escape "$work/pty-nocolor.out"; then fail 'NO_COLOR=1 emitted ANSI escapes in PTY'; fi

  # Empty NO_COLOR= in a real PTY must also emit zero \033 escapes.
  printf '0\n' | NO_COLOR='' TERM=xterm-256color script -qec \
    "bash -c 'source \"$repo/debian-init.sh\"; log pty-info; select_install_mode'" \
    /dev/null >"$work/pty-nocolor-empty.out"
  if has_escape "$work/pty-nocolor-empty.out"; then fail 'empty NO_COLOR emitted ANSI escapes in PTY'; fi

  # TERM=dumb in a real PTY must emit zero \033 escapes.
  printf '0\n' | env -u NO_COLOR TERM=dumb script -qec \
    "bash -c 'source \"$repo/debian-init.sh\"; log pty-info; select_install_mode'" \
    /dev/null >"$work/pty-dumb.out"
  if has_escape "$work/pty-dumb.out"; then fail 'TERM=dumb emitted ANSI escapes in PTY'; fi

  # Normal PTY with xterm-256color: colors enabled, and stripped box lines have uniform width.
  printf '0\n' | env -u NO_COLOR TERM=xterm-256color script -qec \
    "bash -c 'source \"$repo/debian-init.sh\"; UI_WIDTH=72; select_install_mode'" \
    /dev/null >"$work/pty-color.out"
  has_escape "$work/pty-color.out" || fail 'PTY menu did not emit ANSI color codes'
  tr -d '\r' <"$work/pty-color.out" | strip_ansi | grep -E '^[╭│├╰]' >"$work/pty-menu-box.txt"
  [[ -s "$work/pty-menu-box.txt" ]] || fail 'PTY menu box missing'
  check_uniform_width "$work/pty-menu-box.txt" 72

  # The UFW row is yellow unless the first ufw status line is exactly "Status: active".
  cat >"$work/report-probe.sh" <<PROBE
source "$repo/debian-init.sh"
trap - EXIT ERR HUP INT TERM
ssh_listener_addresses() { echo '0.0.0.0:53651'; }
fail2ban_package_installed() { return 0; }
ufw() { printf '%s\n' "\$UFW_OUT"; echo 'second line'; }
smartdns() { echo 'smartdns fixture'; }
sing-box() { echo 'sing-box fixture'; }
sysctl() {
  if [[ "\$2" == kernel.printk ]]; then
    [[ "\${PRINTK_LEVEL:-4}" != unknown ]] || return 1
    printf '%s\t4\t1\t7\n' "\${PRINTK_LEVEL:-4}"
  else
    echo bbr
  fi
}
security_updates_enabled() { return 0; }
BOOT_REPORT=''
BACKUP_DIR=/fixture NETWORK_STACK=dual NETWORK_REQUEST=auto SMARTDNS_TRANSPORT=h2 SAFE_CLEANUP_RESULT=ok
print_report
PROBE
  for ufw_out in 'Status: active' 'Status: inactive' 'Status: active (logging)' 'unavailable' ''; do
    UFW_OUT=$ufw_out env -u NO_COLOR TERM=xterm-256color script -qec "bash \"$work/report-probe.sh\"" /dev/null >"$work/pty-ufw.out"
    ufw_row=$(tr -d '\r' <"$work/pty-ufw.out" | grep 'UFW           :' || true)
    [[ -n "$ufw_row" ]] || fail "UFW row missing for [$ufw_out]"
    if [[ "$ufw_out" == 'Status: active' ]]; then
      [[ "$ufw_row" != *$'\033[33m'* ]] || fail 'UFW active row was marked yellow'
    else
      [[ "$ufw_row" == *$'\033[33m'* ]] || fail "UFW row not yellow for [$ufw_out]"
    fi
  done
  for printk_level in 3 4 5 7 unknown; do
    PRINTK_LEVEL=$printk_level UFW_OUT='Status: active' env -u NO_COLOR TERM=xterm-256color script -qec \
      "bash \"$work/report-probe.sh\"" /dev/null >"$work/pty-printk.out"
    printk_row=$(grep -F '控制台日志    :' "$work/pty-printk.out")
    case "$printk_level" in
      3|4) [[ "$printk_row" == *'只显示错误及以上'* && "$printk_row" != *$'\033[33m'* ]] || fail "printk level $printk_level should be normal" ;;
      5|7) [[ "$printk_row" == *$'\033[33m实际级别 '"$printk_level"* ]] || fail "printk level $printk_level was not shown in yellow" ;;
      unknown) [[ "$printk_row" == *$'\033[33m未知'* ]] || fail 'unreadable printk level was not shown as unknown in yellow' ;;
    esac
  done

  # In a PTY the audit heading keeps its level color and the description row is dim.
  env -u NO_COLOR TERM=xterm-256color script -qec \
    "bash -c 'source \"$repo/debian-init.sh\"; AUDIT_FINDINGS=(); AUDIT_SESSION_KEY=x; print_security_audit full'" \
    /dev/null >"$work/pty-audit.out"
  tr -d '\r' <"$work/pty-audit.out" >"$work/pty-audit.txt"
  grep -F 'A 建议删除（0 项）' "$work/pty-audit.txt" | grep -Fq $'\033[33mA 建议删除' || fail 'A heading lost its yellow'
  grep -F '这些是登录钥匙或商家助手' "$work/pty-audit.txt" | grep -Fq $'\033[2m' || fail 'audit description is not dim'

  # Redirecting print_security_audit to a file from inside a PTY must emit zero \033 escapes.
  env -u NO_COLOR TERM=xterm-256color script -qec \
    "bash -c 'source \"$repo/debian-init.sh\"; AUDIT_FINDINGS=(); print_security_audit full >\"$work/pty-redir.txt\"'" \
    /dev/null >/dev/null
  if has_escape "$work/pty-redir.txt"; then fail 'redirected file from PTY contained ANSI escapes'; fi

  # --help stays plain text without box borders or ANSI escapes even in a PTY.
  env -u NO_COLOR TERM=xterm-256color script -qec \
    "bash \"$repo/debian-init.sh\" --help" /dev/null >"$work/pty-help.out"
  if has_escape "$work/pty-help.out"; then fail '--help emitted ANSI escapes'; fi
  if grep -Eq '[╭╮╰╯│─├┤]' "$work/pty-help.out"; then fail '--help drew box borders'; fi

  # ask_yes_no in a real PTY. default=false: the whole "<question> [y/n] " is bold yellow; Enter
  # and other words ask again with the hint; with NO_COLOR or TERM=dumb nothing is escaped.
  yes_no_probe() {
    local input=$1 default=$2 out=$3
    shift 3
    printf '%b' "$input" | timeout 20 env "$@" script -qec \
      "bash -c 'source \"$repo/debian-init.sh\"; trap - EXIT ERR HUP INT TERM; if ask_yes_no 确认删除 $default; then echo RESULT=yes; else echo RESULT=no; fi'" \
      /dev/null >"$out" || fail "ask_yes_no PTY probe did not finish: $input"
    tr -d '\r' <"$out" >"$out.txt"
  }
  hint='请输入 y 确认，或 n 跳过/取消（Ctrl+C 退出）'
  yes_no_probe '\nmaybe\nn\n' false "$work/pty-yn-no.out" -u NO_COLOR TERM=xterm-256color
  grep -Fq $'\033[1m\033[33m确认删除 [y/n] \033[0m' "$work/pty-yn-no.out.txt" || fail '[y/n] prompt is not entirely bold yellow'
  [[ "$(grep -Fo "$hint" "$work/pty-yn-no.out.txt" | wc -l)" == 2 ]] || fail 'Enter and an unknown word must both re-ask'
  grep -Fq 'RESULT=no' "$work/pty-yn-no.out.txt" || fail 'n after re-asks is not no'
  if grep -Fq '[y/N]' "$work/pty-yn-no.out.txt"; then fail 'old [y/N] prompt shown'; fi
  yes_no_probe '\n Yes \n' false "$work/pty-yn-yes.out" -u NO_COLOR TERM=xterm-256color
  grep -Fq 'RESULT=yes' "$work/pty-yn-yes.out.txt" || fail 'Enter then Yes is not yes'
  for env_case in NO_COLOR=1 'TERM=dumb'; do
    if [[ "$env_case" == NO_COLOR=1 ]]; then
      yes_no_probe '\nn\n' false "$work/pty-yn-plain.out" NO_COLOR=1 TERM=xterm-256color
    else
      yes_no_probe '\nn\n' false "$work/pty-yn-plain.out" -u NO_COLOR TERM=dumb
    fi
    if has_escape "$work/pty-yn-plain.out"; then fail "[y/n] prompt escaped with $env_case"; fi
    grep -Fq '确认删除 [y/n] ' "$work/pty-yn-plain.out.txt" || fail "plain [y/n] prompt missing with $env_case"
    grep -Fq "$hint" "$work/pty-yn-plain.out.txt" || fail "plain re-ask hint missing with $env_case"
    grep -Fq 'RESULT=no' "$work/pty-yn-plain.out.txt" || fail "plain n is not no with $env_case"
  done
  # read_tty's warn style (the [9] hostname confirmation) is bold yellow as a whole line.
  printf 'vps-test\n' | timeout 20 env -u NO_COLOR TERM=xterm-256color script -qec \
    "bash -c 'source \"$repo/debian-init.sh\"; trap - EXIT ERR HUP INT TERM; read_tty 请输入本机主机名： answer warn; echo ANSWER=\$answer'" \
    /dev/null >"$work/pty-warn.out" || fail 'warn prompt probe did not finish'
  tr -d '\r' <"$work/pty-warn.out" | grep -Fq $'\033[1m\033[33m请输入本机主机名：\033[0m' || fail 'warn prompt is not bold yellow'
  tr -d '\r' <"$work/pty-warn.out" | grep -Fq 'ANSWER=vps-test' || fail 'warn prompt answer'
  # default=true keeps [Y/n] (cyan Y) and Enter still means yes.
  yes_no_probe '\n' true "$work/pty-yn-default.out" -u NO_COLOR TERM=xterm-256color
  grep -Fq $'[\033[1m\033[36mY\033[0m/n] ' "$work/pty-yn-default.out.txt" || fail '[Y/n] prompt changed'
  grep -Fq 'RESULT=yes' "$work/pty-yn-default.out.txt" || fail '[Y/n] Enter is not yes'

  # /dev/tty is opened for real: available inside a PTY ...
  printf '' | timeout 20 script -qec \
    "bash -c 'source \"$repo/debian-init.sh\"; trap - EXIT ERR HUP INT TERM; if tty_available; then echo TTY=yes; else echo TTY=no; fi'" \
    /dev/null >"$work/pty-avail.out" || fail 'tty_available PTY probe did not finish'
  grep -Fq 'TTY=yes' "$work/pty-avail.out" || fail 'tty_available false inside a PTY'
  # ... and not without a controlling terminal, although /dev/tty's permission bits allow it.
  if command -v setsid >/dev/null 2>&1; then
    # shellcheck disable=SC2016 # Expanded by the inner bash.
    no_ctty=$(setsid -w bash -c 'source "$1"; trap - EXIT ERR HUP INT TERM
      if tty_available; then echo TTY=yes; else echo TTY=no; fi
      CONFIG_CONFIRMED=false; read_tty "Q: " answer; echo READ=returned' _ "$repo/debian-init.sh" </dev/null 2>&1 || true)
    grep -Fq 'TTY=no' <<<"$no_ctty" || fail "tty_available true without a controlling terminal: $no_ctty"
    grep -Fq '需要交互输入，但当前没有可用 /dev/tty。' <<<"$no_ctty" || fail "read_tty did not die without a controlling terminal: $no_ctty"
    if grep -Fq 'READ=returned' <<<"$no_ctty"; then fail 'read_tty returned without a terminal'; fi
  fi
fi

echo 'PASS: UI color gates, NO_COLOR/TERM=dumb, Unicode/ASCII box widths, wrapping and PTY checks'
