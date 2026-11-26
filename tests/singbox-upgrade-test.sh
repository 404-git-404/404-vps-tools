#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034 # Mocks/state used by sourced installer functions.
# Menu option 4 (install/upgrade sing-box). apt-get, systemctl, dpkg-query ... are fake executables
# on PATH, so the real apt_get wrapper and the real signal handlers run.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

root="$work/root" bin="$work/bin" fakebin="$work/fakebin"
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

mkdir -p "$bin/other" "$fakebin"
# --- fake sing-box: records "<cwd>|<args>" and fails "check" when told to -----------------------
cat >"$bin/sing-box" <<'EOF'
#!/bin/sh
echo "$PWD|$*" >>"$SB_CASE_DIR/check-args"
if [ "$(cat "$SB_CASE_DIR/check")" = fail ]; then
  echo 'FATAL decode config at config.json: bogus_option: json: unknown field "bogus_option"'
  exit 1
fi
exit 0
EOF
cp "$bin/sing-box" "$bin/other/not-sing-box"
chmod 0755 "$bin/sing-box" "$bin/other/not-sing-box"

# --- fake system commands ------------------------------------------------------------------------
cat >"$fakebin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$fakebin/journalctl" <<'EOF'
#!/bin/sh
echo 'sing-box[1]: FATAL start service: listen tcp 127.0.0.1:1: address already in use'
EOF
cat >"$fakebin/apt-mark" <<'EOF'
#!/bin/sh
[ "$1" = showhold ] || { echo "unexpected apt-mark $*" >&2; exit 2; }
cat "$SB_CASE_DIR/held"
EOF
cat >"$fakebin/apt-cache" <<'EOF'
#!/bin/sh
sed -e 's/^/ sing-box | /' -e 's/$/ | https:\/\/deb.sagernet.org *\/* amd64 Packages/' "$SB_CASE_DIR/repo"
EOF
cat >"$fakebin/dpkg-query" <<'EOF'
#!/bin/sh
c=$SB_CASE_DIR
[ -s "$c/version" ] || exit 1
case "$*" in
  *Status-Status*) printf installed ;;
  *Version*) printf '%s' "$(cat "$c/version")" ;;
  *) echo sing-box ;;
esac
EOF
cat >"$fakebin/apt-get" <<'EOF'
#!/bin/sh
c=$SB_CASE_DIR
while [ "$1" = -o ]; do shift 2; done
echo "apt-get $*" >>"$c/trace"
cmd=$1; shift
case "$cmd" in
  update) exit 0 ;;
  install)
    for last; do :; done
    policy=open
    if grep -q 'exit 101' "$SB_POLICY" 2>/dev/null; then policy=blocked; fi
    echo "policy=$policy needrestart=${NEEDRESTART_MODE:-unset}" >>"$c/trace"
    if [ -e "$c/apt-sleep" ]; then : >"$c/apt-started"; /bin/sleep "$(cat "$c/apt-sleep")"; fi
    if grep -Fxq "$last" "$c/apt-fail" 2>/dev/null; then echo 'E: Sub-process /usr/bin/dpkg returned an error code (1)' >&2; exit 100; fi
    case "$last" in
      sing-box=*) echo "${last#sing-box=}" >"$c/version" ;;
      sing-box)
        if [ ! -s "$c/version" ]; then
          mkdir -p "$(dirname "$SB_CONFIG")"
          # dpkg keeps a config.json that is already there (--force-confold).
          [ -e "$SB_CONFIG" ] || echo '{"default":true}' >"$SB_CONFIG"
          cp "$c/latest" "$c/version"
        else
          case " $* " in *' --only-upgrade '*) cp "$c/latest" "$c/version" ;; esac
        fi ;;
    esac
    # The package's own maintainer script restarts a running service unless policy-rc.d refuses.
    if [ -e "$c/pkg-restart" ] && [ "$(cat "$c/active")" = yes ]; then
      mode=$(cat "$c/pkg-restart")
      case "$mode:$last" in bypass-upgrade:sing-box=*) mode=honor ;; esac
      if [ "$mode" != honor ] || [ "$policy" = open ]; then
        echo $(( $(cat "$c/pid") + 1 )) >"$c/pid"; echo 'package restarted service' >>"$c/trace"
        if [ "$mode" = bypass-down ]; then echo no >"$c/active"; fi
      fi
    fi ;;
  *) echo "unexpected apt-get $cmd" >&2; exit 2 ;;
esac
EOF
cat >"$fakebin/systemctl" <<'EOF'
#!/bin/sh
c=$SB_CASE_DIR
cmd=$1; shift
policy() { if grep -q 'exit 101' "$SB_POLICY" 2>/dev/null; then echo blocked; else echo open; fi; }
state() { if [ "$(cat "$c/$1")" = yes ]; then echo "$2"; else echo "$3"; fi; }
case "$cmd" in
  is-active)
    s=$(state active active inactive)
    [ "$1" = --quiet ] || echo "$s"
    [ "$s" = active ] || exit 3 ;;
  is-enabled)
    s=$(state enabled enabled disabled)
    [ "$1" = --quiet ] || echo "$s"
    [ "$s" = enabled ] || exit 1 ;;
  enable) echo enable >>"$c/trace"; echo yes >"$c/enabled" ;;
  stop) echo stop >>"$c/trace"; echo no >"$c/active" ;;
  restart)
    echo "restart policy=$(policy)" >>"$c/trace"
    if [ "$(cat "$c/restart")" = ok ]; then echo yes >"$c/active"; echo $(( $(cat "$c/pid") + 1 )) >"$c/pid"; else echo no >"$c/active"; exit 1; fi ;;
  start)
    echo "start policy=$(policy)" >>"$c/trace"
    if [ "$(cat "$c/start")" = ok ]; then echo yes >"$c/active"; echo $(( $(cat "$c/pid") + 1 )) >"$c/pid"; else exit 1; fi ;;
  reset-failed|daemon-reload) echo "$cmd" >>"$c/trace" ;;
  show)
    prop=
    while [ $# -gt 0 ]; do if [ "$1" = -p ]; then prop=$2; shift; fi; shift; done
    case "$prop" in
      ExecStart) cat "$c/execstart" ;;
      WorkingDirectory) cat "$c/wd" ;;
      Environment) cat "$c/environment" ;;
      EnvironmentFiles) cat "$c/environmentfiles" ;;
      MainPID) if [ "$(cat "$c/active")" = yes ]; then cat "$c/pid"; else echo 0; fi ;;
      *) echo "unexpected property $prop" >&2; exit 2 ;;
    esac ;;
  *) echo "unexpected systemctl $cmd" >&2; exit 2 ;;
esac
EOF
chmod 0755 "$fakebin"/*

# The line systemctl prints for `show -p ExecStart --value` (no "ExecStart=" prefix).
exec_line() {
  printf '{ path=%s ; argv[]=%s ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n' "$1" "$2"
}
set_exec() { local IFS=" "; exec_line "$bin/sing-box" "$bin/sing-box $*" >"$c/execstart"; }

# Defaults: 1.12.0 installed, running (PID 100), configured, standard unit; 1.13.0 is the latest.
setup_case() {
  c="$work/cases/$1"
  rm -rf -- "$root"
  mkdir -p "$c/tmp" "$root/usr-sbin" "$root/etc/sing-box" "$root/etc/sing-box.service.d" "$root/var/lib/sing-box"
  printf '1.12.0\n' >"$c/version"
  printf '1.13.0\n' >"$c/latest"
  printf '1.13.0\n1.12.0\n1.11.0\n' >"$c/repo"
  printf 'yes\n' >"$c/active"
  printf 'yes\n' >"$c/enabled"
  printf '100\n' >"$c/pid"
  : >"$c/held"
  : >"$c/trace"
  : >"$c/apt-fail"
  printf 'pass\n' >"$c/check"
  printf 'ok\n' >"$c/restart"
  printf 'ok\n' >"$c/start"
  printf '%s\n' "$root/var/lib/sing-box" >"$c/wd"
  : >"$c/environment"
  : >"$c/environmentfiles"
  set_exec -D "$root/var/lib/sing-box" -C "$root/etc/sing-box" run
  printf '{}\n' >"$root/etc/sing-box/config.json"
}

# run_case reads SB_VERSION (--sing-box-version), SB_MODE (a failing file operation) and
# SB_SIGNALS (real kill -SIG, the first during apt-get, the rest during the slow rollback).
SB_VERSION='' SB_MODE='' SB_SIGNALS=''
run_case() {
  export SB_CASE_DIR="$c" SB_POLICY="$root/usr-sbin/policy-rc.d" SB_CONFIG="$root/etc/sing-box/config.json"
  local pid i sig
  local -a signals=()
  set +e
  (
    set -Ee
    trap cleanup EXIT
    trap 'on_error $LINENO' ERR
    trap 'on_signal HUP' HUP
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM
    PATH="$fakebin:$PATH"
    TMP_DIR="$c/tmp" BACKUP_DIR="$c/backup"
    if [[ "$SB_MODE" == fail-printf ]]; then TMP_DIR="$c/no-such-dir"; fi
    mkdir -p "$BACKUP_DIR"
    SING_BOX_VERSION=$SB_VERSION
    configure_sagernet_repo() { echo repo >>"$c/trace"; }
    mv() { if [[ "$SB_MODE" == fail-mv && "$1 $2" == "-- $POLICY_RC_D" ]]; then return 1; fi; command mv "$@"; }
    install() { if [[ "$SB_MODE" == fail-install && "${*: -1}" == "$POLICY_RC_D" ]]; then return 1; fi; command install "$@"; }
    if [[ -n "$SB_SIGNALS" ]]; then
      echo 1 >"$c/apt-sleep"
      rollback_ufw() { echo called >>"$c/rollback-calls"; : >"$c/rollback-started"; /bin/sleep 1; }
    fi
    upgrade_sing_box
  ) >"$c/output" 2>&1 &
  pid=$!
  if [[ -n "$SB_SIGNALS" ]]; then
    IFS=" " read -r -a signals <<<"$SB_SIGNALS"
    for i in {1..100}; do [[ -e "$c/apt-started" ]] && break; /bin/sleep 0.1; done
    [[ -e "$c/apt-started" ]] || fail 'apt-get never started'
    kill -"${signals[0]}" "$pid"
    # The handler runs once apt-get returns; the next signals must land in the middle of the rollback.
    for i in {1..100}; do [[ -e "$c/rollback-started" ]] && break; /bin/sleep 0.1; done
    [[ -e "$c/rollback-started" ]] || fail 'rollback never started'
    if grep -Fq 'exit 101' "$root/usr-sbin/policy-rc.d" 2>/dev/null; then
      fail 'policy-rc.d was not restored before the slow rollback steps'
    fi
    for sig in "${signals[@]:1}"; do kill -"$sig" "$pid"; done
  fi
  wait "$pid"
  printf '%s\n' "$?" >"$c/rc"
  set -e
  SB_VERSION='' SB_MODE='' SB_SIGNALS=''
}

rc_of() { cat "$c/rc"; }
trace_has() { grep -Fxq -- "$1" "$c/trace" || { cat "$c/trace" "$c/output"; fail "trace lacks: $1"; }; }
trace_count() { grep -c -- "$1" "$c/trace" || true; }
out_has() { grep -Fq -- "$1" "$c/output" || { cat "$c/output"; fail "output lacks: $1"; }; }
out_lacks() { if grep -Fq -- "$1" "$c/output"; then cat "$c/output"; fail "output has: $1"; fi; }
policy_clean() { [[ ! -e "$root/usr-sbin/policy-rc.d" && ! -L "$root/usr-sbin/policy-rc.d" && ! -e "$root/usr-sbin/policy-rc.d.404-vps-backup" ]] || fail "policy-rc.d residue in $c"; }
expect_rc() { [[ "$(rc_of)" == "$1" ]] || { cat "$c/output"; fail "rc=$(rc_of), expected $1 in $c"; }; }
expect_fail() { [[ "$(rc_of)" != 0 ]] || { cat "$c/output"; fail "rc=0, expected failure in $c"; }; }
no_install() { [[ "$(trace_count '^apt-get install')" == 0 ]] || fail "unexpected package operation in $c"; }
check_args() { cat "$c/check-args"; }
gate_is_new() { grep -Fxq 'ConditionPathExistsGlob=/etc/sing-box/*.json' "$root/etc/sing-box.service.d/10-gate.conf"; }

# 1. First install: stable package, no check, never started, boot-enabled behind the config gate.
setup_case fresh
: >"$c/version"; echo no >"$c/active"; echo no >"$c/enabled"; rm -f "$root/etc/sing-box/config.json"
run_case
expect_rc 0
trace_has 'apt-get install -y sing-box'
[[ "$(cat "$c/version")" == 1.13.0 ]]
[[ ! -e "$c/check-args" ]]
[[ "$(trace_count '^restart')" == 0 && "$(trace_count '^start')" == 0 ]]
[[ ! -e "$root/etc/sing-box/config.json" ]] || fail 'default config left behind'
[[ -s "$root/etc/sing-box.service.d/10-gate.conf" && -s "$root/var/sing-box-managed" ]]
gate_is_new
[[ "$(cat "$c/enabled")" == yes && "$(cat "$c/active")" == no ]]
out_has '未安装 → 1.13.0'
out_has '未检查（首次安装）'
policy_clean

# 2. Configured and running, check passes: restart only after the restart block is gone.
setup_case upgrade-restart
run_case
expect_rc 0
trace_has 'apt-get install -y --only-upgrade sing-box'
trace_has 'policy=blocked needrestart=l'
trace_has 'restart policy=open'
[[ "$(trace_count '^restart')" == 1 && "$(trace_count '^start')" == 0 ]]
[[ "$(trace_count 'package restarted')" == 0 ]]
[[ "$(check_args)" == "$root/var/lib/sing-box|check -D $root/var/lib/sing-box -C $root/etc/sing-box" ]]
[[ "$(cat "$c/version")" == 1.13.0 && "$(cat "$c/active")" == yes && "$(cat "$c/enabled")" == yes ]]
[[ "$(cat "$c/pid")" == 101 ]]
out_has '1.12.0 → 1.13.0'
out_has '配置检查：通过'
out_has '已重启：是'
out_has '已降级：否'
out_has '软件包自行重启服务：否'
# The units are reloaded before the restart (the gate is not written in this unmanaged case).
awk '/^daemon-reload$/ && !d {d=NR} /^restart policy=open$/ && !r {r=NR} END{exit !(d && r && d < r)}' "$c/trace" || { cat "$c/trace"; fail 'daemon-reload before restart'; }
policy_clean

# 3. Check fails: downgrade, running process untouched, no restart.
setup_case check-fail
echo fail >"$c/check"
run_case
expect_rc 0
trace_has 'apt-get install -y --allow-downgrades sing-box=1.12.0'
[[ "$(cat "$c/version")" == 1.12.0 && "$(cat "$c/active")" == yes && "$(cat "$c/pid")" == 100 ]]
[[ "$(trace_count '^restart')" == 0 && "$(trace_count '^start')" == 0 && "$(trace_count '^stop')" == 0 ]]
out_has '新版本 1.13.0 与现有配置不兼容，已回退到 1.12.0'
out_has 'unknown field "bogus_option"'
out_has '配置检查：未通过'
out_has '已降级：是（1.13.0 → 1.12.0）'
[[ "$(cat "$c/enabled")" == yes ]]
policy_clean

# 4. Restart fails: downgrade, then stop / daemon-reload / reset-failed / start in that order.
setup_case restart-fail
echo fail >"$c/restart"
run_case
expect_rc 0
trace_has 'apt-get install -y --allow-downgrades sing-box=1.12.0'
awk '/^stop$/ && !s {s=NR} s && /^daemon-reload$/ && !d {d=NR} d && /^reset-failed$/ && !r {r=NR} r && /^start policy=open$/ && !t {t=NR} END{exit !t}' "$c/trace" ||
  { cat "$c/trace"; fail 'stop, daemon-reload, reset-failed, start order after downgrade'; }
[[ "$(cat "$c/version")" == 1.12.0 && "$(cat "$c/active")" == yes ]]
out_has '服务曾中断，已回退并重新启动'
out_has 'address already in use'
policy_clean

# 4b. Restart fails, the downgrade works, but the old version does not start either: failure, loud.
setup_case restart-fail-start-fail
echo fail >"$c/restart"; echo fail >"$c/start"
run_case
expect_fail
out_has '服务已中断，当前未运行'
out_has '服务中断，回退后仍未能启动'
out_has '已降级：是（1.13.0 → 1.12.0）'
[[ "$(cat "$c/version")" == 1.12.0 && "$(cat "$c/active")" == no ]]
policy_clean

# 5. Cannot downgrade (old version gone from the repository, or apt refuses).
setup_case no-downgrade-check
echo fail >"$c/check"
printf '1.13.0\n' >"$c/repo"
run_case
expect_fail
out_has '未重启，但下次开机将无法启动'
out_has '重启后 sing-box 将无法启动，请先修改配置'
out_has '已降级：失败'
[[ "$(trace_count '^restart')" == 0 && "$(trace_count '^start')" == 0 ]]
[[ "$(cat "$c/version")" == 1.13.0 && "$(cat "$c/active")" == yes ]]
policy_clean

setup_case no-downgrade-restart
echo fail >"$c/restart"
printf '1.13.0\n' >"$c/repo"
run_case
expect_fail
out_has '服务已中断，当前未运行'
out_lacks '未重启，但下次开机将无法启动'
[[ "$(trace_count '^start')" == 0 ]]
policy_clean

setup_case downgrade-apt-fail
echo fail >"$c/check"
echo 'sing-box=1.12.0' >"$c/apt-fail"
run_case
expect_fail
out_has '未重启，但下次开机将无法启动'
policy_clean

# 6. Permanent hold: skip the upgrade (and never resolve the unit), still boot-enable.
setup_case held
printf 'operator-package\nsing-box\n' >"$c/held"
echo no >"$c/enabled"
printf 'garbage\n' >"$c/execstart"
run_case
expect_rc 0
no_install
[[ ! -e "$c/check-args" && "$(trace_count '^restart')" == 0 ]]
[[ "$(cat "$c/version")" == 1.12.0 && "$(cat "$c/enabled")" == yes ]]
out_has '已被 hold，跳过升级'
out_has '1.12.0 → 1.12.0'
policy_clean

# 7. No config / same version / stopped service.
setup_case no-config
rm -f "$root/etc/sing-box/config.json"; echo no >"$c/active"; printf 'garbage\n' >"$c/execstart"
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

setup_case stopped
echo no >"$c/active"
run_case
expect_rc 0
[[ -e "$c/check-args" && "$(trace_count '^restart')" == 0 && "$(trace_count '^start')" == 0 && "$(cat "$c/active")" == no ]]
out_has '否（原本未运行）'

# 8. ExecStart: a -c file, and a relative -C resolved against WorkingDirectory.
setup_case exec-c
set_exec run -c "$root/etc/sing-box/config.json"
run_case
expect_rc 0
[[ "$(check_args)" == "$root/var/lib/sing-box|check -c $root/etc/sing-box/config.json" ]]

setup_case exec-relative
set_exec -C etc/sing-box run
echo "$root" >"$c/wd"
run_case
expect_rc 0
[[ "$(check_args)" == "$root|check -C etc/sing-box" ]]
[[ "$(trace_count '^restart')" == 1 ]]

# Anything that is not the plain form: no package operation at all, still boot-enabled, exit 0.
expect_undetermined() {
  expect_rc 0
  no_install
  [[ ! -e "$c/check-args" && "$(cat "$c/version")" == 1.12.0 && "$(cat "$c/active")" == yes && "$(cat "$c/pid")" == 100 ]]
  [[ "$(cat "$c/enabled")" == yes ]]
  out_has '无法确定服务的启动参数（原因：'
  out_has '为安全起见未升级，请手动升级'
  out_has '配置检查：无法确定'
  policy_clean
}
undetermined() { # name, then the function that breaks the default unit
  setup_case "undetermined-$1"
  shift
  "$@"
  run_case
  expect_undetermined
}
two_lines() { { exec_line "$bin/sing-box" "$bin/sing-box -C $root/etc/sing-box run"; exec_line "$bin/sing-box" "$bin/sing-box -C $root/etc/sing-box run"; } >"$c/execstart"; }
quoted() { exec_line "$bin/sing-box" "$bin/sing-box -C \"$root/etc/sing-box\" run" >"$c/execstart"; }
escaped() { exec_line "$bin/sing-box" "$bin/sing-box -C $root/etc/sing\\ box run" >"$c/execstart"; }
spaced() { exec_line "$bin/sing-box" "$bin/sing-box -C $root/etc/sing box run" >"$c/execstart"; }
env_wrapper() { exec_line /usr/bin/env "/usr/bin/env sing-box -C $root/etc/sing-box run" >"$c/execstart"; }
sh_wrapper() { exec_line /bin/sh "/bin/sh -c 'exec $bin/sing-box -C $root/etc/sing-box run'" >"$c/execstart"; }
wrong_name() { exec_line "$bin/other/not-sing-box" "$bin/other/not-sing-box -C $root/etc/sing-box run" >"$c/execstart"; }
path_mismatch() { exec_line "$bin/sing-box" "/bin/true -C $root/etc/sing-box run" >"$c/execstart"; }
with_environment() { echo 'SB_FLAG=1' >"$c/environment"; }
with_environment_file() { echo '/etc/default/sing-box (ignore_errors=no)' >"$c/environmentfiles"; }
no_config_arg() { set_exec -D "$root/var/lib/sing-box" run; }
attached() { set_exec "-C$root/etc/sing-box" run; }
equals() { set_exec -D "$root/var/lib/sing-box" "--config-directory=$root/etc/sing-box" run; }
missing_config() { set_exec -C "$root/etc/nowhere" run; }
missing_workdir() { echo "$root/var/lib/nowhere" >"$c/wd"; }
dangling_value() { set_exec run -c; }
no_output() { : >"$c/execstart"; }
undetermined multiple-execstart two_lines
undetermined quoted quoted
undetermined escaped escaped
undetermined spaces spaced
undetermined env-wrapper env_wrapper
undetermined sh-wrapper sh_wrapper
undetermined wrong-binary-name wrong_name
undetermined argv0-differs path_mismatch
undetermined environment with_environment
undetermined environment-file with_environment_file
undetermined no-config-argument no_config_arg
undetermined attached-value attached
undetermined equals-form equals
undetermined config-missing missing_config
undetermined workdir-missing missing_workdir
undetermined missing-value dangling_value
undetermined no-execstart no_output
setup_case reason-text
env_wrapper
run_case
out_has '不是名为 sing-box 的可执行文件'

# 8b. The whitelist: only -c/-C/-D (and long forms) with an existing target, plus "run" exactly once.
spaced_c_existing() { mkdir -p "$root/etc/sing"; exec_line "$bin/sing-box" "$bin/sing-box -C $root/etc/sing box run" >"$c/execstart"; }
spaced_d_existing() { mkdir -p "$root/var/lib/sing"; exec_line "$bin/sing-box" "$bin/sing-box -D $root/var/lib/sing box -C $root/etc/sing-box run" >"$c/execstart"; }
unknown_flag() { set_exec --foo -C "$root/etc/sing-box" run; }
missing_run() { set_exec -D "$root/var/lib/sing-box" -C "$root/etc/sing-box"; }
run_twice() { set_exec -C "$root/etc/sing-box" run run; }
missing_dir_d() { set_exec -D "$root/var/lib/nowhere" -C "$root/etc/sing-box" run; }
trailing_space() { exec_line "$bin/sing-box" "$bin/sing-box -C $root/etc/sing-box run " >"$c/execstart"; }
tab_separated() { exec_line "$bin/sing-box" "$bin/sing-box -C $root/etc/sing-box"$'\t'"run" >"$c/execstart"; }
undetermined spaced-config-dir-existing spaced_c_existing
undetermined spaced-working-dir-existing spaced_d_existing
undetermined unknown-flag unknown_flag
undetermined missing-run missing_run
undetermined run-twice run_twice
undetermined working-dir-missing missing_dir_d
undetermined trailing-space trailing_space
undetermined tab-separated tab_separated
setup_case reason-spaced-c; spaced_c_existing; run_case; out_has '不在白名单内的参数：box'
setup_case reason-spaced-d; spaced_d_existing; run_case; out_has '不在白名单内的参数：box'
setup_case reason-flag; unknown_flag; run_case; out_has '不在白名单内的参数：--foo'
setup_case reason-run; run_twice; run_case; out_has '子命令 run 出现 2 次'
setup_case reason-no-run; missing_run; run_case; out_has '子命令 run 出现 0 次'

# The stock unit has no WorkingDirectory: it must pass, and check runs from /.
setup_case empty-workdir
: >"$c/wd"
run_case
expect_rc 0
[[ "$(check_args)" == "/|check -D $root/var/lib/sing-box -C $root/etc/sing-box" ]]
[[ "$(trace_count '^restart')" == 1 ]]

# 8c. Directory mode: any *.json is a config, and the boot gate is a glob.
setup_case dir-mode
rm -f "$root/etc/sing-box/config.json"; printf '{}\n' >"$root/etc/sing-box/00-main.json"
run_case
expect_rc 0
[[ "$(check_args)" == "$root/var/lib/sing-box|check -D $root/var/lib/sing-box -C $root/etc/sing-box" ]]
[[ "$(trace_count '^restart')" == 1 && "$(cat "$c/version")" == 1.13.0 ]]
[[ -f "$root/etc/sing-box/00-main.json" && ! -e "$root/etc/sing-box/config.json" ]]
gate_is_new

setup_case dir-mode-stopped
rm -f "$root/etc/sing-box/config.json"; printf '{}\n' >"$root/etc/sing-box/00-main.json"; echo no >"$c/active"
run_case
expect_rc 0
[[ -e "$c/check-args" && "$(trace_count '^restart')" == 0 && "$(trace_count '^start')" == 0 ]]

# A running service counts as configured even when its config is not in /etc/sing-box.
setup_case config-elsewhere
rm -f "$root/etc/sing-box/config.json"; printf '{}\n' >"$root/elsewhere.json"
set_exec run -c "$root/elsewhere.json"
run_case
expect_rc 0
[[ "$(check_args)" == "$root/var/lib/sing-box|check -c $root/elsewhere.json" && "$(trace_count '^restart')" == 1 ]]

# No *.json at all and not running: nothing to check.
setup_case no-json-stopped
rm -f "$root/etc/sing-box/config.json"; echo no >"$c/active"; printf 'garbage\n' >"$c/execstart"
run_case
expect_rc 0
[[ ! -e "$c/check-args" ]]
out_has '未检查（没有配置）'

# An old managed drop-in is rewritten with the glob; split files and a user's config.json survive.
setup_case old-gate
printf '[Unit]\nConditionPathExists=/etc/sing-box/config.json\n' >"$root/etc/sing-box.service.d/10-gate.conf"
echo managed-by-vps-init >"$root/var/sing-box-managed"
run_case
expect_rc 0
gate_is_new
if grep -Fq 'config.json' "$root/etc/sing-box.service.d/10-gate.conf"; then fail 'old gate text left behind'; fi

setup_case fresh-split-config
: >"$c/version"; echo no >"$c/active"; echo no >"$c/enabled"
rm -f "$root/etc/sing-box/config.json"; printf '{"user":"split"}\n' >"$root/etc/sing-box/00-main.json"
run_case
expect_rc 0
[[ ! -e "$root/etc/sing-box/config.json" ]] || fail 'package default config.json left behind'
[[ "$(cat "$root/etc/sing-box/00-main.json")" == '{"user":"split"}' ]] || fail 'split config touched'
gate_is_new
out_has '未检查（首次安装）'

setup_case fresh-user-config
: >"$c/version"; echo no >"$c/active"; echo no >"$c/enabled"
printf '{"user":"own"}\n' >"$root/etc/sing-box/config.json"
run_case
expect_rc 0
[[ "$(cat "$root/etc/sing-box/config.json")" == '{"user":"own"}' ]] || fail 'user config.json removed'

# 9. --sing-box-version: exact version (even older), must exist in the repository.
setup_case pinned
SB_VERSION=1.11.0 run_case
expect_rc 0
trace_has 'apt-get install -y --allow-downgrades sing-box=1.11.0'
[[ "$(cat "$c/version")" == 1.11.0 && "$(trace_count '^restart')" == 1 ]]

setup_case pinned-missing
SB_VERSION=9.9.9 run_case
expect_fail
out_has '仓库中找不到 sing-box=9.9.9'
no_install
policy_clean

# 10. The package restarts the service anyway (its maintainer script ignores policy-rc.d).
setup_case pkg-restarts
echo bypass >"$c/pkg-restart"
run_case
expect_rc 0
out_has '软件包自行重启了服务（MainPID 100 → 101）'
out_has '软件包自行重启服务：是（MainPID 100 → 101）'
[[ -e "$c/check-args" ]]
[[ "$(cat "$c/active")" == yes && "$(cat "$c/version")" == 1.13.0 ]]

# The upgrade bypasses policy-rc.d and restarts the service; the downgrade obeys it. The old
# version must still be started explicitly, so it is not left running the new binary.
setup_case pkg-restarts-check-fail
echo bypass-upgrade >"$c/pkg-restart"; echo fail >"$c/check"
run_case
expect_rc 0
out_has '软件包自行重启了服务'
out_has '已回退到 1.12.0'
out_has '软件包重启了服务，已回退并重新启动'
out_lacks '原进程未动'
awk '/^stop$/ && !s {s=NR} s && /^daemon-reload$/ && !d {d=NR} d && /^reset-failed$/ && !r {r=NR} r && /^start policy=open$/ && !t {t=NR} END{exit !t}' "$c/trace" ||
  { cat "$c/trace"; fail 'stop, daemon-reload, reset-failed, start after a package restart'; }
[[ "$(trace_count 'package restarted')" == 1 ]]
[[ "$(cat "$c/version")" == 1.12.0 && "$(cat "$c/active")" == yes && "$(cat "$c/pid")" == 102 ]]

setup_case pkg-restarts-and-dies
echo bypass-down >"$c/pkg-restart"; echo fail >"$c/check"
run_case
expect_rc 0
out_has '软件包自行重启了服务'
out_has '软件包重启了服务，已回退并重新启动'
[[ "$(cat "$c/version")" == 1.12.0 && "$(cat "$c/active")" == yes ]]

# A package that honours policy-rc.d is never restarted by the install itself.
setup_case pkg-honours-policy
echo honor >"$c/pkg-restart"
run_case
expect_rc 0
[[ "$(trace_count 'package restarted')" == 0 && "$(cat "$c/pid")" == 101 ]]
out_lacks '软件包自行重启了服务'

# 11. policy-rc.d is restored on success, failure and interruption, with or without an original.
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
expect_fail
out_has 'sing-box 安装/升级失败'
policy_clean

setup_case policy-orig-failure; original_policy
echo 'sing-box' >"$c/apt-fail"
run_case
expect_fail
policy_unchanged

# A leftover stub from an interrupted run, with no backup: the user never had a policy-rc.d.
setup_case policy-stale-stub
printf '#!/bin/sh\n%s\nexit 101\n' "$POLICY_RC_D_MARK" >"$root/usr-sbin/policy-rc.d"
run_case
expect_rc 0
out_has '已删除上次中断遗留的 policy-rc.d 脚桩'
policy_clean
[[ "$(cat "$c/version")" == 1.13.0 ]]

# Leftover stub plus backup: the user's file comes back; a foreign file next to a backup is not touched.
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
expect_fail
out_has '请先手动确认并还原'
grep -Fq 'someone else' "$root/usr-sbin/policy-rc.d"
no_install

# policy_rc_d_block fails half-way (errexit is off in this call chain): nothing may be left behind.
for mode in fail-mv fail-install fail-printf; do
  setup_case "policy-$mode-orig"; original_policy
  SB_MODE=$mode run_case
  expect_fail
  out_has '无法'
  no_install
  policy_unchanged
  if [[ "$mode" != fail-mv ]]; then
    setup_case "policy-$mode-none"
    SB_MODE=$mode run_case
    expect_fail
    out_has '无法'
    no_install
    policy_clean
  fi
done

# Real signals: TERM then TERM again during the rollback, and HUP then TERM. The rollback and
# the policy-rc.d restoration both finish, and the handler runs exactly once.
for signals in 'TERM TERM' 'HUP TERM'; do
  setup_case "signal-${signals// /-}"
  SB_SIGNALS=$signals run_case
  expect_rc 130
  [[ "$(grep -c '收到 ' "$c/output" || true)" == 1 && "$(grep -c called "$c/rollback-calls")" == 1 ]] || { cat "$c/output"; fail 'signal handler ran more than once'; }
  policy_clean

  setup_case "signal-orig-${signals// /-}"; original_policy
  SB_SIGNALS=$signals run_case
  expect_rc 130
  [[ "$(grep -c '收到 ' "$c/output")" == 1 && "$(grep -c called "$c/rollback-calls")" == 1 ]] || { cat "$c/output"; fail 'signal handler ran more than once'; }
  policy_unchanged
done

# The old wizard and its state file code are gone.
grep -Fq '4. 安装/升级 sing-box' "$repo/debian-init.sh"
if grep -qE 'run_node_config_wizard|SINGBOX_WIZARD|persist_network_stack' "$repo/debian-init.sh"; then fail 'wizard code is still present'; fi
[[ ! -e "$repo/templates" ]] || fail 'templates directory is still present'
echo 'PASS: sing-box install/upgrade, ExecStart rules, check-before-restart, downgrade, hold, policy-rc.d restore and real signals'
