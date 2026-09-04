#!/usr/bin/env bash
# Unit tests for render_upstream_proxy_conf() in bin/cc-container (the
# HTTP(S)_PROXY parsing + Squid/px config rendering for enterprise proxy
# chaining -- see README "Enterprise proxy support").
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/bin/cc-container" # source-guarded: only defines functions

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Runs render_upstream_proxy_conf() in a fresh PROJECT_ROOT with the given
# HTTP_PROXY/HTTPS_PROXY/ENTERPRISE_PROXY_AUTH, leaving upstream_conf/px_ini
# paths in the caller's scope for assertions.
render_case() { # http_proxy https_proxy auth_scheme
    PROJECT_ROOT="$TMP_ROOT/$CURRENT_TEST"
    mkdir -p "$PROJECT_ROOT"
    HTTP_PROXY="$1" HTTPS_PROXY="$2" ENTERPRISE_PROXY_AUTH="$3"
    NEEDS_PROXY_AUTH_SIDECAR=false
    render_upstream_proxy_conf
    upstream_conf="$PROJECT_ROOT/.squid-upstream-proxy/upstream.conf"
    px_ini="$PROJECT_ROOT/.squid-upstream-proxy/px.ini"
    px_env="$PROJECT_ROOT/.squid-upstream-proxy/px.env"
}

test_no_proxy_configured() {
    render_case "" "" ""
    assert_file_exists "$upstream_conf"
    assert_contains "$(cat "$upstream_conf")" "No enterprise proxy configured"
    assert_file_not_exists "$px_ini"
    assert_file_not_exists "$px_env"
    assert_equal false "$NEEDS_PROXY_AUTH_SIDECAR"
}

test_basic_no_credentials() {
    render_case "" "http://proxy.corp.example.com:8080" "basic"
    assert_contains "$(cat "$upstream_conf")" "cache_peer proxy.corp.example.com parent 8080 0 no-query default"
    assert_not_contains "$(cat "$upstream_conf")" "login="
    assert_contains "$(cat "$upstream_conf")" "never_direct allow all"
    assert_file_not_exists "$px_ini"
    assert_file_not_exists "$px_env"
    assert_equal false "$NEEDS_PROXY_AUTH_SIDECAR"
}

test_basic_with_credentials() {
    render_case "" "http://myuser:mypass@proxy.corp.example.com:8080" "basic"
    assert_contains "$(cat "$upstream_conf")" "login=myuser:mypass"
    assert_file_not_exists "$px_ini"
    assert_file_not_exists "$px_env"
    assert_equal false "$NEEDS_PROXY_AUTH_SIDECAR"
}

test_basic_is_the_default_auth_scheme() {
    render_case "" "http://myuser:mypass@proxy.corp.example.com:8080" ""
    assert_contains "$(cat "$upstream_conf")" "login=myuser:mypass"
    assert_equal false "$NEEDS_PROXY_AUTH_SIDECAR"
}

test_https_proxy_takes_precedence_over_http_proxy() {
    render_case "http://http-proxy.example.com:1111" "http://https-proxy.example.com:2222" "basic"
    assert_contains "$(cat "$upstream_conf")" "https-proxy.example.com parent 2222"
}

test_http_proxy_used_when_https_proxy_unset() {
    render_case "http://http-proxy.example.com:1111" "" "basic"
    assert_contains "$(cat "$upstream_conf")" "http-proxy.example.com parent 1111"
}

test_ntlm_uses_proxy_auth_sidecar() {
    render_case "" 'http://CORP\jdoe:s3cr3t@proxy.corp.example.com:8080' "ntlm"
    assert_contains "$(cat "$upstream_conf")" "cache_peer proxy-auth parent 3128 0 no-query default"
    assert_not_contains "$(cat "$upstream_conf")" "login="
    assert_file_exists "$px_ini"
    assert_contains "$(cat "$px_ini")" "server = proxy.corp.example.com:8080"
    assert_contains "$(cat "$px_ini")" 'username = CORP\jdoe'
    assert_not_contains "$(cat "$px_ini")" "password"
    # px has no `password` key for px.ini (see bin/cc-container) -- the
    # password is rendered separately as PX_PASSWORD in px.env instead.
    assert_file_exists "$px_env"
    assert_contains "$(cat "$px_env")" "PX_PASSWORD=s3cr3t"
    assert_equal true "$NEEDS_PROXY_AUTH_SIDECAR"
}

test_kerberos_without_password_omits_px_env_content() {
    render_case "" "http://proxy.corp.example.com:8080" "kerberos"
    assert_file_exists "$px_ini"
    assert_contains "$(cat "$px_ini")" "server = proxy.corp.example.com:8080"
    assert_not_contains "$(cat "$px_ini")" "username ="
    assert_not_contains "$(cat "$px_ini")" "password"
    assert_file_exists "$px_env"
    assert_equal "" "$(cat "$px_env")"
    assert_equal true "$NEEDS_PROXY_AUTH_SIDECAR"
}

test_unknown_auth_scheme_falls_back_to_basic() {
    render_case "" "http://u:p@proxy.corp.example.com:8080" "weird-scheme"
    assert_contains "$(cat "$upstream_conf")" "login=u:p"
    assert_file_not_exists "$px_ini"
    assert_file_not_exists "$px_env"
    assert_equal false "$NEEDS_PROXY_AUTH_SIDECAR"
}

test_unparseable_url_is_ignored_not_fatal() {
    render_case "" "not-a-url" "basic"
    assert_contains "$(cat "$upstream_conf")" "not parseable"
    assert_file_not_exists "$px_ini"
    assert_file_not_exists "$px_env"
    assert_equal false "$NEEDS_PROXY_AUTH_SIDECAR"
}

test_switching_back_to_no_proxy_removes_stale_px_ini() {
    render_case "" 'http://CORP\jdoe:s3cr3t@proxy.corp.example.com:8080' "ntlm"
    assert_file_exists "$px_ini"
    assert_file_exists "$px_env"

    HTTP_PROXY="" HTTPS_PROXY="" ENTERPRISE_PROXY_AUTH=""
    NEEDS_PROXY_AUTH_SIDECAR=false
    render_upstream_proxy_conf
    assert_file_not_exists "$px_ini"
    assert_file_not_exists "$px_env"
}

run_test test_no_proxy_configured
run_test test_basic_no_credentials
run_test test_basic_with_credentials
run_test test_basic_is_the_default_auth_scheme
run_test test_https_proxy_takes_precedence_over_http_proxy
run_test test_http_proxy_used_when_https_proxy_unset
run_test test_ntlm_uses_proxy_auth_sidecar
run_test test_kerberos_without_password_omits_px_env_content
run_test test_unknown_auth_scheme_falls_back_to_basic
run_test test_unparseable_url_is_ignored_not_fatal
run_test test_switching_back_to_no_proxy_removes_stale_px_ini

print_summary
