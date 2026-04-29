#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"
TMP_DIR_CLEANUP=""

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
}

usage() {
    cat <<'EOF'
用法：
  bash deploy-zip.sh example.com /tmp/example.com.zip

说明：
  该脚本在 VPS 上执行，会备份旧站点、解压 zip、同步到站点目录、修复权限并重载 OpenResty。
EOF
}

validate_domain() {
    local domain="$1"
    [[ "${domain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
        || die "域名格式无效：${domain}"
}

require_command() {
    local command_name="$1"
    command -v "${command_name}" >/dev/null 2>&1 || die "缺少命令：${command_name}"
}

validate_zip_paths() {
    local zip_file="$1"
    local bad_path

    bad_path="$(zipinfo -1 "${zip_file}" | awk '
        /^\/|(^|\/)\.\.($|\/)/ || /^\.\.($|\/)/ {
            print
            exit
        }
    ')"

    [[ -z "${bad_path}" ]] || die "zip 内包含不安全路径：${bad_path}"
}

main() {
    require_root
    load_config

    if [[ "$#" -ne 2 ]]; then
        usage
        exit 1
    fi

    local domain zip_file site_dir site_conf
    domain="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    zip_file="$2"
    site_dir="${WEB_ROOT}/${domain}"
    site_conf="${OPENRESTY_CONF}/sites-available/${domain}.conf"
    TMP_DIR_CLEANUP="$(mktemp -d "/tmp/restyfleet-${domain}.XXXXXX")"

    trap '[[ -n "${TMP_DIR_CLEANUP:-}" ]] && rm -rf "${TMP_DIR_CLEANUP}"' EXIT

    validate_domain "${domain}"
    [[ -f "${zip_file}" ]] || die "zip 文件不存在：${zip_file}"
    [[ -d "${site_dir}" ]] || die "站点目录不存在：${site_dir}。请先执行 create-site.sh 创建站点。"
    [[ -f "${site_conf}" ]] || warn "未找到站点配置：${site_conf}"

    require_command unzip
    require_command zipinfo
    require_command rsync
    require_command openresty

    validate_zip_paths "${zip_file}"

    if [[ -x "${SCRIPT_DIR}/backup-site.sh" ]]; then
        info "正在备份旧站点..."
        bash "${SCRIPT_DIR}/backup-site.sh" "${domain}" || warn "备份失败，继续部署前请确认是否可接受。"
    fi

    info "正在解压 ${zip_file}..."
    unzip -q "${zip_file}" -d "${TMP_DIR_CLEANUP}"

    info "正在同步到 ${site_dir}..."
    rsync -a --delete "${TMP_DIR_CLEANUP}/" "${site_dir}/"

    if id www-data >/dev/null 2>&1; then
        info "正在修复文件所有权和权限..."
        chown -R www-data:www-data "${site_dir}"
    else
        warn "未找到 www-data 用户，跳过 chown。"
    fi

    find "${site_dir}" -type d -exec chmod 755 {} \;
    find "${site_dir}" -type f -exec chmod 644 {} \;

    info "正在检查 OpenResty 配置..."
    openresty -t

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet openresty; then
        info "正在重载 OpenResty..."
        systemctl reload openresty
    else
        warn "OpenResty 服务未运行，配置已检查但没有重载。"
    fi

    cat <<EOF

zip 部署完成：${domain}

站点目录：
  ${site_dir}

本机测试：
  curl -I -H "Host: ${domain}" http://127.0.0.1
EOF
}

main "$@"
