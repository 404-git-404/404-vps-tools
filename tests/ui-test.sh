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
  sysctl() { echo 'bbr'; }
  security_updates_enabled() { return 1; }
  BOOT_REPORT=$'ssh.service: enabled / active \n'
  BACKUP_DIR='/root/vps-init-backups/fixture'
  NETWORK_STACK='dual'
  SMARTDNS_TRANSPORT='h2'
  SAFE_CLEANUP_RESULT='已完成'
  print_report
) >"$work/non-tty.out" 2>"$work/non-tty.err"

if has_escape "$work/non-tty.out"; then fail 'non-TTY stdout contained ANSI escapes'; fi
if has_escape "$work/non-tty.err"; then fail 'non-TTY stderr contained ANSI escapes'; fi
grep -Fxq '[INFO] info line' "$work/non-tty.out" || fail 'log prefix broken on non-TTY'
grep -Fxq '[WARN] warn line' "$work/non-tty.err" || fail 'warn prefix broken on non-TTY'

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

# 4. Overlong lines are printed intact without truncation, without wrapping, and without right border.
long_text='1. 恢复 IPv6：写入脚本管理的 /etc/sysctl.d/99-vps-init-network.conf 覆盖上述设置（不修改原有文件）TAIL_MARKER_END'
(
  export NO_COLOR=1 TERM=xterm-256color
  # shellcheck disable=SC1091
  source "$repo/debian-init.sh"
  trap - EXIT ERR HUP INT TERM
  ui_init
  UI_WIDTH=72
  ui_box_line "$long_text"
) >"$work/overflow.out"
[[ "$(wc -l <"$work/overflow.out")" -eq 1 ]] || fail 'overflow line wrapped'
grep -Fxq "│ $long_text" "$work/overflow.out" || fail 'overflow line truncated or kept right border'

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
fi

echo 'PASS: UI color gates, NO_COLOR/TERM=dumb, Unicode/ASCII box widths, overflow and PTY checks'
