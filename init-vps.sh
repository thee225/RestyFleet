#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"

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

    : "${ADMIN_IP:=}"
    : "${SSH_PORT:=22}"
    : "${WEB_ROOT:=/www/wwwroot}"
    : "${BACKUP_ROOT:=/backup}"
    : "${OPENRESTY_CONF:=/usr/local/openresty/nginx/conf}"
    : "${OPENRESTY_LUA:=/usr/local/openresty/nginx/lua}"
    : "${PHP_FPM_SOCK:=/run/php/php8.3-fpm.sock}"
    : "${DEFAULT_EMAIL:=admin@example.com}"
    : "${SKIP_APT_UPGRADE:=0}"
    : "${UFW_CONFIRM_ENABLE:=1}"
}

backup_file() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a "${file}" "${file}.bak.${stamp}"
}

check_ubuntu_version() {
    [[ -r /etc/os-release ]] || die "未找到 /etc/os-release，无法检测系统版本。"
    # shellcheck source=/dev/null
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
        warn "检测到系统为 ${PRETTY_NAME:-未知系统}；本项目默认面向 Ubuntu 24.04 LTS。"
        confirm "仍然继续吗？" || die "已停止：当前系统不是 Ubuntu 24.04。"
    fi
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

check_web_conflicts() {
    if pkg_installed nginx; then
        warn "检测到已安装 nginx 包。OpenResty 可能与普通 nginx 包冲突。"
        confirm "我已手动确认该冲突，并仍要继续" || die "请先卸载或处理 nginx 冲突。"
    fi

    if pkg_installed apache2; then
        warn "检测到已安装 apache2，可能占用 80/443 端口。"
        confirm "我已手动确认该冲突，并仍要继续" || die "请先卸载或处理 apache2 冲突。"
    fi
}

check_ports_free() {
    if ! command -v ss >/dev/null 2>&1; then
        warn "未找到 ss 命令，跳过端口预检查。"
        return
    fi

    local occupied
    occupied="$(ss -ltnp '( sport = :80 or sport = :443 )' || true)"
    if echo "${occupied}" | awk 'NR > 1 { found=1 } END { exit !found }'; then
        if pkg_installed openresty && ! pkg_installed nginx \
            && ! echo "${occupied}" | awk 'NR > 1 && $0 !~ /(openresty|nginx)/ { bad=1 } END { exit !bad }'; then
            info "80/443 端口已由 OpenResty 使用，按重复执行场景继续。"
            return
        fi
        echo "${occupied}" >&2
        die "80 或 443 端口已被占用。请先停止占用进程，再安装 OpenResty。"
    fi
}

install_base_packages() {
    info "正在更新 apt 软件包索引..."
    apt update

    if [[ "${SKIP_APT_UPGRADE}" == "1" ]]; then
        warn "SKIP_APT_UPGRADE=1，跳过 apt upgrade。"
    else
        info "正在升级已安装的软件包..."
        DEBIAN_FRONTEND=noninteractive apt upgrade -y
    fi

    info "正在安装基础工具..."
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
            die "OpenResty 官方 Ubuntu 仓库不支持当前架构：${arch}"
            ;;
    esac

    repo_line="deb [arch=${arch} signed-by=${keyring}] ${repo_base} ${codename} main"

    info "正在添加 OpenResty 官方 APT 仓库..."
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
    info "正在安装 OpenResty..."
    DEBIAN_FRONTEND=noninteractive apt install -y openresty
}

install_php83() {
    info "正在从 Ubuntu 官方仓库安装 PHP 8.3-FPM 和常用扩展..."
    DEBIAN_FRONTEND=noninteractive apt install -y \
        php8.3-fpm php8.3-cli php8.3-common php8.3-mysql php8.3-curl \
        php8.3-xml php8.3-mbstring php8.3-zip php8.3-gd php8.3-opcache \
        php8.3-bcmath php8.3-intl
}

create_directories() {
    info "正在创建 OpenResty、站点、备份、snippet、SSL 和 Lua 目录..."
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
    info "正在安装 Lua 辅助文件..."
    install -m 0644 "${SCRIPT_DIR}/lua/"*.lua "${OPENRESTY_LUA}/"
}

ensure_nginx_conf_include() {
    local nginx_conf="${OPENRESTY_CONF}/nginx.conf"
    local tmp_file need_conf_include=0 need_local_include=0

    [[ -f "${nginx_conf}" ]] || die "未找到 OpenResty nginx.conf：${nginx_conf}"

    grep -Eq '^[[:space:]]*include[[:space:]]+conf/sites-enabled/\*;' "${nginx_conf}" || need_conf_include=1
    grep -Eq '^[[:space:]]*include[[:space:]]+sites-enabled/\*;' "${nginx_conf}" || need_local_include=1

    if [[ "${need_conf_include}" -eq 0 && "${need_local_include}" -eq 0 ]]; then
        info "OpenResty nginx.conf 已包含 sites-enabled。"
        return
    fi

    info "正在向 OpenResty http 区块添加 sites-enabled include..."
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
        die "未能在 ${nginx_conf} 中找到 http { 区块。"
    }

    install -m 0644 "${tmp_file}" "${nginx_conf}"
    rm -f "${tmp_file}"
}

ensure_openresty_worker_user() {
    local nginx_conf="${OPENRESTY_CONF}/nginx.conf"
    local tmp_file

    [[ -f "${nginx_conf}" ]] || die "未找到 OpenResty nginx.conf：${nginx_conf}"

    if grep -Eq '^[[:space:]]*user[[:space:]]+www-data;' "${nginx_conf}"; then
        info "OpenResty worker 用户已是 www-data。"
        return
    fi

    info "正在将 OpenResty worker 用户设置为 www-data，以便访问 PHP-FPM socket..."
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

managed_ufw_rule_numbers() {
    local pattern="$1"
    ufw status numbered | awk -v pattern="${pattern}" '
        $0 ~ pattern && match($0, /^\[[[:space:]]*[0-9]+\]/) {
            rule = substr($0, RSTART, RLENGTH)
            gsub(/[^0-9]/, "", rule)
            print rule
        }
    ' | sort -rn
}

clear_managed_cf_ufw_rules() {
    mapfile -t rule_numbers < <(managed_ufw_rule_numbers '(restyfleet|openresty-manager)-cloudflare')
    local rule
    for rule in "${rule_numbers[@]:-}"; do
        [[ -n "${rule}" ]] && ufw --force delete "${rule}" >/dev/null
    done
}

clear_managed_ssh_ufw_rules() {
    mapfile -t rule_numbers < <(managed_ufw_rule_numbers '(restyfleet|openresty-manager)-ssh')
    local rule
    for rule in "${rule_numbers[@]:-}"; do
        [[ -n "${rule}" ]] && ufw --force delete "${rule}" >/dev/null
    done
}

current_ssh_source_ip() {
    if [[ -n "${SSH_CLIENT:-}" ]]; then
        awk '{ print $1 }' <<<"${SSH_CLIENT}"
    elif [[ -n "${SSH_CONNECTION:-}" ]]; then
        awk '{ print $1 }' <<<"${SSH_CONNECTION}"
    else
        echo ""
    fi
}

confirm_ufw_enable() {
    local ssh_source admin_host answer
    ssh_source="$(current_ssh_source_ip)"
    admin_host="${ADMIN_IP%/*}"

    echo
    warn "即将启用 UFW。"
    warn "SSH 放行规则：ADMIN_IP=${ADMIN_IP}, SSH_PORT=${SSH_PORT}"
    if [[ -n "${ssh_source}" ]]; then
        warn "从 SSH_CLIENT/SSH_CONNECTION 检测到当前 SSH 来源 IP：${ssh_source}"
        if [[ "${ssh_source}" != "${admin_host}" ]]; then
            warn "当前 SSH 来源 IP 与 ADMIN_IP 主机部分（${admin_host}）不完全一致。"
            warn "如果 ADMIN_IP 不是包含当前来源的 CIDR 网段，SSH 可能会被锁定。"
        fi
    else
        warn "无法检测当前 SSH 来源 IP，建议确认你有控制台或服务商救援通道。"
    fi

    if [[ "${UFW_CONFIRM_ENABLE}" == "0" ]]; then
        warn "UFW_CONFIRM_ENABLE=0，将不再交互确认，直接启用 UFW。"
        return
    fi

    read -r -p "请输入 YES 以启用 UFW：" answer
    [[ "${answer}" == "YES" ]] || die "已停止：未启用 UFW。"
}

configure_ufw() {
    if [[ -z "${ADMIN_IP}" ]]; then
        warn "ADMIN_IP 为空。为避免锁死 SSH，本次不会启用 UFW。"
        warn "请编辑 ./config 设置 ADMIN_IP，然后重新执行 init-vps.sh，或手动配置 UFW。"
        return
    fi

    if [[ "${ADMIN_IP}" == "0.0.0.0/0" ]]; then
        warn "ADMIN_IP 为 0.0.0.0/0，这会把 SSH 暴露给整个 IPv4 互联网。"
        confirm "仍要使用这个不安全的 SSH 放行规则吗？" || die "已停止：ADMIN_IP 不安全。"
    fi

    local tmpdir ip
    tmpdir="$(mktemp -d)"
    info "正在获取 Cloudflare IP 段，用于生成 UFW 规则..."
    curl -fsSL https://www.cloudflare.com/ips-v4 -o "${tmpdir}/ips-v4"
    curl -fsSL https://www.cloudflare.com/ips-v6 -o "${tmpdir}/ips-v6"

    confirm_ufw_enable
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
    info "正在启用并启动服务..."
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

    info "正在生成 Cloudflare 真实 IP 配置片段..."
    bash "${SCRIPT_DIR}/update-cf-ips.sh"

    enable_services
    configure_ufw

    openresty -t
    systemctl reload openresty

    cat <<EOF

OpenResty VPS 初始化完成。

下一步：
  1. 在 Cloudflare 为域名添加 DNS 记录，并开启代理小云朵。
  2. 创建站点：bash create-site.sh example.com php
  3. 将占位证书替换为 Cloudflare Origin CA 证书。
  4. Cloudflare SSL/TLS 模式保持 Full strict。
EOF
}

main "$@"
