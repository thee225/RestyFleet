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

    : "${ADMIN_IP:=}"
    : "${SSH_PORT:=22}"
    : "${WEB_ROOT:=/www/wwwroot}"
    : "${BACKUP_ROOT:=/backup}"
    : "${OPENRESTY_CONF:=/usr/local/openresty/nginx/conf}"
    : "${OPENRESTY_LUA:=/usr/local/openresty/nginx/lua}"
    : "${PHP_FPM_SOCK:=/run/php/php8.3-fpm.sock}"
    : "${DEFAULT_EMAIL:=admin@example.com}"
}

backup_file() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a "${file}" "${file}.bak.${stamp}"
}

check_ubuntu_version() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found; cannot detect OS."
    # shellcheck source=/dev/null
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
        warn "Detected ${PRETTY_NAME:-unknown OS}; this project is designed for Ubuntu 24.04 LTS."
        confirm "Continue anyway?" || die "Aborted because OS is not Ubuntu 24.04."
    fi
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

check_web_conflicts() {
    if pkg_installed nginx; then
        warn "Package nginx is installed. OpenResty conflicts with ordinary nginx packages."
        confirm "I have manually reviewed this conflict and want to continue" || die "Please remove or resolve nginx first."
    fi

    if pkg_installed apache2; then
        warn "Package apache2 is installed. It may occupy ports 80/443."
        confirm "I have manually reviewed this conflict and want to continue" || die "Please remove or resolve apache2 first."
    fi
}

check_ports_free() {
    if ! command -v ss >/dev/null 2>&1; then
        warn "Command ss not found; skipping port preflight."
        return
    fi

    local occupied
    occupied="$(ss -ltnp '( sport = :80 or sport = :443 )' || true)"
    if echo "${occupied}" | awk 'NR > 1 { found=1 } END { exit !found }'; then
        if pkg_installed openresty && ! pkg_installed nginx \
            && ! echo "${occupied}" | awk 'NR > 1 && $0 !~ /(openresty|nginx)/ { bad=1 } END { exit !bad }'; then
            info "Ports 80/443 are already used by OpenResty; continuing for idempotent rerun."
            return
        fi
        echo "${occupied}" >&2
        die "Port 80 or 443 is already in use. Stop the occupying process before installing OpenResty."
    fi
}

install_base_packages() {
    info "Updating apt package indexes and upgrading installed packages..."
    apt update
    DEBIAN_FRONTEND=noninteractive apt upgrade -y

    info "Installing base tools..."
    DEBIAN_FRONTEND=noninteractive apt install -y \
        curl wget gnupg ca-certificates lsb-release software-properties-common \
        unzip git ufw fail2ban rsync rclone logrotate openssl
}

install_openresty_repo() {
    local arch codename keyring repo_file repo_base repo_line
    arch="$(dpkg --print-architecture)"
    codename="$(lsb_release -sc)"
    keyring="/usr/share/keyrings/openresty.gpg"
    repo_file="/etc/apt/sources.list.d/openresty.list"

    case "${arch}" in
        amd64)
            repo_base="http://openresty.org/package/ubuntu"
            ;;
        arm64)
            repo_base="http://openresty.org/package/arm64/ubuntu"
            ;;
        *)
            die "Unsupported architecture for OpenResty official Ubuntu repo: ${arch}"
            ;;
    esac

    repo_line="deb [arch=${arch} signed-by=${keyring}] ${repo_base} ${codename} main"

    info "Adding OpenResty official APT repository..."
    curl -fsSL https://openresty.org/package/pubkey.gpg | gpg --dearmor -o "${keyring}.tmp"
    install -m 0644 "${keyring}.tmp" "${keyring}"
    rm -f "${keyring}.tmp"

    if [[ -f "${repo_file}" ]] && ! grep -Fxq "${repo_line}" "${repo_file}"; then
        backup_file "${repo_file}"
    fi
    printf '%s\n' "${repo_line}" > "${repo_file}"

    apt update
}

install_openresty() {
    info "Installing OpenResty..."
    DEBIAN_FRONTEND=noninteractive apt install -y openresty
}

install_php83() {
    info "Installing PHP 8.3-FPM and common extensions from Ubuntu repositories..."
    DEBIAN_FRONTEND=noninteractive apt install -y \
        php8.3-fpm php8.3-cli php8.3-common php8.3-mysql php8.3-curl \
        php8.3-xml php8.3-mbstring php8.3-zip php8.3-gd php8.3-opcache \
        php8.3-bcmath php8.3-intl
}

create_directories() {
    info "Creating OpenResty, site, backup, snippet, SSL, and Lua directories..."
    mkdir -p \
        "${WEB_ROOT}" \
        "${BACKUP_ROOT}" \
        "${OPENRESTY_CONF}/sites-available" \
        "${OPENRESTY_CONF}/sites-enabled" \
        "${OPENRESTY_CONF}/snippets" \
        "${OPENRESTY_CONF}/ssl" \
        "${OPENRESTY_LUA}"
}

install_lua_files() {
    info "Installing Lua helper files..."
    install -m 0644 "${SCRIPT_DIR}/lua/"*.lua "${OPENRESTY_LUA}/"
}

ensure_nginx_conf_include() {
    local nginx_conf="${OPENRESTY_CONF}/nginx.conf"
    local tmp_file need_conf_include=0 need_local_include=0

    [[ -f "${nginx_conf}" ]] || die "OpenResty nginx.conf not found: ${nginx_conf}"

    grep -Eq '^[[:space:]]*include[[:space:]]+conf/sites-enabled/\*;' "${nginx_conf}" || need_conf_include=1
    grep -Eq '^[[:space:]]*include[[:space:]]+sites-enabled/\*;' "${nginx_conf}" || need_local_include=1

    if [[ "${need_conf_include}" -eq 0 && "${need_local_include}" -eq 0 ]]; then
        info "OpenResty nginx.conf already includes sites-enabled."
        return
    fi

    info "Adding sites-enabled include to OpenResty http block..."
    backup_file "${nginx_conf}"
    tmp_file="$(mktemp)"

    awk -v add_conf="${need_conf_include}" -v add_local="${need_local_include}" '
        BEGIN { added = 0 }
        {
            print
            if (!added && $0 ~ /^[[:space:]]*http[[:space:]]*\{/) {
                if (add_conf == 1) print "    include conf/sites-enabled/*;"
                if (add_local == 1) print "    include sites-enabled/*;"
                added = 1
            }
        }
        END {
            if (!added) {
                exit 2
            }
        }
    ' "${nginx_conf}" > "${tmp_file}" || {
        rm -f "${tmp_file}"
        die "Could not find http { block in ${nginx_conf}."
    }

    install -m 0644 "${tmp_file}" "${nginx_conf}"
    rm -f "${tmp_file}"
}

ensure_openresty_worker_user() {
    local nginx_conf="${OPENRESTY_CONF}/nginx.conf"
    local tmp_file

    [[ -f "${nginx_conf}" ]] || die "OpenResty nginx.conf not found: ${nginx_conf}"

    if grep -Eq '^[[:space:]]*user[[:space:]]+www-data;' "${nginx_conf}"; then
        info "OpenResty worker user is already www-data."
        return
    fi

    info "Setting OpenResty worker user to www-data for PHP-FPM socket access..."
    backup_file "${nginx_conf}"
    tmp_file="$(mktemp)"

    awk '
        BEGIN { changed = 0; inserted = 0 }
        /^[[:space:]]*#?[[:space:]]*user[[:space:]]+/ && !changed {
            print "user www-data;"
            changed = 1
            next
        }
        /^[[:space:]]*events[[:space:]]*\{/ && !changed && !inserted {
            print "user www-data;"
            inserted = 1
        }
        { print }
    ' "${nginx_conf}" > "${tmp_file}"

    install -m 0644 "${tmp_file}" "${nginx_conf}"
    rm -f "${tmp_file}"
}

clear_managed_cf_ufw_rules() {
    mapfile -t rule_numbers < <(ufw status numbered | awk '/(restyfleet|openresty-manager)-cloudflare/ { gsub(/\[|\]/, "", $1); print $1 }' | sort -rn)
    local rule
    for rule in "${rule_numbers[@]:-}"; do
        [[ -n "${rule}" ]] && ufw --force delete "${rule}" >/dev/null
    done
}

clear_managed_ssh_ufw_rules() {
    mapfile -t rule_numbers < <(ufw status numbered | awk '/(restyfleet|openresty-manager)-ssh/ { gsub(/\[|\]/, "", $1); print $1 }' | sort -rn)
    local rule
    for rule in "${rule_numbers[@]:-}"; do
        [[ -n "${rule}" ]] && ufw --force delete "${rule}" >/dev/null
    done
}

configure_ufw() {
    if [[ -z "${ADMIN_IP}" ]]; then
        warn "ADMIN_IP is empty. UFW will not be enabled to avoid locking you out of SSH."
        warn "Edit ./config and set ADMIN_IP, then rerun init-vps.sh or configure UFW manually."
        return
    fi

    if [[ "${ADMIN_IP}" == "0.0.0.0/0" ]]; then
        warn "ADMIN_IP is 0.0.0.0/0. This exposes SSH to the whole IPv4 Internet."
        confirm "Continue with this unsafe SSH allow rule?" || die "Aborted because ADMIN_IP is unsafe."
    fi

    local tmpdir ip
    tmpdir="$(mktemp -d)"
    info "Fetching Cloudflare IP ranges for UFW rules..."
    curl -fsSL https://www.cloudflare.com/ips-v4 -o "${tmpdir}/ips-v4"
    curl -fsSL https://www.cloudflare.com/ips-v6 -o "${tmpdir}/ips-v6"

    ufw default deny incoming
    ufw default allow outgoing
    clear_managed_ssh_ufw_rules
    ufw allow from "${ADMIN_IP}" to any port "${SSH_PORT}" proto tcp comment "restyfleet-ssh"

    clear_managed_cf_ufw_rules
    while IFS= read -r ip; do
        [[ -z "${ip}" ]] && continue
        ufw allow from "${ip}" to any port 80 proto tcp comment "restyfleet-cloudflare"
        ufw allow from "${ip}" to any port 443 proto tcp comment "restyfleet-cloudflare"
    done < <(cat "${tmpdir}/ips-v4" "${tmpdir}/ips-v6")

    ufw --force enable
    rm -rf "${tmpdir}"
}

enable_services() {
    info "Enabling and starting services..."
    systemctl enable openresty
    systemctl start openresty
    systemctl enable php8.3-fpm
    systemctl start php8.3-fpm
    systemctl enable fail2ban
    systemctl start fail2ban
}

main() {
    require_root
    load_config
    check_ubuntu_version
    check_web_conflicts
    check_ports_free
    install_base_packages
    install_openresty_repo
    install_openresty
    install_php83
    create_directories
    install_lua_files
    ensure_openresty_worker_user
    ensure_nginx_conf_include

    info "Generating Cloudflare real IP snippet..."
    bash "${SCRIPT_DIR}/update-cf-ips.sh"

    enable_services
    configure_ufw

    openresty -t
    systemctl reload openresty

    cat <<EOF

OpenResty VPS initialization completed.

Next steps:
  1. Add Cloudflare DNS records for your domains and enable proxy.
  2. Create sites with: bash create-site.sh example.com php
  3. Replace placeholder certificates with Cloudflare Origin CA certificates.
  4. Keep Cloudflare SSL/TLS mode set to Full strict.
EOF
}

main "$@"
