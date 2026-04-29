# 由 update-cf-ips.sh 生成。
# 请不要手动修改；重新更新 Cloudflare IP 时会覆盖本文件。

real_ip_header CF-Connecting-IP;
real_ip_recursive on;

{{SET_REAL_IP_FROM}}
