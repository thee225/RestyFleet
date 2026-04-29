#!/usr/bin/env bash
set -euo pipefail

die() {
    echo "错误：$*" >&2
    exit 1
}

info() {
    echo "[信息] $*"
}

usage() {
    cat <<'EOF'
用法：
  bash publish-zip.sh example.com 1.2.3.4 /path/to/example.com.zip
  bash publish-zip.sh example.com 1.2.3.4 /path/to/example.com.zip root 22

说明：
  该脚本在本地执行，会上传 zip 到 VPS，然后远程调用 /root/RestyFleet/deploy-zip.sh。

可选环境变量：
  RESTYFLEET_REMOTE_DIR="/root/RestyFleet"
  SSHPASS="你的 SSH 密码"

如果设置了 SSHPASS 且本机安装了 sshpass，脚本会自动使用 sshpass。
更推荐正式环境使用 SSH 密钥登录。
EOF
}

validate_domain() {
    local domain="$1"
    [[ "${domain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] \
        || die "域名格式无效：${domain}"
}

remote_shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

run_scp() {
    if [[ -n "${SSHPASS:-}" ]]; then
        command -v sshpass >/dev/null 2>&1 || die "已设置 SSHPASS，但本机未安装 sshpass。"
        sshpass -e scp "$@"
    else
        scp "$@"
    fi
}

run_ssh() {
    if [[ -n "${SSHPASS:-}" ]]; then
        command -v sshpass >/dev/null 2>&1 || die "已设置 SSHPASS，但本机未安装 sshpass。"
        sshpass -e ssh "$@"
    else
        ssh "$@"
    fi
}

main() {
    if [[ "$#" -lt 3 || "$#" -gt 5 ]]; then
        usage
        exit 1
    fi

    local domain host zip_file ssh_user ssh_port remote_dir remote_zip remote_target remote_cmd
    domain="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    host="$2"
    zip_file="$3"
    ssh_user="${4:-root}"
    ssh_port="${5:-22}"
    remote_dir="${RESTYFLEET_REMOTE_DIR:-/root/RestyFleet}"
    remote_zip="/tmp/restyfleet-${domain}-$(date +%Y%m%d-%H%M%S).zip"
    remote_target="${ssh_user}@${host}"

    validate_domain "${domain}"
    [[ -f "${zip_file}" ]] || die "本地 zip 文件不存在：${zip_file}"

    info "正在上传 zip 到 ${host}:${remote_zip}..."
    run_scp -P "${ssh_port}" -o StrictHostKeyChecking=accept-new "${zip_file}" "${remote_target}:${remote_zip}"

    remote_cmd="cd $(remote_shell_quote "${remote_dir}") && bash deploy-zip.sh $(remote_shell_quote "${domain}") $(remote_shell_quote "${remote_zip}")"

    info "正在远程部署 ${domain}..."
    run_ssh -p "${ssh_port}" -o StrictHostKeyChecking=accept-new "${remote_target}" "${remote_cmd}"

    cat <<EOF

发布完成：${domain}

远程文件：
  ${remote_zip}

测试：
  curl -I https://${domain}
EOF
}

main "$@"
