#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034 # Mocks/state used by sourced installer functions.
# Menu option 4 (install/upgrade sing-box) against a fake apt/systemd/sing-box.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

root="$work/root"
sed -e "s|^readonly POLICY_RC_D=.*|readonly POLICY_RC_D='$root/usr-sbin/policy-rc.d'|" \
  -e "s|^readonly POLICY_RC_D_BACKUP=.*|readonly POLICY_RC_D_BACKUP='$root/usr-sbin/policy-rc.d.404-vps-backup'|" \
  -e "s|^readonly SINGBOX_CONFIG=.*|readonly SINGBOX_CONFIG='$root/etc/sing-box/config.json'|" \
  -e "s|^readonly SINGBOX_DROPIN_DIR=.*|readonly SINGBOX_DROPIN_DIR='$root/etc/sing-box.service.d'|" \
  -e "s|^readonly SINGBOX_DROPIN=.*|readonly SINGBOX_DROPIN='$root/etc/sing-box.service.d/10-gate.conf'|" \
  -e "s|^readonly SINGBOX_MANAGED_MARKER=.*|readonly SINGBOX_MANAGED_MARKER='$root/var/sing-box-managed'|" \
  "$repo/debian-init.sh" >"$work/installer"
# shellcheck disable=SC1091
source "$work/installer"
trap - ERR HUP INT TERM EXIT

mkdir -p "$work/bin"
cat >"$work/bin/sing-box" <<'EOF'
#!/bin/sh
echo "$*" >>"$SB_CASE_DIR/check-args"
if [ "$(cat "$SB_CASE_DIR/check")" = fail ]; then
  echo 'decode config at /etc/sing-box/config.json: unknown field "legacy_option"'
  exit 1
fi
exit 0
EOF
chmod 0755 "$work/bin/sing-box"

# Defaults: 1.12.0 installed, running, configured; 1.13.0 is the latest stable.
setup_case() {
  c="$work/cases/$1"
  rm -rf -- "$root"
  mkdir -p "$c/tmp" "$root/usr-sbin" "$root/etc/sing-box" "$root/etc/sing-box.service.d" "$root/var"
  printf '1.12.0\n' >"$c/version"
  printf '1.13.0\n' >"$c/latest"
  printf '1.13.0\n1.12.0\n1.11.0\n' >"$c/repo"
  printf 'yes\n' >"$c/active"
  printf 'yes\n' >"$c/enabled"
  : >"$c/held"
  : >"$c/trace"
  printf 'C\n' >"$c/exec"
  printf 'pass\n' >"$c/check"
  printf 'ok\n' >"$c/restart"
  printf 'ok\n' >"$c/start"
  : >"$c/apt-fail"
  printf '{}\n' >"$root/etc/sing-box/config.json"
}

# $1 = scenario dir name, rest = extra arguments for parse_args. Output: $c/output, status: $c/rc.
run_case() {
  local mode=${2:-}
  export SB_CASE_DIR="$c"
  set +e
  (
    set -Ee
    trap cleanup EXIT
    trap 'on_error $LINENO' ERR
    trap 'on_signal TERM' TERM
    TMP_DIR="$c/tmp" BACKUP_DIR="$c/backup"
    mkdir -p "$BACKUP_DIR"
    SING_BOX_VERSION=${SB_VERSION:-}
    t() { printf '%s\n' "$*" >>"$c/trace"; }
    policy_state() { if grep -Fq 'exit 101' "$POLICY_RC_D" 2>/dev/null; then echo blocked; else echo open; fi; }
    configure_sagernet_repo() { t repo; }
    sleep() { :; }
    journalctl() { echo 'sing-box[1]: FATAL start service: listen tcp 127.0.0.1:1: address already in use'; }
    apt_get() {
      local IFS=' ' last=${*: -1}
      t "apt $*"
      case "$1" in
        update) return 0 ;;
        install)
          t "policy=$(policy_state) needrestart=${NEEDRESTART_MODE:-unset}"
          [[ "$(policy_state)" == blocked ]] || fail 'package operation ran without the restart block'
          [[ "$NEEDRESTART_MODE" == l ]] || fail 'needrestart could restart the service'
          if [[ "$mode" == signal-install ]]; then on_signal TERM; fi
          if grep -Fxq "$last" "$c/apt-fail"; then return 100; fi
          case "$last" in
            sing-box=*) printf '%s\n' "${last#sing-box=}" >"$c/version" ;;
            sing-box)
              if [[ ! -s "$c/version" ]]; then printf '{"default":true}\n' >"$SINGBOX_CONFIG"; fi
              if [[ -s "$c/version" && "$*" != *--only-upgrade* ]]; then :; else cp "$c/latest" "$c/version"; fi ;;
          esac ;;
        *) fail "unexpected apt-get $*" ;;
      esac
    }
    apt-cache() { sed -e 's/^/ sing-box | /' -e 's/$/ | https:\/\/deb.sagernet.org stable\/main Packages/' "$c/repo"; }
    apt-mark() { [[ "$1" == showhold ]] || fail "unexpected apt-mark $*"; cat "$c/held"; }
    dpkg-query() {
      local IFS=' ' args="$*"
      [[ -s "$c/version" ]] || return 1
      case "$args" in
        *Status-Status*) printf installed ;;
        *Version*) tr -d '\n' <"$c/version" ;;
        *) printf 'sing-box\n' ;;
      esac
    }
    systemctl() {
      local IFS=' '
      case "$1" in
        is-active)
          if [[ "$2" != --quiet ]]; then if [[ "$(cat "$c/active")" == yes ]]; then echo active; else echo inactive; fi; return 0; fi
          [[ "$(cat "$c/active")" == yes ]] ;;
        is-enabled)
          if [[ "$2" != --quiet ]]; then if [[ "$(cat "$c/enabled")" == yes ]]; then echo enabled; else echo disabled; fi; return 0; fi
          [[ "$(cat "$c/enabled")" == yes ]] ;;
        enable) t enable; echo yes >"$c/enabled" ;;
        stop) t stop; echo no >"$c/active" ;;
        restart)
          t "restart policy=$(policy_state)"
          if [[ "$(cat "$c/restart")" == ok ]]; then echo yes >"$c/active"; else echo no >"$c/active"; return 1; fi ;;
        start)
          t "start policy=$(policy_state)"
          if [[ "$(cat "$c/start")" == ok ]]; then echo yes >"$c/active"; else return 1; fi ;;
        reset-failed|daemon-reload) t "$1" ;;
        show)
          case "$(cat "$c/exec")" in
            C) argv="$work/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run" ;;
            c) argv="$work/bin/sing-box run -c /etc/sing-box/config.json" ;;
            eq) argv="$work/bin/sing-box -D /var/lib/sing-box --config-directory=/etc/sing-box run" ;;
            none) argv="$work/bin/sing-box run" ;;
          esac
          printf 'ExecStart={ path=%s ; argv[]=%s ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n' "$work/bin/sing-box" "$argv" ;;
        *) fail "unexpected systemctl $*" ;;
      esac
    }
    if [[ "$mode" == original-policy ]]; then :; fi
    upgrade_sing_box
  ) >"$c/output" 2>&1
  printf '%s\n' "$?" >"$c/rc"
  set -e
}

rc_of() { cat "$c/rc"; }
trace_has() { grep -Fxq -- "$1" "$c/trace"; }
trace_count() { grep -c -- "$1" "$c/trace" || true; }
out_has() { grep -Fq -- "$1" "$c/output" || { cat "$c/output"; fail "output lacks: $1"; }; }
out_lacks() { if grep -Fq -- "$1" "$c/output"; then cat "$c/output"; fail "output has: $1"; fi; }
policy_clean() { [[ ! -e "$root/usr-sbin/policy-rc.d" && ! -e "$root/usr-sbin/policy-rc.d.404-vps-backup" ]]; }
expect_rc() { [[ "$(rc_of)" == "$1" ]] || { cat "$c/output"; fail "rc=$(rc_of), expected $1 in $c"; }; }

# 1. First install: stable package, no check, never started, boot-enabled behind the config gate.
setup_case fresh
: >"$c/version"; echo no >"$c/active"; echo no >"$c/enabled"; rm -f "$root/etc/sing-box/config.json"
run_case
expect_rc 0
trace_has 'apt install -y sing-box'
[[ "$(cat "$c/version")" == 1.13.0 ]]
[[ ! -e "$c/check-args" ]]
[[ "$(trace_count '^restart')" == 0 && "$(trace_count '^start')" == 0 ]]
[[ ! -e "$root/etc/sing-box/config.json" ]] || fail 'default config left behind'
[[ -s "$root/etc/sing-box.service.d/10-gate.conf" && -s "$root/var/sing-box-managed" ]]
[[ "$(cat "$c/enabled")" == yes && "$(cat "$c/active")" == no ]]
out_has '未安装 → 1.13.0'
out_has '未检查（首次安装）'
policy_clean

# 2. Configured and running, check passes: restart after the restart block is gone (PID kept until then).
setup_case upgrade-restart
run_case
expect_rc 0
trace_has 'apt install -y --only-upgrade sing-box'
trace_has 'policy=blocked needrestart=l'
trace_has 'restart policy=open'
[[ "$(trace_count '^restart')" == 1 && "$(trace_count '^start')" == 0 ]]
[[ "$(cat "$c/check-args")" == 'check -D /var/lib/sing-box -C /etc/sing-box' ]]
[[ "$(cat "$c/version")" == 1.13.0 && "$(cat "$c/active")" == yes && "$(cat "$c/enabled")" == yes ]]
out_has '1.12.0 → 1.13.0'
out_has 'sing-box check -D /var/lib/sing-box -C /etc/sing-box'
out_has '配置检查：通过'
out_has '已重启：是'
out_has '已降级：否'
policy_clean

# 3. Check fails: downgrade, running process untouched, no restart.
setup_case check-fail
echo fail >"$c/check"
run_case
expect_rc 0
trace_has 'apt install -y --allow-downgrades sing-box=1.12.0'
[[ "$(cat "$c/version")" == 1.12.0 && "$(cat "$c/active")" == yes ]]
[[ "$(trace_count '^restart')" == 0 && "$(trace_count '^start')" == 0 ]]
out_has '新版本 1.13.0 与现有配置不兼容，已回退到 1.12.0'
out_has 'unknown field "legacy_option"'
out_has '配置检查：未通过'
out_has '已降级：是（1.13.0 → 1.12.0）'
[[ "$(cat "$c/enabled")" == yes ]]
policy_clean

# 4. Restart fails: downgrade, then start the service again.
setup_case restart-fail
echo fail >"$c/restart"
run_case
expect_rc 0
trace_has 'apt install -y --allow-downgrades sing-box=1.12.0'
trace_has 'reset-failed'
trace_has 'start policy=open'
[[ "$(cat "$c/version")" == 1.12.0 && "$(cat "$c/active")" == yes ]]
out_has '已重启：失败，已回退并重新启动'
out_has 'address already in use'
policy_clean

# 5. Cannot downgrade (old version gone from the repository): loud warning, no restart, non-zero exit.
setup_case no-downgrade-check
echo fail >"$c/check"
printf '1.13.0\n' >"$c/repo"
run_case
[[ "$(rc_of)" != 0 ]] || fail 'unrecoverable incompatibility exited 0'
out_has '重启后 sing-box 将无法启动，请先修改配置'
out_has '已降级：失败'
[[ "$(trace_count '^restart')" == 0 && "$(trace_count '^start')" == 0 ]]
[[ "$(cat "$c/version")" == 1.13.0 && "$(cat "$c/active")" == yes ]]
policy_clean

setup_case no-downgrade-restart
echo fail >"$c/restart"
printf '1.13.0\n' >"$c/repo"
run_case
[[ "$(rc_of)" != 0 ]] || fail 'unrecoverable restart failure exited 0'
out_has '重启后 sing-box 将无法启动，请先修改配置'
[[ "$(trace_count '^start')" == 0 ]]
policy_clean

# A downgrade that apt itself rejects is reported the same way.
setup_case downgrade-apt-fail
echo fail >"$c/check"
echo 'sing-box=1.12.0' >"$c/apt-fail"
run_case
[[ "$(rc_of)" != 0 ]] || fail 'failed downgrade exited 0'
out_has '重启后 sing-box 将无法启动，请先修改配置'
policy_clean

# 6. Permanent hold: skip the upgrade, still boot-enable.
setup_case held
printf 'operator-package\nsing-box\n' >"$c/held"
echo no >"$c/enabled"
run_case
expect_rc 0
[[ "$(trace_count '^apt install')" == 0 ]]
[[ ! -e "$c/check-args" && "$(trace_count '^restart')" == 0 ]]
[[ "$(cat "$c/version")" == 1.12.0 && "$(cat "$c/enabled")" == yes ]]
out_has '已被 hold，跳过升级'
out_has '1.12.0 → 1.12.0'
policy_clean

# 7. No config / same version: no check, no restart.
setup_case no-config
rm -f "$root/etc/sing-box/config.json"; echo no >"$c/active"
run_case
expect_rc 0
[[ "$(cat "$c/version")" == 1.13.0 && ! -e "$c/check-args" && "$(trace_count '^restart')" == 0 && "$(trace_count '^start')" == 0 ]]
out_has '未检查（没有配置）'
[[ "$(cat "$c/enabled")" == yes ]]

setup_case same-version
echo 1.13.0 >"$c/version"
run_case
expect_rc 0
[[ ! -e "$c/check-args" && "$(trace_count '^restart')" == 0 ]]
out_has '未检查（版本未变化）'

# Configured but stopped: checked, but never started.
setup_case stopped
echo no >"$c/active"
run_case
expect_rc 0
[[ -e "$c/check-args" && "$(trace_count '^restart')" == 0 && "$(trace_count '^start')" == 0 && "$(cat "$c/active")" == no ]]
out_has '否（原本未运行）'

# 8. ExecStart forms: -C directory, -c file, --config-directory=, and one that names no config.
setup_case exec-c
echo c >"$c/exec"
run_case
expect_rc 0
[[ "$(cat "$c/check-args")" == 'check -c /etc/sing-box/config.json' ]]

setup_case exec-eq
echo eq >"$c/exec"
run_case
expect_rc 0
[[ "$(cat "$c/check-args")" == 'check -D /var/lib/sing-box --config-directory=/etc/sing-box' ]]

setup_case exec-none
echo none >"$c/exec"
run_case
expect_rc 0
[[ ! -e "$c/check-args" ]]
out_has 'ExecStart 中没有 -c/-C 配置参数'
out_has '已回退到 1.12.0'
[[ "$(cat "$c/version")" == 1.12.0 && "$(trace_count '^restart')" == 0 ]]

# 9. --sing-box-version: exact version (even older), must exist in the repository.
setup_case pinned
SB_VERSION=1.11.0 run_case
expect_rc 0
trace_has 'apt install -y --allow-downgrades sing-box=1.11.0'
[[ "$(cat "$c/version")" == 1.11.0 && "$(trace_count '^restart')" == 1 ]]

setup_case pinned-missing
SB_VERSION=9.9.9 run_case
[[ "$(rc_of)" != 0 ]]
out_has '仓库中找不到 sing-box=9.9.9'
[[ "$(trace_count '^apt install')" == 0 ]]
policy_clean

# 10. policy-rc.d is restored on success, failure and interruption, with or without an original.
original_policy() {
  printf '#!/bin/sh\n# original policy\nexit 0\n' >"$root/usr-sbin/policy-rc.d"
  chmod 0751 "$root/usr-sbin/policy-rc.d"
  cp -p "$root/usr-sbin/policy-rc.d" "$c/original-policy"
}
policy_unchanged() {
  cmp -s "$root/usr-sbin/policy-rc.d" "$c/original-policy" || fail 'original policy-rc.d changed'
  [[ "$(stat -c %a "$root/usr-sbin/policy-rc.d")" == 751 ]] || fail 'original policy-rc.d mode changed'
  [[ ! -e "$root/usr-sbin/policy-rc.d.404-vps-backup" ]] || fail 'policy-rc.d backup left behind'
}

setup_case policy-orig-success; original_policy
run_case; expect_rc 0
policy_unchanged
trace_has 'policy=blocked needrestart=l'

setup_case policy-orig-downgrade; original_policy
echo fail >"$c/check"
run_case; expect_rc 0
[[ "$(trace_count 'policy=blocked')" == 2 ]]
policy_unchanged

setup_case policy-failure
echo 'sing-box' >"$c/apt-fail"
run_case
[[ "$(rc_of)" != 0 ]]
out_has 'sing-box 安装/升级失败'
policy_clean

setup_case policy-orig-failure; original_policy
echo 'sing-box' >"$c/apt-fail"
run_case
[[ "$(rc_of)" != 0 ]]
policy_unchanged

setup_case policy-signal
run_case "" signal-install
[[ "$(rc_of)" == 130 ]]
policy_clean
[[ "$(cat "$c/version")" == 1.12.0 ]]

setup_case policy-orig-signal; original_policy
run_case "" signal-install
[[ "$(rc_of)" == 130 ]]
policy_unchanged

# Leftover from a killed run: our own stub plus a backup is rolled back; a foreign file is not touched.
setup_case policy-leftover; original_policy
mv "$root/usr-sbin/policy-rc.d" "$root/usr-sbin/policy-rc.d.404-vps-backup"
printf '#!/bin/sh\n%s\nexit 101\n' "$POLICY_RC_D_MARK" >"$root/usr-sbin/policy-rc.d"
run_case; expect_rc 0
out_has '已还原上次中断遗留'
policy_unchanged

setup_case policy-foreign; original_policy
cp -p "$root/usr-sbin/policy-rc.d" "$root/usr-sbin/policy-rc.d.404-vps-backup"
printf '#!/bin/sh\n# someone else\nexit 0\n' >"$root/usr-sbin/policy-rc.d"
run_case
[[ "$(rc_of)" != 0 ]]
out_has '请先手动确认并还原'
grep -Fq 'someone else' "$root/usr-sbin/policy-rc.d"

# Dispatch: option 4 and --sing-box-only reach the same installer, without a TTY or the old wizard.
grep -Fq '4. 安装/升级 sing-box' "$repo/debian-init.sh"
if grep -qE 'run_node_config_wizard|SINGBOX_WIZARD|persist_network_stack' "$repo/debian-init.sh"; then fail 'wizard code is still present'; fi
[[ ! -e "$repo/templates" ]] || fail 'templates directory is still present'
echo 'PASS: sing-box install/upgrade, check-before-restart, downgrade, hold, ExecStart forms and policy-rc.d restore'
