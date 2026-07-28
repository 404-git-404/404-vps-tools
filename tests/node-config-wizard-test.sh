#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly TEST_DIR
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
readonly REPO_ROOT
readonly WIZARD_SCRIPT="$REPO_ROOT/node-config-wizard.sh"

# The path is anchored to this test file, rather than the caller's directory.
# shellcheck disable=SC1090
source "$WIZARD_SCRIPT"
trap - EXIT INT TERM

TEST_COUNT=0
TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/node-config-wizard-tests.XXXXXXXX")
readonly TEST_TEMP_DIR

cleanup_test_files() {
    if [[ -n "$TEST_TEMP_DIR" && "$TEST_TEMP_DIR" == /* &&
        -d "$TEST_TEMP_DIR" ]]; then
        rm -rf -- "$TEST_TEMP_DIR"
    fi
}

trap cleanup_test_files EXIT

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

file_hash() {
    sha256sum "$1" | awk '{print $1}'
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

command -v jq >/dev/null 2>&1 || fail 'jq is required for this test'

test_reality_domain_is_reused
test_append_hy2_preserves_reality_and_unknown_fields
test_append_cf_tunnel_to_hy2
test_duplicate_inbound_is_rejected
test_outbound_collision_is_rejected
test_new_outbound_can_be_route_final
test_route_rules_are_preserved
test_discard_keeps_formal_config_unchanged
test_failed_sing_box_check_does_not_overwrite
test_invalid_existing_structures_are_rejected

printf 'PASS: %d node configuration wizard assertions\n' "$TEST_COUNT"
