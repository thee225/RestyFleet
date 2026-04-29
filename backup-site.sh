#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"

die() {
    echo "错误：$*" >&2
    exit 1
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
    : "${BACKUP_ROOT:=/backup}"
    : "${OPENRESTY_CONF:=/usr/local/openresty/nginx/conf}"
}

usage() {
    echo "用法：bash backup-site.sh example.com"
}

validate_domain() {
    local domain="$1"
    [[ "${domain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
        || die "域名格式无效：${domain}"
}

to_tar_path() {
    local path="$1"
    printf '%s\n' "${path#/}"
}

main() {
    require_root
    load_config

    if [[ "$#" -ne 1 ]]; then
        usage
        exit 1
    fi

    local domain site_dir site_conf ssl_dir backup_dir stamp archive
    domain="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    validate_domain "${domain}"

    site_dir="${WEB_ROOT}/${domain}"
    site_conf="${OPENRESTY_CONF}/sites-available/${domain}.conf"
    ssl_dir="${OPENRESTY_CONF}/ssl/${domain}"

    [[ -d "${site_dir}" ]] || die "站点目录不存在：${site_dir}"

    backup_dir="${BACKUP_ROOT}/${domain}"
    mkdir -p "${backup_dir}"

    stamp="$(date +%Y%m%d-%H%M%S)"
    archive="${backup_dir}/${domain}-${stamp}.tar.gz"

    local tar_paths=()
    tar_paths+=("$(to_tar_path "${site_dir}")")

    if [[ -f "${site_conf}" ]]; then
        tar_paths+=("$(to_tar_path "${site_conf}")")
    else
        warn "未找到站点配置，跳过：${site_conf}"
    fi

    if [[ -d "${ssl_dir}" ]]; then
        tar_paths+=("$(to_tar_path "${ssl_dir}")")
    else
        warn "未找到 SSL 目录，跳过：${ssl_dir}"
    fi

    # 暂不自动备份数据库。后续如果站点有独立数据库，可在这里接入 mysqldump
    # 或 wp-cli export。
    tar -czf "${archive}" -C / "${tar_paths[@]}"

    find "${backup_dir}" -maxdepth 1 -type f -name "${domain}-*.tar.gz" | sort -r | tail -n +8 | xargs -r rm -f

    cat <<EOF
备份已创建：
  ${archive}

保留策略：
  已在 ${backup_dir} 保留最近 7 份备份。

后续可选：
  配置对象存储后，可使用 rclone 上传该备份。
EOF
}

main "$@"
