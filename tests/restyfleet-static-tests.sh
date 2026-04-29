#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_grep() {
    local pattern="$1"
    local file="$2"
    local message="$3"
    grep -Eq "${pattern}" "${ROOT_DIR}/${file}" || fail "${message}"
}

assert_fixed_grep() {
    local text="$1"
    local file="$2"
    local message="$3"
    grep -Fq "${text}" "${ROOT_DIR}/${file}" || fail "${message}"
}

assert_not_grep() {
    local pattern="$1"
    local file="$2"
    local message="$3"
    if grep -Eq "${pattern}" "${ROOT_DIR}/${file}"; then
        fail "${message}"
    fi
}

assert_fixed_grep 'match($0, /^\[[[:space:]]*[0-9]+\]/)' init-vps.sh \
    "init-vps.sh must parse UFW numbered output from the whole line, not awk \$1."
assert_fixed_grep 'match($0, /^\[[[:space:]]*[0-9]+\]/)' update-cf-ips.sh \
    "update-cf-ips.sh must parse UFW numbered output from the whole line, not awk \$1."
assert_not_grep 'match\(\$0, [^)]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\)' init-vps.sh \
    "init-vps.sh must avoid gawk-only match(..., array) syntax."
assert_not_grep 'match\(\$0, [^)]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\)' update-cf-ips.sh \
    "update-cf-ips.sh must avoid gawk-only match(..., array) syntax."

assert_grep 'rollback_site_config' create-site.sh \
    "create-site.sh must roll back site config when openresty -t fails."
assert_grep '^set -E$' create-site.sh \
    "create-site.sh must enable ERR trap inheritance with set -E."
assert_grep 'trap .*rollback_site_config' create-site.sh \
    "create-site.sh must install a rollback trap during site config activation."

assert_grep 'SKIP_APT_UPGRADE=' config.example \
    "config.example must expose SKIP_APT_UPGRADE."
assert_grep 'CHOWN_SITE_ROOT=' config.example \
    "config.example must expose CHOWN_SITE_ROOT."
assert_grep 'UFW_CONFIRM_ENABLE=' config.example \
    "config.example must expose UFW_CONFIRM_ENABLE."

assert_grep 'SSH_CLIENT' init-vps.sh \
    "init-vps.sh must show the current SSH source before enabling UFW."
assert_grep 'UFW_CONFIRM_ENABLE' init-vps.sh \
    "init-vps.sh must require explicit UFW enable confirmation unless configured otherwise."

assert_grep '\*\.pem' .gitignore \
    ".gitignore must ignore PEM certificate/key files."
assert_grep '\*\.key' .gitignore \
    ".gitignore must ignore key files."
assert_grep '\*\.tar\.gz' .gitignore \
    ".gitignore must ignore backup archives."

assert_not_grep 'listen 443 ssl http2;' templates/openresty-static.conf.tpl \
    "static template should use http2 on; instead of deprecated listen ... http2."
assert_not_grep 'listen 443 ssl http2;' templates/openresty-php.conf.tpl \
    "php template should use http2 on; instead of deprecated listen ... http2."
assert_not_grep 'listen 443 ssl http2;' templates/openresty-wordpress.conf.tpl \
    "wordpress template should use http2 on; instead of deprecated listen ... http2."
assert_not_grep 'listen 443 ssl http2;' templates/openresty-static-device.conf.tpl \
    "static-device template should use http2 on; instead of deprecated listen ... http2."
assert_not_grep 'listen 443 ssl http2;' templates/openresty-php-device.conf.tpl \
    "php-device template should use http2 on; instead of deprecated listen ... http2."
assert_not_grep 'listen 443 ssl http2;' templates/openresty-lua-gateway.conf.tpl \
    "lua-gateway template should use http2 on; instead of deprecated listen ... http2."

echo "restyfleet static tests passed."
