#!/usr/bin/env bash
set -euo pipefail
set -E

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"
ROLLBACK_SITE_CONFIG=0
ROLLBACK_SITE_CONF=""
ROLLBACK_ENABLED_LINK=""
ROLLBACK_TMPDIR=""
ROLLBACK_SITE_CONF_EXISTED=0
ROLLBACK_ENABLED_EXISTED=0
CREATED_SITE_PATHS=()

die() {
    echo "错误：$*" >&2
    exit 1
}

info() {
    echo "[信息] $*"
}

warn() {
    echo "[警告] $*" >&2
}

confirm() {
    local prompt="$1"
    local answer
    read -r -p "${prompt} 输入 y 确认，直接回车取消：" answer
    [[ "${answer}" == "y" || "${answer}" == "Y" || "${answer}" == "yes" || "${answer}" == "YES" ]]
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 执行：sudo bash $0"
}

load_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        cat >&2 <<'EOF'
缺少 ./config 配置文件。

请先执行：
  cp config.example config
  nano config
EOF
        exit 1
    fi

    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"

    : "${WEB_ROOT:=/www/wwwroot}"
    : "${OPENRESTY_CONF:=/usr/local/openresty/nginx/conf}"
    : "${OPENRESTY_LUA:=/usr/local/openresty/nginx/lua}"
    : "${PHP_FPM_SOCK:=/run/php/php8.3-fpm.sock}"
    : "${CHOWN_SITE_ROOT:=0}"
}

usage() {
    cat <<'EOF'
用法：
  bash create-site.sh example.com static
  bash create-site.sh example.com php
  bash create-site.sh example.com wordpress
  bash create-site.sh example.com static-device
  bash create-site.sh example.com php-device
  bash create-site.sh example.com lua-gateway
EOF
}

validate_domain() {
    local domain="$1"
    [[ "${domain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
        || die "域名格式无效：${domain}"
}

validate_site_type() {
    case "$1" in
        static|php|wordpress|static-device|php-device|lua-gateway) ;;
        *) die "站点类型无效：$1" ;;
    esac
}

needs_php() {
    case "$1" in
        php|wordpress|php-device|lua-gateway) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_php_fpm_sock() {
    local configured="${PHP_FPM_SOCK:-}"

    if [[ -n "${configured}" && -S "${configured}" ]]; then
        PHP_FPM_SOCK="${configured}"
        return
    fi

    local found=""
    found="$(find /run/php -maxdepth 1 -type s -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n 1 || true)"
    [[ -n "${found}" ]] || die "未找到 PHP-FPM socket。请在 ./config 设置 PHP_FPM_SOCK，或启动 php8.3-fpm。"
    PHP_FPM_SOCK="${found}"
}

backup_file() {
    local file="$1"
    [[ -e "${file}" || -L "${file}" ]] || return 0
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a "${file}" "${file}.bak.${stamp}"
}

safe_var_name() {
    echo "$1" | sed 's/[^A-Za-z0-9_]/_/g'
}

sed_escape_replacement() {
    printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

render_template() {
    local template="$1"
    local output="$2"
    local domain="$3"
    local safe_domain mobile_var device_root_var
    safe_domain="$(safe_var_name "${domain}")"
    mobile_var="\$is_mobile_${safe_domain}"
    device_root_var="\$device_root_${safe_domain}"

    sed \
        -e "s/{{DOMAIN}}/$(sed_escape_replacement "${domain}")/g" \
        -e "s/{{WEB_ROOT}}/$(sed_escape_replacement "${WEB_ROOT}")/g" \
        -e "s/{{OPENRESTY_CONF}}/$(sed_escape_replacement "${OPENRESTY_CONF}")/g" \
        -e "s/{{OPENRESTY_LUA}}/$(sed_escape_replacement "${OPENRESTY_LUA}")/g" \
        -e "s/{{PHP_FPM_SOCK}}/$(sed_escape_replacement "${PHP_FPM_SOCK}")/g" \
        -e "s/{{MOBILE_VAR}}/$(sed_escape_replacement "${mobile_var}")/g" \
        -e "s/{{DEVICE_ROOT_VAR}}/$(sed_escape_replacement "${device_root_var}")/g" \
        "${template}" > "${output}"
}

remember_created_path() {
    CREATED_SITE_PATHS+=("$1")
}

ensure_directory() {
    local dir="$1"
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}"
        remember_created_path "${dir}"
    else
        mkdir -p "${dir}"
    fi
}

chown_created_site_paths() {
    local site_root="$1"
    local path

    id www-data >/dev/null 2>&1 || return 0

    if [[ "${CHOWN_SITE_ROOT}" == "1" ]]; then
        warn "CHOWN_SITE_ROOT=1，将递归修改 ${site_root} 的所有权。"
        chown -R www-data:www-data "${site_root}"
        return
    fi

    for path in "${CREATED_SITE_PATHS[@]:-}"; do
        [[ -e "${path}" || -L "${path}" ]] || continue
        chown www-data:www-data "${path}"
    done
}

create_placeholder_cert() {
    local domain="$1"
    local ssl_dir="${OPENRESTY_CONF}/ssl/${domain}"
    local cert="${ssl_dir}/cert.pem"
    local key="${ssl_dir}/key.pem"

    mkdir -p "${ssl_dir}"
    chmod 700 "${ssl_dir}"

    if [[ -f "${cert}" && -f "${key}" ]]; then
        info "${domain} 的 SSL 文件已存在，保留现有文件。"
        return
    fi

    warn "正在为 ${domain} 创建自签名占位证书。"
    warn "正式使用前请替换为 Cloudflare Origin CA 证书。"
    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
        -keyout "${key}" \
        -out "${cert}" \
        -subj "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain},DNS:www.${domain}" >/dev/null 2>&1
    chmod 600 "${key}"
    chmod 644 "${cert}"
}

create_site_content() {
    local domain="$1"
    local site_type="$2"
    local site_root="${WEB_ROOT}/${domain}"

    ensure_directory "${site_root}"

    case "${site_type}" in
        static)
            if [[ ! -f "${site_root}/index.html" ]]; then
                cat > "${site_root}/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${domain}</title>
</head>
<body>
  <h1>${domain}</h1>
  <p>静态站点已创建。</p>
</body>
</html>
EOF
                remember_created_path "${site_root}/index.html"
            fi
            ;;
        php)
            if [[ ! -f "${site_root}/index.php" ]]; then
                cat > "${site_root}/index.php" <<'EOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
echo "PHP 站点已创建。\n";
echo "时间：" . date('c') . "\n";
EOF
                remember_created_path "${site_root}/index.php"
            fi
            ;;
        wordpress)
            info "已选择 WordPress 类型；只创建目录和 OpenResty 配置，不自动下载 WordPress。"
            ;;
        static-device)
            ensure_directory "${site_root}/pc"
            ensure_directory "${site_root}/mobile"
            if [[ ! -f "${site_root}/pc/index.html" ]]; then
                cat > "${site_root}/pc/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${domain} PC</title></head>
<body><h1>${domain} PC</h1><p>PC 静态站点已创建。</p></body>
</html>
EOF
                remember_created_path "${site_root}/pc/index.html"
            fi
            if [[ ! -f "${site_root}/mobile/index.html" ]]; then
                cat > "${site_root}/mobile/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${domain} 移动端</title></head>
<body><h1>${domain} 移动端</h1><p>移动端静态站点已创建。</p></body>
</html>
EOF
                remember_created_path "${site_root}/mobile/index.html"
            fi
            ;;
        php-device)
            ensure_directory "${site_root}/pc"
            ensure_directory "${site_root}/mobile"
            if [[ ! -f "${site_root}/pc/index.php" ]]; then
                cat > "${site_root}/pc/index.php" <<'EOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
echo "PC PHP 站点已创建。\n";
EOF
                remember_created_path "${site_root}/pc/index.php"
            fi
            if [[ ! -f "${site_root}/mobile/index.php" ]]; then
                cat > "${site_root}/mobile/index.php" <<'EOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
echo "移动端 PHP 站点已创建。\n";
EOF
                remember_created_path "${site_root}/mobile/index.php"
            fi
            ;;
        lua-gateway)
            if [[ ! -f "${site_root}/index.php" ]]; then
                cat > "${site_root}/index.php" <<'EOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
echo "Lua 网关 PHP 路由已创建。\n";
EOF
                remember_created_path "${site_root}/index.php"
            fi
            ;;
    esac

    chown_created_site_paths "${site_root}"
}

template_for_type() {
    case "$1" in
        static) echo "${SCRIPT_DIR}/templates/openresty-static.conf.tpl" ;;
        php) echo "${SCRIPT_DIR}/templates/openresty-php.conf.tpl" ;;
        wordpress) echo "${SCRIPT_DIR}/templates/openresty-wordpress.conf.tpl" ;;
        static-device) echo "${SCRIPT_DIR}/templates/openresty-static-device.conf.tpl" ;;
        php-device) echo "${SCRIPT_DIR}/templates/openresty-php-device.conf.tpl" ;;
        lua-gateway) echo "${SCRIPT_DIR}/templates/openresty-lua-gateway.conf.tpl" ;;
    esac
}

rollback_site_config() {
    local status="$?"
    set +e

    if [[ "${ROLLBACK_SITE_CONFIG}" == "1" ]]; then
        warn "OpenResty 配置检查或重载失败，正在回滚站点配置。"

        if [[ -n "${ROLLBACK_SITE_CONF}" ]]; then
            if [[ "${ROLLBACK_SITE_CONF_EXISTED}" == "1" ]]; then
                cp -a "${ROLLBACK_TMPDIR}/site.conf" "${ROLLBACK_SITE_CONF}"
            else
                rm -f "${ROLLBACK_SITE_CONF}"
            fi
        fi

        if [[ -n "${ROLLBACK_ENABLED_LINK}" ]]; then
            rm -f "${ROLLBACK_ENABLED_LINK}"
            if [[ "${ROLLBACK_ENABLED_EXISTED}" == "1" ]]; then
                cp -a "${ROLLBACK_TMPDIR}/enabled.conf" "${ROLLBACK_ENABLED_LINK}"
            fi
        fi
    fi

    [[ -n "${ROLLBACK_TMPDIR}" ]] && rm -rf "${ROLLBACK_TMPDIR}"
    exit "${status}"
}

prepare_site_config_rollback() {
    local site_conf="$1"
    local enabled_link="$2"

    ROLLBACK_TMPDIR="$(mktemp -d)"
    ROLLBACK_SITE_CONF="${site_conf}"
    ROLLBACK_ENABLED_LINK="${enabled_link}"
    ROLLBACK_SITE_CONF_EXISTED=0
    ROLLBACK_ENABLED_EXISTED=0

    if [[ -e "${site_conf}" || -L "${site_conf}" ]]; then
        cp -a "${site_conf}" "${ROLLBACK_TMPDIR}/site.conf"
        ROLLBACK_SITE_CONF_EXISTED=1
    fi

    if [[ -e "${enabled_link}" || -L "${enabled_link}" ]]; then
        cp -a "${enabled_link}" "${ROLLBACK_TMPDIR}/enabled.conf"
        ROLLBACK_ENABLED_EXISTED=1
    fi

    ROLLBACK_SITE_CONFIG=1
    trap rollback_site_config ERR
}

commit_site_config() {
    ROLLBACK_SITE_CONFIG=0
    trap - ERR
    [[ -n "${ROLLBACK_TMPDIR}" ]] && rm -rf "${ROLLBACK_TMPDIR}"
    ROLLBACK_TMPDIR=""
}

install_site_config() {
    local domain="$1"
    local site_type="$2"
    local template site_conf enabled_link tmp_conf

    template="$(template_for_type "${site_type}")"
    [[ -f "${template}" ]] || die "未找到模板：${template}"

    mkdir -p "${OPENRESTY_CONF}/sites-available" "${OPENRESTY_CONF}/sites-enabled"
    site_conf="${OPENRESTY_CONF}/sites-available/${domain}.conf"
    enabled_link="${OPENRESTY_CONF}/sites-enabled/${domain}.conf"
    tmp_conf="$(mktemp)"

    if [[ -e "${site_conf}" || -L "${site_conf}" ]]; then
        warn "站点配置已存在：${site_conf}"
        confirm "是否覆盖？" || die "已停止：现有站点配置未变更。"
        backup_file "${site_conf}"
    fi

    prepare_site_config_rollback "${site_conf}" "${enabled_link}"
    render_template "${template}" "${tmp_conf}" "${domain}"
    install -m 0644 "${tmp_conf}" "${site_conf}"
    rm -f "${tmp_conf}"
    ln -sfn "${site_conf}" "${enabled_link}"
}

reload_openresty() {
    if ! command -v openresty >/dev/null 2>&1; then
        echo "错误：未找到 openresty 命令。" >&2
        return 1
    fi
    openresty -t
    systemctl reload openresty
}

main() {
    require_root
    load_config

    if [[ "$#" -ne 2 ]]; then
        usage
        exit 1
    fi

    local domain site_type
    domain="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    site_type="$2"

    validate_domain "${domain}"
    validate_site_type "${site_type}"

    if needs_php "${site_type}"; then
        resolve_php_fpm_sock
        info "使用 PHP-FPM socket：${PHP_FPM_SOCK}"
    fi

    create_site_content "${domain}" "${site_type}"
    create_placeholder_cert "${domain}"
    install_site_config "${domain}" "${site_type}"
    reload_openresty
    commit_site_config

    cat <<EOF

站点已创建：${domain}（${site_type}）

下一步：
  1. 在 Cloudflare 添加 A 记录，并开启代理小云朵。
  2. 将 Cloudflare SSL/TLS 模式设置为 Full strict。
  3. 将以下文件替换为 Cloudflare Origin CA 证书文件：
     ${OPENRESTY_CONF}/ssl/${domain}/cert.pem
     ${OPENRESTY_CONF}/ssl/${domain}/key.pem
  4. 测试：
     curl -I https://${domain}
EOF
}

main "$@"
