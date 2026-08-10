#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG_PATH='/etc/sing-box/config.json'
readonly CONFIG_DIR='/etc/sing-box'
readonly MODULE_CANCEL_STATUS=20

TEMP_CONFIG=''
LOG_JSON='{}'
INBOUNDS_JSON='[]'
OUTBOUNDS_JSON='[]'
ROUTE_JSON='{}'
BUILT_ITEM=''
WORKING_CONFIG_JSON=''
OUTBOUND_TAGS=()
MODULE_INPUT_ACTIVE=false
NETWORK_STACK='ipv4'
VIRTUALIZATION='unknown'
CONTAINER_VIRTUALIZATION='none'
ENVIRONMENT_LABEL='Unknown environment'
KERNEL_ENFORCEMENT='unavailable'
APPLICATION_ENFORCEMENT='enabled'
NETWORK_RESULT='SUCCESS'

RED=''
GREEN=''
YELLOW=''
CYAN=''
RESET=''

init_colors() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        RED=$'\033[31m'
        GREEN=$'\033[32m'
        YELLOW=$'\033[33m'
        CYAN=$'\033[36m'
        RESET=$'\033[0m'
    fi
}

info() {
    printf '%s%s%s\n' "$CYAN" "$*" "$RESET"
}

success() {
    printf '%s%s%s\n' "$GREEN" "$*" "$RESET"
}

warn() {
    printf '%s%s%s\n' "$YELLOW" "$*" "$RESET" >&2
}

error() {
    printf '%s错误：%s%s\n' "$RED" "$*" "$RESET" >&2
}

cleanup() {
    if [[ -n "$TEMP_CONFIG" && -f "$TEMP_CONFIG" ]]; then
        rm -f -- "$TEMP_CONFIG"
    fi
}

handle_signal() {
    printf '\n' >&2
    warn '已取消，未完成的临时配置将被清理。'
    exit 130
}

trap cleanup EXIT
trap handle_signal INT TERM

die() {
    error "$*"
    exit 1
}

check_environment() {
    local os_id=''
    local os_version=''

    if (( EUID != 0 )); then
        die '请使用 root 身份运行。'
    fi

    if [[ ! -r /etc/os-release ]]; then
        die '无法读取 /etc/os-release；本工具仅支持 Debian 12/13。'
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"
    os_version="${os_version%%.*}"

    if [[ "$os_id" != 'debian' || ( "$os_version" != '12' && "$os_version" != '13' ) ]]; then
        die "仅支持 Debian 12/13；当前系统为 ${PRETTY_NAME:-未知系统}。"
    fi

    if ! command -v jq >/dev/null 2>&1; then
        die '未找到 jq，请先手动安装 jq。'
    fi
}

detect_runtime_environment() {
    local detected=''
    local container=''

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        detected="$(systemd-detect-virt 2>/dev/null || true)"
        container="$(systemd-detect-virt --container 2>/dev/null || true)"
    fi
    [[ -n "$detected" && "$detected" != 'none' ]] || detected='none'
    [[ -n "$container" && "$container" != 'none' ]] || container='none'
    VIRTUALIZATION="$detected"
    CONTAINER_VIRTUALIZATION="$container"
    if [[ "$container" != 'none' ]]; then
        ENVIRONMENT_LABEL="$container container"
        info "Virtualization: $detected"
        info "Container environment detected: $container."
    elif [[ "$detected" == 'none' ]]; then
        ENVIRONMENT_LABEL='Bare metal'
        info 'Virtualization: none'
    else
        ENVIRONMENT_LABEL="$detected virtual machine"
        info "Virtualization: $detected"
    fi
}

inspect_kernel_enforcement() {
    local all_value='unknown'
    local default_value='unknown'
    local loopback_value='unknown'
    local desired_value=0

    [[ "$NETWORK_STACK" == 'ipv4' ]] && desired_value=1
    if command -v sysctl >/dev/null 2>&1; then
        all_value="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || printf unknown)"
        default_value="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || printf unknown)"
        loopback_value="$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null || printf unknown)"
    fi
    if [[ "$all_value" == "$desired_value" &&
        "$default_value" == "$desired_value" &&
        "$loopback_value" == "$desired_value" ]]; then
        KERNEL_ENFORCEMENT='enabled'
        return 0
    fi
    KERNEL_ENFORCEMENT='unavailable'
    NETWORK_RESULT='SUCCESS_WITH_WARNINGS'
    warn "Kernel enforcement is unavailable for requested mode $NETWORK_STACK; application enforcement will be used."
}

print_network_result() {
    printf '\nRequested mode: %s\n' "$NETWORK_STACK"
    printf 'Kernel enforcement: %s\n' "$KERNEL_ENFORCEMENT"
    printf 'Application enforcement: %s\n' "$APPLICATION_ENFORCEMENT"
    printf 'Environment: %s\n' "$ENVIRONMENT_LABEL"
    printf 'Virtualization: %s\n' "$VIRTUALIZATION"
    printf 'Container: %s\n' "$CONTAINER_VIRTUALIZATION"
    printf 'Result: %s\n' "$NETWORK_RESULT"
}

read_line() {
    local target_name="$1"
    local prompt="$2"
    local secret="${3:-false}"
    local value=''
    local key=''
    local next_key=''
    local read_status=0
    local echo_input=false

    if [[ "$secret" != 'true' && -t 0 ]]; then
        echo_input=true
    fi

    printf '%s' "$prompt"
    while true; do
        if IFS= read -r -s -n 1 key; then
            :
        else
            read_status=$?
            printf '\n' >&2
            if (( read_status > 128 )); then
                return "$read_status"
            fi
            exit 0
        fi

        case "$key" in
            '')
                printf '\n'
                printf -v "$target_name" '%s' "$value"
                return 0
                ;;
            $'\177'|$'\b')
                if [[ -n "$value" ]]; then
                    value="${value%?}"
                    if [[ "$echo_input" == 'true' ]]; then
                        printf '\b \b'
                    fi
                fi
                ;;
            $'\e')
                if IFS= read -r -s -n 1 -t 0.05 next_key; then
                    consume_escape_sequence "$next_key"
                    continue
                fi
                if [[ "$MODULE_INPUT_ACTIVE" == 'true' ]]; then
                    printf '\n'
                    printf -v "$target_name" '%s' ''
                    return "$MODULE_CANCEL_STATUS"
                fi
                ;;
            *)
                value+="$key"
                if [[ "$echo_input" == 'true' ]]; then
                    printf '%s' "$key"
                fi
                ;;
        esac
    done
}

consume_escape_sequence() {
    local first_key="$1"
    local key=''

    case "$first_key" in
        '[')
            while IFS= read -r -s -n 1 -t 0.01 key; do
                [[ "$key" == [@-~] ]] && break
            done
            ;;
        'O')
            IFS= read -r -s -n 1 -t 0.01 key || true
            ;;
    esac
}

begin_module_build() {
    BUILT_ITEM=''
    MODULE_INPUT_ACTIVE=true
}

finish_module_build() {
    MODULE_INPUT_ACTIVE=false
}

module_prompt() {
    local prompt_status=0

    if "$@"; then
        return 0
    else
        prompt_status=$?
    fi

    BUILT_ITEM=''
    finish_module_build
    return "$prompt_status"
}

prompt_required() {
    local target_name="$1"
    local label="$2"
    local secret="${3:-false}"
    local input=''
    local prompt_status=0

    while true; do
        if read_line input "${label}：" "$secret"; then
            :
        else
            prompt_status=$?
            return "$prompt_status"
        fi
        if [[ -n "$input" ]]; then
            printf -v "$target_name" '%s' "$input"
            return
        fi
        error '此字段不能为空，请重新输入。'
    done
}

prompt_port() {
    local target_name="$1"
    local label="$2"
    local default_port="$3"
    local input=''
    local prompt_status=0

    while true; do
        if read_line input "${label} [${default_port}]：" false; then
            :
        else
            prompt_status=$?
            return "$prompt_status"
        fi
        input="${input:-$default_port}"
        if [[ "$input" =~ ^[0-9]+$ && ${#input} -le 5 ]] \
            && (( 10#$input >= 1 && 10#$input <= 65535 )); then
            printf -v "$target_name" '%s' "$((10#$input))"
            return
        fi
        error '端口必须是 1–65535 的整数。'
    done
}

prompt_yes_no() {
    local target_name="$1"
    local label="$2"
    local input=''
    local prompt_status=0

    while true; do
        if read_line input "${label} [y/n]：" false; then
            :
        else
            prompt_status=$?
            return "$prompt_status"
        fi
        case "${input,,}" in
            y|yes)
                printf -v "$target_name" '%s' 'yes'
                return
                ;;
            n|no)
                printf -v "$target_name" '%s' 'no'
                return
                ;;
            *)
                error '请输入 y、yes、n 或 no。'
                ;;
        esac
    done
}

prompt_numbered_choice() {
    local target_name="$1"
    local minimum="$2"
    local maximum="$3"
    local default_choice="${4:-}"
    local input=''
    local prompt_status=0

    while true; do
        if [[ -n "$default_choice" ]]; then
            if read_line input "请输入选项 [${default_choice}]：" false; then
                :
            else
                prompt_status=$?
                return "$prompt_status"
            fi
            input="${input:-$default_choice}"
        else
            if read_line input '请输入选项：' false; then
                :
            else
                prompt_status=$?
                return "$prompt_status"
            fi
        fi

        if [[ "$input" =~ ^[0-9]+$ && ${#input} -le 9 ]] \
            && (( 10#$input >= minimum && 10#$input <= maximum )); then
            printf -v "$target_name" '%s' "$((10#$input))"
            return
        fi
        error "请输入 ${minimum}–${maximum} 之间的数字。"
    done
}

prompt_method() {
    local target_name="$1"
    local choice=''
    local prompt_status=0

    printf '\n请选择 Shadowsocks 2022 method：\n\n'
    printf '1. 2022-blake3-aes-128-gcm（默认）\n'
    printf '2. 2022-blake3-aes-256-gcm\n'
    printf '3. 2022-blake3-chacha20-poly1305\n'
    if prompt_numbered_choice choice 1 3 1; then
        :
    else
        prompt_status=$?
        return "$prompt_status"
    fi

    case "$choice" in
        1) printf -v "$target_name" '%s' '2022-blake3-aes-128-gcm' ;;
        2) printf -v "$target_name" '%s' '2022-blake3-aes-256-gcm' ;;
        3) printf -v "$target_name" '%s' '2022-blake3-chacha20-poly1305' ;;
    esac
}

prompt_server_ip() {
    local target_name="$1"
    local candidate=''
    local prompt_status=0

    while true; do
        if prompt_required candidate '请输入服务器 IP' false; then
            :
        else
            prompt_status=$?
            return "$prompt_status"
        fi
        if [[ "$candidate" =~ [[:space:]] ]]; then
            error '服务器 IP 不得包含空格。'
            continue
        fi

        if [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || [[ "$candidate" == *:* && "$candidate" =~ ^[0-9A-Fa-f:]+$ ]]; then
            printf -v "$target_name" '%s' "$candidate"
            return
        fi

        error '请输入 IPv4 或 IPv6 地址，不接受域名。'
    done
}

is_valid_ipv4() {
    local candidate="$1"
    local octet=''
    local -a octets=()

    [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -r -a octets <<<"$candidate"
    (( ${#octets[@]} == 4 )) || return 1
    for octet in "${octets[@]}"; do
        [[ ${#octet} -le 3 ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

is_valid_ipv6() {
    local candidate="$1"
    local ipv4_tail=''
    local left=''
    local right=''
    local part=''
    local explicit_parts=0
    local -a parts=()

    if [[ "$candidate" == *.* ]]; then
        ipv4_tail="${candidate##*:}"
        is_valid_ipv4 "$ipv4_tail" || return 1
        candidate="${candidate%:*}:0:0"
    fi

    [[ "$candidate" == *:* && "$candidate" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$candidate" != *:::* ]] || return 1

    if [[ "$candidate" == *::* ]]; then
        left="${candidate%%::*}"
        right="${candidate#*::}"
        [[ "$right" != *::* ]] || return 1
        if [[ -n "$left" ]]; then
            [[ "$left" != :* && "$left" != *: ]] || return 1
            IFS=':' read -r -a parts <<<"$left"
            for part in "${parts[@]}"; do
                [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
                ((explicit_parts += 1))
            done
        fi
        if [[ -n "$right" ]]; then
            [[ "$right" != :* && "$right" != *: ]] || return 1
            IFS=':' read -r -a parts <<<"$right"
            for part in "${parts[@]}"; do
                [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
                ((explicit_parts += 1))
            done
        fi
        (( explicit_parts < 8 ))
        return
    fi

    [[ "$candidate" != :* && "$candidate" != *: ]] || return 1
    IFS=':' read -r -a parts <<<"$candidate"
    (( ${#parts[@]} == 8 )) || return 1
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
}

is_valid_domain() {
    local candidate="$1"
    local label=''
    local -a labels=()

    (( ${#candidate} <= 253 )) || return 1
    [[ "$candidate" != .* && "$candidate" != *. && "$candidate" != *..* ]] || return 1
    [[ ! "$candidate" =~ ^[0-9.]+$ ]] || return 1
    IFS='.' read -r -a labels <<<"$candidate"
    for label in "${labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

prompt_server_address() {
    local target_name="$1"
    local candidate=''
    local prompt_status=0

    while true; do
        if prompt_required candidate '请输入 server' false; then
            :
        else
            prompt_status=$?
            return "$prompt_status"
        fi

        if [[ "$candidate" =~ [[:space:]] || "$candidate" == *://* \
            || "$candidate" == */* ]]; then
            error 'server 必须是 IPv4、IPv6 或域名，且不得包含空格、协议或路径。'
        elif is_valid_ipv4 "$candidate" || is_valid_ipv6 "$candidate" \
            || is_valid_domain "$candidate"; then
            printf -v "$target_name" '%s' "$candidate"
            return 0
        else
            error '请输入合法的 IPv4、IPv6 或域名；server 中不要附带端口。'
        fi
    done
}

tag_exists() {
    local candidate="$1"
    local existing=''

    for existing in "${OUTBOUND_TAGS[@]}"; do
        if [[ "$existing" == "$candidate" ]]; then
            return 0
        fi
    done
    return 1
}

prompt_outbound_tag() {
    local target_name="$1"
    local candidate=''
    local prompt_status=0

    while true; do
        if prompt_required candidate '请输入 outbound tag' false; then
            :
        else
            prompt_status=$?
            return "$prompt_status"
        fi
        if [[ "$candidate" =~ [[:space:]] ]]; then
            error 'outbound tag 不得包含空格。'
        elif [[ "$candidate" == 'direct' ]]; then
            error 'outbound tag 不得等于 direct。'
        elif tag_exists "$candidate"; then
            error "outbound tag '${candidate}' 已存在，请重新输入 tag。"
        else
            printf -v "$target_name" '%s' "$candidate"
            return
        fi
    done
}

append_inbound() {
    local item="$1"
    local updated=''

    if updated="$(jq -c --argjson item "$item" '. + [$item]' <<<"$INBOUNDS_JSON")"; then
        INBOUNDS_JSON="$updated"
        return 0
    fi
    return 1
}

append_outbound() {
    local item="$1"
    local updated=''

    if updated="$(jq -c --argjson item "$item" '. + [$item]' <<<"$OUTBOUNDS_JSON")"; then
        OUTBOUNDS_JSON="$updated"
        return 0
    fi
    return 1
}

reset_generation_state() {
    LOG_JSON='{}'
    INBOUNDS_JSON='[]'
    OUTBOUNDS_JSON='[]'
    ROUTE_JSON='{}'
    BUILT_ITEM=''
    WORKING_CONFIG_JSON=''
    OUTBOUND_TAGS=()
    MODULE_INPUT_ACTIVE=false

    if [[ -n "$TEMP_CONFIG" && -f "$TEMP_CONFIG" ]]; then
        rm -f -- "$TEMP_CONFIG"
    fi
    TEMP_CONFIG=''
}

discard_existing_changes() {
    reset_generation_state
}

load_existing_config_file() {
    local config_path="$1"

    if [[ ! -e "$config_path" ]]; then
        error "现有配置不存在：${config_path}"
        return 1
    fi
    if [[ ! -r "$config_path" ]]; then
        error "现有配置不可读：${config_path}"
        return 1
    fi
    if ! jq empty "$config_path" >/dev/null 2>&1; then
        error "现有配置不是合法 JSON：${config_path}"
        return 1
    fi
    if ! jq -e 'type == "object"' "$config_path" >/dev/null 2>&1; then
        error '现有配置的 JSON 顶层必须是对象。'
        return 1
    fi

    WORKING_CONFIG_JSON="$(jq -c '.' "$config_path")"
}

working_field_type() {
    local field="$1"

    jq -r --arg field "$field" \
        'if has($field) then (.[$field] | type) else "missing" end' \
        <<<"$WORKING_CONFIG_JSON"
}

ensure_working_array() {
    local field="$1"
    local field_type=''

    field_type="$(working_field_type "$field")"
    case "$field_type" in
        missing|array)
            return 0
            ;;
        *)
            error "现有配置的 .${field} 必须是数组，本轮修改已停止。"
            return 1
            ;;
    esac
}

ensure_working_route_object() {
    local field_type=''

    field_type="$(working_field_type 'route')"
    case "$field_type" in
        missing|object)
            return 0
            ;;
        *)
            error '现有配置的 .route 必须是对象，本轮修改已停止。'
            return 1
            ;;
    esac
}

working_tag_exists() {
    local field="$1"
    local tag="$2"

    jq -e --arg field "$field" --arg tag "$tag" \
        'any(.[$field][]?; (.tag? | type == "string") and .tag == $tag)' \
        <<<"$WORKING_CONFIG_JSON" >/dev/null
}

append_working_inbound() {
    local item="$1"
    local tag=''

    ensure_working_array 'inbounds' || return 1
    tag="$(jq -r '.tag // empty' <<<"$item")"
    if [[ -z "$tag" ]]; then
        error '新 inbound 缺少 tag，无法追加。'
        return 1
    fi
    if working_tag_exists 'inbounds' "$tag"; then
        error "inbound tag '${tag}' 已经存在，不允许重复追加。"
        return 1
    fi

    WORKING_CONFIG_JSON="$(jq -c --argjson item "$item" \
        '.inbounds = ((.inbounds // []) + [$item])' \
        <<<"$WORKING_CONFIG_JSON")"
}

refresh_outbound_tags_from_working() {
    local tag=''
    local existing=''
    local duplicate='false'

    ensure_working_array 'outbounds' || return 1
    OUTBOUND_TAGS=()
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        duplicate='false'
        for existing in "${OUTBOUND_TAGS[@]}"; do
            if [[ "$existing" == "$tag" ]]; then
                duplicate='true'
                break
            fi
        done
        if [[ "$duplicate" == 'false' ]]; then
            OUTBOUND_TAGS+=("$tag")
        fi
    done < <(jq -r '
        .outbounds[]?
        | .tag?
        | select(type == "string" and length > 0)
    ' <<<"$WORKING_CONFIG_JSON")
}

append_working_outbound() {
    local item="$1"
    local tag=''
    local updated=''
    local original_config="$WORKING_CONFIG_JSON"
    local -a original_tags=("${OUTBOUND_TAGS[@]}")

    ensure_working_array 'outbounds' || return 1
    tag="$(jq -r '.tag // empty' <<<"$item")"
    if [[ -z "$tag" ]]; then
        error '新 outbound 的 tag 不能为空。'
        return 1
    fi
    if [[ "$tag" =~ [[:space:]] ]]; then
        error '新 outbound 的 tag 不得包含空格。'
        return 1
    fi
    if [[ "$tag" == 'direct' ]]; then
        error '追加模式暂不提供 direct outbound。'
        return 1
    fi
    if working_tag_exists 'outbounds' "$tag"; then
        error "outbound tag '${tag}' 已经存在，不允许重复追加。"
        return 1
    fi

    if updated="$(jq -c --argjson item "$item" \
        '.outbounds = ((.outbounds // []) + [$item])' \
        <<<"$WORKING_CONFIG_JSON")"; then
        WORKING_CONFIG_JSON="$updated"
        if refresh_outbound_tags_from_working; then
            return 0
        fi
        WORKING_CONFIG_JSON="$original_config"
        OUTBOUND_TAGS=("${original_tags[@]}")
    fi
    return 1
}

set_working_route_final() {
    local final_tag="$1"

    ensure_working_array 'outbounds' || return 1
    ensure_working_route_object || return 1
    if ! working_tag_exists 'outbounds' "$final_tag"; then
        error "outbound tag '${final_tag}' 不存在，不能设为 route.final。"
        return 1
    fi

    WORKING_CONFIG_JSON="$(jq -c --arg final "$final_tag" \
        '.route = (.route // {}) | .route.final = $final' \
        <<<"$WORKING_CONFIG_JSON")"
}

write_working_config_temp() {
    if [[ -n "$TEMP_CONFIG" && -f "$TEMP_CONFIG" ]]; then
        rm -f -- "$TEMP_CONFIG"
    fi
    TEMP_CONFIG=''
    create_temp_config
    jq . <<<"$WORKING_CONFIG_JSON" >"$TEMP_CONFIG"
}

display_working_tags() {
    local field="$1"
    local label="$2"
    local field_type=''
    local tag=''
    local count=0

    field_type="$(working_field_type "$field")"
    printf '\n当前已有的 %s tag：\n' "$label"
    if [[ "$field_type" == 'missing' ]]; then
        printf '（无）\n'
        return
    fi
    if [[ "$field_type" != 'array' ]]; then
        printf '（.%s 不是数组）\n' "$field"
        return
    fi

    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        printf -- '- %s\n' "$tag"
        ((count += 1))
    done < <(jq -r --arg field "$field" '
        .[$field][]?
        | .tag?
        | select(type == "string" and length > 0)
    ' <<<"$WORKING_CONFIG_JSON")

    if (( count == 0 )); then
        printf '（无）\n'
    fi
}

configure_log() {
    local choice=''

    printf '\n请选择日志等级：\n\n'
    printf '1. warn（默认）\n'
    printf '2. info\n'
    printf '3. error\n'
    printf '4. disabled\n'
    prompt_numbered_choice choice 1 4 1

    case "$choice" in
        1) LOG_JSON="$(jq -cn '{level:"warn",timestamp:true}')" ;;
        2) LOG_JSON="$(jq -cn '{level:"info",timestamp:true}')" ;;
        3) LOG_JSON="$(jq -cn '{level:"error",timestamp:true}')" ;;
        4) LOG_JSON="$(jq -cn '{disabled:true}')" ;;
    esac
}

select_network_stack() {
    local choice=''

    printf '\n请选择网络栈：\n\n'
    printf '1) IPv4-only [默认]\n'
    printf '2) IPv6-only\n'
    printf '3) Dual-stack\n'
    prompt_numbered_choice choice 1 3 1

    case "$choice" in
        1) NETWORK_STACK='ipv4' ;;
        2) NETWORK_STACK='ipv6' ;;
        3) NETWORK_STACK='dual' ;;
    esac
    info "Applying application-level $NETWORK_STACK configuration."
    inspect_kernel_enforcement
}

get_listen_address() {
    case "$NETWORK_STACK" in
        ipv4) printf '0.0.0.0' ;;
        ipv6|dual) printf '::' ;;
        *)
            error "未知网络栈：${NETWORK_STACK}"
            return 1
            ;;
    esac
}

build_reality_inbound() {
    local listen_port=''
    local listen_address=''
    local uuid=''
    local disguise_domain=''
    local handshake_port=''
    local private_key=''
    local short_id=''

    begin_module_build
    info '配置 VLESS Reality inbound'
    module_prompt prompt_port listen_port '请输入监听端口' 443 || return $?
    module_prompt prompt_required uuid '请输入 UUID' true || return $?
    module_prompt prompt_required disguise_domain '请输入 Reality 伪装域名' false || return $?
    module_prompt prompt_port handshake_port '请输入 Reality handshake.server_port' 443 || return $?
    module_prompt prompt_required private_key '请输入 Reality private_key' true || return $?
    module_prompt prompt_required short_id '请输入 Reality short_id' true || return $?
    listen_address="$(get_listen_address)" || return $?

    BUILT_ITEM="$(jq -cn \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        --arg uuid "$uuid" \
        --arg disguise_domain "$disguise_domain" \
        --argjson handshake_port "$handshake_port" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        '{
            type: "vless",
            tag: "vless-reality-in",
            listen: $listen_address,
            listen_port: $listen_port,
            users: [{
                name: "main",
                uuid: $uuid,
                flow: "xtls-rprx-vision"
            }],
            tls: {
                enabled: true,
                server_name: $disguise_domain,
                reality: {
                    enabled: true,
                    handshake: {
                        server: $disguise_domain,
                        server_port: $handshake_port
                    },
                    private_key: $private_key,
                    short_id: [$short_id]
                }
            }
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_transit_hysteria2_inbound() {
    local listen_port=''
    local listen_address=''
    local user_password=''
    local certificate_directory=''

    begin_module_build
    info '配置 Hysteria2 inbound'
    module_prompt prompt_port listen_port '请输入监听端口' 443 || return $?
    module_prompt prompt_required user_password '请输入 Hysteria2 用户 password' true || return $?
    module_prompt prompt_required certificate_directory '请输入 /etc/ssl/ 下的证书目录名' false || return $?
    listen_address="$(get_listen_address)" || return $?

    BUILT_ITEM="$(jq -cn \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        --arg user_password "$user_password" \
        --arg certificate_path "/etc/ssl/${certificate_directory}/fullchain.pem" \
        --arg key_path "/etc/ssl/${certificate_directory}/privkey.pem" \
        '{
            type: "hysteria2",
            tag: "hy2-in",
            listen: $listen_address,
            listen_port: $listen_port,
            users: [{
                name: "main",
                password: $user_password
            }],
            tls: {
                enabled: true,
                certificate_path: $certificate_path,
                key_path: $key_path,
                min_version: "1.3"
            }
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_exit_hysteria2_inbound() {
    local listen_port=''
    local listen_address=''
    local user_password=''
    local certificate_directory=''

    begin_module_build
    info '配置 Hysteria2 inbound'
    module_prompt prompt_port listen_port '请输入监听端口' 32124 || return $?
    module_prompt prompt_required user_password '请输入 Hysteria2 用户 password' true || return $?
    module_prompt prompt_required certificate_directory '请输入 /etc/ssl/ 下的证书目录名' false || return $?
    listen_address="$(get_listen_address)" || return $?

    BUILT_ITEM="$(jq -cn \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        --arg user_password "$user_password" \
        --arg certificate_path "/etc/ssl/${certificate_directory}/fullchain.pem" \
        --arg key_path "/etc/ssl/${certificate_directory}/privkey.pem" \
        '{
            type: "hysteria2",
            tag: "hy2-in",
            listen: $listen_address,
            listen_port: $listen_port,
            users: [{
                name: "main",
                password: $user_password
            }],
            tls: {
                enabled: true,
                certificate_path: $certificate_path,
                key_path: $key_path,
                min_version: "1.3"
            }
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_cf_tunnel_inbound() {
    local listen_port=''
    local uuid=''

    begin_module_build
    info '配置 CF Tunnel inbound'
    module_prompt prompt_port listen_port '请输入监听端口' 33333 || return $?
    module_prompt prompt_required uuid '请输入 UUID' true || return $?

    BUILT_ITEM="$(jq -cn \
        --argjson listen_port "$listen_port" \
        --arg uuid "$uuid" \
        '{
            type: "vless",
            tag: "cf-tunnel-in",
            listen: "127.0.0.1",
            listen_port: $listen_port,
            users: [{
                name: "cf-user",
                uuid: $uuid
            }],
            transport: {
                type: "ws",
                path: ""
            }
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_cf_websocket_inbound() {
    local listen_port=''
    local listen_address=''
    local uuid=''
    local certificate_directory=''
    local websocket_path=''

    begin_module_build
    info '配置 CF WebSocket inbound'
    module_prompt prompt_port listen_port '请输入监听端口' 8443 || return $?
    module_prompt prompt_required uuid '请输入 UUID' true || return $?
    module_prompt prompt_required certificate_directory '请输入 /etc/ssl/ 下的证书目录名' false || return $?
    module_prompt prompt_required websocket_path '请输入 WebSocket path' false || return $?
    if [[ "$websocket_path" != /* ]]; then
        websocket_path="/${websocket_path}"
    fi
    listen_address="$(get_listen_address)" || return $?

    BUILT_ITEM="$(jq -cn \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        --arg uuid "$uuid" \
        --arg certificate_path "/etc/ssl/${certificate_directory}/fullchain.pem" \
        --arg key_path "/etc/ssl/${certificate_directory}/privkey.pem" \
        --arg websocket_path "$websocket_path" \
        '{
            type: "vless",
            tag: "vless-cf-ws-in",
            listen: $listen_address,
            listen_port: $listen_port,
            users: [{
                name: "cf-ws",
                uuid: $uuid
            }],
            tls: {
                enabled: true,
                certificate_path: $certificate_path,
                key_path: $key_path
            },
            transport: {
                type: "ws",
                path: $websocket_path
            }
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_exit_shadowsocks_inbound() {
    local listen_port=''
    local listen_address=''
    local method=''
    local password=''

    begin_module_build
    info '配置 SS2022 inbound'
    module_prompt prompt_port listen_port '请输入监听端口' 32123 || return $?
    module_prompt prompt_method method || return $?
    module_prompt prompt_required password '请输入 SS2022 password' true || return $?
    listen_address="$(get_listen_address)" || return $?

    BUILT_ITEM="$(jq -cn \
        --arg listen_address "$listen_address" \
        --argjson listen_port "$listen_port" \
        --arg method "$method" \
        --arg password "$password" \
        '{
            type: "shadowsocks",
            tag: "ss2022-in",
            listen: $listen_address,
            listen_port: $listen_port,
            method: $method,
            password: $password
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

configure_transit_inbounds() {
    while true; do
        INBOUNDS_JSON='[]'

        configure_optional_inbound '是否添加 VLESS Reality inbound？' \
            build_reality_inbound || return $?
        configure_optional_inbound '是否添加 Hysteria2 inbound？' \
            build_transit_hysteria2_inbound || return $?
        configure_optional_inbound '是否添加 CF Tunnel inbound？' \
            build_cf_tunnel_inbound || return $?
        configure_optional_inbound '是否添加 CF WebSocket inbound？' \
            build_cf_websocket_inbound || return $?

        if (( $(jq 'length' <<<"$INBOUNDS_JSON") > 0 )); then
            return
        fi

        error '中转配置至少需要一个 inbound，请重新选择。'
    done
}

configure_exit_inbounds() {
    while true; do
        INBOUNDS_JSON='[]'

        configure_optional_inbound '是否添加 SS2022 inbound？' \
            build_exit_shadowsocks_inbound || return $?
        configure_optional_inbound '是否添加 Hysteria2 inbound？' \
            build_exit_hysteria2_inbound || return $?
        configure_optional_inbound '是否添加 CF Tunnel inbound？' \
            build_cf_tunnel_inbound || return $?
        configure_optional_inbound '是否添加 CF WebSocket inbound？' \
            build_cf_websocket_inbound || return $?

        if (( $(jq 'length' <<<"$INBOUNDS_JSON") > 0 )); then
            return
        fi

        error '落地配置至少需要一个 inbound，请重新选择。'
    done
}

configure_optional_inbound() {
    local question="$1"
    local builder="$2"
    local answer=''
    local item=''
    local build_status=0

    while true; do
        prompt_yes_no answer "$question"
        [[ "$answer" == 'yes' ]] || return 0

        if "$builder"; then
            item="$BUILT_ITEM"
            append_inbound "$item" || return $?
            return 0
        else
            build_status=$?
        fi

        if (( build_status == MODULE_CANCEL_STATUS )); then
            warn '已取消当前 inbound，未保存任何字段。'
            continue
        fi
        return "$build_status"
    done
}

build_shadowsocks_outbound() {
    local tag=''
    local server=''
    local server_port=''
    local method=''
    local password=''

    begin_module_build
    info '配置 SS2022 outbound'
    module_prompt prompt_outbound_tag tag || return $?
    module_prompt prompt_server_ip server || return $?
    module_prompt prompt_port server_port '请输入 server_port' 32123 || return $?
    module_prompt prompt_method method || return $?
    module_prompt prompt_required password '请输入 SS2022 password' true || return $?

    BUILT_ITEM="$(jq -cn \
        --arg tag "$tag" \
        --arg server "$server" \
        --argjson server_port "$server_port" \
        --arg method "$method" \
        --arg password "$password" \
        '{
            type: "shadowsocks",
            tag: $tag,
            server: $server,
            server_port: $server_port,
            method: $method,
            password: $password
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_socks5_outbound() {
    local tag=''
    local server=''
    local server_port=''
    local use_auth=''
    local username=''
    local password=''

    begin_module_build
    info '配置 SOCKS5 outbound'
    module_prompt prompt_outbound_tag tag || return $?
    module_prompt prompt_server_address server || return $?
    module_prompt prompt_port server_port '请输入 server_port' 443 || return $?
    module_prompt prompt_yes_no use_auth '是否使用用户名和密码认证？' || return $?
    if [[ "$use_auth" == 'yes' ]]; then
        module_prompt prompt_required username '请输入 username' false || return $?
        module_prompt prompt_required password '请输入 password' true || return $?
    fi

    BUILT_ITEM="$(jq -cn \
        --arg tag "$tag" \
        --arg server "$server" \
        --argjson server_port "$server_port" \
        --arg use_auth "$use_auth" \
        --arg username "$username" \
        --arg password "$password" \
        '{
            type: "socks",
            tag: $tag,
            server: $server,
            server_port: $server_port,
            version: "5"
        } + if $use_auth == "yes" then {
            username: $username,
            password: $password
        } else {} end')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

build_hysteria2_outbound() {
    local tag=''
    local server=''
    local server_port=''
    local password=''
    local server_name=''

    begin_module_build
    info '配置 Hysteria2 outbound'
    module_prompt prompt_outbound_tag tag || return $?
    module_prompt prompt_server_ip server || return $?
    module_prompt prompt_port server_port '请输入 server_port' 32124 || return $?
    module_prompt prompt_required password '请输入 Hysteria2 password' true || return $?
    module_prompt prompt_required server_name '请输入 tls.server_name' false || return $?

    BUILT_ITEM="$(jq -cn \
        --arg tag "$tag" \
        --arg server "$server" \
        --argjson server_port "$server_port" \
        --arg password "$password" \
        --arg server_name "$server_name" \
        '{
            type: "hysteria2",
            tag: $tag,
            server: $server,
            server_port: $server_port,
            password: $password,
            tls: {
                enabled: true,
                server_name: $server_name
            }
        }')" || {
        BUILT_ITEM=''
        finish_module_build
        return 1
    }
    finish_module_build
}

configure_transit_outbounds() {
    local outbound_choice=''
    local builder=''
    local item=''
    local tag=''
    local build_status=0

    OUTBOUNDS_JSON='[]'
    OUTBOUND_TAGS=()

    while true; do
        printf '\n请选择要添加的 outbound：\n\n'
        printf '1. SS2022 outbound\n'
        printf '2. SOCKS5 outbound\n'
        printf '3. Hysteria2 outbound\n'
        printf '4. 完成并返回\n'
        prompt_numbered_choice outbound_choice 1 4

        case "$outbound_choice" in
            1) builder='build_shadowsocks_outbound' ;;
            2) builder='build_socks5_outbound' ;;
            3) builder='build_hysteria2_outbound' ;;
            4) break ;;
        esac

        if "$builder"; then
            item="$BUILT_ITEM"
            tag="$(jq -r '.tag' <<<"$item")"
            if append_outbound "$item"; then
                OUTBOUND_TAGS+=("$tag")
            else
                return $?
            fi
        else
            build_status=$?
            if (( build_status == MODULE_CANCEL_STATUS )); then
                warn '已取消当前 outbound，未保存任何字段。'
                continue
            fi
            return "$build_status"
        fi
    done

    if append_outbound "$(jq -cn '{type:"direct",tag:"direct"}')"; then
        OUTBOUND_TAGS+=('direct')
    else
        return $?
    fi
}

configure_transit_route() {
    local choice=''
    local index=0
    local final_tag=''

    printf '\n请选择 route.final：\n\n'
    for index in "${!OUTBOUND_TAGS[@]}"; do
        printf '%d. %s\n' "$((index + 1))" "${OUTBOUND_TAGS[$index]}"
    done
    prompt_numbered_choice choice 1 "${#OUTBOUND_TAGS[@]}"
    final_tag="${OUTBOUND_TAGS[$((choice - 1))]}"

    ROUTE_JSON="$(jq -cn --arg final "$final_tag" '{
        rules: [
            {
                ip_is_private: true,
                action: "reject"
            },
            {
                action: "sniff"
            },
            {
                rule_set: [
                    "geosite-cn",
                    "geoip-cn"
                ],
                action: "reject"
            }
        ],
        rule_set: [
            {
                tag: "geosite-cn",
                type: "remote",
                format: "binary",
                url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs",
                download_detour: "direct",
                update_interval: "1d"
            },
            {
                tag: "geoip-cn",
                type: "remote",
                format: "binary",
                url: "https://github.com/qljsyph/ruleset-icon/raw/refs/heads/main/sing-box/geoip/China-ASN-combined-ip.srs",
                download_detour: "direct",
                update_interval: "1d"
            }
        ],
        final: $final
    }')"
}

configure_exit_route() {
    ROUTE_JSON="$(jq -cn '{
        rules: [{
            ip_is_private: true,
            action: "reject"
        }]
    }')"
}

create_temp_config() {
    umask 077
    TEMP_CONFIG="$(mktemp "${TMPDIR:-/tmp}/sing-box-config.XXXXXX.json")"
}

generate_transit_config() {
    configure_log
    configure_transit_inbounds
    configure_transit_outbounds
    configure_transit_route
    create_temp_config

    jq -n \
        --argjson log "$LOG_JSON" \
        --argjson inbounds "$INBOUNDS_JSON" \
        --argjson outbounds "$OUTBOUNDS_JSON" \
        --argjson route "$ROUTE_JSON" \
        '{
            log: $log,
            inbounds: $inbounds,
            outbounds: $outbounds,
            route: $route
        }' >"$TEMP_CONFIG"
}

generate_exit_config() {
    configure_log
    configure_exit_inbounds
    configure_exit_route
    create_temp_config

    jq -n \
        --argjson log "$LOG_JSON" \
        --argjson inbounds "$INBOUNDS_JSON" \
        --argjson route "$ROUTE_JSON" \
        '{
            log: $log,
            inbounds: $inbounds,
            route: $route
        }' >"$TEMP_CONFIG"
}

add_inbound_to_working_config() {
    local config_kind=''
    local inbound_choice=''
    local target_tag=''
    local builder=''
    local build_status=0

    ensure_working_array 'inbounds' || return 1

    printf '\n现有配置属于：\n\n'
    printf '1. 中转配置\n'
    printf '2. 落地配置\n'
    printf '3. 返回\n'
    prompt_numbered_choice config_kind 1 3
    if [[ "$config_kind" == '3' ]]; then
        return 0
    fi

    while true; do
        printf '\n请选择要添加的 inbound：\n\n'
        if [[ "$config_kind" == '1' ]]; then
            printf '1. VLESS Reality inbound\n'
            printf '2. Hysteria2 inbound\n'
            printf '3. CF Tunnel inbound\n'
            printf '4. CF WebSocket inbound\n'
            printf '5. 返回\n'
            prompt_numbered_choice inbound_choice 1 5
            case "$inbound_choice" in
                1) target_tag='vless-reality-in'; builder='build_reality_inbound' ;;
                2) target_tag='hy2-in'; builder='build_transit_hysteria2_inbound' ;;
                3) target_tag='cf-tunnel-in'; builder='build_cf_tunnel_inbound' ;;
                4) target_tag='vless-cf-ws-in'; builder='build_cf_websocket_inbound' ;;
                5) return 0 ;;
            esac
        else
            printf '1. SS2022 inbound\n'
            printf '2. Hysteria2 inbound\n'
            printf '3. CF Tunnel inbound\n'
            printf '4. CF WebSocket inbound\n'
            printf '5. 返回\n'
            prompt_numbered_choice inbound_choice 1 5
            case "$inbound_choice" in
                1) target_tag='ss2022-in'; builder='build_exit_shadowsocks_inbound' ;;
                2) target_tag='hy2-in'; builder='build_exit_hysteria2_inbound' ;;
                3) target_tag='cf-tunnel-in'; builder='build_cf_tunnel_inbound' ;;
                4) target_tag='vless-cf-ws-in'; builder='build_cf_websocket_inbound' ;;
                5) return 0 ;;
            esac
        fi

        if working_tag_exists 'inbounds' "$target_tag"; then
            error "inbound tag '${target_tag}' 已经存在，不允许重复追加。"
            return 0
        fi

        if "$builder"; then
            if append_working_inbound "$BUILT_ITEM"; then
                success "已追加 inbound：${target_tag}"
            fi
            return 0
        else
            build_status=$?
            if (( build_status == MODULE_CANCEL_STATUS )); then
                warn '已取消当前 inbound，未保存任何字段。'
                continue
            fi
            return "$build_status"
        fi
    done
}

add_outbounds_to_working_config() {
    local outbound_choice=''
    local builder=''
    local build_status=0
    local tag=''

    ensure_working_array 'outbounds' || return 1
    refresh_outbound_tags_from_working || return 1

    while true; do
        printf '\n请选择要添加的 outbound：\n\n'
        printf '1. SS2022 outbound\n'
        printf '2. SOCKS5 outbound\n'
        printf '3. Hysteria2 outbound\n'
        printf '4. 完成并返回\n'
        prompt_numbered_choice outbound_choice 1 4

        case "$outbound_choice" in
            1) builder='build_shadowsocks_outbound' ;;
            2) builder='build_socks5_outbound' ;;
            3) builder='build_hysteria2_outbound' ;;
            4) return 0 ;;
        esac

        if "$builder"; then
            tag="$(jq -r '.tag' <<<"$BUILT_ITEM")"
            if append_working_outbound "$BUILT_ITEM"; then
                success "已追加 outbound：${tag}"
            fi
        else
            build_status=$?
            if (( build_status == MODULE_CANCEL_STATUS )); then
                warn '已取消当前 outbound，未保存任何字段。'
                continue
            fi
            return "$build_status"
        fi
    done
}

modify_working_route_final() {
    local current_final=''
    local action_choice=''
    local final_choice=''
    local index=0

    ensure_working_array 'outbounds' || return 1
    ensure_working_route_object || return 1
    refresh_outbound_tags_from_working || return 1

    current_final="$(jq -r '
        if ((.route // {}) | has("final")) then
            if .route.final == null then
                "未设置"
            elif (.route.final | type) == "string" then
                .route.final
            else
                (.route.final | tojson)
            end
        else
            "未设置"
        end
    ' <<<"$WORKING_CONFIG_JSON")"

    printf '\n当前 route.final：%s\n' "$current_final"
    printf '\n请选择操作：\n\n'
    printf '1. 保持当前值\n'
    printf '2. 从现有 outbound tag 中选择新值\n'
    prompt_numbered_choice action_choice 1 2
    if [[ "$action_choice" == '1' ]]; then
        return 0
    fi

    if (( ${#OUTBOUND_TAGS[@]} == 0 )); then
        error '当前没有可选择的 outbound tag。'
        return 0
    fi

    printf '\n请选择新的 route.final：\n\n'
    for index in "${!OUTBOUND_TAGS[@]}"; do
        printf '%d. %s\n' "$((index + 1))" "${OUTBOUND_TAGS[$index]}"
    done
    prompt_numbered_choice final_choice 1 "${#OUTBOUND_TAGS[@]}"

    if set_working_route_final "${OUTBOUND_TAGS[$((final_choice - 1))]}"; then
        success "route.final 已设置为：${OUTBOUND_TAGS[$((final_choice - 1))]}"
    fi
}

existing_config_preview_menu() {
    local choice=''
    local apply_status=0

    while true; do
        printf '请选择下一步：\n\n'
        printf '1. 确认应用配置\n'
        printf '2. 返回继续添加\n'
        printf '3. 放弃全部修改并返回主菜单\n'
        printf '4. 退出，不作修改\n'
        prompt_numbered_choice choice 1 4

        case "$choice" in
            1)
                if apply_config; then
                    return 0
                else
                    apply_status=$?
                fi
                if (( apply_status == 1 )); then
                    printf '\n'
                    continue
                fi
                return 4
                ;;
            2)
                if [[ -n "$TEMP_CONFIG" && -f "$TEMP_CONFIG" ]]; then
                    rm -f -- "$TEMP_CONFIG"
                fi
                TEMP_CONFIG=''
                return 1
                ;;
            3)
                discard_existing_changes
                return 2
                ;;
            4)
                discard_existing_changes
                return 3
                ;;
        esac
    done
}

edit_existing_config() {
    local menu_choice=''
    local preview_status=0

    if ! load_existing_config_file "$CONFIG_PATH"; then
        return 1
    fi

    while true; do
        display_working_tags 'inbounds' 'inbound'
        display_working_tags 'outbounds' 'outbound'

        printf '\n请选择操作：\n\n'
        printf '1. 添加 inbound\n'
        printf '2. 添加 outbound\n'
        printf '3. 修改 route.final\n'
        printf '4. 完成并预览\n'
        printf '5. 放弃并返回主菜单\n'
        prompt_numbered_choice menu_choice 1 5

        case "$menu_choice" in
            1)
                if ! add_inbound_to_working_config; then
                    continue
                fi
                ;;
            2)
                if ! add_outbounds_to_working_config; then
                    continue
                fi
                ;;
            3)
                if ! modify_working_route_final; then
                    continue
                fi
                ;;
            4)
                write_working_config_temp
                show_preview
                if existing_config_preview_menu; then
                    return 0
                else
                    preview_status=$?
                fi
                case "$preview_status" in
                    1) continue ;;
                    2) return 1 ;;
                    3) return 2 ;;
                    4) return 3 ;;
                esac
                ;;
            5)
                discard_existing_changes
                return 1
                ;;
        esac
    done
}

show_preview() {
    printf '\n%s完整配置预览：%s\n\n' "$CYAN" "$RESET"
    jq . "$TEMP_CONFIG"
    printf '\n'
}

show_service_failure() {
    local backup_path="$1"
    local status="$2"

    error "sing-box 服务状态异常：${status}"
    if [[ -n "$backup_path" ]]; then
        warn "旧配置备份路径：${backup_path}"
    else
        warn '应用前不存在旧配置，因此没有备份文件。'
    fi

    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u sing-box -n 50 --no-pager || true
    else
        warn '未找到 journalctl，无法显示 sing-box 服务日志。'
    fi
}

apply_config_to_path() {
    local target_config="$1"
    local target_dir="$2"
    local sing_box_bin=''
    local backup_path=''
    local service_status=''
    local enable_output=''
    local enable_status=''
    local enable_check_exit=0

    if ! jq empty "$TEMP_CONFIG"; then
        error 'jq 校验失败；正式配置未修改，sing-box 未重启。'
        return 1
    fi

    if ! sing_box_bin="$(command -v sing-box)"; then
        error '未找到 sing-box；正式配置未修改，服务未重启。'
        return 1
    fi

    if ! "$sing_box_bin" check -c "$TEMP_CONFIG"; then
        error 'sing-box 配置检查失败；正式配置未修改，服务未重启。'
        return 1
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        error '未找到 systemctl；正式配置未修改，服务未重启。'
        return 1
    fi

    if ! install -d -m 0755 "$target_dir"; then
        error "无法创建配置目录：${target_dir}；正式配置未修改，服务未重启。"
        return 1
    fi

    if [[ -e "$target_config" ]]; then
        backup_path="${target_config}.bak-$(date '+%Y%m%d-%H%M%S')"
        if [[ -e "$backup_path" ]]; then
            error "备份目标已存在：${backup_path}；正式配置未修改。"
            return 1
        fi
        if ! cp -a -- "$target_config" "$backup_path"; then
            error "无法备份现有配置：${target_config}；正式配置未修改，服务未重启。"
            return 1
        fi
    fi

    if ! install -m 0600 -- "$TEMP_CONFIG" "$target_config"; then
        error "无法写入正式配置：${target_config}；服务未重启。"
        return 1
    fi
    success "配置已写入：${target_config}"
    if [[ -n "$backup_path" ]]; then
        success "旧配置备份路径：${backup_path}"
    else
        info '应用前不存在旧配置，已跳过备份。'
    fi

    if ! systemctl restart sing-box; then
        show_service_failure "$backup_path" 'restart 失败'
        return 2
    fi

    if service_status="$(systemctl is-active sing-box 2>&1)"; then
        if [[ "$service_status" != 'active' ]]; then
            show_service_failure "$backup_path" "${service_status:-未知}"
            return 2
        fi
    else
        show_service_failure "$backup_path" "${service_status:-未知}"
        return 2
    fi

    if ! enable_output="$(systemctl enable sing-box.service 2>&1)"; then
        error '配置已经应用且服务正在运行，但设置开机自启失败。'
        if [[ -n "$enable_output" ]]; then
            warn "systemctl enable 诊断：${enable_output}"
        else
            warn 'systemctl enable 未返回诊断信息。'
        fi
        return 2
    fi

    if enable_status="$(systemctl is-enabled sing-box.service 2>&1)"; then
        enable_check_exit=0
    else
        enable_check_exit=$?
    fi
    if (( enable_check_exit != 0 )) || [[ "$enable_status" != 'enabled' ]]; then
        error "配置已经应用且服务正在运行，但开机自启状态验证失败：${enable_status:-无输出}；退出码：${enable_check_exit}"
        return 2
    fi

    success "sing-box 当前状态：${service_status}；开机自启状态：${enable_status}"
    print_network_result
    return 0
}

apply_config() {
    apply_config_to_path "$CONFIG_PATH" "$CONFIG_DIR"
}

choose_config_type() {
    local target_name="$1"
    local choice=''

    printf '\n请选择配置类型：\n\n'
    printf '1. 新建中转小鸡配置\n'
    printf '2. 新建落地小鸡配置\n'
    printf '3. 添加到现有配置\n'
    printf '4. 退出\n'
    prompt_numbered_choice choice 1 4
    printf -v "$target_name" '%s' "$choice"
}

final_menu() {
    local choice=''
    local apply_status=0

    while true; do
        printf '请选择下一步：\n\n'
        printf '1. 确认应用配置\n'
        printf '2. 重新生成\n'
        printf '3. 退出，不作修改\n'
        prompt_numbered_choice choice 1 3

        case "$choice" in
            1)
                if apply_config; then
                    return 0
                else
                    apply_status=$?
                fi

                if (( apply_status == 1 )); then
                    printf '\n'
                    continue
                fi
                return 2
                ;;
            2)
                reset_generation_state
                return 1
                ;;
            3)
                return 3
                ;;
        esac
    done
}

main() {
    local config_type=''
    local menu_status=0
    local edit_status=0

    init_colors
    check_environment
    detect_runtime_environment
    select_network_stack

    while true; do
        reset_generation_state
        choose_config_type config_type

        case "$config_type" in
            1) generate_transit_config ;;
            2) generate_exit_config ;;
            3)
                if edit_existing_config; then
                    return 0
                else
                    edit_status=$?
                fi

                case "$edit_status" in
                    1)
                        reset_generation_state
                        continue
                        ;;
                    2)
                        return 0
                        ;;
                    3)
                        return 1
                        ;;
                    *)
                        die "添加到现有配置流程返回了未知状态：${edit_status}"
                        ;;
                esac
                ;;
            4)
                info '已退出，未作任何修改。'
                return 0
                ;;
        esac

        show_preview

        if final_menu; then
            return 0
        else
            menu_status=$?
        fi

        case "$menu_status" in
            1)
                info '已清除本轮数据，请重新生成。'
                ;;
            2)
                return 1
                ;;
            3)
                info '已退出，未作任何修改。'
                return 0
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
