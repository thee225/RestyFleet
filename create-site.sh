#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

confirm() {
    local prompt="$1"
    local answer
    read -r -p "${prompt} [y/N] " answer
    [[ "${answer}" == "y" || "${answer}" == "Y" || "${answer}" == "yes" || "${answer}" == "YES" ]]
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Please run as root: sudo bash $0"
}

load_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        cat >&2 <<'EOF'
Missing ./config.

Please run:
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
}

usage() {
    cat <<'EOF'
Usage:
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
        || die "Invalid domain: ${domain}"
}

validate_site_type() {
    case "$1" in
        static|php|wordpress|static-device|php-device|lua-gateway) ;;
        *) die "Invalid site type: $1" ;;
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
    [[ -n "${found}" ]] || die "PHP-FPM socket not found. Set PHP_FPM_SOCK in ./config or start php8.3-fpm."
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

create_placeholder_cert() {
    local domain="$1"
    local ssl_dir="${OPENRESTY_CONF}/ssl/${domain}"
    local cert="${ssl_dir}/cert.pem"
    local key="${ssl_dir}/key.pem"

    mkdir -p "${ssl_dir}"
    chmod 700 "${ssl_dir}"

    if [[ -f "${cert}" && -f "${key}" ]]; then
        info "SSL files already exist for ${domain}; keeping existing files."
        return
    fi

    warn "Creating self-signed placeholder certificate for ${domain}."
    warn "Replace it with a Cloudflare Origin CA certificate before production use."
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

    mkdir -p "${site_root}"

    case "${site_type}" in
        static)
            if [[ ! -f "${site_root}/index.html" ]]; then
                cat > "${site_root}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${domain}</title>
</head>
<body>
  <h1>${domain}</h1>
  <p>Static site is ready.</p>
</body>
</html>
EOF
            fi
            ;;
        php)
            if [[ ! -f "${site_root}/index.php" ]]; then
                cat > "${site_root}/index.php" <<'EOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
echo "PHP site is ready.\n";
echo "Time: " . date('c') . "\n";
EOF
            fi
            ;;
        wordpress)
            info "WordPress type selected; directory and OpenResty config will be created, WordPress will not be downloaded."
            ;;
        static-device)
            mkdir -p "${site_root}/pc" "${site_root}/mobile"
            if [[ ! -f "${site_root}/pc/index.html" ]]; then
                cat > "${site_root}/pc/index.html" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${domain} PC</title></head>
<body><h1>${domain} PC</h1><p>PC static site is ready.</p></body>
</html>
EOF
            fi
            if [[ ! -f "${site_root}/mobile/index.html" ]]; then
                cat > "${site_root}/mobile/index.html" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${domain} Mobile</title></head>
<body><h1>${domain} Mobile</h1><p>Mobile static site is ready.</p></body>
</html>
EOF
            fi
            ;;
        php-device)
            mkdir -p "${site_root}/pc" "${site_root}/mobile"
            if [[ ! -f "${site_root}/pc/index.php" ]]; then
                cat > "${site_root}/pc/index.php" <<'EOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
echo "PC PHP site is ready.\n";
EOF
            fi
            if [[ ! -f "${site_root}/mobile/index.php" ]]; then
                cat > "${site_root}/mobile/index.php" <<'EOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
echo "Mobile PHP site is ready.\n";
EOF
            fi
            ;;
        lua-gateway)
            if [[ ! -f "${site_root}/index.php" ]]; then
                cat > "${site_root}/index.php" <<'EOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
echo "Lua gateway PHP route is ready.\n";
EOF
            fi
            ;;
    esac

    if id www-data >/dev/null 2>&1; then
        chown -R www-data:www-data "${site_root}"
    fi
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

install_site_config() {
    local domain="$1"
    local site_type="$2"
    local template site_conf enabled_link tmp_conf

    template="$(template_for_type "${site_type}")"
    [[ -f "${template}" ]] || die "Template not found: ${template}"

    mkdir -p "${OPENRESTY_CONF}/sites-available" "${OPENRESTY_CONF}/sites-enabled"
    site_conf="${OPENRESTY_CONF}/sites-available/${domain}.conf"
    enabled_link="${OPENRESTY_CONF}/sites-enabled/${domain}.conf"
    tmp_conf="$(mktemp)"

    if [[ -e "${site_conf}" ]]; then
        warn "Site config already exists: ${site_conf}"
        confirm "Overwrite it?" || die "Aborted; existing site config was not changed."
        backup_file "${site_conf}"
    fi

    render_template "${template}" "${tmp_conf}" "${domain}"
    install -m 0644 "${tmp_conf}" "${site_conf}"
    rm -f "${tmp_conf}"
    ln -sfn "${site_conf}" "${enabled_link}"
}

reload_openresty() {
    command -v openresty >/dev/null 2>&1 || die "openresty command not found."
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
        info "Using PHP-FPM socket: ${PHP_FPM_SOCK}"
    fi

    create_site_content "${domain}" "${site_type}"
    create_placeholder_cert "${domain}"
    install_site_config "${domain}" "${site_type}"
    reload_openresty

    cat <<EOF

Site created: ${domain} (${site_type})

Next steps:
  1. Add an A record in Cloudflare and enable proxy.
  2. Set Cloudflare SSL/TLS mode to Full strict.
  3. Replace these files with Cloudflare Origin CA certificate files:
     ${OPENRESTY_CONF}/ssl/${domain}/cert.pem
     ${OPENRESTY_CONF}/ssl/${domain}/key.pem
  4. Test:
     curl -I https://${domain}
EOF
}

main "$@"
