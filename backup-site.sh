#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "[WARN] $*" >&2
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
    : "${BACKUP_ROOT:=/backup}"
    : "${OPENRESTY_CONF:=/usr/local/openresty/nginx/conf}"
}

usage() {
    echo "Usage: bash backup-site.sh example.com"
}

validate_domain() {
    local domain="$1"
    [[ "${domain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
        || die "Invalid domain: ${domain}"
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

    [[ -d "${site_dir}" ]] || die "Site directory does not exist: ${site_dir}"

    backup_dir="${BACKUP_ROOT}/${domain}"
    mkdir -p "${backup_dir}"

    stamp="$(date +%Y%m%d-%H%M%S)"
    archive="${backup_dir}/${domain}-${stamp}.tar.gz"

    local tar_paths=()
    tar_paths+=("$(to_tar_path "${site_dir}")")

    if [[ -f "${site_conf}" ]]; then
        tar_paths+=("$(to_tar_path "${site_conf}")")
    else
        warn "Site config not found, skipping: ${site_conf}"
    fi

    if [[ -d "${ssl_dir}" ]]; then
        tar_paths+=("$(to_tar_path "${ssl_dir}")")
    else
        warn "SSL directory not found, skipping: ${ssl_dir}"
    fi

    # Database backups are intentionally not automatic yet. Add mysqldump or
    # wp-cli exports here later if a site owns a database.
    tar -czf "${archive}" -C / "${tar_paths[@]}"

    find "${backup_dir}" -maxdepth 1 -type f -name "${domain}-*.tar.gz" | sort -r | tail -n +8 | xargs -r rm -f

    cat <<EOF
Backup created:
  ${archive}

Retention:
  Kept the latest 7 archives in ${backup_dir}.

Optional future step:
  Upload this archive with rclone after object storage is configured.
EOF
}

main "$@"
