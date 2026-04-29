#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "失败：$*" >&2
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
    "init-vps.sh 必须从整行解析 UFW 编号，不能使用 awk \$1。"
assert_fixed_grep 'match($0, /^\[[[:space:]]*[0-9]+\]/)' update-cf-ips.sh \
    "update-cf-ips.sh 必须从整行解析 UFW 编号，不能使用 awk \$1。"
assert_not_grep 'match\(\$0, [^)]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\)' init-vps.sh \
    "init-vps.sh 必须避免使用 gawk 专属的 match(..., array) 语法。"
assert_not_grep 'match\(\$0, [^)]*,[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\)' update-cf-ips.sh \
    "update-cf-ips.sh 必须避免使用 gawk 专属的 match(..., array) 语法。"

assert_grep 'rollback_site_config' create-site.sh \
    "create-site.sh 必须在 openresty -t 失败时回滚站点配置。"
assert_grep '^set -E$' create-site.sh \
    "create-site.sh 必须通过 set -E 启用 ERR trap 继承。"
assert_grep 'trap .*rollback_site_config' create-site.sh \
    "create-site.sh 必须在启用站点配置时安装回滚 trap。"
assert_grep 'validate_zip_paths' deploy-zip.sh \
    "deploy-zip.sh 必须检查 zip 路径，避免目录穿越。"
assert_grep 'rsync -a --delete' deploy-zip.sh \
    "deploy-zip.sh 必须使用 rsync --delete 同步站点目录。"
assert_grep 'bash deploy-zip.sh' publish-zip.sh \
    "publish-zip.sh 必须远程调用 deploy-zip.sh。"
assert_grep 'SSHPASS' publish-zip.sh \
    "publish-zip.sh 应支持通过环境变量 SSHPASS 配合 sshpass 使用。"

assert_grep 'SKIP_APT_UPGRADE=' config.example \
    "config.example 必须提供 SKIP_APT_UPGRADE。"
assert_grep 'CHOWN_SITE_ROOT=' config.example \
    "config.example 必须提供 CHOWN_SITE_ROOT。"
assert_grep 'UFW_CONFIRM_ENABLE=' config.example \
    "config.example 必须提供 UFW_CONFIRM_ENABLE。"

assert_grep 'SSH_CLIENT' init-vps.sh \
    "init-vps.sh 必须在启用 UFW 前显示当前 SSH 来源。"
assert_grep 'UFW_CONFIRM_ENABLE' init-vps.sh \
    "init-vps.sh 必须默认要求显式确认后才启用 UFW。"

assert_grep '\*\.pem' .gitignore \
    ".gitignore 必须忽略 PEM 证书/密钥文件。"
assert_grep '\*\.key' .gitignore \
    ".gitignore 必须忽略 key 文件。"
assert_grep '\*\.tar\.gz' .gitignore \
    ".gitignore 必须忽略备份压缩包。"

assert_not_grep 'listen 443 ssl http2;' templates/openresty-static.conf.tpl \
    "static 模板应使用 http2 on; 而不是已弃用的 listen ... http2。"
assert_not_grep 'listen 443 ssl http2;' templates/openresty-php.conf.tpl \
    "php 模板应使用 http2 on; 而不是已弃用的 listen ... http2。"
assert_not_grep 'listen 443 ssl http2;' templates/openresty-wordpress.conf.tpl \
    "wordpress 模板应使用 http2 on; 而不是已弃用的 listen ... http2。"
assert_not_grep 'listen 443 ssl http2;' templates/openresty-static-device.conf.tpl \
    "static-device 模板应使用 http2 on; 而不是已弃用的 listen ... http2。"
assert_not_grep 'listen 443 ssl http2;' templates/openresty-php-device.conf.tpl \
    "php-device 模板应使用 http2 on; 而不是已弃用的 listen ... http2。"
assert_not_grep 'listen 443 ssl http2;' templates/openresty-lua-gateway.conf.tpl \
    "lua-gateway 模板应使用 http2 on; 而不是已弃用的 listen ... http2。"

echo "RestyFleet 静态测试通过。"
