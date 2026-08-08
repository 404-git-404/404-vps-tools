#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
readonly REPO_ROOT
readonly WIZARD_SCRIPT="$REPO_ROOT/node-config-wizard.sh"
readonly INSTALL_SCRIPT="$REPO_ROOT/404notfound.sh"

# The path is anchored to this test file, rather than the caller's directory.
# shellcheck disable=SC1090
source "$WIZARD_SCRIPT"
trap - EXIT INT TERM

TEST_COUNT=0
TEST_COMPLETE=false
TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/node-config-wizard-tests.XXXXXXXX")
readonly TEST_TEMP_DIR

SERVICE_CASE_DIR=''
SERVICE_TARGET_DIR=''
SERVICE_TARGET_CONFIG=''
SERVICE_OUTPUT_FILE=''
SERVICE_APPLY_STATUS=0
SYSTEMCTL_CALL_LOG=''
MOCK_ENABLED_FILE=''

cleanup_test_files() {
    if [[ -n "$TEST_TEMP_DIR" && "$TEST_TEMP_DIR" == /* &&
        -d "$TEST_TEMP_DIR" ]]; then
        rm -rf -- "$TEST_TEMP_DIR"
    fi
}

handle_test_exit() {
    local exit_status="$1"

    trap - EXIT
    cleanup_test_files
    if (( exit_status == 0 )) && [[ "$TEST_COMPLETE" != 'true' ]]; then
        printf '%s\n' \
            'ERROR: node configuration wizard tests exited before all assertions completed' \
            >&2
        exit 1
    fi
    exit "$exit_status"
}

trap 'handle_test_exit "$?"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"

    ((TEST_COUNT += 1))
    [[ "$actual" == "$expected" ]] ||
        fail "$description: expected [$expected], got [$actual]"
}

assert_json_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"
    local normalized_expected=''
    local normalized_actual=''

    normalized_expected="$(jq -S -c . <<<"$expected")"
    normalized_actual="$(jq -S -c . <<<"$actual")"
    assert_equal "$normalized_expected" "$normalized_actual" "$description"
}

assert_true() {
    local description="$1"
    shift

    ((TEST_COUNT += 1))
    "$@" || fail "$description"
}

assert_builder_cancelled() {
    local builder="$1"
    local input="$2"
    local description="$3"
    local build_status=0
    local tags_before=''
    local inbounds_before=''
    local outbounds_before=''

    reset_generation_state
    BUILT_ITEM='{"stale":true}'
    OUTBOUND_TAGS=('kept-out')
    INBOUNDS_JSON='[{"tag":"kept-in"}]'
    OUTBOUNDS_JSON='[{"type":"direct","tag":"kept-out"}]'
    tags_before="${OUTBOUND_TAGS[*]}"
    inbounds_before="$INBOUNDS_JSON"
    outbounds_before="$OUTBOUNDS_JSON"

    if "$builder" >/dev/null < <(printf '%b' "$input"); then
        fail "$description: builder unexpectedly succeeded"
    else
        build_status=$?
    fi

    assert_equal "$MODULE_CANCEL_STATUS" "$build_status" \
        "$description returns the module cancellation status"
    assert_equal '' "$BUILT_ITEM" "$description clears BUILT_ITEM"
    assert_equal "$tags_before" "${OUTBOUND_TAGS[*]}" \
        "$description leaves outbound tags unchanged"
    assert_json_equal "$inbounds_before" "$INBOUNDS_JSON" \
        "$description leaves inbound JSON unchanged"
    assert_json_equal "$outbounds_before" "$OUTBOUNDS_JSON" \
        "$description leaves outbound JSON unchanged"
}

create_service_apply_stubs() {
    local stub_dir="$1"

    mkdir -p "$stub_dir"
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'exit "${MOCK_SING_BOX_CHECK_STATUS:-0}"' \
        >"$stub_dir/sing-box"
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'printf "%s\n" "$*" >>"${SYSTEMCTL_CALL_LOG:?}"' \
        'case "${1:-}" in' \
        '    restart)' \
        '        if (( ${MOCK_RESTART_STATUS:-0} != 0 )); then' \
        '            printf "%s\n" "${MOCK_RESTART_DIAGNOSTIC:-restart failed}" >&2' \
        '        fi' \
        '        exit "${MOCK_RESTART_STATUS:-0}"' \
        '        ;;' \
        '    is-active)' \
        '        printf "%s\n" "${MOCK_ACTIVE_STATE:-active}"' \
        '        exit "${MOCK_ACTIVE_STATUS:-0}"' \
        '        ;;' \
        '    enable)' \
        '        if (( ${MOCK_ENABLE_STATUS:-0} != 0 )); then' \
        '            printf "%s\n" "${MOCK_ENABLE_DIAGNOSTIC:-enable failed}" >&2' \
        '            exit "${MOCK_ENABLE_STATUS:-1}"' \
        '        fi' \
        '        : >"${MOCK_ENABLED_FILE:?}"' \
        '        ;;' \
        '    is-enabled)' \
        '        if [[ -n "${MOCK_IS_ENABLED_STATE+x}" ]]; then' \
        '            printf "%s\n" "$MOCK_IS_ENABLED_STATE"' \
        '            exit "${MOCK_IS_ENABLED_STATUS:-0}"' \
        '        fi' \
        '        if [[ -e "${MOCK_ENABLED_FILE:?}" ]]; then' \
        '            printf "enabled\n"' \
        '            exit 0' \
        '        fi' \
        '        printf "disabled\n"' \
        '        exit 1' \
        '        ;;' \
        'esac' \
        >"$stub_dir/systemctl"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$stub_dir/journalctl"
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'if [[ "${1:-}" == "-m" && "${2:-}" == "0600" ]] && (( ${MOCK_CONFIG_INSTALL_STATUS:-0} != 0 )); then' \
        '    printf "mock config install failed\n" >&2' \
        '    exit "$MOCK_CONFIG_INSTALL_STATUS"' \
        'fi' \
        'exec "${REAL_INSTALL_BIN:?}" "$@"' \
        >"$stub_dir/install"
    chmod +x "$stub_dir/sing-box" "$stub_dir/systemctl" \
        "$stub_dir/journalctl" "$stub_dir/install"
}

prepare_service_apply_case() {
    local case_name="$1"

    SERVICE_CASE_DIR="$TEST_TEMP_DIR/service-${case_name}"
    SERVICE_TARGET_DIR="$SERVICE_CASE_DIR/etc/sing-box"
    SERVICE_TARGET_CONFIG="$SERVICE_TARGET_DIR/config.json"
    SERVICE_OUTPUT_FILE="$SERVICE_CASE_DIR/apply-output"
    SYSTEMCTL_CALL_LOG="$SERVICE_CASE_DIR/systemctl-calls"
    MOCK_ENABLED_FILE="$SERVICE_CASE_DIR/enabled-state"
    mkdir -p "$SERVICE_TARGET_DIR"
    printf '%s\n' '{"custom":"formal-original"}' >"$SERVICE_TARGET_CONFIG"
    printf '%s\n' '{"custom":"candidate"}' >"$SERVICE_CASE_DIR/candidate.json"
    printf '' >"$SYSTEMCTL_CALL_LOG"
    TEMP_CONFIG="$SERVICE_CASE_DIR/candidate.json"

    export SYSTEMCTL_CALL_LOG MOCK_ENABLED_FILE
    unset MOCK_SING_BOX_CHECK_STATUS MOCK_RESTART_STATUS MOCK_RESTART_DIAGNOSTIC
    unset MOCK_ACTIVE_STATE MOCK_ACTIVE_STATUS MOCK_ENABLE_STATUS MOCK_ENABLE_DIAGNOSTIC
    unset MOCK_IS_ENABLED_STATE MOCK_IS_ENABLED_STATUS
    unset MOCK_CONFIG_INSTALL_STATUS
}

run_service_apply_case() {
    SERVICE_APPLY_STATUS=0
    if apply_config_to_path "$SERVICE_TARGET_CONFIG" "$SERVICE_TARGET_DIR" \
        >"$SERVICE_OUTPUT_FILE" 2>&1; then
        SERVICE_APPLY_STATUS=0
    else
        SERVICE_APPLY_STATUS=$?
    fi
}

file_hash() {
    sha256sum "$1" | awk '{print $1}'
}

test_network_stack_listen_addresses() {
    local mode=''
    local expected=''

    for mode in ipv4 ipv6 dual; do
        NETWORK_STACK="$mode"
        case "$mode" in
            ipv4) expected='0.0.0.0' ;;
            ipv6|dual) expected='::' ;;
        esac
        assert_equal "$expected" "$(get_listen_address)" \
            "$mode maps to the required public listen address"

        reset_generation_state
        build_exit_shadowsocks_inbound >/dev/null <<'EOF'


test-password
EOF
        assert_equal "$expected" "$(jq -r '.listen' <<<"$BUILT_ITEM")" \
            "$mode public inbound uses get_listen_address"

        reset_generation_state
        build_cf_tunnel_inbound >/dev/null <<'EOF'

test-uuid
EOF
        assert_equal '127.0.0.1' "$(jq -r '.listen' <<<"$BUILT_ITEM")" \
            "$mode keeps CF Tunnel localhost-only"
    done

    NETWORK_STACK='dual'
    select_network_stack >/dev/null <<<''
    assert_equal 'ipv4' "$NETWORK_STACK" \
        'direct Enter selects IPv4-only by default'
}

test_reality_domain_is_reused() {
    local output_file="$TEST_TEMP_DIR/reality-output"
    local prompt_output=''
    local prompt_count=0

    reset_generation_state
    build_reality_inbound >"$output_file" <<'EOF'

test-uuid
reality.example.com

test-private-key
0123456789abcdef
EOF
    prompt_output="$(<"$output_file")"
    prompt_count="$(grep -Fc '请输入 Reality 伪装域名：' "$output_file")"

    assert_equal 'reality.example.com' \
        "$(jq -r '.tls.server_name' <<<"$BUILT_ITEM")" \
        'Reality server_name uses the disguise domain'
    assert_equal 'reality.example.com' \
        "$(jq -r '.tls.reality.handshake.server' <<<"$BUILT_ITEM")" \
        'Reality handshake server uses the disguise domain'
    assert_equal '443' \
        "$(jq -r '.tls.reality.handshake.server_port' <<<"$BUILT_ITEM")" \
        'Reality handshake port keeps its default'
    assert_equal '1' "$prompt_count" 'Reality disguise domain is prompted once'
    [[ "$prompt_output" != *'请输入 TLS server_name'* ]] ||
        fail 'obsolete TLS server_name prompt is still displayed'
    [[ "$prompt_output" != *'请输入 Reality handshake.server：'* ]] ||
        fail 'obsolete Reality handshake.server prompt is still displayed'
    ((TEST_COUNT += 2))
}

test_transit_hysteria2_has_no_salamander_obfs() {
    local output_file="$TEST_TEMP_DIR/transit-hy2-output"
    local prompt_output=''

    reset_generation_state
    build_transit_hysteria2_inbound >"$output_file" <<'EOF'

hy2-user-password
example-cert-directory
EOF
    prompt_output="$(<"$output_file")"

    [[ "$prompt_output" != *'salamander obfs password'* ]] ||
        fail 'transit Hysteria2 still prompts for salamander obfs password'
    ((TEST_COUNT += 1))
    assert_equal 'false' "$(jq -r 'has("obfs")' <<<"$BUILT_ITEM")" \
        'transit Hysteria2 JSON omits obfs'
    assert_equal 'false' \
        "$(jq -r 'tostring | contains("salamander")' <<<"$BUILT_ITEM")" \
        'transit Hysteria2 JSON does not contain salamander'
    assert_equal 'hy2-user-password' \
        "$(jq -r '.users[0].password' <<<"$BUILT_ITEM")" \
        'transit Hysteria2 keeps the user password'
    assert_equal '/etc/ssl/example-cert-directory/fullchain.pem' \
        "$(jq -r '.tls.certificate_path' <<<"$BUILT_ITEM")" \
        'transit Hysteria2 keeps certificate_path'
    assert_equal '/etc/ssl/example-cert-directory/privkey.pem' \
        "$(jq -r '.tls.key_path' <<<"$BUILT_ITEM")" \
        'transit Hysteria2 keeps key_path'
    assert_equal '1.3' "$(jq -r '.tls.min_version' <<<"$BUILT_ITEM")" \
        'transit Hysteria2 keeps TLS min_version'

    assert_builder_cancelled build_transit_hysteria2_inbound '\n\033' \
        'transit Hysteria2 cancellation at user password'
}

test_append_hy2_preserves_reality_and_unknown_fields() {
    local original_reality=''
    local expected_unknown=''

    WORKING_CONFIG_JSON="$(jq -cn '{
        log: {level: "warn", keep: true},
        dns: {servers: [{tag: "dns-a", address: "192.0.2.53"}]},
        inbounds: [{
            type: "vless",
            tag: "vless-reality-in",
            listen: "::",
            listen_port: 443,
            users: [{uuid: "existing-uuid", flow: "xtls-rprx-vision"}],
            tls: {
                enabled: true,
                server_name: "existing.example",
                reality: {
                    enabled: true,
                    handshake: {server: "existing.example", server_port: 443},
                    private_key: "existing-private",
                    short_id: ["existing-short"]
                }
            },
            preserved_unknown: {nested: [1, 2, 3]}
        }],
        route: {
            final: "direct",
            rules: [{action: "sniff"}],
            rule_set: [{tag: "existing-rules"}]
        },
        experimental: {cache_file: {enabled: true}},
        endpoints: [{tag: "endpoint-a"}],
        services: [{tag: "service-a"}],
        custom_top_level: {keep: "yes"}
    }')"
    original_reality="$(jq -c '.inbounds[0]' <<<"$WORKING_CONFIG_JSON")"
    expected_unknown="$(jq -c '{
        log,
        dns,
        route,
        experimental,
        endpoints,
        services,
        custom_top_level
    }' <<<"$WORKING_CONFIG_JSON")"

    append_working_inbound \
        '{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":8443}'

    assert_json_equal "$original_reality" \
        "$(jq -c '.inbounds[0]' <<<"$WORKING_CONFIG_JSON")" \
        'existing Reality inbound is unchanged after HY2 append'
    assert_equal 'hy2-in' \
        "$(jq -r '.inbounds[1].tag' <<<"$WORKING_CONFIG_JSON")" \
        'HY2 inbound is appended'
    assert_json_equal "$expected_unknown" \
        "$(jq -c '{
            log,
            dns,
            route,
            experimental,
            endpoints,
            services,
            custom_top_level
        }' <<<"$WORKING_CONFIG_JSON")" \
        'unknown and existing top-level fields are preserved'
}

test_append_cf_tunnel_to_hy2() {
    local original_hy2=''

    WORKING_CONFIG_JSON='{"inbounds":[{"type":"hysteria2","tag":"hy2-in","custom":"keep"}]}'
    original_hy2="$(jq -c '.inbounds[0]' <<<"$WORKING_CONFIG_JSON")"

    append_working_inbound \
        '{"type":"vless","tag":"cf-tunnel-in","listen":"127.0.0.1","listen_port":33333}'

    assert_json_equal "$original_hy2" \
        "$(jq -c '.inbounds[0]' <<<"$WORKING_CONFIG_JSON")" \
        'existing HY2 inbound is unchanged after CF Tunnel append'
    assert_equal 'cf-tunnel-in' \
        "$(jq -r '.inbounds[1].tag' <<<"$WORKING_CONFIG_JSON")" \
        'CF Tunnel inbound is appended'
}

test_duplicate_inbound_is_rejected() {
    local before=''

    WORKING_CONFIG_JSON='{"inbounds":[{"tag":"hy2-in","keep":true}]}'
    before="$WORKING_CONFIG_JSON"
    if append_working_inbound '{"tag":"hy2-in","new":true}' 2>/dev/null; then
        fail 'duplicate inbound tag was accepted'
    fi
    ((TEST_COUNT += 1))
    assert_json_equal "$before" "$WORKING_CONFIG_JSON" \
        'duplicate inbound rejection leaves working config unchanged'
}

test_outbound_collision_is_rejected() {
    local before=''

    WORKING_CONFIG_JSON='{"outbounds":[{"type":"shadowsocks","tag":"existing-out"}]}'
    before="$WORKING_CONFIG_JSON"
    if append_working_outbound \
        '{"type":"hysteria2","tag":"existing-out","server":"192.0.2.1"}' \
        2>/dev/null; then
        fail 'outbound tag collision was accepted'
    fi
    ((TEST_COUNT += 1))
    assert_json_equal "$before" "$WORKING_CONFIG_JSON" \
        'outbound collision leaves working config unchanged'
}

test_new_outbound_can_be_route_final() {
    WORKING_CONFIG_JSON='{"outbounds":[{"type":"direct","tag":"direct"}]}'

    append_working_outbound \
        '{"type":"hysteria2","tag":"hy2-exit","server":"192.0.2.20","server_port":32124}'
    set_working_route_final 'hy2-exit'

    assert_equal 'hy2-exit' \
        "$(jq -r '.route.final' <<<"$WORKING_CONFIG_JSON")" \
        'new outbound can be selected as route.final'
    assert_equal '2' \
        "$(jq -r '.outbounds | length' <<<"$WORKING_CONFIG_JSON")" \
        'existing outbound remains and new outbound is appended'
}

test_route_rules_are_preserved() {
    local rules_before=''
    local rule_set_before=''

    WORKING_CONFIG_JSON="$(jq -cn '{
        outbounds: [{tag: "direct"}, {tag: "new-final"}],
        route: {
            final: "direct",
            rules: [{inbound: ["a"], action: "route", outbound: "direct"}],
            rule_set: [{tag: "geo", type: "remote", format: "binary"}],
            unknown_route_field: {keep: true}
        }
    }')"
    rules_before="$(jq -c '.route.rules' <<<"$WORKING_CONFIG_JSON")"
    rule_set_before="$(jq -c '.route.rule_set' <<<"$WORKING_CONFIG_JSON")"

    set_working_route_final 'new-final'

    assert_json_equal "$rules_before" \
        "$(jq -c '.route.rules' <<<"$WORKING_CONFIG_JSON")" \
        'route.rules is preserved when final changes'
    assert_json_equal "$rule_set_before" \
        "$(jq -c '.route.rule_set' <<<"$WORKING_CONFIG_JSON")" \
        'route.rule_set is preserved when final changes'
    assert_equal 'true' \
        "$(jq -r '.route.unknown_route_field.keep' <<<"$WORKING_CONFIG_JSON")" \
        'unknown route fields are preserved when final changes'
}

test_discard_keeps_formal_config_unchanged() {
    local formal_dir="$TEST_TEMP_DIR/discard-formal"
    local formal_config="$formal_dir/config.json"
    local hash_before=''
    local hash_after=''
    local discarded_temp=''

    mkdir -p "$formal_dir"
    printf '%s\n' '{"inbounds":[{"tag":"vless-reality-in"}],"custom":"original"}' \
        >"$formal_config"
    hash_before="$(file_hash "$formal_config")"

    load_existing_config_file "$formal_config"
    append_working_inbound '{"tag":"hy2-in"}'
    write_working_config_temp
    discarded_temp="$TEMP_CONFIG"
    discard_existing_changes
    hash_after="$(file_hash "$formal_config")"

    assert_equal "$hash_before" "$hash_after" \
        'discarding changes leaves formal config hash unchanged'
    assert_true 'discarding changes removes the temporary config' \
        test ! -e "$discarded_temp"
}

test_failed_sing_box_check_does_not_overwrite() {
    local formal_dir="$TEST_TEMP_DIR/check-failure-formal"
    local formal_config="$formal_dir/config.json"
    local stub_dir="$TEST_TEMP_DIR/check-failure-bin"
    local original_path="$PATH"
    local hash_before=''
    local hash_after=''
    local backup_count=0

    mkdir -p "$formal_dir" "$stub_dir"
    printf '%s\n' '{"custom":"formal-original"}' >"$formal_config"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$stub_dir/sing-box"
    chmod +x "$stub_dir/sing-box"
    printf '%s\n' '{"custom":"candidate"}' >"$TEST_TEMP_DIR/check-failure-candidate.json"
    TEMP_CONFIG="$TEST_TEMP_DIR/check-failure-candidate.json"
    hash_before="$(file_hash "$formal_config")"

    PATH="$stub_dir:$PATH"
    if apply_config_to_path "$formal_config" "$formal_dir" 2>/dev/null; then
        PATH="$original_path"
        fail 'configuration was applied after sing-box check failed'
    fi
    PATH="$original_path"
    ((TEST_COUNT += 1))

    hash_after="$(file_hash "$formal_config")"
    backup_count="$(find "$formal_dir" -maxdepth 1 -name 'config.json.bak-*' -print |
        wc -l | tr -d '[:space:]')"
    assert_equal "$hash_before" "$hash_after" \
        'sing-box check failure leaves formal config hash unchanged'
    assert_equal '0' "$backup_count" \
        'sing-box check failure occurs before backup or overwrite'
    TEMP_CONFIG=''
}

test_apply_enables_service_only_after_active() {
    local stub_dir="$TEST_TEMP_DIR/service-apply-bin"
    local original_path="$PATH"
    local expected_calls=''
    local backup_count=0
    local cancel_status=0
    local real_install_bin=''

    real_install_bin="$(command -v install)"
    export REAL_INSTALL_BIN="$real_install_bin"
    create_service_apply_stubs "$stub_dir"
    PATH="$stub_dir:$PATH"

    prepare_service_apply_case 'success-disabled'
    run_service_apply_case
    expected_calls=$'restart sing-box\nis-active sing-box\nenable sing-box.service\nis-enabled sing-box.service'
    assert_equal '0' "$SERVICE_APPLY_STATUS" \
        'apply succeeds after restart, active check, enable, and enabled check'
    assert_equal "$expected_calls" "$(<"$SYSTEMCTL_CALL_LOG")" \
        'service management calls are executed in the required order'
    assert_true 'success output includes active service status' \
        grep -Fq 'sing-box 当前状态：active' "$SERVICE_OUTPUT_FILE"
    assert_true 'success output includes enabled startup status' \
        grep -Fq '开机自启状态：enabled' "$SERVICE_OUTPUT_FILE"
    assert_true 'successful enable records the persistent enabled state' \
        test -e "$MOCK_ENABLED_FILE"
    assert_json_equal '{"custom":"candidate"}' \
        "$(<"$SERVICE_TARGET_CONFIG")" \
        'successful apply keeps the new formal config'

    prepare_service_apply_case 'already-enabled'
    : >"$MOCK_ENABLED_FILE"
    run_service_apply_case
    assert_equal '0' "$SERVICE_APPLY_STATUS" \
        'applying while sing-box is already enabled remains successful'
    assert_equal "$expected_calls" "$(<"$SYSTEMCTL_CALL_LOG")" \
        'already-enabled service still follows the full verification sequence'
    assert_true 'already-enabled success still reports enabled' \
        grep -Fq '开机自启状态：enabled' "$SERVICE_OUTPUT_FILE"

    prepare_service_apply_case 'enable-failure'
    export MOCK_ENABLE_STATUS=1
    export MOCK_ENABLE_DIAGNOSTIC='mock enable diagnostic'
    run_service_apply_case
    expected_calls=$'restart sing-box\nis-active sing-box\nenable sing-box.service'
    assert_equal '2' "$SERVICE_APPLY_STATUS" 'enable failure makes apply fail'
    assert_equal "$expected_calls" "$(<"$SYSTEMCTL_CALL_LOG")" \
        'enable failure does not run is-enabled or stop the service'
    assert_true 'enable failure explains that config and service already succeeded' \
        grep -Fq '配置已经应用且服务正在运行，但设置开机自启失败。' \
        "$SERVICE_OUTPUT_FILE"
    assert_true 'enable failure preserves systemctl diagnostics' \
        grep -Fq 'mock enable diagnostic' "$SERVICE_OUTPUT_FILE"
    assert_json_equal '{"custom":"candidate"}' \
        "$(<"$SERVICE_TARGET_CONFIG")" \
        'enable failure does not roll back the applied config'
    backup_count="$(find "$SERVICE_TARGET_DIR" -maxdepth 1 \
        -name 'config.json.bak-*' -print | wc -l | tr -d '[:space:]')"
    assert_equal '1' "$backup_count" \
        'enable failure retains the original config backup without restoring it'

    prepare_service_apply_case 'enabled-output-nonzero-exit'
    export MOCK_IS_ENABLED_STATE='enabled'
    export MOCK_IS_ENABLED_STATUS=7
    run_service_apply_case
    expected_calls=$'restart sing-box\nis-active sing-box\nenable sing-box.service\nis-enabled sing-box.service'
    assert_equal '2' "$SERVICE_APPLY_STATUS" \
        'nonzero is-enabled exit rejects an enabled output'
    assert_equal "$expected_calls" "$(<"$SYSTEMCTL_CALL_LOG")" \
        'nonzero is-enabled exit keeps the required service call order'
    assert_true 'nonzero is-enabled error includes the enabled output' \
        grep -Fq '开机自启状态验证失败：enabled' "$SERVICE_OUTPUT_FILE"
    assert_true 'nonzero is-enabled error includes the exit code' \
        grep -Fq '退出码：7' "$SERVICE_OUTPUT_FILE"
    assert_json_equal '{"custom":"candidate"}' \
        "$(<"$SERVICE_TARGET_CONFIG")" \
        'nonzero is-enabled exit does not roll back the applied config'

    prepare_service_apply_case 'empty-output-nonzero-exit'
    export MOCK_IS_ENABLED_STATE=''
    export MOCK_IS_ENABLED_STATUS=9
    run_service_apply_case
    assert_equal '2' "$SERVICE_APPLY_STATUS" \
        'nonzero is-enabled exit with empty output makes apply fail'
    assert_equal "$expected_calls" "$(<"$SYSTEMCTL_CALL_LOG")" \
        'empty is-enabled output keeps the required service call order'
    assert_true 'empty is-enabled output uses a readable placeholder' \
        grep -Fq '开机自启状态验证失败：无输出' "$SERVICE_OUTPUT_FILE"
    assert_true 'empty is-enabled output reports the exit code' \
        grep -Fq '退出码：9' "$SERVICE_OUTPUT_FILE"

    prepare_service_apply_case 'disabled-verification'
    export MOCK_IS_ENABLED_STATE='disabled'
    export MOCK_IS_ENABLED_STATUS=0
    run_service_apply_case
    expected_calls=$'restart sing-box\nis-active sing-box\nenable sing-box.service\nis-enabled sing-box.service'
    assert_equal '2' "$SERVICE_APPLY_STATUS" \
        'disabled result after enable makes apply fail'
    assert_equal "$expected_calls" "$(<"$SYSTEMCTL_CALL_LOG")" \
        'disabled verification runs only the expected service commands'
    assert_true 'disabled verification error includes the actual state' \
        grep -Fq '开机自启状态验证失败：disabled' "$SERVICE_OUTPUT_FILE"
    assert_true 'disabled verification error includes the zero exit code' \
        grep -Fq '退出码：0' "$SERVICE_OUTPUT_FILE"
    assert_json_equal '{"custom":"candidate"}' \
        "$(<"$SERVICE_TARGET_CONFIG")" \
        'disabled verification does not roll back the applied config'

    prepare_service_apply_case 'enabled-runtime-verification'
    export MOCK_IS_ENABLED_STATE='enabled-runtime'
    export MOCK_IS_ENABLED_STATUS=0
    run_service_apply_case
    assert_equal '2' "$SERVICE_APPLY_STATUS" \
        'enabled-runtime is rejected as non-persistent enablement'
    assert_equal "$expected_calls" "$(<"$SYSTEMCTL_CALL_LOG")" \
        'enabled-runtime verification follows the full service sequence'
    assert_true 'enabled-runtime verification error includes the actual state' \
        grep -Fq '开机自启状态验证失败：enabled-runtime' "$SERVICE_OUTPUT_FILE"
    assert_true 'enabled-runtime verification error includes the zero exit code' \
        grep -Fq '退出码：0' "$SERVICE_OUTPUT_FILE"

    prepare_service_apply_case 'restart-failure'
    export MOCK_RESTART_STATUS=1
    run_service_apply_case
    assert_equal '2' "$SERVICE_APPLY_STATUS" 'restart failure keeps apply failure behavior'
    assert_equal 'restart sing-box' "$(<"$SYSTEMCTL_CALL_LOG")" \
        'restart failure does not call is-active, enable, or is-enabled'
    assert_json_equal '{"custom":"candidate"}' \
        "$(<"$SERVICE_TARGET_CONFIG")" \
        'restart failure preserves the existing written-config behavior'

    prepare_service_apply_case 'inactive-failure'
    export MOCK_ACTIVE_STATE='inactive'
    export MOCK_ACTIVE_STATUS=3
    run_service_apply_case
    expected_calls=$'restart sing-box\nis-active sing-box'
    assert_equal '2' "$SERVICE_APPLY_STATUS" 'inactive service makes apply fail'
    assert_equal "$expected_calls" "$(<"$SYSTEMCTL_CALL_LOG")" \
        'inactive service does not call enable or is-enabled'
    assert_true 'inactive service keeps the existing status error' \
        grep -Fq 'sing-box 服务状态异常：inactive' "$SERVICE_OUTPUT_FILE"
    assert_json_equal '{"custom":"candidate"}' \
        "$(<"$SERVICE_TARGET_CONFIG")" \
        'inactive service preserves the existing written-config behavior'

    prepare_service_apply_case 'check-failure-no-enable'
    export MOCK_SING_BOX_CHECK_STATUS=1
    run_service_apply_case
    assert_equal '1' "$SERVICE_APPLY_STATUS" 'sing-box check failure makes apply fail'
    assert_equal '' "$(<"$SYSTEMCTL_CALL_LOG")" \
        'sing-box check failure does not call any systemctl command'
    assert_json_equal '{"custom":"formal-original"}' \
        "$(<"$SERVICE_TARGET_CONFIG")" \
        'sing-box check failure leaves the formal config unchanged'

    prepare_service_apply_case 'invalid-json-no-enable'
    printf '{\n' >"$TEMP_CONFIG"
    run_service_apply_case
    assert_equal '1' "$SERVICE_APPLY_STATUS" 'invalid JSON makes apply fail'
    assert_equal '' "$(<"$SYSTEMCTL_CALL_LOG")" \
        'invalid JSON does not call any systemctl command'
    assert_json_equal '{"custom":"formal-original"}' \
        "$(<"$SERVICE_TARGET_CONFIG")" \
        'invalid JSON leaves the formal config unchanged'

    prepare_service_apply_case 'formal-write-failure'
    export MOCK_CONFIG_INSTALL_STATUS=1
    run_service_apply_case
    assert_equal '1' "$SERVICE_APPLY_STATUS" 'formal config write failure makes apply fail'
    assert_equal '' "$(<"$SYSTEMCTL_CALL_LOG")" \
        'formal config write failure does not call any systemctl command'
    assert_json_equal '{"custom":"formal-original"}' \
        "$(<"$SERVICE_TARGET_CONFIG")" \
        'formal config write failure leaves the existing formal config intact'

    prepare_service_apply_case 'preview-and-cancel'
    show_preview >"$SERVICE_OUTPUT_FILE"
    assert_equal '' "$(<"$SYSTEMCTL_CALL_LOG")" \
        'preview mode does not call enable or is-enabled'
    if build_reality_inbound >/dev/null < <(printf '\033'); then
        fail 'Esc cancellation unexpectedly completed a module'
    else
        cancel_status=$?
    fi
    assert_equal "$MODULE_CANCEL_STATUS" "$cancel_status" \
        'Esc cancellation still returns the dedicated status'
    assert_equal '' "$(<"$SYSTEMCTL_CALL_LOG")" \
        'Esc cancellation does not call enable or is-enabled'

    PATH="$original_path"
}

test_invalid_existing_structures_are_rejected() {
    local before=''

    WORKING_CONFIG_JSON='{"inbounds":{"not":"an array"},"custom":"keep"}'
    before="$WORKING_CONFIG_JSON"
    if append_working_inbound '{"tag":"hy2-in"}' 2>/dev/null; then
        fail 'non-array inbounds was accepted'
    fi
    ((TEST_COUNT += 1))
    assert_json_equal "$before" "$WORKING_CONFIG_JSON" \
        'invalid inbounds structure is not modified'

    WORKING_CONFIG_JSON='{"outbounds":[{"tag":"direct"}],"route":[],"custom":"keep"}'
    before="$WORKING_CONFIG_JSON"
    if set_working_route_final 'direct' 2>/dev/null; then
        fail 'non-object route was accepted'
    fi
    ((TEST_COUNT += 1))
    assert_json_equal "$before" "$WORKING_CONFIG_JSON" \
        'invalid route structure is not modified'
}

test_key_reader_escape_and_sequences() {
    local input_value=''
    local read_status=0

    begin_module_build
    if read_line input_value '' false >/dev/null < <(printf '\033'); then
        fail 'standalone Esc was accepted as ordinary input'
    else
        read_status=$?
    fi
    finish_module_build
    assert_equal "$MODULE_CANCEL_STATUS" "$read_status" \
        'standalone Esc returns the module cancellation status'

    begin_module_build
    if ! read_line input_value '' false >/dev/null \
        < <(printf '\033[Aproxy.example.com\n'); then
        fail 'arrow-key escape sequence cancelled input'
    fi
    finish_module_build
    assert_equal 'proxy.example.com' "$input_value" \
        'arrow-key escape sequence is ignored without cancelling'

    begin_module_build
    if ! read_line input_value '' false >/dev/null < <(printf 'ab\177c\n'); then
        fail 'Backspace input failed'
    fi
    finish_module_build
    assert_equal 'ac' "$input_value" 'Backspace removes the preceding character'
}

test_outbound_builders_cancel_transactionally() {
    assert_builder_cancelled build_shadowsocks_outbound '\033' \
        'SS2022 cancellation at tag'
    assert_builder_cancelled build_shadowsocks_outbound \
        'ss-server-cancel\n\033' 'SS2022 cancellation at server'
    assert_builder_cancelled build_shadowsocks_outbound \
        'ss-secret-cancel\n192.0.2.10\n\n\n\033' \
        'SS2022 cancellation at secret password'

    assert_builder_cancelled build_socks5_outbound '\033' \
        'SOCKS5 cancellation at tag'
    assert_builder_cancelled build_socks5_outbound \
        'socks-server-cancel\n\033' 'SOCKS5 cancellation at server'
    assert_builder_cancelled build_socks5_outbound \
        'socks-secret-cancel\nproxy.example.com\n\ny\nuser\n\033' \
        'SOCKS5 cancellation at secret password'

    assert_builder_cancelled build_hysteria2_outbound \
        'hy2-cancel\n192.0.2.20\n\n\033' \
        'Hysteria2 cancellation at secret password'
    assert_builder_cancelled build_reality_inbound '\033' \
        'Reality cancellation at listen port'
    assert_builder_cancelled build_reality_inbound \
        '\ntest-uuid\nreality.example.com\n\n\033' \
        'Reality cancellation at private key'
}

test_secret_cancel_is_not_echoed() {
    local output_file="$TEST_TEMP_DIR/secret-cancel-output"
    local build_status=0

    reset_generation_state
    if build_shadowsocks_outbound >"$output_file" < <(
        printf 'secret-cancel\n192.0.2.30\n\n\npartial-secret'
        sleep 0.2
        printf '\033'
    ); then
        fail 'Esc in a secret field did not cancel the module'
    else
        build_status=$?
    fi
    assert_equal "$MODULE_CANCEL_STATUS" "$build_status" \
        'Esc cancels from a secret field'
    if grep -Fq 'partial-secret' "$output_file"; then
        fail 'secret input was echoed'
    fi
    ((TEST_COUNT += 1))
}

test_cancel_returns_to_outbound_menu_without_err_trap() {
    local err_marker="$TEST_TEMP_DIR/cancel-err-trap"

    reset_generation_state
    trap 'printf triggered >"$err_marker"' ERR
    configure_transit_outbounds >/dev/null < <(
        printf '1\nss-cancel\n192.0.2.40\n\n\n\033'
        sleep 0.2
        printf '2\nsocks-after-cancel\nproxy.example.com\n\nn\n4\n'
    )
    trap - ERR

    assert_equal '2' "$(jq -r 'length' <<<"$OUTBOUNDS_JSON")" \
        'wizard continues after Esc and adds a later outbound plus direct'
    assert_equal 'socks-after-cancel' \
        "$(jq -r '.[0].tag' <<<"$OUTBOUNDS_JSON")" \
        'cancelled SS2022 is not appended and later SOCKS5 is retained'
    assert_equal 'socks-after-cancel direct' "${OUTBOUND_TAGS[*]}" \
        'cancelled SS2022 tag is not retained'
    assert_true 'module cancellation does not trigger ERR trap' test ! -e "$err_marker"
}

test_socks_cancel_can_continue_with_other_outbound() {
    reset_generation_state
    configure_transit_outbounds >/dev/null < <(
        printf '2\nsocks-cancel-before-append\nproxy.example.com\n\ny\nuser\n\033'
        sleep 0.2
        printf '1\nss-after-socks-cancel\n192.0.2.41\n\n\nss-password\n4\n'
    )

    assert_equal '2' "$(jq -r 'length' <<<"$OUTBOUNDS_JSON")" \
        'wizard continues with another outbound after SOCKS5 cancellation'
    assert_equal 'ss-after-socks-cancel' \
        "$(jq -r '.[0].tag' <<<"$OUTBOUNDS_JSON")" \
        'cancelled SOCKS5 is not appended before the later outbound'
    assert_equal 'ss-after-socks-cancel direct' "${OUTBOUND_TAGS[*]}" \
        'cancelled SOCKS5 tag is not retained'
}

test_failed_append_does_not_register_tag() {
    local tags_before=''

    reset_generation_state
    OUTBOUND_TAGS=('existing')
    tags_before="${OUTBOUND_TAGS[*]}"
    OUTBOUNDS_JSON='not-json'
    if append_outbound '{"type":"socks","tag":"not-appended"}' 2>/dev/null; then
        fail 'append_outbound accepted an invalid outbound array'
    fi
    ((TEST_COUNT += 1))
    assert_equal "$tags_before" "${OUTBOUND_TAGS[*]}" \
        'failed new-config append does not register a tag'

    WORKING_CONFIG_JSON='{"outbounds":[]}'
    if append_working_outbound 'not-json' 2>/dev/null; then
        fail 'append_working_outbound accepted invalid item JSON'
    fi
    ((TEST_COUNT += 1))
    assert_equal "$tags_before" "${OUTBOUND_TAGS[*]}" \
        'failed existing-config append does not register a tag'
}

test_cancel_in_existing_mode_is_transactional() {
    local before=''

    reset_generation_state
    WORKING_CONFIG_JSON='{"outbounds":[{"type":"direct","tag":"direct"}],"custom":{"keep":true}}'
    before="$WORKING_CONFIG_JSON"
    add_outbounds_to_working_config >/dev/null < <(
        printf '2\nsocks-existing-cancel\n\033'
        sleep 1
        printf '4\n'
    )
    assert_json_equal "$before" "$WORKING_CONFIG_JSON" \
        'Esc while adding an outbound does not modify working config'
    assert_equal 'direct' "${OUTBOUND_TAGS[*]}" \
        'Esc in existing mode does not retain a ghost tag'

    WORKING_CONFIG_JSON='{"inbounds":[{"tag":"existing-in"}],"custom":{"keep":true}}'
    before="$WORKING_CONFIG_JSON"
    add_inbound_to_working_config >/dev/null < <(
        printf '1\n1\n\ntest-uuid\n\033'
        sleep 0.2
        printf '5\n'
    )
    assert_json_equal "$before" "$WORKING_CONFIG_JSON" \
        'Esc while adding an inbound does not modify working config'
}

test_new_inbound_cancel_preserves_previous_module() {
    reset_generation_state
    configure_transit_inbounds >/dev/null < <(
        printf 'y\n\ntest-uuid\nreality.example.com\n\ntest-private\nshort-id\ny\n\n\033'
        sleep 0.2
        printf 'n\nn\nn\n'
    )

    assert_equal '1' "$(jq -r 'length' <<<"$INBOUNDS_JSON")" \
        'cancelling a later inbound preserves an earlier successful inbound'
    assert_equal 'vless-reality-in' "$(jq -r '.[0].tag' <<<"$INBOUNDS_JSON")" \
        'the earlier successful inbound remains unchanged after cancellation'
}

test_socks5_json_variants_and_addresses() {
    local input_value=''

    reset_generation_state
    build_socks5_outbound >/dev/null <<'EOF'
socks-domain
proxy.example.com

n
EOF
    assert_json_equal \
        '{"type":"socks","tag":"socks-domain","server":"proxy.example.com","server_port":443,"version":"5"}' \
        "$BUILT_ITEM" 'SOCKS5 without authentication has the expected JSON'
    assert_equal 'false' "$(jq -r 'has("username") or has("password")' <<<"$BUILT_ITEM")" \
        'SOCKS5 without authentication omits credential fields'
    assert_equal '443' "$(jq -r '.server_port' <<<"$BUILT_ITEM")" \
        'SOCKS5 default port is 443'

    reset_generation_state
    build_socks5_outbound >/dev/null <<'EOF'
socks-ipv4-auth
1.2.3.4
1080
y
proxy-user
proxy-password
EOF
    assert_json_equal \
        '{"type":"socks","tag":"socks-ipv4-auth","server":"1.2.3.4","server_port":1080,"version":"5","username":"proxy-user","password":"proxy-password"}' \
        "$BUILT_ITEM" 'SOCKS5 with authentication has the expected JSON'

    reset_generation_state
    build_socks5_outbound >/dev/null <<'EOF'
socks-ipv6
2001:db8::1

n
EOF
    assert_equal '2001:db8::1' "$(jq -r '.server' <<<"$BUILT_ITEM")" \
        'SOCKS5 accepts IPv6 server addresses'

    prompt_server_address input_value >/dev/null <<'EOF'
proxy.example.com:443
https://proxy.example.com
proxy.example.com/path
proxy.example.com
EOF
    assert_equal 'proxy.example.com' "$input_value" \
        'SOCKS5 server rejects embedded ports, schemes, and paths'
}

test_multiple_socks5_and_unique_tags() {
    reset_generation_state
    configure_transit_outbounds >/dev/null <<'EOF'
2
socks-one
proxy-one.example.com

n
2
socks-two
192.0.2.50
1080
y
user-two
password-two
4
EOF
    assert_equal '3' "$(jq -r 'length' <<<"$OUTBOUNDS_JSON")" \
        'multiple SOCKS5 outbounds and direct are appended'
    assert_equal 'socks-one socks-two direct' "${OUTBOUND_TAGS[*]}" \
        'each SOCKS5 tag is retained after successful append'

    OUTBOUND_TAGS=('duplicate-tag')
    build_socks5_outbound >/dev/null <<'EOF'
duplicate-tag
direct
unique-tag
proxy.example.com

n
EOF
    assert_equal 'unique-tag' "$(jq -r '.tag' <<<"$BUILT_ITEM")" \
        'duplicate and direct tags are rejected before accepting a unique tag'
}

test_outbound_menu_order_and_sudo_package() {
    local new_menu=''
    local existing_menu=''
    local expected_menu=''

    expected_menu=$'1. SS2022 outbound\n2. SOCKS5 outbound\n3. Hysteria2 outbound\n4. 完成并返回'
    reset_generation_state
    new_menu="$(configure_transit_outbounds <<<'4')"
    [[ "$new_menu" == *"$expected_menu"* ]] || fail 'new-config outbound menu order is incorrect'
    ((TEST_COUNT += 1))

    WORKING_CONFIG_JSON='{"outbounds":[]}'
    existing_menu="$(add_outbounds_to_working_config <<<'4')"
    [[ "$existing_menu" == *"$expected_menu"* ]] || fail 'existing-config outbound menu order is incorrect'
    ((TEST_COUNT += 1))

    if ! sed -n '/readonly -a BASE_PACKAGES=(/,/^)/p' "$INSTALL_SCRIPT" | grep -qw sudo; then
        fail 'sudo is missing from BASE_PACKAGES'
    fi
    ((TEST_COUNT += 1))
}

command -v jq >/dev/null 2>&1 || fail 'jq is required for this test'

test_network_stack_listen_addresses
test_reality_domain_is_reused
test_transit_hysteria2_has_no_salamander_obfs
test_append_hy2_preserves_reality_and_unknown_fields
test_append_cf_tunnel_to_hy2
test_duplicate_inbound_is_rejected
test_outbound_collision_is_rejected
test_new_outbound_can_be_route_final
test_route_rules_are_preserved
test_discard_keeps_formal_config_unchanged
test_failed_sing_box_check_does_not_overwrite
test_apply_enables_service_only_after_active
test_invalid_existing_structures_are_rejected
test_key_reader_escape_and_sequences
test_outbound_builders_cancel_transactionally
test_secret_cancel_is_not_echoed
test_cancel_returns_to_outbound_menu_without_err_trap
test_socks_cancel_can_continue_with_other_outbound
test_failed_append_does_not_register_tag
test_cancel_in_existing_mode_is_transactional
test_new_inbound_cancel_preserves_previous_module
test_socks5_json_variants_and_addresses
test_multiple_socks5_and_unique_tags
test_outbound_menu_order_and_sudo_package

TEST_COMPLETE=true
printf 'PASS: %d node configuration wizard assertions\n' "$TEST_COUNT"
