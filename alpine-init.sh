#!/bin/sh

set -eu
umask 077

export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

SCRIPT_NAME='alpine-init.sh'
TARGET_ALPINE_MINOR=24
TARGET_ALPINE_BRANCH='v3.24'
ALPINE_MIRROR='https://dl-cdn.alpinelinux.org/alpine'
SINGBOX_VERSION='1.14.0'
SINGBOX_CONFIG='/etc/sing-box/config.json'
SINGBOX_INIT='/etc/init.d/sing-box'
AUTHORIZED_KEYS='/root/.ssh/authorized_keys'
SSH_CONFIG='/etc/ssh/sshd_config'
LOCK_DIR='/run/alpine-init.lock'

CURRENT_STEP='启动'
TMP_DIR=''
BACKUP_DIR=''
PUBLIC_KEY=''
INITIAL_MINOR=''
BRANCH_UPGRADED=0

log() {
    printf '\n==> %s\n' "$*"
}

info() {
    printf '    %s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf '\nERROR [%s]: %s\n' "$CURRENT_STEP" "$*" >&2
    exit 1
}

cleanup() {
    [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
    rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

require_root_alpine() {
    CURRENT_STEP='检查运行环境'
    [ "$(id -u)" -eq 0 ] || die '请使用 root 执行。'
    [ -f /etc/alpine-release ] || die '这不是 Alpine Linux。'
    command -v apk >/dev/null 2>&1 || die '找不到 apk。'
    command -v rc-service >/dev/null 2>&1 || die '找不到 OpenRC rc-service。'
    mkdir "$LOCK_DIR" 2>/dev/null || die "已有 $SCRIPT_NAME 正在运行。"
    TMP_DIR="$(mktemp -d /root/alpine-init.XXXXXX)" || die '无法创建临时目录。'
    BACKUP_DIR="/root/alpine-init-backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
}

collect_public_key() {
    CURRENT_STEP='读取 SSH 公钥'
    printf '请输入 SSH 公钥：\n> '
    IFS= read -r PUBLIC_KEY || true
    [ -n "$PUBLIC_KEY" ] || die 'SSH 公钥不能为空。'
    printf '%s\n' "$PUBLIC_KEY" > "$TMP_DIR/public-key"
}

validate_public_key_basic() {
    CURRENT_STEP='初步验证 SSH 公钥'
    key_type="$(awk 'NR==1 {print $1}' "$TMP_DIR/public-key")"
    key_blob="$(awk 'NR==1 {print $2}' "$TMP_DIR/public-key")"

    case "$key_type" in
        ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
        *) die "不支持或无法识别的 SSH 公钥类型：${key_type:-empty}" ;;
    esac

    [ -n "$key_blob" ] || die 'SSH 公钥内容为空。'
    printf '%s' "$key_blob" | base64 -d >/dev/null 2>&1 \
        || die 'SSH 公钥 Base64 内容无效。'
}

validate_public_key_openssh() {
    CURRENT_STEP='验证 SSH 公钥'
    ssh-keygen -l -f "$TMP_DIR/public-key" >/dev/null 2>&1 \
        || die 'SSH 公钥无法通过 ssh-keygen 校验。'
}

install_authorized_key() {
    CURRENT_STEP='写入 SSH 公钥'
    log '写入 SSH 公钥'

    [ ! -L /root/.ssh ] || die '/root/.ssh 不能是符号链接。'
    mkdir -p /root/.ssh
    chmod 0700 /root/.ssh
    chown root:root /root/.ssh

    [ ! -L "$AUTHORIZED_KEYS" ] || die "$AUTHORIZED_KEYS 不能是符号链接。"
    touch "$AUTHORIZED_KEYS"
    chmod 0600 "$AUTHORIZED_KEYS"
    chown root:root "$AUTHORIZED_KEYS"

    key_type="$(awk 'NR==1 {print $1}' "$TMP_DIR/public-key")"
    key_blob="$(awk 'NR==1 {print $2}' "$TMP_DIR/public-key")"
    if awk -v t="$key_type" -v b="$key_blob" '$1 == t && $2 == b { found=1 } END { exit found ? 0 : 1 }' "$AUTHORIZED_KEYS"; then
        info 'authorized_keys 已存在相同公钥。'
    else
        printf '%s\n' "$PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
        info 'SSH 公钥已添加。'
    fi
}

parse_alpine_version() {
    CURRENT_STEP='识别 Alpine 版本'
    version="$(cat /etc/alpine-release 2>/dev/null || true)"
    major="$(printf '%s' "$version" | awk -F. '{print $1}')"
    minor="$(printf '%s' "$version" | awk -F. '{print $2}')"

    case "$major:$minor" in
        *[!0-9:]*|'':*) die "无法识别 Alpine 版本：$version" ;;
    esac

    [ "$major" -eq 3 ] || die "仅支持 Alpine 3.x；当前版本：$version"
    if [ "$minor" -gt "$TARGET_ALPINE_MINOR" ]; then
        die "当前 Alpine $version 高于 3.24.x；脚本拒绝执行不受支持的降级。"
    fi

    INITIAL_MINOR="$minor"
    info "当前 Alpine：$version"
}

write_repositories() {
    branch="$1"
    CURRENT_STEP="切换 Alpine 仓库到 $branch"

    if [ -f /etc/apk/repositories ] && [ ! -f "$BACKUP_DIR/repositories.before" ]; then
        cp -p /etc/apk/repositories "$BACKUP_DIR/repositories.before"
    fi

    cat > /etc/apk/repositories <<EOF_REPOS
${ALPINE_MIRROR}/${branch}/main
${ALPINE_MIRROR}/${branch}/community
EOF_REPOS
}

upgrade_one_branch() {
    next_minor="$1"
    branch="v3.${next_minor}"

    log "升级 Alpine -> $branch"
    write_repositories "$branch"

    CURRENT_STEP="更新 $branch 软件索引"
    apk update

    CURRENT_STEP="升级 $branch apk-tools"
    apk add --upgrade apk-tools

    CURRENT_STEP="升级 $branch 全部软件包"
    apk upgrade --available
    sync
}

upgrade_alpine() {
    CURRENT_STEP='升级 Alpine'
    minor="$INITIAL_MINOR"

    if [ "$minor" -lt "$TARGET_ALPINE_MINOR" ]; then
        BRANCH_UPGRADED=1
        next=$((minor + 1))
        while [ "$next" -le "$TARGET_ALPINE_MINOR" ]; do
            if [ "$next" -eq 20 ] && apk info -e grub >/dev/null 2>&1; then
                warn '检测到 GRUB，且升级路径经过 Alpine 3.20。官方对此路径有额外 bootloader 注意事项。'
                warn '脚本不会自动 reboot；升级完成后请先确认 bootloader 状态再重启。'
            fi
            upgrade_one_branch "$next"
            next=$((next + 1))
        done
    else
        log '已在 Alpine 3.24.x，更新到当前 3.24 分支最新补丁'
        write_repositories "$TARGET_ALPINE_BRANCH"
        apk update
        apk add --upgrade apk-tools
        apk upgrade --available
        sync
    fi

    CURRENT_STEP='验证 Alpine 版本'
    final_version="$(cat /etc/alpine-release 2>/dev/null || true)"
    case "$final_version" in
        3.24.*) info "Alpine 已就绪：$final_version" ;;
        *) die "升级后版本异常：$final_version" ;;
    esac
}

install_base_packages() {
    CURRENT_STEP='安装基础组件'
    log '安装 SSH / 下载组件'
    apk add --no-cache ca-certificates curl tar openssh
    update-ca-certificates >/dev/null 2>&1 || true
    ssh-keygen -A >/dev/null 2>&1 || true
}

write_ssh_config() {
    CURRENT_STEP='配置 SSH'
    log '配置 SSH：22 / root key-only'

    if [ -f "$SSH_CONFIG" ]; then
        cp -p "$SSH_CONFIG" "$BACKUP_DIR/sshd_config.before"
    fi
    if [ -d /etc/ssh/sshd_config.d ]; then
        cp -a /etc/ssh/sshd_config.d "$BACKUP_DIR/sshd_config.d.before"
    fi

    mkdir -p /etc/ssh/sshd_config.d

    staged="$TMP_DIR/sshd_config"
    cat > "$staged" <<'EOF_SSH'
Port 22
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AuthorizedKeysCommand none
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
X11Forwarding no
Subsystem sftp internal-sftp
EOF_SSH

    chmod 0600 "$staged"

    sshd -t -f "$staged" || die '新的 sshd_config 校验失败，未替换现有配置。'

    cp "$staged" "$SSH_CONFIG"
    chmod 0600 "$SSH_CONFIG"
    chown root:root "$SSH_CONFIG"

    sshd -t || {
        if [ -f "$BACKUP_DIR/sshd_config.before" ]; then
            cp "$BACKUP_DIR/sshd_config.before" "$SSH_CONFIG"
        fi
        die '安装后的 SSH 配置校验失败，已恢复主配置。'
    }

    rc-update add sshd default >/dev/null 2>&1 || true

    if rc-service sshd status >/dev/null 2>&1; then
        if ! rc-service sshd restart; then
            if [ -f "$BACKUP_DIR/sshd_config.before" ]; then
                cp "$BACKUP_DIR/sshd_config.before" "$SSH_CONFIG"
                sshd -t >/dev/null 2>&1 && rc-service sshd restart >/dev/null 2>&1 || true
            fi
            die 'sshd 重启失败，已尝试恢复原配置。'
        fi
    else
        rc-service sshd start || die 'sshd 启动失败。'
    fi

    CURRENT_STEP='验证 SSH 生效配置'
    effective="$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null)" \
        || die '无法读取 sshd 生效配置。'

    printf '%s\n' "$effective" | grep -Eq '^port 22$' || die 'SSH Port 22 未生效。'
    printf '%s\n' "$effective" | grep -Eq '^permitrootlogin (prohibit-password|without-password)$' || die 'PermitRootLogin 未按预期生效。'
    printf '%s\n' "$effective" | grep -Eq '^pubkeyauthentication yes$' || die 'PubkeyAuthentication 未生效。'
    printf '%s\n' "$effective" | grep -Eq '^passwordauthentication no$' || die 'PasswordAuthentication=no 未生效。'
    printf '%s\n' "$effective" | grep -Eq '^kbdinteractiveauthentication no$' || die 'KbdInteractiveAuthentication=no 未生效。'
    printf '%s\n' "$effective" | grep -Eq '^authenticationmethods publickey$' || die 'AuthenticationMethods=publickey 未生效。'

    info 'SSH 已固定为 TCP/22 + root 公钥认证。'
}

singbox_arch() {
    case "$(uname -m)" in
        x86_64) printf '%s\n' 'amd64' ;;
        aarch64|arm64) printf '%s\n' 'arm64' ;;
        *) return 1 ;;
    esac
}

install_singbox() {
    CURRENT_STEP='安装 sing-box'
    log "安装 sing-box ${SINGBOX_VERSION}"

    arch="$(singbox_arch)" || die "sing-box 安装暂只支持 x86_64 / aarch64；当前架构：$(uname -m)"
    case "$arch" in
        amd64) expected_sha256='d2d6b4543d850269214ced70ffe41b13b1595baa1b6f9c016466abfba162c4d4' ;;
        arm64) expected_sha256='1811c446a4957edee1b62ed2363607f8e99e1f7b6d88179719251d7ed5f30169' ;;
        *) die "没有 ${arch} 的固定校验值。" ;;
    esac

    asset="sing-box-${SINGBOX_VERSION}-linux-${arch}-musl.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${asset}"
    archive="$TMP_DIR/$asset"
    extract_dir="$TMP_DIR/sing-box-${SINGBOX_VERSION}-linux-${arch}-musl"

    curl -fL --retry 3 --connect-timeout 15 --max-time 600 "$url" -o "$archive" \
        || die '下载 sing-box 失败。'

    printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum -c - >/dev/null 2>&1 \
        || die 'sing-box SHA-256 校验失败。'

    tar -tzf "$archive" | grep -Fqx "sing-box-${SINGBOX_VERSION}-linux-${arch}-musl/sing-box" \
        || die 'sing-box 压缩包结构异常。'

    tar -xzf "$archive" -C "$TMP_DIR"
    [ -x "$extract_dir/sing-box" ] || chmod 0755 "$extract_dir/sing-box"

    downloaded_version="$("$extract_dir/sing-box" version 2>/dev/null | awk 'NR==1 {print $3}')"
    [ "$downloaded_version" = "$SINGBOX_VERSION" ] \
        || die "下载的 sing-box 版本异常：${downloaded_version:-unknown}"

    if [ -x /usr/local/bin/sing-box ]; then
        cp -p /usr/local/bin/sing-box "$BACKUP_DIR/sing-box.before" 2>/dev/null || true
    fi
    if [ -f "$SINGBOX_INIT" ]; then
        cp -p "$SINGBOX_INIT" "$BACKUP_DIR/sing-box.init.before" 2>/dev/null || true
        rc-service sing-box stop >/dev/null 2>&1 || true
    fi
    if [ -f "$SINGBOX_CONFIG" ]; then
        mkdir -p "$BACKUP_DIR/sing-box"
        cp -p "$SINGBOX_CONFIG" "$BACKUP_DIR/sing-box/config.json.before"
    fi

    mkdir -p /usr/local/bin /etc/sing-box
    cp "$extract_dir/sing-box" /usr/local/bin/sing-box
    chmod 0755 /usr/local/bin/sing-box
    chown root:root /usr/local/bin/sing-box

    installed_version="$(/usr/local/bin/sing-box version 2>/dev/null | awk 'NR==1 {print $3}')"
    [ "$installed_version" = "$SINGBOX_VERSION" ] \
        || die "sing-box 安装验证失败：${installed_version:-unknown}"

    write_singbox_service

    # 用户要求：启用开机项，但当前机器不保留默认 config.json，也不立即运行 sing-box。
    rc-service sing-box stop >/dev/null 2>&1 || true
    rm -f "$SINGBOX_CONFIG"
    rc-update add sing-box default >/dev/null 2>&1 || true
    rc-service sing-box zap >/dev/null 2>&1 || true

    info "sing-box 已安装：$installed_version"
    info 'OpenRC：已加入 default runlevel；当前未运行。'
    info "$SINGBOX_CONFIG：不存在。"
}

write_singbox_service() {
    CURRENT_STEP='配置 sing-box OpenRC 服务'

    cat > "$SINGBOX_INIT" <<'EOF_SERVICE'
#!/sbin/openrc-run

name="sing-box"
description="sing-box proxy service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
retry="TERM/10/KILL/5"

depend() {
    need net
    after firewall
}

start() {
    if [ ! -s /etc/sing-box/config.json ]; then
        ewarn "sing-box config is absent; leaving service inactive"
        mark_service_inactive "$RC_SVCNAME"
        return 0
    fi

    if ! "$command" check -c /etc/sing-box/config.json; then
        eerror "sing-box config check failed"
        return 1
    fi

    default_start
}
EOF_SERVICE

    chmod 0755 "$SINGBOX_INIT"
    chown root:root "$SINGBOX_INIT"
}

summary() {
    CURRENT_STEP='完成'
    alpine_version="$(cat /etc/alpine-release 2>/dev/null || printf 'unknown')"
    ssh_state='stopped'
    rc-service sshd status >/dev/null 2>&1 && ssh_state='started'

    singbox_state='stopped'
    if pidof sing-box >/dev/null 2>&1; then
        singbox_state='running'
    fi

    printf '\n========================================\n'
    printf ' Alpine init 完成\n'
    printf '========================================\n'
    printf 'Alpine   : %s\n' "$alpine_version"
    printf 'SSH      : port 22 / root key-only\n'
    printf 'sshd     : %s / boot enabled\n' "$ssh_state"
    printf 'sing-box : %s\n' "$SINGBOX_VERSION"
    printf 'service  : boot enabled\n'
    printf 'config   : absent (%s)\n' "$SINGBOX_CONFIG"
    printf 'process  : %s\n' "$singbox_state"
    printf 'backup   : %s\n' "$BACKUP_DIR"
    if [ "$BRANCH_UPGRADED" -eq 1 ]; then
        printf 'reboot   : recommended after release-branch upgrade\n'
    else
        printf 'reboot   : not forced by this script\n'
    fi
    printf '========================================\n'
}

main() {
    require_root_alpine

    # 按用户要求：脚本一开始即询问公钥，之后不再询问任何内容。
    collect_public_key
    validate_public_key_basic
    install_authorized_key

    parse_alpine_version
    upgrade_alpine
    install_base_packages

    # 升级后使用 OpenSSH 本身再次验证，再切换成 key-only。
    validate_public_key_openssh
    write_ssh_config
    install_singbox
    summary
}

main "$@"
