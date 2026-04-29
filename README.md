# RestyFleet

`RestyFleet` 是一套多 VPS 站群源站部署脚本，面向统一接入 Cloudflare 的 OpenResty + PHP 8.3-FPM 环境。

它不使用宝塔、1Panel、aaPanel、CloudPanel 或其他 Web 面板；不安装普通 `nginx` 包；OpenResty 使用官方 APT 仓库安装，PHP 8.3-FPM 使用 Ubuntu 24.04 官方 apt 仓库安装。

## 项目用途

- 多 VPS 站群源站初始化。
- OpenResty + PHP 8.3-FPM 站点配置生成。
- Cloudflare 统一接入，源站使用 Cloudflare Origin CA 证书。
- Cloudflare SSL/TLS 模式使用 `Full strict`。
- 源站 `80/443` 只允许 Cloudflare IP 回源访问。
- SSH 只允许 `ADMIN_IP` 访问。
- 支持站点类型：`static`、`php`、`wordpress`、`static-device`、`php-device`、`lua-gateway`。

## 系统建议

- 推荐 Ubuntu 24.04 LTS。
- 推荐 PHP 8.3。
- OpenResty 官方 APT 仓库支持 Ubuntu 24.04 Noble 的 `amd64` 和 `arm64` 架构，脚本会按架构选择仓库路径。
- 如果老程序不兼容 PHP 8.3，可以单独创建老 PHP 兼容池，不建议默认使用 PHP 7.4。

## 安装步骤

上传项目到 VPS 后进入目录：

```bash
cd RestyFleet
cp config.example config
nano config
```

至少设置：

```bash
ADMIN_IP="你的管理IP/32"
SSH_PORT="22"
```

然后执行：

```bash
bash init-vps.sh
```

如果 `ADMIN_IP` 为空，脚本不会自动启用 UFW，避免锁死 SSH。设置了 `ADMIN_IP` 后，脚本会在启用 UFW 前显示当前 SSH 来源 IP，并要求输入 `YES` 确认；批量自动化部署时可以在确认无误后设置 `UFW_CONFIRM_ENABLE="0"`。

默认会执行 `apt upgrade -y`。如果你的系统镜像已经提前更新，可以设置 `SKIP_APT_UPGRADE="1"` 跳过完整升级。

## 新增站点

```bash
bash create-site.sh example.com static
bash create-site.sh example.com php
bash create-site.sh example.com wordpress
bash create-site.sh example.com static-device
bash create-site.sh example.com php-device
bash create-site.sh example.com lua-gateway
```

`wordpress` 类型只创建目录和 OpenResty 配置，不自动下载 WordPress。

## Cloudflare 配置

1. DNS 添加 A 记录，指向对应 VPS IP。
2. 开启代理小云朵。
3. SSL/TLS 模式选择 `Full strict`。
4. 使用 Cloudflare Origin CA 证书替换站点 SSL 目录里的 `cert.pem` 和 `key.pem`。

## 替换证书

站点证书路径：

```bash
/usr/local/openresty/nginx/conf/ssl/example.com/cert.pem
/usr/local/openresty/nginx/conf/ssl/example.com/key.pem
```

替换后执行：

```bash
openresty -t
systemctl reload openresty
```

`create-site.sh` 在证书不存在时会生成自签名占位证书，只用于避免 OpenResty 因证书文件缺失而启动失败。正式环境必须替换为 Cloudflare Origin CA 证书。

## 测试命令

```bash
openresty -t
systemctl status openresty
systemctl status php8.3-fpm
curl -I https://example.com
tail -f /usr/local/openresty/nginx/logs/example.com.access.log
ufw status
```

## 日常使用流程

新 VPS：

```bash
bash init-vps.sh
```

新站点：

```bash
bash create-site.sh domain.com php
```

更新 Cloudflare IP：

```bash
bash update-cf-ips.sh
```

备份站点：

```bash
bash backup-site.sh domain.com
```

部署 zip 包到站点：

```bash
# 在 VPS 上执行
bash deploy-zip.sh domain.com /tmp/domain.com.zip
```

从本地上传 zip 并远程部署：

```bash
# 在本地电脑执行
bash publish-zip.sh domain.com VPS_IP /path/to/domain.com.zip
```

如果本地使用 SSH 密码登录，可以临时配合 `sshpass`：

```bash
SSHPASS="你的SSH密码" bash publish-zip.sh domain.com VPS_IP /path/to/domain.com.zip
```

正式环境更推荐使用 SSH 密钥登录，不建议把密码写进脚本或仓库。

检查配置并重载：

```bash
openresty -t
systemctl reload openresty
```

## 安全说明

- `80/443` 只允许 Cloudflare IP。
- SSH 只允许 `ADMIN_IP`。
- 不开放数据库端口。
- 不安装 Web 面板。
- 不安装普通 `nginx`。
- 不要把自签名占位证书用于正式环境。
- `ADMIN_IP` 为空时不会启用 UFW，避免锁死 SSH。
- `UFW_CONFIRM_ENABLE="1"` 时，启用 UFW 前必须手动输入 `YES`。
- `CHOWN_SITE_ROOT="0"` 时，`create-site.sh` 只调整脚本新建占位文件的所有权，不递归改动已有业务文件。
- 正式环境建议使用 SSH 密钥登录，关闭密码登录可作为后续增强项。

## 配置文件

复制 `config.example` 为 `config` 后编辑：

```bash
ADMIN_IP=""
SSH_PORT="22"
WEB_ROOT="/www/wwwroot"
BACKUP_ROOT="/backup"
OPENRESTY_CONF="/usr/local/openresty/nginx/conf"
OPENRESTY_LUA="/usr/local/openresty/nginx/lua"
PHP_FPM_SOCK="/run/php/php8.3-fpm.sock"
DEFAULT_EMAIL="admin@example.com"
SKIP_APT_UPGRADE="0"
UFW_CONFIRM_ENABLE="1"
CHOWN_SITE_ROOT="0"
```

配置项说明：

- `SKIP_APT_UPGRADE="0"`：默认更新系统包；设为 `1` 时只执行 `apt update` 和必要软件安装。
- `UFW_CONFIRM_ENABLE="1"`：默认启用 UFW 前要求输入 `YES`；设为 `0` 可用于确认过来源 IP 的自动化部署。
- `CHOWN_SITE_ROOT="0"`：默认只 `chown` 脚本新建的占位目录/文件；设为 `1` 会递归 `chown -R` 整个站点目录。

## 目录结构

```text
RestyFleet/
  README.md
  config.example
  init-vps.sh
  create-site.sh
  deploy-zip.sh
  publish-zip.sh
  update-cf-ips.sh
  backup-site.sh
  templates/
  lua/
  examples/
```
