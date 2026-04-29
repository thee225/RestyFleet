#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config"
TMPDIR_CLEANUP=""

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

    : "${OPENRESTY_CONF:=/usr/local/openresty/nginx/conf}"
}

backup_file() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a "${file}" "${file}.bak.${stamp}"
}

fetch_cloudflare_ips() {
    local tmpdir="$1"
    curl -fsSL https://www.cloudflare.com/ips-v4 -o "${tmpdir}/ips-v4"
    curl -fsSL https://www.cloudflare.com/ips-v6 -o "${tmpdir}/ips-v6"

    [[ -s "${tmpdir}/ips-v4" ]] || die "Cloudflare IPv4 列表为空。"
    [[ -s "${tmpdir}/ips-v6" ]] || die "Cloudflare IPv6 列表为空。"
}

write_realip_snippet() {
    local tmpdir="$1"
    local snippet="${OPENRESTY_CONF}/snippets/cloudflare-realip.conf"
    local tmp_snippet="${tmpdir}/cloudflare-realip.conf"
    local set_real_ip_file="${tmpdir}/set-real-ip.conf"

    mkdir -p "${OPENRESTY_CONF}/snippets"

    awk 'NF { print "set_real_ip_from " $0 ";" }' "${tmpdir}/ips-v4" "${tmpdir}/ips-v6" > "${set_real_ip_file}"

    if [[ -f "${SCRIPT_DIR}/templates/cloudflare-realip.conf.tpl" ]]; then
        awk -v repl_file="${set_real_ip_file}" '
            {
                if ($0 == "{{SET_REAL_IP_FROM}}") {
                    while ((getline line < repl_file) > 0) print line
                    close(repl_file)
                } else {
                    print
                }
            }
        ' "${SCRIPT_DIR}/templates/cloudflare-realip.conf.tpl" > "${tmp_snippet}"
    else
        {
            echo "# 由 update-cf-ips.sh 生成。"
            echo "real_ip_header CF-Connecting-IP;"
            echo "real_ip_recursive on;"
            cat "${set_real_ip_file}"
        } > "${tmp_snippet}"
    fi

    if [[ -f "${snippet}" ]] && cmp -s "${tmp_snippet}" "${snippet}"; then
        info "Cloudflare 真实 IP 配置片段已是最新。"
    else
        backup_file "${snippet}"
        install -m 0644 "${tmp_snippet}" "${snippet}"
        info "已更新 ${snippet}。"
    fi
}

ufw_is_active() {
    ufw status | grep -q '^Status: active'
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

update_ufw_rules() {
    local tmpdir="$1"
    local ip

    if ! command -v ufw >/dev/null 2>&1; then
        warn "未安装 UFW，仅更新 OpenResty 真实 IP 配置片段。"
        return
    fi

    if ! ufw_is_active; then
        warn "UFW 未启用，不添加防火墙规则，也不会自动启用 UFW。"
        return
    fi

    clear_managed_cf_ufw_rules

    while IFS= read -r ip; do
        [[ -z "${ip}" ]] && continue
        ufw allow from "${ip}" to any port 80 proto tcp comment "restyfleet-cloudflare"
        ufw allow from "${ip}" to any port 443 proto tcp comment "restyfleet-cloudflare"
    done < <(cat "${tmpdir}/ips-v4" "${tmpdir}/ips-v6")
}

reload_openresty_if_available() {
    if ! command -v openresty >/dev/null 2>&1; then
        warn "未找到 openresty 命令，跳过配置检查和重载。"
        return
    fi

    openresty -t

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet openresty; then
        systemctl reload openresty
    else
        warn "OpenResty 服务未运行；配置检查已通过，但没有重载服务。"
    fi
}

main() {
    require_root
    load_config

    local ipv4_count ipv6_count
    TMPDIR_CLEANUP="$(mktemp -d)"
    trap '[[ -n "${TMPDIR_CLEANUP:-}" ]] && rm -rf "${TMPDIR_CLEANUP}"' EXIT

    fetch_cloudflare_ips "${TMPDIR_CLEANUP}"
    ipv4_count="$(awk 'NF { count++ } END { print count + 0 }' "${TMPDIR_CLEANUP}/ips-v4")"
    ipv6_count="$(awk 'NF { count++ } END { print count + 0 }' "${TMPDIR_CLEANUP}/ips-v6")"

    write_realip_snippet "${TMPDIR_CLEANUP}"
    update_ufw_rules "${TMPDIR_CLEANUP}"
    reload_openresty_if_available

    echo "Cloudflare IP 更新完成：IPv4=${ipv4_count}, IPv6=${ipv6_count}。"
}

main "$@"
