#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034,SC2016 # Mocks/state and literal APT placeholders.
set -Eeuo pipefail
# shellcheck source=tests/process-helper.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/process-helper.sh"
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
root="$work/root"
mkdir -p "$root" "$work/tmp" "$work/backup"
if [[ ${1:-} == --exim4-package-manager ]]; then
  [[ -f /.dockerenv && $EUID == 0 ]] || { echo 'Exim package test requires a disposable root Docker container.' >&2; exit 1; }
  # shellcheck disable=SC1091
  source "$repo/debian-init.sh"
  trap - ERR HUP INT TERM
  trap 'rm -rf -- "$work"' EXIT
  TMP_DIR="$work/tmp" BACKUP_DIR="$work/backup"
  build_exim_fixture() (
    local name=$1 depends=${2:-}
    umask 022
    mkdir -p "$work/$name/DEBIAN"
    {
      printf 'Package: %s\nVersion: 1\nArchitecture: all\nMaintainer: Test\nDescription: Disposable Exim test fixture\n' "$name"
      if [[ -n "$depends" ]]; then printf 'Depends: %s\n' "$depends"; fi
    } >"$work/$name/DEBIAN/control"
    if [[ "$name" == exim4-base ]]; then
      mkdir -p "$work/$name/etc/exim4"
      echo 'local fixture configuration' >"$work/$name/etc/exim4/fixture.conf"
      echo /etc/exim4/fixture.conf >"$work/$name/DEBIAN/conffiles"
    fi
    dpkg-deb --build "$work/$name" "$work/$name.deb"
    dpkg --install "$work/$name.deb"
  )
  build_exim_fixture exim4-base
  build_exim_fixture exim4-config
  build_exim_fixture exim4 'exim4-base, exim4-config'
  build_exim_fixture mail-consumer-fixture exim4-base
  extra_confirmed=false
  ask_yes_no() {
    [[ "$2" == false ]]
    if [[ "$1" == '额外确认：'* ]]; then [[ "$extra_confirmed" == true ]]; else return 0; fi
  }
  hardening_purge_exim4
  [[ $(dpkg-query -W -f='${db:Status-Status}' mail-consumer-fixture) == installed ]]
  [[ $(dpkg-query -W -f='${db:Status-Status}' exim4-base) == installed ]]
  [[ ! -e "$BACKUP_DIR/exim4-purge-plan.txt" ]]
  extra_confirmed=true
  hardening_purge_exim4
  [[ $(dpkg-query -W -f='${db:Status-Status}' exim4-base 2>/dev/null || true) != installed ]]
  [[ $(dpkg-query -W -f='${db:Status-Status}' mail-consumer-fixture 2>/dev/null || true) != installed ]]
  grep -Fxq 'local fixture configuration' "$BACKUP_DIR/files/etc/exim4/fixture.conf"
  grep -Fq mail-consumer-fixture "$BACKUP_DIR/exim4-purge-plan.txt"
  echo 'PASS: real APT Exim wildcard, collateral dependency confirmation, purge and backup'
  exit 0
fi
sed -e "s|^readonly AUDIT_ROOT=.*|readonly AUDIT_ROOT='$root'|" \
  -e "s|^readonly TRUSTED_KEYS_STATE=.*|readonly TRUSTED_KEYS_STATE='$work/trusted'|" \
  -e "s|^readonly AUTHORIZED_KEYS=.*|readonly AUTHORIZED_KEYS='$root/root/.ssh/authorized_keys'|" \
  -e "s|^readonly SECURITY_APT_CONF=.*|readonly SECURITY_APT_CONF='$root/etc/apt/apt.conf.d/zzzz-404-security'|" \
  -e "s|^readonly SINGBOX_DROPIN_DIR=.*|readonly SINGBOX_DROPIN_DIR='$root/etc/systemd/system/sing-box.service.d'|" \
  -e "s|^readonly SINGBOX_DROPIN=.*|readonly SINGBOX_DROPIN='$root/etc/systemd/system/sing-box.service.d/10-vps-init-config-gate.conf'|" \
  -e "s|^readonly SINGBOX_CONFIG=.*|readonly SINGBOX_CONFIG='$root/etc/sing-box/config.json'|" \
  -e "s|^readonly CF_TIMER=.*|readonly CF_TIMER='$root/etc/systemd/system/vps-init-cloudflare-8443.timer'|" \
  -e "s|^readonly BACKUP_ROOT=.*|readonly BACKUP_ROOT='$work/hardening-backups'|"   -e "s|^readonly CLOUD_DISABLED_FLAG=.*|readonly CLOUD_DISABLED_FLAG='$root/etc/cloud/cloud-init.disabled'|"   -e "s|/root/vps-hardening-|$work/vps-hardening-|" \
  -e "s|/dev/tty|$work/tty|g" "$repo/debian-init.sh" >"$work/installer"
# shellcheck disable=SC1091
source "$work/installer"
# Keep the installer's own IFS (newline and tab only): word-splitting bugs must show up
# here and not only on servers. Mocks that join "$@" set a local IFS themselves.
trap - ERR HUP INT TERM
trap 'rm -rf -- "$work"' EXIT
TMP_DIR="$work/tmp" BACKUP_DIR="$work/backup"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# The process helper must keep errexit even when invoked from a condition.
errexit_probe() { echo 'errexit probe'; false; echo 'unexpected continuation'; }
expect_bash_failure 'errexit probe' errexit_probe

# Actual menu, including an invalid choice and exit 0.
for mapping in 1:quick 2:custom 3:smartdns 4:singbox 5:fail2ban 6:update 7:cleanup 8:hardening 9:reinstall; do
  INSTALL_MODE=''
  read_tty() { printf -v "$2" '%s' "${mapping%%:*}"; }
  select_install_mode
  [[ "$INSTALL_MODE" == "${mapping#*:}" ]] || fail "menu $mapping"
done
grep -Fq '0. 退出' "$work/tty"
grep -Fq '9. 重装为官方 Debian 13（会清空整机）' "$work/tty" || fail 'menu lacks option 9'
(
  INSTALL_MODE='' replies=0
  read_tty() { replies=$((replies + 1)); if (( replies == 1 )); then printf -v "$2" 10; else printf -v "$2" 3; fi; }
  select_install_mode
  [[ "$INSTALL_MODE" == smartdns && "$replies" == 2 ]]
)
(INSTALL_MODE=''; read_tty() { printf -v "$2" 0; }; select_install_mode; fail 'exit did not exit')

# Effective APT parsing with real apt-config and a deliberately unsafe earlier config.
mkdir -p "${SECURITY_APT_CONF%/*}"
cat >"${SECURITY_APT_CONF%/*}/50-old" <<'EOF'
Unattended-Upgrade::Allowed-Origins { "ThirdParty:stable"; };
Unattended-Upgrade::Origins-Pattern { "origin=Other"; };
Unattended-Upgrade::Package-Blacklist { "operator-held"; };
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Mail "operator@example.invalid";
EOF
printf 'Dir::Etc::Parts "%s";\nDir::Etc::main "-";\n' "${SECURITY_APT_CONF%/*}" >"$work/apt.conf"
export APT_CONFIG="$work/apt.conf"
trace="$work/trace"
: >"$trace"
apt_get() {
  local IFS=' '
  [[ "$*" == 'install -y unattended-upgrades' ]] || fail 'security APT command'
  grep -Fq '#clear Unattended-Upgrade::Allowed-Origins;' "$SECURITY_APT_CONF" || fail 'policy was not written before installation'
  echo install >>"$trace"
}
systemctl() { local IFS=' '; printf '%s\n' "$*" >>"$trace"; }
configure_security_updates
config=$(apt-config dump)
grep -Fq 'origin=Debian,codename=${distro_codename}-security,label=Debian-Security' <<<"$config"
if grep -Eq 'ThirdParty|origin=Other' <<<"$config"; then fail 'unsafe origins survived'; fi
grep -Fq 'operator-held' <<<"$config"
grep -Fq '^sing-box$' <<<"$config"
grep -Fq '^smartdns$' <<<"$config"
grep -Fxq 'Unattended-Upgrade::Mail "";' <<<"$config"
grep -Fxq 'Unattended-Upgrade::Automatic-Reboot "false";' <<<"$config"
cp "$SECURITY_APT_CONF" "$work/expected-policy"
configure_security_updates
cmp "$SECURITY_APT_CONF" "$work/expected-policy"
cmp "$BACKUP_DIR/files$SECURITY_APT_CONF" "$work/expected-policy"
AUTO_SECURITY=false
: >"$trace"
configure_security_updates
[[ ! -s "$trace" ]] || fail 'opt out changed configuration'
AUTO_SECURITY=true
unset APT_CONFIG

# Real keys exist only in a temporary fixture; no credentials are committed.
for name in current other last; do ssh-keygen -q -t ed25519 -N '' -C "$name" -f "$work/$name"; done
current=$(cat "$work/current.pub") other=$(cat "$work/other.pub") last=$(cat "$work/last.pub")
current_fp=$(ssh_public_key_fingerprints <<<"$current")
other_fp=$(ssh_public_key_fingerprints <<<"$other")
last_fp=$(ssh_public_key_fingerprints <<<"$last")
mkdir -p "${AUTHORIZED_KEYS%/*}" "$root/home/person/.ssh"
file="$AUTHORIZED_KEYS"
printf '%s\n%s\n' "$current" "$other" >"$file"
chmod 600 "$file"

# Exercise journal correlation before replacing the function with a fixture.
SSH_CONNECTION='192.0.2.10 1234 192.0.2.20 22'
ps() {
  local IFS=' '
  case "$*" in
    '-o comm='*) echo sshd ;;
    '-o lstart='*) echo 'Wed Nov 25 01:00:00 2026' ;;
    '-o ppid='*) echo 1 ;;
    *) fail 'unexpected ps' ;;
  esac
}
journalctl() {
  local IFS=' '
  [[ "$*" == *'--since 2026-11-25 01:00:00'* && "$*" == *'_PID='* ]] || fail 'unbound journal query'
  printf 'Accepted publickey for root from 192.0.2.10 port 1234 ssh2: ED25519 %s\n' "$current_fp"
  printf 'Accepted publickey for root from 192.0.2.99 port 1234 ssh2: ED25519 %s\n' "$other_fp"
  printf 'Accepted publickey for root from 192.0.2.10 port 7777 ssh2: ED25519 %s\n' "$other_fp"
}
[[ $(audit_session_key) == "$current_fp" ]] || fail 'session correlation'
journalctl() { local IFS=' '; printf 'Accepted password for root from 192.0.2.10 port 1234 ssh2\n'; }
if run_in_bash audit_session_key >/dev/null 2>&1; then fail 'password session treated as publickey'; fi
journalctl() { local IFS=' '; printf 'Accepted publickey for root from 192.0.2.10 port 1234 ssh2: ED25519 %s\n' "$current_fp" "$other_fp"; }
if run_in_bash audit_session_key >/dev/null 2>&1; then fail 'ambiguous session allowed'; fi
unset -f ps journalctl
audit_session_key() { [[ -n "${session_key:-}" ]] && printf '%s\n' "$session_key"; }
session_key=$current_fp
before=$(sha256sum "$file")
hardening_delete_key "$file" "$current_fp"
[[ $(sha256sum "$file") == "$before" ]] || fail 'deleted current key'
session_key=''
hardening_delete_key "$file" "$other_fp"
[[ $(sha256sum "$file") == "$before" ]] || fail 'unknown session deleted key'
session_key=$current_fp
printf '%s\n' "$last" >"$file"
before=$(sha256sum "$file")
hardening_delete_key "$file" "$last_fp"
[[ $(sha256sum "$file") == "$before" ]] || fail 'deleted last key'
printf '%s\nrestrict %s\n%s\n# keep comment\n' "$current" "$other" "$other" >"$file"
cp "$file" "$work/keys-before"
hardening_delete_key "$file" "$other_fp"
[[ $(ssh_public_key_fingerprints "$file") == "$current_fp" ]] || fail 'key deletion failed'
grep -Fxq '# keep comment' "$file"
cmp "$BACKUP_DIR/files$file" "$work/keys-before"
[[ $(stat -c %a "$file") == 600 ]] || fail 'key permissions changed'
ln -s "$file" "$root/home/person/.ssh/authorized_keys"
if run_in_bash "audit_regular_key_path '$root/home/person/.ssh/authorized_keys'" >/dev/null 2>&1; then fail 'symlink accepted'; fi
rm "$root/home/person/.ssh/authorized_keys"
printf '%s\n' "$other" >"$root/home/person/.ssh/authorized_keys"

# Provenance: only confirmed keys are recorded, other accounts retained.
PUBLIC_KEY=$current REUSE_PUBLIC_KEY=false
record_trusted_keys
grep -Fxq "$file"$'\t'"$current_fp" "$TRUSTED_KEYS_STATE"
if grep -Fq "$other_fp" "$TRUSTED_KEYS_STATE"; then fail 'unprovided key trusted'; fi
REUSE_PUBLIC_KEY=true REUSED_KEY_FINGERPRINTS="$current_fp"$'\n'"$other_fp"
record_trusted_keys
grep -Fxq "$file"$'\t'"$other_fp" "$TRUSTED_KEYS_STATE"
REUSE_PUBLIC_KEY=false

# R4 cloud-init network classification: regular files under /etc decide; DHCP, SLAAC and
# static addresses all pass; /run-only configs and per-boot regeneration are skipped.
mkdir -p "$root/etc/network/interfaces.d" "$root/etc/systemd/network" "$root/etc/cloud/cloud.cfg.d" "$root/etc/netplan" "$root/run/systemd/network"
net_reset() {
  rm -rf "$root/etc/network/interfaces" "$root/etc/cloud/cloud.cfg" "$root/run/systemd/network/"*
  rm -f "$root"/etc/network/interfaces.d/* "$root"/etc/netplan/* "$root"/etc/systemd/network/* "$root"/etc/cloud/cloud.cfg.d/*
}
# Classification runs in its own Bash process (fresh errexit, as in production) and reports
# its globals through an EXIT trap.
net_probe() {
  trap 'printf "RESULT|%s|%s|%s\n" "$CLOUD_NET_KIND" "$CLOUD_NET_STATIC" "$CLOUD_NET_REASON"' EXIT
  audit_cloud_network_classify
}
expect_net() { # expect_net pass|skip static|dynamic label
  local want=$1 static=$2 label=$3 rc=0 out
  out=$(run_in_bash net_probe 2>&1) || rc=$?
  IFS='|' read -r _ CLOUD_NET_KIND CLOUD_NET_STATIC CLOUD_NET_REASON <<<"$(grep '^RESULT|' <<<"$out")"
  if [[ "$want" == pass ]]; then
    (( rc == 0 )) || fail "$label refused: $CLOUD_NET_REASON"
    [[ "$CLOUD_NET_STATIC" == "$static" ]] || fail "$label static flag=$CLOUD_NET_STATIC"
  else
    (( rc != 0 )) || fail "$label allowed"
    [[ -n "$CLOUD_NET_REASON" ]] || fail "$label has no reason"
  fi
}
net_reset
printf 'auto eth0\niface eth0 inet dhcp\n' >"$root/etc/network/interfaces"
expect_net pass false 'ifupdown DHCP'
printf 'auto lo\niface lo inet loopback\nauto eth0\niface eth0 inet6 auto\n' >"$root/etc/network/interfaces"
expect_net pass false 'ifupdown IPv6 SLAAC'
# Real shape of a vendor image: generated header, static IPv4 + static IPv6, included file.
net_reset
printf 'source /etc/network/interfaces.d/*\n' >"$root/etc/network/interfaces"
cat >"$root/etc/network/interfaces.d/50-cloud-init" <<'NETEOF'
# This file is generated from information provided by the datasource.  Changes
# to it will not persist across an instance reboot.
auto lo
iface lo inet loopback
    dns-nameservers 192.0.2.53

auto eth0
iface eth0 inet static
    address 192.0.2.20/32
    gateway 192.0.2.1

auto eth1
iface eth1 inet6 static
    address 2001:db8::a/64
    gateway 2001:db8::1
NETEOF
expect_net pass true 'generated static ifupdown'
[[ "$CLOUD_NET_KIND" == ifupdown ]] || fail 'ifupdown kind'
# An interfaces.d file nobody sources is not proof; loopback only is not proof either.
printf 'auto lo\niface lo inet loopback\n' >"$root/etc/network/interfaces"
expect_net skip false 'unsourced interfaces.d'
grep -Fq '/run' <<<"$CLOUD_NET_REASON" || fail 'skip reason does not mention /run'
net_reset
printf 'auto lo\niface lo inet loopback\n' >"$root/etc/network/interfaces"
expect_net skip false 'loopback only'
# Netplan: DHCP, DNS-only addresses are dynamic, interface addresses are static.
net_reset
printf 'network:\n  version: 2\n  ethernets:\n    eth0:\n      dhcp4: true\n      nameservers:\n        addresses: [192.0.2.53]\n' >"$root/etc/netplan/50-cloud-init.yaml"
expect_net pass false 'netplan DHCP with DNS addresses'
printf 'network:\n  version: 2\n  ethernets:\n    eth0:\n      addresses:\n        - 192.0.2.20/24\n      routes:\n        - to: default\n          via: 192.0.2.1\n' >"$root/etc/netplan/50-cloud-init.yaml"
expect_net pass true 'netplan static'
[[ "$CLOUD_NET_KIND" == netplan ]] || fail 'netplan kind'
# systemd-networkd.
net_reset
printf '[Match]\nName=eth0\n[Network]\nDHCP=yes\n' >"$root/etc/systemd/network/10-wan.network"
expect_net pass false 'networkd DHCP'
printf '[Match]\nName=eth0\n[Network]\nAddress=192.0.2.20/24\nGateway=192.0.2.1\n' >"$root/etc/systemd/network/10-wan.network"
expect_net pass true 'networkd static'
printf '[Match]\nName=eth0\n[Network]\nIPv6AcceptRA=yes\n' >"$root/etc/systemd/network/10-wan.network"
expect_net pass false 'networkd SLAAC'
# Only in /run, or a symlink into /run: skip.
net_reset
printf '[Match]\nName=eth0\n[Network]\nDHCP=yes\n' >"$root/run/systemd/network/10-netplan-eth0.network"
expect_net skip false '/run only'
ln -s "$root/run/systemd/network/10-netplan-eth0.network" "$root/etc/systemd/network/10-link.network"
expect_net skip false 'symlink into /run'
# Per-boot regeneration: block list, inline list, flow mapping skip; boot-new-instance does not.
net_reset
printf 'auto eth0\niface eth0 inet dhcp\n' >"$root/etc/network/interfaces"
for variant in block inline flow other-key; do
  case "$variant" in
    block) printf 'updates:\n  network:\n    when:\n      - boot-new-instance\n      - boot\n' ;;
    inline) printf 'updates:\n  network:\n    when: [boot-new-instance, "boot"]\n' ;;
    flow) printf 'updates: {network: {when: [boot]}}\n' ;;
    other-key) printf 'updates:\n  network:\n    when: [boot-legacy]\nother:\n  when: [boot]\n' ;;
  esac >"$root/etc/cloud/cloud.cfg.d/90-updates.cfg"
  if [[ "$variant" == other-key ]]; then expect_net pass false "boot only elsewhere ($variant)"
  else expect_net skip false "per-boot regeneration ($variant)"; fi
  grep -Fq 'boot' <<<"$CLOUD_NET_REASON" || [[ "$variant" == other-key ]] || fail 'regeneration reason'
done
printf 'updates:\n  network:\n    when: [boot-new-instance]\n' >"$root/etc/cloud/cloud.cfg.d/90-updates.cfg"
expect_net pass false 'boot-new-instance only'
printf 'updates:\n  network:\n    when: [boot]\n' >"$root/etc/cloud/cloud.cfg"
rm "$root/etc/cloud/cloud.cfg.d/90-updates.cfg"
expect_net skip false 'regeneration in cloud.cfg'
# An IPv6 SSH session no longer blocks the decision (SLAAC/static IPv6 is fine).
rm "$root/etc/cloud/cloud.cfg"
SSH_CONNECTION='2001:db8::1 1234 2001:db8::2 22'
expect_net pass false 'IPv6 session'
SSH_CONNECTION='192.0.2.10 1234 192.0.2.20 22'

# Full audit positive and negative fixtures, including each A/B/C detector.
audit_mode=positive
mkdir -p "$root/etc/cron.d" "$root/etc/sudoers.d" "$root/proc/321" "$root/usr/local/aegis" "$root/usr/lib/systemd/system"
touch "$root/usr/lib/systemd/system/getty@.service"
printf 'root:x:0:0::/root:/bin/bash\nextra:x:0:0::/home/extra:/bin/bash\n' >"$root/etc/passwd"
echo preload >"$root/etc/ld.so.preload"
echo cron >"$root/etc/cron.d/unowned"
echo sudo >"$root/etc/sudoers.d/extra"
ln -s /opt/agent "$root/proc/321/exe"
qemu_guest_agent_status() { if [[ "$audit_mode" == positive ]]; then echo installed; else echo not-installed; fi; }
dpkg-query() {
  local IFS=' '
  case "$1" in
    -S)
      case "$*" in
        *barad_agent.service*) echo 'vendor-barad: /etc/systemd/system/barad_agent.service' ;;
        *walinuxagent.service*) echo 'walinuxagent: /lib/systemd/system/walinuxagent.service' ;;
        # Debian 12 dpkg: only the registered spelling of a merged-/usr path is found.
        *'/usr/lib/systemd/system/aliased.service') echo 'pkg-aliased: /usr/lib/systemd/system/aliased.service' ;;
        *'-S -- /lib/systemd/system/aliased.service'*) return 1 ;;
        *'/system/sing-box.service') echo 'sing-box: /usr/lib/systemd/system/sing-box.service' ;;
        *getty@.service*) echo 'systemd: /usr/lib/systemd/system/getty@.service' ;;
        *) if [[ "$audit_mode" == negative || "$*" == *'/usr/bin/official'* ]]; then echo 'official: /usr/bin/official'; else return 1; fi ;;
      esac ;;
    -W)
      if [[ "$*" == *'${Version}'* ]]; then echo 1.0
      elif [[ "$*" == *'${binary:Package}'* ]]; then printf 'official\tinstalled\n'; [[ "$audit_mode" != positive ]] || printf 'external\tinstalled\nexim4-base\tinstalled\nwalinuxagent\tinstalled\nvendor-barad\tinstalled\n'
      else return 1; fi ;;
    *) return 1 ;;
  esac
}
apt-cache() {
  local IFS=' '
  if [[ "$*" == policy ]]; then
    printf ' 500 https://deb.debian.org/debian stable/main amd64 Packages\n     release o=Debian,a=stable\n'
  elif [[ "$*" == *'external'* || "$*" == *'vendor-barad'* ]]; then
    printf ' *** 1.0 100\n        500 https://vendor.invalid stable/main amd64 Packages\n'
  else
    printf ' *** 1.0 100\n        500 https://deb.debian.org/debian stable/main amd64 Packages\n'
  fi
}
systemctl() {
  local IFS=' '
  case "$*" in
    'list-unit-files --state=enabled'*) [[ "$audit_mode" != positive ]] || printf 'custom.service enabled\naliased.service enabled\ngetty@.service enabled\nsing-box.service enabled\n' ;;
    'list-unit-files --type=service'*) [[ "$audit_mode" != positive ]] || printf 'autovt@.service enabled\nbarad_agent.service enabled\nwalinuxagent.service enabled\nnothing.service enabled\n' ;;
    'show -p Id,FragmentPath,ExecStart'*)
      [[ "$audit_mode" == positive ]] || return 0
      # Real systemctl refuses template units and then prints nothing at all.
      if [[ "$*" == *'@.'* ]]; then echo 'Failed to get properties: Unit name is not valid.' >&2; return 1; fi
      printf 'ExecStart={ path=/usr/local/qcloud/monitor/barad/admin/barad_agent ; argv[]=x ; ignore_errors=no }\nId=barad_agent.service\nFragmentPath=/etc/systemd/system/barad_agent.service\n\n'
      printf 'ExecStart={ path=/usr/sbin/waagent ; argv[]=/usr/sbin/waagent }\nId=walinuxagent.service\nFragmentPath=/lib/systemd/system/walinuxagent.service\n\n'
      printf 'ExecStart={ path=/bin/true ; argv[]=true }\nId=nothing.service\nFragmentPath=/lib/systemd/system/nothing.service\n' ;; # real systemd prints ExecStart before Id
    'show -p FragmentPath'*)
      case "$*" in
        *aliased.service*) echo /lib/systemd/system/aliased.service ;;
        *getty@.service*) return 1 ;; # systemd cannot show template units
        *sing-box.service*) echo /usr/lib/systemd/system/sing-box.service ;;
        *) echo /etc/systemd/system/custom.service ;;
      esac ;;
    'show -p DropInPaths'*)
      case "$*" in
        *getty@.service*) return 1 ;;
        *sing-box.service*) echo "$SINGBOX_DROPIN" ;;
      esac ;;
    'is-enabled --quiet networking.service') return 0 ;;
    *) return 1 ;;
  esac
}
ps() {
  local IFS=' '
  [[ "$*" == '-eo pid=,comm=' ]] || fail "unexpected ps $*"
  if [[ "$audit_mode" == positive ]]; then printf '%7s %s\n' 1 systemd 321 AliYunDun; fi # real ps right-aligns the pid
}
ss() { if [[ "$audit_mode" == positive ]]; then echo 'tcp LISTEN 0 128 0.0.0.0:9999 0.0.0.0:* users:(("agent",pid=321,fd=3))'; fi; }
sshd() {
  if [[ "$audit_mode" == positive ]]; then printf 'authorizedkeyscommand /opt/keys\nauthorizedkeysfile /opt/keys-file\n'
  else printf 'authorizedkeyscommand none\nauthorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2\n'; fi
}
net_reset
printf 'auto eth0\niface eth0 inet dhcp\n' >"$root/etc/network/interfaces"
echo '# cloud.cfg' >"$root/etc/cloud/cloud.cfg"
printf '%s\n%s\n' "$current" "$other" >"$file"
rm "$TRUSTED_KEYS_STATE"
collect_security_audit
print_security_audit full >"$work/positive"
for detector in key cloud qga agent mail package service cron sudo port preload uid ssh; do
  printf '%s\n' "${AUDIT_FINDINGS[@]}" | grep -q $'\t'"$detector"$'\t' || fail "missing positive $detector"
done
grep -Fq '没有归属记录' "$work/positive"
has_finding() { printf '%s\n' "${AUDIT_FINDINGS[@]}" | grep -Eq "$1"; }
# Services: the unowned custom unit is B; merged-/usr aliases, template units and the
# installer's own sing-box start condition are not; no ERR trap noise from template units.
has_finding $'^B\tservice\tcustom.service\t' || fail 'unowned service not B'
for ok_unit in aliased.service getty@.service sing-box.service; do
  if has_finding $'^B\tservice\t'"$ok_unit"$'\t'; then fail "$ok_unit wrongly reported as unowned"; fi
done
: >"$work/err-trap"
(trap 'echo "ERR line $LINENO" >>"$work/err-trap"' ERR; set -E; collect_security_audit)
[[ ! -s "$work/err-trap" ]] || fail "audit raised an ERR trap: $(cat "$work/err-trap")"
# R5: a non-official package that owns a vendor service is A; same-name Debian packages are
# excluded; unowned processes and install paths are B with a manual-removal hint.
has_finding $'^A\tagent\tvendor-barad\t' || fail 'vendor package not A'
if has_finding $'^[AB]\tagent\twalinuxagent\t'; then fail 'official Debian agent listed'; fi
has_finding $'^B\tagent\tAliYunDun\t' || fail 'unowned process not B'
has_finding $'^B\tagent\taegis\t' || fail 'unowned install path not B'
if has_finding $'^A\tagent\t(AliYunDun|aegis)\t'; then fail 'unowned agent offered for purge'; fi
grep -Fq '手动卸载' "$work/positive"
has_finding $'^A\tcloud\tcloud-init\t' || fail 'cloud-init not offered'
if has_finding "$CLOUD_STATIC_HINT"; then fail 'DHCP got the static hint'; fi
# Plain-language help is printed for every category that has findings.
for label in 登录公钥 cloud-init 'QEMU Guest Agent' '商家 agent' '邮件服务' '非软件包服务'; do
  grep -Fq "▸ $label" "$work/positive" || fail "no help for $label"
done
# Static address: the hint is attached to the cloud-init finding.
printf 'auto eth0\niface eth0 inet static\n    address 192.0.2.20/24\n    gateway 192.0.2.1\n' >"$root/etc/network/interfaces"
collect_security_audit
has_finding "$CLOUD_STATIC_HINT" || fail 'static hint missing'
# Unprovable network: only the cloud-init item is skipped (reported as B), nothing else changes.
printf 'auto lo\niface lo inet loopback\n' >"$root/etc/network/interfaces"
collect_security_audit
has_finding $'^B\tcloud-skip\tcloud-init\t' || fail 'unprovable network not reported'
if has_finding $'^A\tcloud\t'; then fail 'cloud-init offered with unprovable network'; fi
has_finding $'^A\tqga\t' || fail 'skip suppressed other items'
printf 'auto eth0\niface eth0 inet dhcp\n' >"$root/etc/network/interfaces"
PUBLIC_KEY=$current REUSE_PUBLIC_KEY=false
record_trusted_keys
# Root ownership check is mocked only for this fixture on non-root CI runners.
stat() { local IFS=' '; if [[ "$*" == "-c %u $TRUSTED_KEYS_STATE" ]]; then echo 0; else command stat "$@"; fi; }
collect_security_audit
print_security_audit full >"$work/recorded"
grep -Fq '不是你提供的' "$work/recorded"
# sshd AuthorizedKeysFile: both Debian defaults and the installer's own pin are normal.
for keysfile in '.ssh/authorized_keys' '.ssh/authorized_keys .ssh/authorized_keys2'; do
  sshd() { printf 'authorizedkeyscommand none\nauthorizedkeysfile %s\n' "$keysfile"; }
  collect_security_audit
  if has_finding $'^C\tssh\t'; then fail "normal AuthorizedKeysFile '$keysfile' is critical"; fi
done
for keysfile in '.ssh/authorized_keys /opt/keys' '/opt/keys' '.ssh/other'; do
  sshd() { printf 'authorizedkeyscommand none\nauthorizedkeysfile %s\n' "$keysfile"; }
  collect_security_audit
  has_finding $'^C\tssh\tAuthorizedKeysFile\t' || fail "odd AuthorizedKeysFile '$keysfile' not critical"
done
sshd() {
  if [[ "$audit_mode" == positive ]]; then printf 'authorizedkeyscommand /opt/keys\nauthorizedkeysfile /opt/keys-file\n'
  else printf 'authorizedkeyscommand none\nauthorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2\n'; fi
}
audit_mode=negative
printf 'root:x:0:0::/root:/bin/bash\nregular:x:1000:1000::/home/regular:/bin/bash\n' >"$root/etc/passwd"
: >"$root/etc/ld.so.preload"
rm "$root/etc/sudoers.d/extra" "$file" "$root/home/person/.ssh/authorized_keys"
touch "$root/etc/cloud/cloud-init.disabled"
rm -r "$root/usr/local/aegis"
collect_security_audit
[[ ${#AUDIT_FINDINGS[@]} == 0 ]] || { print_security_audit full; fail 'negative fixture has findings'; }

# --audit dispatch has no writes, even to lock/backup/DNS; compare content + metadata
# across the entire fixture, including hidden files and symlinks. Audit emits to stdout.
snapshot() { find "$root" -printf '%P %y %m %U %G %s %T@ %l\n'; find "$root" -type f -exec sha256sum {} +; }
snapshot >"$work/before"
(
  preflight() { fail 'audit preflight wrote state'; }
  acquire_lock() { fail 'audit created lock'; }
  ensure_system_dns() { fail 'audit repaired DNS'; }
  install() { fail 'audit installed or created files'; }
  # root permission is checked by production main; run the dispatch in root CI below.
  if (( EUID == 0 )); then INSTALL_MODE=''; main --audit; else collect_security_audit; print_security_audit full; fi
) >"$work/audit-output"
snapshot >"$work/after"
cmp "$work/before" "$work/after"

# [8] flow. Nothing is written before the risk notice is confirmed; with nothing to do
# there is no backup directory; a cloud-init skip never stops the remaining items.
await_text() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do grep -Fq -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
(
  collect_security_audit() { AUDIT_FINDINGS=(); audit_add B cloud-skip cloud-init 'reason'; }
  ask_yes_no() { fail 'prompt without actionable items'; }
  hardening_backup() { fail 'backup without actionable items'; }
  run_security_hardening >"$work/flow-none"
  [[ ! -e "$BACKUP_ROOT" ]] || fail 'backup root created without actions'
  grep -Fq '没有 A 级建议项' "$work/flow-none"
)
(
  collect_security_audit() { AUDIT_FINDINGS=(); audit_add A mail exim4 'x'; }
  ask_yes_no() { printf '%s\n' "$1" >>"$work/flow-trace"; return 1; }
  hardening_purge_exim4() { fail 'executed after the risk notice was declined'; }
  : >"$work/flow-trace"
  run_security_hardening >"$work/flow-declined"
  [[ ! -e "$BACKUP_ROOT" ]] || fail 'backup created before confirmation'
  grep -Fxq '关闭 cloud-init 和 Guest Agent 后，面板上的重置密码等功能可能失效。请确认你在面板上能看到 root 密码，或者自己知道 root 密码。' "$work/flow-declined"
  [[ $(wc -l <"$work/flow-trace") == 1 ]] || fail 'asked more than the risk question'
)
# Real cloud-init detection (mocks from the audit fixture are still active, no other findings).
audit_mode=negative
rm -f "$CLOUD_DISABLED_FLAG"
echo '# cloud.cfg' >"$root/etc/cloud/cloud.cfg"
printf 'auto eth0\niface eth0 inet static\n    address 192.0.2.20/24\n    gateway 192.0.2.1\n' >"$root/etc/network/interfaces"
: >"$work/backups-trace"
hardening_backup() { printf '%s\n' "$1" >>"$work/backups-trace"; }
(
  ask_yes_no() { printf '%s\n' "$1" >>"$work/flow-asks"; return 0; }
  : >"$work/flow-asks"
  run_security_hardening >"$work/flow-cloud" 2>&1
)
[[ -f "$CLOUD_DISABLED_FLAG" ]] || fail 'cloud-init not disabled after confirmation'
grep -Fxq "$root/etc/cloud" "$work/backups-trace" || fail 'cloud-init disabled without a backup'
await_text "$work/flow-cloud" '加固报告' || fail 'no final report'
grep -Fq "$CLOUD_STATIC_HINT" "$work/flow-cloud" || fail 'static hint not shown'
grep -Fq "恢复：删除 $CLOUD_DISABLED_FLAG" "$work/flow-cloud" || fail 'restore instruction missing'
grep -Fq '关闭 cloud-init？' "$work/flow-asks"
backup_count=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)
[[ "$backup_count" == 1 ]] || fail "expected one backup directory, got $backup_count"
backup_dir=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d)
[[ -s "$backup_dir/audit-before.txt" && -s "$backup_dir/audit-after.txt" ]] || fail 'audit reports missing'
if grep -Fq 'A	cloud' "$backup_dir/audit-after.txt"; then fail 'processed item still listed'; fi
# actions.txt is written after the loop from the executed actions, "- " per line, mode 600; the
# same lines appear in the final report (the loop output itself is no longer piped through tee).
[[ -f "$backup_dir/actions.txt" ]] || fail 'actions.txt missing after an executed action'
[[ "$(stat -c %a "$backup_dir/actions.txt")" == 600 ]] || fail 'actions.txt is not mode 600'
[[ "$(cat "$backup_dir/actions.txt")" == "- 已关闭 cloud-init（创建 /etc/cloud/cloud-init.disabled）；恢复：删除这个文件即可重新启用" ]] || fail 'actions.txt content differs from HARDENING_ACTIONS'
grep -Fxq "  $(cat "$backup_dir/actions.txt")" "$work/flow-cloud" || fail 'actions.txt line missing from the final report'
# Second run: the processed item is gone, no prompt, no second backup directory.
(
  ask_yes_no() { fail 'prompt on a clean second run'; }
  run_security_hardening >"$work/flow-second" 2>&1
)
grep -Fq '没有 A 级建议项' "$work/flow-second"
[[ $(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l) == 1 ]] || fail 'second run created a backup'
# Network proof lost between the audit and the action: skip only cloud-init, still run the rest.
rm -f "$CLOUD_DISABLED_FLAG"
rm -rf "$BACKUP_ROOT"
printf 'auto eth0\niface eth0 inet dhcp\n' >"$root/etc/network/interfaces"
eval "real_$(declare -f collect_security_audit)"
(
  collect_security_audit() { real_collect_security_audit; audit_add A mail exim4 'x'; }
  ask_yes_no() {
    if [[ "$1" == '关闭 cloud-init？' ]]; then printf 'auto lo\niface lo inet loopback\n' >"$root/etc/network/interfaces"; fi
    return 0
  }
  hardening_purge_exim4() { echo mail-ran >>"$work/flow-mail"; HARDENING_MAIL_PURGED=true; }
  : >"$work/flow-mail"
  run_security_hardening >"$work/flow-skip" 2>&1
)
[[ ! -e "$CLOUD_DISABLED_FLAG" ]] || fail 'cloud-init disabled although network proof was lost'
await_text "$work/flow-skip" '加固报告' || fail 'no final report after skip'
grep -Fq '跳过 cloud-init' "$work/flow-skip" || fail 'skip not reported'
grep -Fxq mail-ran "$work/flow-mail" || fail 'cloud-init skip stopped the remaining items'
grep -Fq '已 purge exim4' "$work/flow-skip" || fail 'executed mail purge not in the report'
# A declined / failed purge is not reported as done and leaves no backup directory behind.
rm -rf "$BACKUP_ROOT"
(
  collect_security_audit() { AUDIT_FINDINGS=(); audit_add A mail exim4 'x'; }
  ask_yes_no() { return 0; }
  hardening_purge_exim4() { echo mail-declined >>"$work/flow-mail"; return 0; }
  run_security_hardening >"$work/flow-nothing" 2>&1
)
await_text "$work/flow-nothing" '没有执行任何修改' || fail 'declined purge treated as an action'
if grep -Fq '已 purge exim4' "$work/flow-nothing"; then fail 'declined purge reported as done'; fi
[[ $(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l) == 0 ]] || fail 'unused backup directory kept'
unset -f real_collect_security_audit
printf 'auto eth0\niface eth0 inet dhcp\n' >"$root/etc/network/interfaces"
unset -f hardening_backup
eval "$(sed -n '/^hardening_backup() {/,/^}/p' "$work/installer")"

# Exim purge: default N, independent collateral confirmation, fixed list, changes,
# unsafe simulations and failures. The real confirmation parser is used throughout.
for scenario in family multiarch collateral collateral-cancel cancel absent malformed simulation-failure resim-failure changed version-change only-extra ssh-package purge-failure verification-failure query-failure; do
  exim_dir="$work/exim-$scenario"
  mkdir -p "$exim_dir/backup"
  echo 0 >"$exim_dir/count"
  : >"$exim_dir/trace"
  set +e
  (
    set -Ee
    BACKUP_DIR="$exim_dir/backup"
    wait_for_package_manager() { :; }
    read_tty() {
      [[ "$1" == *'[y/N] '* ]] || fail 'Exim confirmation not default N'
      printf '%s\n' "$1" >>"$exim_dir/trace"
      if [[ "$scenario" == cancel || ( "$scenario" == collateral-cancel && "$1" == '额外确认：'* ) ]]; then
        printf -v "$2" ''
      else printf -v "$2" y; fi
    }
    apt_get() {
      local IFS=' '
      local IFS=' ' calls
      [[ "$*" == '-s -o APT::Get::AutomaticRemove=false purge -- exim4*' ]] || fail 'Exim wildcard not passed literally to APT'
      calls=$(cat "$exim_dir/count"); calls=$((calls + 1)); echo "$calls" >"$exim_dir/count"
      echo simulate >>"$exim_dir/trace"
      [[ "$scenario" != simulation-failure ]] || return 100
      if [[ "$scenario" == resim-failure && "$calls" == 2 ]]; then return 100; fi
      case "$scenario" in
        absent) echo '0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.' ;;
        only-extra) printf '0 upgraded, 0 newly installed, 1 to remove and 0 not upgraded.\nPurg mail-consumer [1]\n' ;;
        malformed) printf '1 upgraded, 0 newly installed, 1 to remove and 0 not upgraded.\nInst unrelated [1]\nPurg exim4 [1]\n' ;;
        multiarch) printf '0 upgraded, 0 newly installed, 2 to remove and 0 not upgraded.\nPurg exim4:amd64 [1]\nPurg exim4-base:amd64 [1]\n' ;;
        collateral|collateral-cancel) printf '0 upgraded, 0 newly installed, 3 to remove and 0 not upgraded.\nPurg exim4 [1]\nPurg exim4-base [1]\nRemv mail-consumer [1]\n' ;;
        ssh-package) printf '0 upgraded, 0 newly installed, 2 to remove and 0 not upgraded.\nPurg exim4 [1]\nPurg openssh-server [1]\n' ;;
        changed)
          if (( calls == 2 )); then printf '0 upgraded, 0 newly installed, 3 to remove and 0 not upgraded.\nPurg exim4 [1]\nPurg exim4-base [1]\nPurg unexpected-package [1]\n'
          else printf '0 upgraded, 0 newly installed, 2 to remove and 0 not upgraded.\nPurg exim4 [1]\nPurg exim4-base [1]\n'; fi ;;
        *) printf '0 upgraded, 0 newly installed, 2 to remove and 0 not upgraded.\nPurg exim4 [1]\nPurg exim4-base [1]\n' ;;
      esac
    }
    dpkg-query() {
      local IFS=' '
      local IFS=' '
      if [[ "$*" == *'${db:Status-Status}'* ]]; then
        [[ -f "$exim_dir/purged" ]] || fail 'unexpected verification before purge'
        case "$scenario" in
          verification-failure) echo config-files ;;
          query-failure) return 2 ;;
          *) return 1 ;;
        esac
      elif [[ "$1" == -W ]]; then
        if [[ "$scenario" == version-change && $(cat "$exim_dir/count") == 2 ]]; then echo 'exim4 2'; else echo 'exim4 1'; fi
      elif [[ "$1" == -L ]]; then echo /etc/exim4/fixture.conf
      else fail 'unexpected Exim dpkg-query'; fi
    }
    hardening_backup() { [[ "$1" == /etc/exim4 ]]; echo backup >>"$exim_dir/trace"; touch "$exim_dir/config-backup"; }
    dpkg() {
      local IFS=' ' expected
      [[ "${*:1:3}" == '--no-force-depends,depends-version --purge --' ]] || fail 'unsafe Exim dpkg flags'
      expected=$'exim4\nexim4-base'
      case "$scenario" in multiarch) expected=$'exim4-base:amd64\nexim4:amd64';; collateral) expected+=$'\nmail-consumer';; esac
      [[ $(printf '%s\n' "${@:4}" | sort) == "$expected" ]] || fail 'unapproved Exim purge list'
      [[ -f "$exim_dir/config-backup" && -s "$BACKUP_DIR/exim4-purge-plan.txt" && -s "$BACKUP_DIR/exim4-purge-versions.txt" ]] || fail 'Exim purge preceded backups'
      echo purge >>"$exim_dir/trace"
      [[ "$scenario" != purge-failure ]] || return 1
      touch "$exim_dir/purged"
    }
    hardening_purge_exim4
  ) >"$exim_dir/output" 2>&1
  result=$?
  set -e
  case "$scenario" in
    malformed|simulation-failure|resim-failure|changed|version-change|only-extra|ssh-package|purge-failure|verification-failure|query-failure)
      (( result != 0 )) || fail "Exim $scenario accepted" ;;
    *) (( result == 0 )) || { cat "$exim_dir/output"; fail "Exim $scenario failed"; } ;;
  esac
  case "$scenario" in
    family|multiarch|collateral|purge-failure|verification-failure|query-failure) grep -Fxq purge "$exim_dir/trace" ;;
    *) if grep -Fxq purge "$exim_dir/trace"; then fail "Exim $scenario purged packages"; fi ;;
  esac
  case "$scenario" in
    collateral|collateral-cancel)
      grep -Fxq '  mail-consumer' "$exim_dir/output"
      grep -Fq '额外确认：也删除' "$exim_dir/trace" ;;
    *) if grep -Fq '额外确认：' "$exim_dir/trace"; then fail 'unexpected collateral confirmation'; fi ;;
  esac
  case "$scenario" in
    absent|malformed|simulation-failure|only-extra|ssh-package) ;;
    *) grep -Fq 'cron 任务的输出邮件将无法投递' "$exim_dir/output" ;;
  esac
done

# Boot checks enable only, preserve SSH, report UFW active and waiting config.
trace="$work/boot-trace" enabled_file="$work/enabled"
: >"$trace"; : >"$enabled_file"
mkdir -p "${CF_TIMER%/*}"
touch "$CF_TIMER"
make_mutable() { :; }
systemctl() {
  local IFS=' '
  printf '%s\n' "$*" >>"$trace"
  case "$1" in
    is-enabled)
      if [[ "$*" == *ssh.socket* ]]; then return 1; fi
      if grep -Fxq "${@: -1}" "$enabled_file"; then [[ "$*" == *--quiet* ]] || echo enabled
      else [[ "$*" == *--quiet* ]] || echo disabled; return 1; fi ;;
    enable)
      [[ "$2" != sing-box.service ]] || grep -Fxq 'ConditionPathExistsGlob=/etc/sing-box/*.json' "$SINGBOX_DROPIN" || fail 'enable before gate'
      printf '%s\n' "${@:2}" >>"$enabled_file" ;;
    is-active) echo inactive; return 3 ;;
    daemon-reload) : ;;
    *) fail "unexpected systemctl $*" ;;
  esac
}
ufw() { echo 'Status: active'; }
PRESERVE_SSH=false
check_boot_services
for unit in ssh.service ufw.service smartdns.service fail2ban.service chrony.service cron.service vnstat.service sing-box.service vps-init-cloudflare-8443.timer apt-daily.timer apt-daily-upgrade.timer; do
  grep -Fxq "$unit" "$enabled_file" || fail "missing boot enable $unit"
done
grep -Fq '已启用，等待配置' <<<"$BOOT_REPORT"
grep -Fq 'Status: active' <<<"$BOOT_REPORT"
if grep -Eq '^(start|restart|enable --now)' "$trace"; then fail 'boot check started service'; fi
: >"$trace"; : >"$enabled_file"
PRESERVE_SSH=true
check_boot_services
if grep -Eq '^enable (ssh|ufw|fail2ban)\.service' "$trace"; then fail 'preserve mode changed boot access'; fi
grep -Fq '保留 SSH：只报告' <<<"$BOOT_REPORT"
# R7: apt-daily timers are always checked (even when automatic security updates are off),
# and an inactive UFW is flagged but never enabled here.
: >"$trace"; : >"$enabled_file"
PRESERVE_SSH=false AUTO_SECURITY=false
ufw() { echo 'Status: inactive'; }
check_boot_services
grep -Fxq apt-daily.timer "$enabled_file" || fail 'apt-daily.timer skipped when security updates are off'
grep -Fxq apt-daily-upgrade.timer "$enabled_file" || fail 'apt-daily-upgrade.timer skipped when security updates are off'
grep -Fq 'ufw 状态不是 active' <<<"$BOOT_REPORT" || fail 'inactive UFW not flagged'
if grep -Eq '^(start|restart|enable --now)|ufw enable' "$trace"; then fail 'inactive UFW was started'; fi
PRESERVE_SSH=true
check_boot_services
if grep -Fq 'ufw 状态不是 active' <<<"$BOOT_REPORT"; then fail 'preserve mode flagged UFW as a failure'; fi
PRESERVE_SSH=false AUTO_SECURITY=true
ufw() { echo 'Status: active'; }

# Fresh sing-box install state restoration sets the gate before enable, never starts.
: >"$trace"; : >"$enabled_file"
SINGBOX_WAS_INSTALLED=false
systemctl_base=$(declare -f systemctl)
eval "${systemctl_base/systemctl ()/boot_systemctl ()}"
systemctl() { local IFS=' '; if [[ "$1" == stop ]]; then echo "$*" >>"$trace"; else boot_systemctl "$@"; fi; }
restore_singbox_state
grep -Fxq 'enable sing-box.service' "$trace"
if grep -Eq '^(start|restart)' "$trace"; then fail 'sing-box was started'; fi
[[ ! -e "$SINGBOX_CONFIG" ]] || fail 'business config written'
echo 'PASS: hardening menu, security updates, A/B/C, key guards, network, boot and read-only audit'
