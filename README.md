# EasyRealm

realm 一键管理脚本的精简版，只做 **TCP + UDP 不加密流量转发**。

交互和文件布局对齐 [Multi-EasyGost](https://github.com/Gaslys/Multi-EasyGost) 里的 `gost-lite.sh`：同样的六项菜单、同样的 `rawconf` 规则格式，配置目录换成 `/etc/realm`。适合只需要端口转发、不想碰证书和加密协议的场景。

## 功能

- 一键安装 [zhboner/realm](https://github.com/zhboner/realm) v2.9.6（musl 静态二进制），校验 SHA256 后安装，systemd 托管
- 新增、查看、删除转发规则，TCP 与 UDP 同时转发；删除单条前会显示规则并确认
- 改完自动重建配置并重启；起不来自动回滚到上一份配置
- 新增前检查端口占用；realm 绑不上端口时进程不会退出，脚本会进一步核对端口确实由 realm 监听
- 目标地址支持域名和 IPv6 字面量
- 重装保留 `/etc/realm` 下的其它文件，并恢复 rawconf 与 config.json；卸载需要二次确认

## 使用

需要 root 权限和 systemd。安装依赖 wget 或 curl、tar、gzip；端口校验依赖 iproute2 的 `ss`，缺少时脚本会尝试安装。

```shell
bash <(curl -fsSL https://raw.githubusercontent.com/Gaslys/EasyRealm/main/realm-lite.sh)
```

也可以下载后执行：

```shell
chmod +x realm-lite.sh
./realm-lite.sh
```

菜单：

```text
1 安装   2 新增   3 查看   4 删除   5 重启   6 卸载   0 退出
```

安装时会从 GitHub Releases 下载对应架构的二进制，先校验 SHA256 和版本号，通过后才替换旧文件。重装会备份 `/etc/realm`，恢复 `rawconf` 和 `config.json`，再按 rawconf 重建配置并核对端口；启动失败时保留备份，不会把原配置直接删掉。

## 文件

| 路径 | 说明 |
| --- | --- |
| `/usr/bin/realm` | realm 二进制 |
| `/etc/realm/config.json` | 由 rawconf 生成的 realm 配置，权限 0600 |
| `/etc/realm/rawconf` | 规则源文件，每行一条 |
| `/etc/realm/config.json.bak` | 上一份配置，重启失败时回滚用 |
| `/etc/realm/rawconf.bak` | 删光规则时保留的规则副本 |
| `/usr/lib/systemd/system/realm.service` | systemd unit |

`rawconf` 每行一条，格式同 `gost-lite.sh`：

```text
nonencrypt/本地端口#目标地址#目标端口
```

例如 `nonencrypt/8080#1.2.3.4#443`，表示本机 8080 的 TCP、UDP 都转发到 `1.2.3.4:443`。IPv6 写成 `nonencrypt/8080#[2001:db8::1]#443`。

迁移时把 `/etc/gost/rawconf` 的 `nonencrypt` 行复制到 `/etc/realm/rawconf`，执行菜单 5。混有 `ss`、`tls` 等类型时，脚本会拒绝重建，避免写丢。

## 支持架构

x86_64、aarch64、armv7、armv6、mips、mipsel、mips64、mips64el。

realm 官方没有 32 位 x86 和 armv5 的 Linux 构建，遇到这两种架构脚本会直接报错，不会装上一个跑不起来的二进制。

## 说明

- 只做明文转发，不含 TLS / WS / 负载均衡 / 证书。需要这些功能请直接写 realm 原版配置，或使用 gost 完整版。
- 系统启用 IPv6 时监听地址用 `[::]`（同时接收 IPv4 和 IPv6），否则退回 `0.0.0.0`。
- 安装后的默认配置只在 `127.0.0.1:65532` 放一个占位监听，用来让服务能正常启动；新增第一条规则时整份配置会被替换。
- 删除最后一条规则会停止服务并取消开机启动，旧配置留作 `config.json.bak`，规则留作 `rawconf.bak`；下次新增规则会自动恢复开机启动。
- 端口是否由 realm 监听依赖 `ss`（iproute2）判断；安装时检测到 `ss` 缺失或不可用会尝试安装 iproute2。老版本 iproute2 不支持 `ss -H` 时会回退到去表头解析，CentOS 7 这类系统也能正常校验。

## 卸载

菜单 6，会停止并删除 realm、`/etc/realm` 下的全部文件（包括你自己放进去的文件）和 systemd unit。卸载前请确认没有别的程序还在使用这些转发端口。

## 许可

[GPL-3.0](LICENSE)。

交互设计和部分实现参考 [KANIKIG/Multi-EasyGost](https://github.com/KANIKIG/Multi-EasyGost) 的 `gost-lite.sh`（GPL-3.0），realm 本身由 [zhboner](https://github.com/zhboner/realm) 开发，本仓库只包含管理脚本。
