#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034,SC2016 # Mocks/state and literal APT placeholders.
set -Eeuo pipefail
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
  -e "s|^readonly BACKUP_ROOT=.*|readonly BACKUP_ROOT='$work/hardening-backups'|" \
  -e "s|/dev/tty|$work/tty|g" "$repo/debian-init.sh" >"$work/installer"
# shellcheck disable=SC1091
source "$work/installer"
IFS=$' \t\n'
trap - ERR HUP INT TERM
trap 'rm -rf -- "$work"' EXIT
TMP_DIR="$work/tmp" BACKUP_DIR="$work/backup"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Actual menu, including invalid reserved 9 and exit 0.
for mapping in 1:quick 2:custom 3:smartdns 4:singbox 5:fail2ban 6:update 7:cleanup 8:hardening; do
  INSTALL_MODE=''
  read_tty() { printf -v "$2" '%s' "${mapping%%:*}"; }
  select_install_mode
  [[ "$INSTALL_MODE" == "${mapping#*:}" ]] || fail "menu $mapping"
done
grep -Fq '0. 退出' "$work/tty"
if grep -q '^9\.' "$work/tty"; then fail 'menu occupied reserved 9'; fi
(
  INSTALL_MODE='' replies=0
  read_tty() { replies=$((replies + 1)); if (( replies == 1 )); then printf -v "$2" 9; else printf -v "$2" 3; fi; }
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
  [[ "$*" == 'install -y unattended-upgrades' ]] || fail 'security APT command'
  grep -Fq '#clear Unattended-Upgrade::Allowed-Origins;' "$SECURITY_APT_CONF" || fail 'policy was not written before installation'
  echo install >>"$trace"
}
systemctl() { printf '%s\n' "$*" >>"$trace"; }
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
  case "$*" in
    '-o comm='*) echo sshd ;;
    '-o lstart='*) echo 'Wed Nov 25 01:00:00 2026' ;;
    '-o ppid='*) echo 1 ;;
    *) fail 'unexpected ps' ;;
  esac
}
journalctl() {
  [[ "$*" == *'--since 2026-11-25 01:00:00'* && "$*" == *'_PID='* ]] || fail 'unbound journal query'
  printf 'Accepted publickey for root from 192.0.2.10 port 1234 ssh2: ED25519 %s\n' "$current_fp"
  printf 'Accepted publickey for root from 192.0.2.99 port 1234 ssh2: ED25519 %s\n' "$other_fp"
  printf 'Accepted publickey for root from 192.0.2.10 port 7777 ssh2: ED25519 %s\n' "$other_fp"
}
[[ $(audit_session_key) == "$current_fp" ]] || fail 'session correlation'
journalctl() { printf 'Accepted password for root from 192.0.2.10 port 1234 ssh2\n'; }
if audit_session_key; then fail 'password session treated as publickey'; fi
journalctl() { printf 'Accepted publickey for root from 192.0.2.10 port 1234 ssh2: ED25519 %s\n' "$current_fp" "$other_fp"; }
if audit_session_key; then fail 'ambiguous session allowed'; fi
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
if audit_regular_key_path "$root/home/person/.ssh/authorized_keys"; then fail 'symlink accepted'; fi
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

# Network allow/skip: actual route/address evidence, boot ownership and generated files.
mkdir -p "$root/etc/network/interfaces.d" "$root/etc/systemd/network" "$root/etc/cloud" "$root/etc/netplan" "$root/run/systemd/network"
network_backend=ifup
systemctl() {
  case "$*" in
    'is-enabled --quiet networking.service') [[ "$network_backend" == ifup ]] ;;
    'is-enabled --quiet systemd-networkd.service') [[ "$network_backend" == networkd ]] ;;
    *) return 1 ;;
  esac
}
ifquery() { [[ "$*" == '--state eth0' ]]; }
ip() {
  if [[ "$*" == '-o route show default' ]]; then echo 'default via 192.0.2.1 dev eth0 proto dhcp'
  else echo '2: eth0 inet 192.0.2.20/24 scope global dynamic eth0'; fi
}
printf 'auto eth0\niface eth0 inet dhcp\n' >"$root/etc/network/interfaces"
audit_network_persistent || fail 'simple DHCP refused'
printf '# generated by cloud-init\n' >>"$root/etc/network/interfaces"
if audit_network_persistent; then fail 'cloud generated config allowed'; fi
printf 'auto eth0\niface eth0 inet dhcp\nup curl example.invalid\n' >"$root/etc/network/interfaces"
if audit_network_persistent; then fail 'network hooks allowed'; fi
printf 'auto eth0\niface eth0 inet static\n' >"$root/etc/network/interfaces"
if audit_network_persistent; then fail 'unverified static network allowed'; fi
printf 'source /etc/network/interfaces.d/*\n' >"$root/etc/network/interfaces"
printf 'allow-hotplug eth0\niface eth0 inet dhcp\n' >"$root/etc/network/interfaces.d/eth0"
audit_network_persistent || fail 'included DHCP refused'
touch "$root/etc/netplan/50-cloud.yaml"
if audit_network_persistent; then fail 'netplan precedence guessed'; fi
rm "$root/etc/netplan/50-cloud.yaml" "$root/etc/network/interfaces.d/eth0"
network_backend=networkd
printf '[Match]\nName=eth0\n[Network]\nDHCP=ipv4\n' >"$root/etc/systemd/network/10-wan.network"
networkctl() { echo ' Network File: /etc/systemd/network/10-wan.network'; }
audit_network_persistent || fail 'simple networkd DHCP refused'
touch "$root/run/systemd/network/generated.network"
if audit_network_persistent; then fail 'runtime generated network allowed'; fi
rm "$root/run/systemd/network/generated.network"
SSH_CONNECTION='2001:db8::1 1234 2001:db8::2 22'
if audit_network_persistent; then fail 'unverified IPv6 network allowed'; fi
SSH_CONNECTION='192.0.2.10 1234 192.0.2.20 22'

# Full audit positive and negative fixtures, including each A/B/C detector.
audit_mode=positive
mkdir -p "$root/etc/cron.d" "$root/etc/sudoers.d" "$root/proc/321" "$root/usr/local/aegis"
printf 'root:x:0:0::/root:/bin/bash\nextra:x:0:0::/home/extra:/bin/bash\n' >"$root/etc/passwd"
echo preload >"$root/etc/ld.so.preload"
echo cron >"$root/etc/cron.d/unowned"
echo sudo >"$root/etc/sudoers.d/extra"
ln -s /opt/agent "$root/proc/321/exe"
qemu_guest_agent_status() { if [[ "$audit_mode" == positive ]]; then echo installed; else echo not-installed; fi; }
dpkg-query() {
  case "$1" in
    -S) if [[ "$audit_mode" == negative || "$*" == *'/usr/bin/official'* ]]; then echo 'official: /usr/bin/official'; else return 1; fi ;;
    -W)
      if [[ "$*" == *'${Version}'* ]]; then echo 1.0
      elif [[ "$*" == *'${binary:Package}'* ]]; then printf 'official\tinstalled\n'; [[ "$audit_mode" != positive ]] || printf 'external\tinstalled\nexim4-base\tinstalled\n'
      elif [[ "$*" == *'-- aegis' && "$audit_mode" == positive ]]; then echo installed
      else return 1; fi ;;
    *) return 1 ;;
  esac
}
apt-cache() {
  if [[ "$*" == policy ]]; then
    printf ' 500 https://deb.debian.org/debian stable/main amd64 Packages\n     release o=Debian,a=stable\n'
  elif [[ "$*" == *'external'* || "$*" == *'aegis'* ]]; then
    printf ' *** 1.0 100\n        500 https://vendor.invalid stable/main amd64 Packages\n'
  else
    printf ' *** 1.0 100\n        500 https://deb.debian.org/debian stable/main amd64 Packages\n'
  fi
}
systemctl() {
  case "$*" in
    'list-unit-files --state=enabled'*) [[ "$audit_mode" != positive ]] || echo 'custom.service enabled' ;;
    'list-unit-files --type=service'*) [[ "$audit_mode" != positive ]] || echo 'aegis.service enabled' ;;
    'show -p FragmentPath'*) echo /etc/systemd/system/custom.service ;;
    'show -p DropInPaths'*) : ;;
    'is-enabled --quiet networking.service') return 0 ;;
    *) return 1 ;;
  esac
}
ss() { if [[ "$audit_mode" == positive ]]; then echo 'tcp LISTEN 0 128 0.0.0.0:9999 0.0.0.0:* users:(("agent",pid=321,fd=3))'; fi; }
sshd() {
  if [[ "$audit_mode" == positive ]]; then printf 'authorizedkeyscommand /opt/keys\nauthorizedkeysfile /opt/keys-file\n'
  else printf 'authorizedkeyscommand none\nauthorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2\n'; fi
}
printf 'auto eth0\niface eth0 inet dhcp\n' >"$root/etc/network/interfaces"
rm "$root/etc/systemd/network/10-wan.network"
printf '%s\n%s\n' "$current" "$other" >"$file"
rm "$TRUSTED_KEYS_STATE"
collect_security_audit
print_security_audit full >"$work/positive"
for detector in key cloud qga agent mail package service cron sudo port preload uid ssh; do
  printf '%s\n' "${AUDIT_FINDINGS[@]}" | grep -q $'\t'"$detector"$'\t' || fail "missing positive $detector"
done
grep -Fq '没有归属记录' "$work/positive"
PUBLIC_KEY=$current REUSE_PUBLIC_KEY=false
record_trusted_keys
# Root ownership check is mocked only for this fixture on non-root CI runners.
stat() { if [[ "$*" == "-c %u $TRUSTED_KEYS_STATE" ]]; then echo 0; else command stat "$@"; fi; }
collect_security_audit
print_security_audit full >"$work/recorded"
grep -Fq '不是你提供的' "$work/recorded"
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

# Unknown cloud network stops before any destructive work or even a risk prompt.
(
  collect_security_audit() { AUDIT_FINDINGS=(); audit_add B network cloud-init 'unknown'; }
  ask_yes_no() { fail 'network uncertainty reached execution'; }
  run_security_hardening
)

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
  printf '%s\n' "$*" >>"$trace"
  case "$1" in
    is-enabled)
      if [[ "$*" == *ssh.socket* ]]; then return 1; fi
      if grep -Fxq "${@: -1}" "$enabled_file"; then [[ "$*" == *--quiet* ]] || echo enabled
      else [[ "$*" == *--quiet* ]] || echo disabled; return 1; fi ;;
    enable)
      [[ "$2" != sing-box.service ]] || grep -Fxq 'ConditionPathExists=/etc/sing-box/config.json' "$SINGBOX_DROPIN" || fail 'enable before gate'
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

# Fresh sing-box install state restoration sets the gate before enable, never starts.
: >"$trace"; : >"$enabled_file"
SINGBOX_WAS_INSTALLED=false
systemctl_base=$(declare -f systemctl)
eval "${systemctl_base/systemctl ()/boot_systemctl ()}"
systemctl() { if [[ "$1" == stop ]]; then echo "$*" >>"$trace"; else boot_systemctl "$@"; fi; }
restore_singbox_state
grep -Fxq 'enable sing-box.service' "$trace"
if grep -Eq '^(start|restart)' "$trace"; then fail 'sing-box was started'; fi
[[ ! -e "$SINGBOX_CONFIG" ]] || fail 'business config written'
echo 'PASS: hardening menu, security updates, A/B/C, key guards, network, boot and read-only audit'
