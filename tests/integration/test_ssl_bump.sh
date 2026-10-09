#!/usr/bin/env bash
# Integration test for SSL Bump (see README "TLS interception" and
# AGENTS.md "SSL Bump support"). Not run by default under `--integration`/
# `--all` -- opt in with TEST_SSL_BUMP=1, since this needs
# bin/generate-bump-ca.sh, a claude-code rebuild (to trust the new CA), and
# an egress-proxy rebuild, all slower than this suite's other tests, and
# because ubuntu/squid:latest's actual SSL/security_file_certgen support
# was never live-verified in the session that wrote this feature (see
# Dockerfile.egress-proxy's own comment) -- this test is partly how that
# gets verified for the first time, not a regression guard for already-
# confirmed behavior like the rest of this suite.
set -uo pipefail

if [ "${TEST_SSL_BUMP:-0}" != "1" ]; then
    echo "  SKIP: SSL Bump integration test not run by default -- set TEST_SSL_BUMP=1 to opt in (see this file's own header)."
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/assert.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/docker_lib.sh"

PROJECT="$(docker_test_project_name)"
COMPOSE=(docker compose -f "$REPO_ROOT/docker-compose.yml" -p "$PROJECT")

cleanup() {
    docker_test_cleanup "$PROJECT"
}
trap cleanup EXIT

echo "  (using COMPOSE_PROJECT_NAME=$PROJECT -- generates a bump CA, rebuilds claude-code + egress-proxy, can take a while)"

"$REPO_ROOT/bin/generate-bump-ca.sh"

# All three together, exactly like bin/cc-container --ssl-bump does --
# any one left at its default makes SSL Bump inert (see squid.conf's own
# comment). SQUID_HTTP_PORT_DIR was missing here in an earlier version of
# this test, which is why the first live run against this test showed
# egress-proxy healthy and reachable but NOT actually bumping anything
# (GitHub's real cert came through, exfil_suspicious_url never evaluated)
# -- the listener itself never gained ssl-bump capability, so the
# sslbump/*.conf include's rules had nothing to attach to.
export SQUID_HTTP_PORT_DIR="$REPO_ROOT/.squid-http-port-sslbump"
export SQUID_SSLBUMP_DIR="$REPO_ROOT/.squid-sslbump-enabled"
export SQUID_BUMP_CA_DIR="$REPO_ROOT/.squid-bump-ca"

if ! "${COMPOSE[@]}" build claude-code egress-proxy 2>&1 | sed 's/^/  /'; then
    CURRENT_TEST="ssl-bump image build"
    _fail "docker compose build claude-code egress-proxy failed -- see output above"
    print_summary
    exit 1
fi

if ! "${COMPOSE[@]}" up -d --wait 2>&1 | sed 's/^/  /'; then
    CURRENT_TEST="ssl-bump stack startup"
    # egress-proxy's own startup log (squid's actual error, if that's why
    # it's unhealthy) is otherwise lost the moment this script exits and
    # the cleanup trap tears the stack down -- dump it here so a failure
    # is diagnosable from this run's own output, not a second round-trip.
    egress_log="$("${COMPOSE[@]}" logs egress-proxy 2>&1 || true)"
    _fail "docker compose up -d --wait failed -- see output above and egress-proxy's own log below"
    echo "    --- diagnostic: egress-proxy log ---"
    echo "$egress_log" | sed 's/^/    log> /'
    print_summary
    exit 1
fi

test_bumped_domain_still_reachable() {
    # The main functional check: if claude-code doesn't trust the bump CA
    # (Dockerfile.egress-proxy's security_file_certgen path, or the CA
    # sync into certs/, silently didn't work), every HTTPS request to an
    # allowed domain fails here -- this would also catch that, not just a
    # dedicated cert-chain check.
    assert_success "${COMPOSE[@]}" exec -T claude-code \
        curl -fsS --max-time 10 -o /dev/null https://api.github.com
}

test_bumped_connection_uses_generated_ca() {
    # Confirms bumping is actually happening, not just that the request
    # happens to succeed for some unrelated reason (e.g. splice silently
    # still active). openssl s_client through the proxy would need CONNECT
    # scripting -- simpler and equally conclusive: curl -v's own TLS
    # handshake trace names the cert issuer it actually validated against.
    local trace
    trace="$("${COMPOSE[@]}" exec -T claude-code \
        curl -v --max-time 10 -o /dev/null https://api.github.com 2>&1)"
    assert_contains "$trace" "claude-code-docker egress-proxy bump CA" \
        "curl's TLS trace shows the generated bump CA as the issuer, not GitHub's real one"
}

test_non_allowlisted_domain_still_blocked() {
    # Regression check: SSL Bump must not loosen the domain-level gate.
    assert_failure "${COMPOSE[@]}" exec -T claude-code \
        curl -fsS --max-time 5 -o /dev/null https://example.com
}

test_suspicious_url_pattern_blocked() {
    # The illustrative exfil_suspicious_url ACL (.squid-sslbump-enabled/
    # 10-bump.conf) -- a long base64-ish query string to an allowed domain
    # should now be blocked, where it wasn't before SSL Bump.
    local long_token
    long_token="$(head -c 64 /dev/urandom | base64 | tr -d '\n=+/' | head -c 70)"
    assert_failure "${COMPOSE[@]}" exec -T claude-code \
        curl -fsS --max-time 10 -o /dev/null "https://api.github.com/search/issues?q=${long_token}"
}

test_search_only_domains_restricted() {
    # Data-driven, not one function per domain (26 near-identical checks) --
    # each entry: domain|allowed-search-url|blocked-nonsearch-url. See
    # .squid-sslbump-enabled/20-search-only.conf for the source of truth on
    # which domains/patterns this tests, and its header comment for which
    # domains were deliberately left out (no simple restrictable search
    # endpoint) and why.
    #
    # Requires .squid-claudecode-docker/00-defaults.conf to already have the
    # 2026-09-18 reference-domain entries with leading dots (`.stackoverflow.com`
    # etc.) -- applied outside this sandbox, see this repo's own commit
    # history/conversation record, not re-documented here. Domains not yet
    # present there will fail both checks below with a domain-level (not
    # path-level) block, which still shows up as a real FAIL, just not for
    # the reason this test exists to catch -- check
    # .squid-claudecode-docker/00-defaults.conf first if every case here
    # fails at once.
    local cases=(
        "stackoverflow.com|https://stackoverflow.com/search?q=python|https://stackoverflow.com/questions"
        "stackexchange.com|https://stackexchange.com/search?q=python|https://stackexchange.com/sites"
        "developer.mozilla.org|https://developer.mozilla.org/en-US/search?q=fetch|https://developer.mozilla.org/en-US/docs/Web"
        "pkg.go.dev|https://pkg.go.dev/search?q=json|https://pkg.go.dev/std"
        "learn.microsoft.com|https://learn.microsoft.com/search/?terms=azure|https://learn.microsoft.com/en-us/azure/"
        "pypi.org|https://pypi.org/search/?q=requests|https://pypi.org/project/requests/"
        # crates.io: both /search?q= and /api/v1/crates?q= live-confirmed
        # reachable through this rule (Via header shows the request reaching
        # real origin infrastructure, "varnish, ... egress-proxy") -- but
        # crates.io's OWN infrastructure returns an empty-body 403 for
        # EITHER path when curl's default User-Agent is used (live-confirmed
        # by testing the exact same URL with a browser UA: 200 OK). This is
        # why the loop below passes a browser-like -A to every case, not
        # just this one -- unrelated to this project's Squid rule, which
        # already allows both crates.io paths (see 20-search-only.conf's
        # crates_api ACL).
        "crates.io|https://crates.io/api/v1/crates?q=serde|https://crates.io/crates/serde"
        "npmjs.com|https://npmjs.com/search?q=react|https://npmjs.com/package/react"
        "rubygems.org|https://rubygems.org/search?query=rails|https://rubygems.org/gems/rails"
        "packagist.org|https://packagist.org/?query=monolog|https://packagist.org/packages/monolog/monolog"
        "docs.djangoproject.com|https://docs.djangoproject.com/en/5.1/search/?q=views|https://docs.djangoproject.com/en/5.1/topics/"
        "en.wikipedia.org|https://en.wikipedia.org/w/index.php?search=docker|https://en.wikipedia.org/wiki/Docker_(software)"
        "postgresql.org|https://postgresql.org/search/?q=index|https://postgresql.org/docs/current/"
    )
    # Browser-like User-Agent on every request here, not just crates.io's --
    # live-confirmed necessary for crates.io specifically (curl's default
    # UA gets an empty-body 403 from crates.io's own infrastructure on
    # EITHER allowed path; a browser UA gets a real 200), applied to all
    # cases as cheap insurance against the same bot-filtering on other
    # sites in this list.
    local browser_ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    local case domain allow_url block_url
    for case in "${cases[@]}"; do
        IFS='|' read -r domain allow_url block_url <<< "$case"
        CURRENT_TEST="search-only: $domain (allowed search URL reachable)"
        assert_success "${COMPOSE[@]}" exec -T claude-code \
            curl -fsS -A "$browser_ua" --max-time 10 -o /dev/null "$allow_url"
        CURRENT_TEST="search-only: $domain (non-search page blocked)"
        assert_failure "${COMPOSE[@]}" exec -T claude-code \
            curl -fsS -A "$browser_ua" --max-time 10 -o /dev/null "$block_url"
    done
}

test_algolia_query_path_reachable() {
    # Doesn't assert a 2xx -- Algolia itself will very likely reject an
    # unauthenticated request (missing API key), which is expected and not
    # this project's concern. Only checks that the response came from
    # Algolia itself, not from Squid's own access-denied error page (which
    # includes "squid" in its default footer) -- i.e. confirms the proxy let
    # the request through to the real site rather than blocking it outright.
    # NOT independently re-verified against a live build (no Docker in the
    # session that wrote this) -- if this fails, check with `curl -v`
    # locally whether Squid's own error page (mentions "squid") or a real
    # Algolia response (JSON, mentions "algolia"/"message") came back.
    local body
    body="$("${COMPOSE[@]}" exec -T claude-code curl -sS --max-time 10 \
        "https://l1xwt2uj7f-3.algolianet.com/1/indexes/angular_v17/query" 2>&1)"
    CURRENT_TEST="Algolia query path reaches Algolia, not blocked by Squid"
    assert_not_contains "$body" "squid"
}

test_algolia_non_query_path_blocked() {
    local body
    body="$("${COMPOSE[@]}" exec -T claude-code curl -sS --max-time 10 \
        "https://l1xwt2uj7f-3.algolianet.com/1/indexes/angular_v17/settings" 2>&1)"
    CURRENT_TEST="Algolia non-query path (settings) blocked by Squid"
    assert_contains "$body" "squid"
}

test_github_read_only() {
    # .squid-sslbump-enabled/20-search-only.conf's github_dom block: reads
    # (incl. the POST-based git-upload-pack fetch) pass, push and API/gist
    # writes are denied by Squid itself. Compares against Squid's own error
    # page ("squid" in its footer) like the Algolia tests above, so an
    # upstream 4xx from GitHub (e.g. unauthenticated POST) isn't mistaken
    # for a proxy block.
    local body
    CURRENT_TEST="github: info/refs?service=git-upload-pack reachable"
    assert_success "${COMPOSE[@]}" exec -T claude-code \
        curl -fsS --max-time 10 -o /dev/null \
        "https://github.com/octocat/Hello-World.git/info/refs?service=git-upload-pack"
    body="$("${COMPOSE[@]}" exec -T claude-code curl -sS --max-time 10 \
        "https://github.com/octocat/Hello-World.git/info/refs?service=git-receive-pack" 2>&1)"
    CURRENT_TEST="github: info/refs?service=git-receive-pack blocked by Squid"
    assert_contains "$body" "squid"
    body="$("${COMPOSE[@]}" exec -T claude-code curl -sS --max-time 10 -X POST \
        "https://github.com/octocat/Hello-World.git/git-receive-pack" 2>&1)"
    CURRENT_TEST="github: POST git-receive-pack blocked by Squid"
    assert_contains "$body" "squid"
    body="$("${COMPOSE[@]}" exec -T claude-code curl -sS --max-time 10 -X POST \
        -d '{}' "https://api.github.com/gists" 2>&1)"
    CURRENT_TEST="github: POST api.github.com/gists blocked by Squid"
    assert_contains "$body" "squid"
}

test_github_clone_works() {
    # End-to-end proof for the one allow rule test_github_read_only above
    # doesn't touch: a real clone does POST .../git-upload-pack, which the
    # github_dom block allows explicitly (read despite the method). Without
    # that rule this fails, since the generic allow is GET/HEAD only. Shallow
    # to keep it small; needs outbound access to github.com like the rest of
    # this suite. Cleans up its temp dir either way.
    CURRENT_TEST="github: git clone (POST git-upload-pack) works through the bump"
    assert_success "${COMPOSE[@]}" exec -T claude-code bash -c \
        'd="$(mktemp -d)"; trap "rm -rf \"$d\"" EXIT; git clone --depth 1 -q https://github.com/octocat/Hello-World.git "$d/hw"'
}

test_gcs_restricted_to_anthropic_bucket() {
    local body
    body="$("${COMPOSE[@]}" exec -T claude-code curl -sS --max-time 10 \
        "https://storage.googleapis.com/some-other-bucket/x" 2>&1)"
    CURRENT_TEST="gcs: foreign bucket blocked by Squid"
    assert_contains "$body" "squid"
    # Positive path of the gcs_anthropic rule. Uses a SHORT path under the
    # bucket (/<bucket>/x = 56 chars) on purpose: the real
    # plugin-stats/plugin-details.json path is a 60+ char
    # [A-Za-z0-9+/_-] run, which 10-bump.conf's exfil_suspicious_url denies
    # BEFORE 20-search-only.conf is reached (live run 2026-10-07), so it
    # can't exercise this rule. Google itself answers (404/403 XML), not Squid.
    body="$("${COMPOSE[@]}" exec -T claude-code curl -sS --max-time 10 \
        "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/x" 2>&1)"
    CURRENT_TEST="gcs: Anthropic bucket short path reaches GCS, not blocked by Squid"
    assert_not_contains "$body" "squid"
    # Pins the interaction described above, so a change to either rule's
    # ordering or the 60-char threshold shows up here instead of silently.
    body="$("${COMPOSE[@]}" exec -T claude-code curl -sS --max-time 10 \
        "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/plugin-stats/plugin-details.json" 2>&1)"
    CURRENT_TEST="gcs: real plugin-stats path still denied by exfil_suspicious_url"
    assert_contains "$body" "squid"
}

run_test test_bumped_domain_still_reachable
run_test test_bumped_connection_uses_generated_ca
run_test test_non_allowlisted_domain_still_blocked
run_test test_suspicious_url_pattern_blocked
run_test test_search_only_domains_restricted
run_test test_algolia_query_path_reachable
run_test test_algolia_non_query_path_blocked
run_test test_github_read_only
run_test test_github_clone_works
run_test test_gcs_restricted_to_anthropic_bucket

print_summary
