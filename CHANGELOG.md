# 更新记录

## 1.0.0 - 2026-10-31

首个版本。

- 六项菜单：安装、新增、查看、删除、重启、卸载，交互对齐 `gost-lite.sh`
- 固定安装 realm v2.9.6 的 musl 静态二进制，按 x86_64 / aarch64 / armv7 / armv6 / mips / mipsel / mips64 / mips64el 选择资产
- 安装前先下载、解压并执行 `realm -v` 校验，通过后才替换旧文件；重装自动备份并恢复 `/etc/realm`
- `rawconf` 沿用 `nonencrypt/本地端口#目标地址#目标端口` 格式，可直接迁移 gost-lite 的明文规则
- 配置写入临时文件、校验 JSON 后原子替换，保留 `config.json.bak` 用于回滚
- 新增规则前检查 rawconf 重复端口和系统端口占用；重启后核对端口确实由 realm 监听，失败自动回滚
- 目标地址支持域名和 IPv6 字面量，重建时自动补方括号；混入其它类型规则时拒绝重建
- rawconf 末尾缺换行时自动补齐，坏行跳过并提示行号
