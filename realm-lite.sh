#!/bin/bash
# realm 精简版: 只做 tcp+udp 不加密流量转发
# 配置目录 /etc/realm, 规则文件 rawconf 与 gost-lite 格式相同(nonencrypt/本地端口#目标地址#目标端口)
Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Warn="${Red_font_prefix}[警告]${Font_color_suffix}"
Cyan_font_prefix="\033[36m"
Bold="\033[1m"
shell_version="1.0.0"
realm_new_ver="2.9.6"
realm_conf_path="/etc/realm/config.json"
raw_conf_path="/etc/realm/rawconf"

function die() {
  echo -e "${Error} $*" >&2
  exit 1
}
function warn() {
  echo -e "${Warn} $*" >&2
}

function json_ok() {
  local f="$1"
  [[ -s ${f} ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq empty "${f}" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${f}" >/dev/null 2>&1
  else
    grep -q '"endpoints"' "${f}" && tail -c 3 "${f}" | grep -q "}"
  fi || return 1
  grep -q '"endpoints"' "${f}"
}

function check_root() {
  [[ $EUID != 0 ]] && echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_background_prefix}sudo su${Font_color_suffix} 命令获取临时ROOT权限（执行后可能会提示输入当前账号的密码）。" && exit 1
}

function set_asset() {
  case "$1" in
  x86_64 | amd64) realm_asset="x86_64-unknown-linux-musl" ;;
  aarch64 | arm64) realm_asset="aarch64-unknown-linux-musl" ;;
  armv7l | armv7) realm_asset="armv7-unknown-linux-musleabihf" ;;
  armv6l | armv6) realm_asset="arm-unknown-linux-musleabihf" ;;
  mips) realm_asset="mips-unknown-linux-musl" ;;
  mipsel) realm_asset="mipsel-unknown-linux-musl" ;;
  mips64) realm_asset="mips64-unknown-linux-muslabi64" ;;
  mips64el) realm_asset="mips64el-unknown-linux-muslabi64" ;;
  *) return 1 ;;
  esac
}

function check_sys() {
  local arch
  arch=$(uname -m)
  set_asset "${arch}" && return 0
  case "${arch}" in
  i386 | i486 | i586 | i686)
    die "realm 官方没有 32 位 x86 的 Linux 构建，当前架构 ${arch} 无法安装"
    ;;
  armv5l | armv5*)
    die "realm 官方不提供 armv5 构建，当前架构 ${arch} 无法安装"
    ;;
  esac
  echo "无法识别当前架构 ${arch}，请输入芯片架构，/x86_64/aarch64/armv7/armv6/mips/mipsel/mips64/mips64el"
  read -r arch
  set_asset "${arch}" || die "不支持的架构: ${arch}"
}

# 下载失败直接中止, 不再降级为跳过证书校验重试
function download() {
  local url="$1" dest="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=20 -O "${dest}" "${url}" && return 0
    warn "下载失败（网络不通或证书校验未通过），已中止，未改动现有安装"
    return 1
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 180 -o "${dest}" "${url}" && return 0
    warn "下载失败（网络不通或证书校验未通过），已中止，未改动现有安装"
    return 1
  fi
  return 1
}

function Installation_dependency() {
  local -a pkgs=()
  command -v wget >/dev/null 2>&1 || pkgs+=(wget)
  command -v tar >/dev/null 2>&1 || pkgs+=(tar)
  command -v gzip >/dev/null 2>&1 || pkgs+=(gzip)
  ((${#pkgs[@]})) || return 0
  echo -e "${Info} 缺少依赖: ${pkgs[*]}，正在安装 ..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${pkgs[@]}"
  else
    die "未找到可用的包管理器，请手动安装: ${pkgs[*]}"
  fi || die "依赖安装失败，请手动安装: ${pkgs[*]}"
}

function check_file() {
  [[ -d /usr/lib/systemd/system ]] || mkdir -p /usr/lib/systemd/system || die "无法创建 /usr/lib/systemd/system，当前系统可能没有 systemd"
}

function check_nor_file() {
  rm -f /usr/bin/realm
  rm -f /usr/lib/systemd/system/realm.service
  rm -rf /etc/realm
}

# 先下载、解压、跑 realm -v 校验, 全部通过后才动旧文件
function Install_ct() {
  check_root
  Installation_dependency
  check_file
  check_sys

  local bin_url tmpdir backup_dir="" ans
  bin_url="https://github.com/zhboner/realm/releases/download/v${realm_new_ver}/realm-${realm_asset}.tar.gz"

  if [[ -x /usr/bin/realm || -f /usr/lib/systemd/system/realm.service || -d /etc/realm ]]; then
    echo -e "${Warn} 检测到已安装的 realm：将替换二进制与 unit，现有转发配置会保留"
    read -r -p "是否继续重装？[y/N]:" ans
    [[ ${ans} == [Yy] ]] || {
      echo "已取消"
      return 1
    }
    backup_dir=$(mktemp -d "${HOME:-/root}/.realm-backup.XXXXXX") || die "无法创建备份目录"
    if [[ -d /etc/realm ]]; then
      cp -a /etc/realm/. "${backup_dir}/" || die "备份 /etc/realm 失败，已中止安装"
    fi
  fi

  tmpdir=$(mktemp -d "${HOME:-/root}/.realm-install.XXXXXX") || die "无法创建临时目录"
  echo -e "${Info} 正在下载 realm v${realm_new_ver} (${realm_asset}) ..."
  if ! download "${bin_url}" "${tmpdir}/realm.tar.gz"; then
    rm -rf "${tmpdir}"
    [[ -n ${backup_dir} ]] && rm -rf "${backup_dir}"
    die "realm 下载失败，现有安装未改动"
  fi
  if ! tar -xzf "${tmpdir}/realm.tar.gz" -C "${tmpdir}"; then
    rm -rf "${tmpdir}"
    [[ -n ${backup_dir} ]] && rm -rf "${backup_dir}"
    die "realm 解压失败，下载内容可能已损坏，现有安装未改动"
  fi
  [[ -f "${tmpdir}/realm" ]] || {
    rm -rf "${tmpdir}"
    [[ -n ${backup_dir} ]] && rm -rf "${backup_dir}"
    die "压缩包里没有 realm 可执行文件，现有安装未改动"
  }
  chmod 0755 "${tmpdir}/realm"
  if ! "${tmpdir}/realm" -v 2>&1 | grep -qF "${realm_new_ver}"; then
    rm -rf "${tmpdir}"
    [[ -n ${backup_dir} ]] && rm -rf "${backup_dir}"
    die "下载的 realm 无法运行或版本不符（可能被篡改、不完整，或架构选择错误），已中止安装，现有安装未改动"
  fi

  check_nor_file

  cat >"${tmpdir}/realm.service" <<'UNIT'
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5
LimitNOFILE=65535
ExecStart=/usr/bin/realm -c /etc/realm/config.json

[Install]
WantedBy=multi-user.target
UNIT
  cat >"${tmpdir}/config.json" <<'CONF'
{
    "log": {
        "level": "warn",
        "output": "stdout"
    },
    "network": {
        "no_tcp": false,
        "use_udp": true
    },
    "endpoints": [
        {
            "listen": "127.0.0.1:65532",
            "remote": "127.0.0.1:65533"
        }
    ]
}
CONF

  install -m 0755 "${tmpdir}/realm" /usr/bin/realm || { rm -rf "${tmpdir}"; die "安装 realm 二进制失败，原配置备份在 ${backup_dir:-无}"; }
  install -m 0644 "${tmpdir}/realm.service" /usr/lib/systemd/system/realm.service || { rm -rf "${tmpdir}"; die "安装 service 文件失败，原配置备份在 ${backup_dir:-无}"; }
  mkdir -p /etc/realm && chmod 0700 /etc/realm
  install -m 0644 "${tmpdir}/config.json" /etc/realm/config.json || { rm -rf "${tmpdir}"; die "安装默认配置失败，原配置备份在 ${backup_dir:-无}"; }

  if [[ -n ${backup_dir} ]]; then
    if [[ -f "${backup_dir}/rawconf" ]]; then
      install -m 0644 "${backup_dir}/rawconf" "${raw_conf_path}" || warn "恢复 rawconf 失败"
      [[ -f "${backup_dir}/config.json" ]] && { install -m 0600 "${backup_dir}/config.json" "${realm_conf_path}" || warn "恢复 config.json 失败"; }
      echo -e "${Info} 已恢复原有转发配置"
    elif [[ -f "${backup_dir}/config.json" ]]; then
      # 没有 rawconf 说明这份配置不是本脚本写的, 原样保留, 不能拿默认配置覆盖
      install -m 0600 "${backup_dir}/config.json" "${realm_conf_path}" || warn "恢复 config.json 失败"
      warn "没有找到 ${raw_conf_path}，已保留原 config.json；脚本暂时无法列出这些规则"
    fi
  fi

  [[ -n ${backup_dir} ]] && rm -rf "${backup_dir}"
  rm -rf "${tmpdir}"

  systemctl daemon-reload
  systemctl enable realm >/dev/null 2>&1
  systemctl restart realm
  sleep 1
  echo "------------------------------"
  if [[ -x /usr/bin/realm && -f /usr/lib/systemd/system/realm.service && -f /etc/realm/config.json ]] && systemctl is-active --quiet realm; then
    echo "realm安装成功"
  else
    echo "realm没有安装成功，请执行 systemctl status realm 及 journalctl -u realm -n 50 查看原因"
  fi
}

function Uninstall_ct() {
  check_root
  local ans
  echo -e "${Warn} 即将停止并删除 realm、/etc/realm 下的全部转发配置"
  read -r -p "确认卸载？[y/N]:" ans
  [[ ${ans} == [Yy] ]] || {
    echo "已取消"
    return 1
  }
  systemctl stop realm >/dev/null 2>&1
  systemctl disable realm >/dev/null 2>&1
  rm -f /usr/bin/realm
  rm -f /usr/lib/systemd/system/realm.service
  rm -rf /etc/realm
  systemctl daemon-reload
  echo "realm已经成功删除"
}

# 主机拼进配置前的统一处理: IPv6 字面量要加方括号, 否则 "地址:端口" 会有歧义
# 顺带挡掉"把 IP:端口 填进地址栏"这种常见错误(冒号只有一个且不是 IPv6)
function uri_host() {
  local h="$1" colons
  [[ ${h} == \[*\] ]] && {
    printf '%s' "${h}"
    return 0
  }
  [[ ${h} != *:* ]] && {
    printf '%s' "${h}"
    return 0
  }
  [[ ${h} =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
  colons=${h//[^:]/}
  (( ${#colons} >= 2 )) || return 1
  printf '[%s]' "${h}"
}

# 判断是不是 IPv6 字面量(可带方括号), 用于校验手改的 rawconf
function is_ipv6_host() {
  local h="$1" colons
  h=${h//[\[\]]/}
  [[ ${h} =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
  colons=${h//[^:]/}
  (( ${#colons} >= 2 ))
}

function norm_host() {
  local h="$1"
  if [[ ${h} == \[*\] ]]; then
    printf '%s' "${h}"
  elif [[ ${h} == *:* ]]; then
    printf '[%s]' "${h}"
  else
    printf '%s' "${h}"
  fi
}

# 监听地址: 系统开着 IPv6 时用 [::] 同时收 v4/v6(内核默认 v4-mapped), 否则退回 0.0.0.0
function listen_host() {
  local f=/proc/sys/net/ipv6/conf/all/disable_ipv6
  if [[ -r ${f} && $(cat "${f}" 2>/dev/null) == "0" ]]; then
    printf '[::]'
  else
    printf '0.0.0.0'
  fi
}

function valid_port() {
  local v="$1" label="$2"
  [[ ${v} =~ ^[0-9]+$ ]] || die "${label}必须是 1-65535 的数字"
  ((10#${v} >= 1 && 10#${v} <= 65535)) || die "${label}必须是 1-65535 的数字"
}
function valid_host() {
  local v="$1" label="$2"
  [[ -n ${v} ]] || die "${label}不能为空"
  [[ ${v} != *[[:space:]]* && ${v} != *'"'* && ${v} != *\\* && ${v} != *'#'* && ${v} != *'@'* && ${v} != */* && ${v} != *'?'* && ${v} != *'%'* ]] ||
    die "${label}不能包含空格、引号、反斜杠、#、@、/、?、%"
}

# 解析一行 rawconf: nonencrypt/本地端口#目标IP#目标端口
# 返回 0 正常, 1 行无效, 2 是别的规则类型(gost 完整版脚本写的)
function parse_rule() {
  local line="${1%$'\r'}" f1 host dport extra
  [[ -z ${line//[[:space:]]/} ]] && return 1
  IFS='#' read -r f1 host dport extra <<<"${line}"
  r_type=${f1%%/*}
  if [[ ${r_type} != "nonencrypt" ]]; then
    # 只有形如 ss/xxx#...#... 的才算完整版的规则, 其余一律当坏行
    [[ ${line} == *"#"*"#"* ]] && return 2
    return 1
  fi
  [[ -n ${extra} ]] && return 1
  r_sport=${f1#*/}
  r_dhost=${host}
  r_dport=${dport}
  [[ ${r_sport} =~ ^[0-9]+$ && ${r_dport} =~ ^[0-9]+$ ]] || return 1
  ((10#${r_sport} >= 1 && 10#${r_sport} <= 65535)) || return 1
  ((10#${r_dport} >= 1 && 10#${r_dport} <= 65535)) || return 1
  [[ -n ${r_dhost} ]] || return 1
  [[ ${r_dhost} != *[[:space:]]* && ${r_dhost} != *'"'* && ${r_dhost} != *\\* && ${r_dhost} != *'#'* && ${r_dhost} != *'@'* && ${r_dhost} != */* && ${r_dhost} != *'?'* && ${r_dhost} != *'%'* ]] || return 1
  # 带冒号的必须是 IPv6, 否则 "1.2.3.4:443" 这种会拼出非法地址
  [[ ${r_dhost} == *:* ]] && ! is_ipv6_host "${r_dhost}" && return 1
  return 0
}

function count_rules() {
  local n=0 line
  [[ -f ${raw_conf_path} ]] || {
    echo 0
    return
  }
  while IFS= read -r line || [[ -n ${line} ]]; do
    parse_rule "${line}" && n=$((n + 1))
  done <"${raw_conf_path}"
  echo "${n}"
}

# rawconf 里有没有别的脚本写的 ss/tls/ws 等规则
function has_foreign_rules() {
  local line
  [[ -f ${raw_conf_path} ]] || return 1
  while IFS= read -r line || [[ -n ${line} ]]; do
    parse_rule "${line}"
    (($? == 2)) && return 0
  done <"${raw_conf_path}"
  return 1
}
# 本脚本只认 nonencrypt; 混有其它类型时拒绝重建, 否则会把它们写丢
function ensure_lite() {
  if has_foreign_rules; then
    warn "检测到 ${raw_conf_path} 里还有本脚本不支持的规则类型（ss / tls / ws 等）"
    warn "为了不把它们的配置写丢，这里不重建配置；请改用 gost.sh 或手动处理这些行"
    return 1
  fi
  return 0
}

# 由 rawconf 重建 config.json: 写临时文件, 校验通过后原子替换
function rebuild_config() {
  local target="${realm_conf_path}" tmp line n=0 lineno=0 dup=0 seen=" " p lhost dest
  local -a sports dests
  ensure_lite || return 1
  if [[ ! -f ${raw_conf_path} ]]; then
    warn "未找到 ${raw_conf_path}，没有可用的转发规则"
    return 1
  fi
  lhost=$(listen_host)
  while IFS= read -r line || [[ -n ${line} ]]; do
    lineno=$((lineno + 1))
    [[ -z ${line//[[:space:]]/} ]] && continue
    parse_rule "${line}"
    case $? in
    0) ;;
    2)
      warn "第 ${lineno} 行是其它类型的规则（${r_type}），本脚本不处理，已跳过"
      continue
      ;;
    *)
      warn "第 ${lineno} 行无法解析，已跳过（格式应为 nonencrypt/本地端口#目标IP#目标端口）"
      continue
      ;;
    esac
    p=$((10#${r_sport}))
    if [[ ${seen} == *" ${p} "* ]]; then
      warn "本地端口 ${p} 在 rawconf 里出现了不止一次，realm 会争抢同一个端口，已中止"
      dup=1
      continue
    fi
    seen+="${p} "
    sports+=("${p}")
    dest=$(norm_host "${r_dhost}")
    dests+=("${dest}:$((10#${r_dport}))")
    n=$((n + 1))
  done <"${raw_conf_path}"
  ((dup)) && return 1
  if ((n == 0)); then
    warn "没有可用的转发规则"
    return 1
  fi

  tmp="${target}.new.$$"
  {
    printf '{\n'
    printf '    "log": {\n        "level": "warn",\n        "output": "stdout"\n    },\n'
    printf '    "network": {\n        "no_tcp": false,\n        "use_udp": true\n    },\n'
    printf '    "endpoints": [\n'
    for ((i = 0; i < n; i++)); do
      printf '        {\n            "listen": "%s:%s",\n            "remote": "%s"\n        }%s\n' \
        "${lhost}" "${sports[i]}" "${dests[i]}" "$([[ ${i} -eq $((n - 1)) ]] && echo '' || echo ',')"
    done
    printf '    ]\n}\n'
  } >"${tmp}" || {
    rm -f "${tmp}"
    warn "无法写入 ${tmp}"
    return 1
  }

  if ! json_ok "${tmp}"; then
    warn "生成的配置无效，已保留上一份配置"
    rm -f "${tmp}"
    return 1
  fi
  chmod 0600 "${tmp}"
  if [[ -f ${target} ]]; then
    cp -a "${target}" "${target}.bak" 2>/dev/null && chmod 0600 "${target}.bak" 2>/dev/null
  else
    # 没有"上一份配置"时清掉旧 .bak: 否则这次重启失败会回滚到一份无关的旧配置,
    # 比如刚删光的规则被复活
    rm -f "${target}.bak"
  fi
  if ! mv -f "${tmp}" "${target}"; then
    warn "替换配置失败，已保留上一份配置"
    rm -f "${tmp}"
    return 1
  fi
  chmod 0600 "${target}"
  return 0
}

# 重启并确认真的起来了; 起不来就回滚, 避免一条坏规则把所有转发带下去
# realm 绑端口失败时进程不退出, 所以除了 is-active 还要核对每个端口是否真的在监听
function restart_realm() {
  local bak="${realm_conf_path}.bak" ports=()
  mapfile -t ports < <(raw_ports)
  systemctl restart realm
  sleep 1
  if systemctl is-active --quiet realm && listeners_ok "${ports[@]}"; then
    return 0
  fi
  sleep 2
  if systemctl is-active --quiet realm && listeners_ok "${ports[@]}"; then
    return 0
  fi
  if [[ -f ${bak} ]]; then
    warn "realm 未能正常监听全部端口${failed_port:+（端口 ${failed_port} 没有由 realm 监听）}，正在回滚到上一份配置 $(basename "${bak}")"
    cp -a "${bak}" "${realm_conf_path}" && chmod 0600 "${realm_conf_path}"
    systemctl restart realm
    sleep 1
    if systemctl is-active --quiet realm; then
      warn "已回滚，本次改动未生效；请检查端口是否被其它程序占用后重试"
      return 1
    fi
  else
    warn "没有可回滚的上一份配置（${bak} 不存在）"
  fi
  warn "realm 仍未正常启动，请执行 systemctl status realm 及 journalctl -u realm -n 50 查看原因"
  return 1
}

function snapshot_rawconf() {
  raw_conf_snap=$(mktemp) || die "无法创建临时文件"
  raw_conf_snap_had=0
  if [[ -f ${raw_conf_path} ]]; then
    cp -a "${raw_conf_path}" "${raw_conf_snap}" || die "备份 rawconf 失败"
    raw_conf_snap_had=1
  fi
}
function restore_rawconf() {
  if ((raw_conf_snap_had)); then
    if install -m 0644 "${raw_conf_snap}" "${raw_conf_path}"; then
      warn "已撤销本次对 rawconf 的改动"
    else
      warn "恢复 rawconf 失败，请手动检查 ${raw_conf_path}"
    fi
  else
    rm -f "${raw_conf_path}"
  fi
  [[ -n ${raw_conf_snap} ]] && rm -f "${raw_conf_snap}"
}
function commit_rawconf() {
  [[ -n ${raw_conf_snap} ]] && rm -f "${raw_conf_snap}"
}

function listen_port_taken() {
  local port="$1" line
  [[ -f ${raw_conf_path} ]] || return 1
  while IFS= read -r line || [[ -n ${line} ]]; do
    parse_rule "${line}" || continue
    [[ $((10#${r_sport})) == "${port}" ]] && return 0
  done <"${raw_conf_path}"
  return 1
}

# 端口是否已被任何进程监听(realm 自己也算)。realm 绑不上端口时不会退出,
# 只会在日志里 panic, 所以新增前必须自己查, 不能指望 is-active 兜底。
function port_in_use() {
  local port="$1" addr
  if command -v ss >/dev/null 2>&1; then
    for addr in $(ss -H -ltn 2>/dev/null | awk '{print $4}') $(ss -H -lun 2>/dev/null | awk '{print $4}'); do
      [[ ${addr} == *":${port}" ]] && return 0
    done
    return 1
  fi
  if command -v netstat >/dev/null 2>&1; then
    for addr in $(netstat -ltn 2>/dev/null | awk 'NR>2{print $4}') $(netstat -lun 2>/dev/null | awk 'NR>2{print $4}'); do
      [[ ${addr} == *":${port}" ]] && return 0
    done
    return 1
  fi
  # 没有 ss/netstat 时只能测 TCP
  (echo >"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && return 0
  return 1
}

# rawconf 里所有有效的本地端口, 每行一个
function raw_ports() {
  local line p seen=" "
  [[ -f ${raw_conf_path} ]] || return 0
  while IFS= read -r line || [[ -n ${line} ]]; do
    parse_rule "${line}" || continue
    p=$((10#${r_sport}))
    [[ ${seen} == *" ${p} "* ]] && continue
    seen+="${p} "
    echo "${p}"
  done <"${raw_conf_path}"
}

# 某个端口的 tcp/udp 监听者是不是 realm 自己
# 端口被别的进程占着时 realm 只会 panic 不退出, 必须看进程名才能识破
function listened_by_realm() {
  local p="$1" proto out line addr found
  for proto in tcp udp; do
    if [[ ${proto} == tcp ]]; then
      out=$(ss -H -ltnp 2>/dev/null) || return 0
    else
      out=$(ss -H -lunp 2>/dev/null) || return 0
    fi
    found=0
    while IFS= read -r line; do
      [[ -z ${line} ]] && continue
      addr=$(awk '{print $4}' <<<"${line}")
      [[ ${addr} == *":${p}" ]] || continue
      found=1
      if [[ ${line} == *"users:"* ]]; then
        [[ ${line} == *'"realm"'* ]] || return 1
      fi
    done <<<"${out}"
    ((found)) || return 1
  done
  return 0
}

# 重启后逐个确认端口真的由 realm 在监听; 没有 ss 时退化为只看服务状态
function listeners_ok() {
  local p
  failed_port=""
  (($#)) || return 0
  command -v ss >/dev/null 2>&1 || return 0
  for p in "$@"; do
    if ! listened_by_realm "${p}"; then
      failed_port="${p}"
      return 1
    fi
  done
  return 0
}

function list_rules() {
  local line i=0
  if [[ ! -f ${raw_conf_path} ]]; then
    warn "还没有任何转发规则，先执行菜单 2 新增"
    return 1
  fi
  echo -e " 序号 | 本地端口 | 转发到"
  echo -e "--------------------------------------------------------"
  while IFS= read -r line || [[ -n ${line} ]]; do
    i=$((i + 1))
    parse_rule "${line}"
    case $? in
    0) echo -e "  ${i}  | ${r_sport}\t| ${r_dhost}:${r_dport}" ;;
    2) echo -e "  ${i}  | 其它类型 | ${r_type}（内容已隐藏，请用 gost.sh 管理）" ;;
    *) [[ -z ${line//[[:space:]]/} ]] || echo -e "  ${i}  | 无法解析 | 内容已隐藏，请手动查看 ${raw_conf_path}" ;;
    esac
    echo -e "--------------------------------------------------------"
  done <"${raw_conf_path}"
}

function add_rule() {
  local port ip dport
  command -v realm >/dev/null 2>&1 || die "realm 尚未安装，请先执行菜单 1 安装"
  [[ -d /etc/realm ]] || die "配置目录 /etc/realm 不存在，请先执行菜单 1 重新安装"
  ensure_lite || return 1
  echo -e "------------------------------------------------------------------"
  read -r -p "本机用哪个端口接收流量: " port
  valid_port "${port}" "本地监听端口"
  port=$((10#${port}))
  listen_port_taken "${port}" && die "端口 ${port} 已被现有规则占用，请换一个"
  port_in_use "${port}" && die "端口 ${port} 已被其它程序占用，请换一个"
  echo -e "------------------------------------------------------------------"
  echo -e "流量转发到哪个 IP 或域名（落地机地址，也可以是 127.0.0.1）"
  read -r -p "请输入: " ip
  valid_host "${ip}" "目标IP或域名"
  ip=$(uri_host "${ip}") || die "目标地址格式不对：带冒号的只支持 IPv6 地址，端口在下一步单独填"
  echo -e "------------------------------------------------------------------"
  read -r -p "转发到${ip}的哪个端口: " dport
  valid_port "${dport}" "目标端口"
  dport=$((10#${dport}))

  snapshot_rawconf
  # rawconf 末尾没有换行时(手改/别的工具写过)先补一个, 否则新规则会接在上一条后面, 两条一起失效
  [[ -s ${raw_conf_path} && -n $(tail -c 1 "${raw_conf_path}") ]] && printf '\n' >>"${raw_conf_path}"
  printf 'nonencrypt/%s#%s#%s\n' "${port}" "${ip}" "${dport}" >>"${raw_conf_path}" || {
    restore_rawconf
    die "写入 ${raw_conf_path} 失败"
  }
  if rebuild_config && restart_realm; then
    commit_rawconf
    echo -e "${Info} 已生效: 本机 ${port} -> ${ip}:${dport} (tcp+udp)"
    list_rules
  else
    restore_rawconf
  fi
}

function delete_rule() {
  local line num total=0
  ensure_lite || return 1
  list_rules || return 1
  read -r -p "请输入要删除的规则序号：" num
  [[ ${num} =~ ^[0-9]+$ ]] || {
    echo "请输入正确数字"
    return 1
  }
  total=$(awk 'END{print NR}' "${raw_conf_path}" 2>/dev/null)
  ((10#${num} >= 1 && 10#${num} <= ${total:-0})) || {
    echo "请输入正确数字"
    return 1
  }
  snapshot_rawconf
  sed -i "${num}d" "${raw_conf_path}" || {
    restore_rawconf
    die "删除失败"
  }
  # 删光了就停服务, 旧配置留作 .bak, 免得菜单 5 又把刚删的规则拉起来
  if (($(count_rules) == 0)); then
    systemctl stop realm >/dev/null 2>&1
    [[ -f ${realm_conf_path} ]] && mv -f "${realm_conf_path}" "${realm_conf_path}.bak" 2>/dev/null
    commit_rawconf
    echo -e "${Info} 规则已全部删除，realm 服务已停止"
    return 0
  fi
  if rebuild_config && restart_realm; then
    commit_rawconf
    echo -e "${Info} 已删除，服务已重启"
    list_rules
  else
    restore_rawconf
  fi
  return 0
}

function restart_all() {
  command -v realm >/dev/null 2>&1 || die "realm 尚未安装，请先执行菜单 1 安装"
  ensure_lite || return 1
  if (($(count_rules) == 0)); then
    warn "当前没有转发规则，先执行菜单 2 新增"
    return 1
  fi
  if rebuild_config && restart_realm; then
    echo -e "${Info} 已按 rawconf 重建配置并重启"
  else
    warn "rawconf 没有改动，请修正 ${raw_conf_path} 后重试（本次重启未生效）"
  fi
}

function show_banner() {
  local ver state color rules
  echo
  echo -e "  ${Bold}${Green_font_prefix}realm 精简版${Font_color_suffix}   ${Bold}v${shell_version}${Font_color_suffix}   ${Cyan_font_prefix}只做 tcp+udp 不加密转发${Font_color_suffix}"
  echo -e "  ------------------------------------------------------------"
  if command -v realm >/dev/null 2>&1; then
    ver=$(realm -v 2>/dev/null | awk '{print $2}')
    if systemctl is-active --quiet realm 2>/dev/null; then
      state="运行中"
      color="${Green_font_prefix}"
    else
      state="未运行"
      color="${Red_font_prefix}"
    fi
    rules=$(count_rules)
    if has_foreign_rules; then
      rules="${rules} 条（另有其它类型规则，请用 gost.sh 管理）"
    else
      rules="${rules} 条"
    fi
    echo -e "  ${color}●${Font_color_suffix} ${state} · realm ${ver:-未知} · 转发规则 ${rules}"
  else
    echo -e "  ${Red_font_prefix}●${Font_color_suffix} 未安装 · 选择 1 开始安装"
  fi
  echo -e "  配置目录 /etc/realm · 规则文件 rawconf（与 gost-lite 格式相同）"
  echo
  echo -e "    ${Green_font_prefix}1${Font_color_suffix} 安装      ${Green_font_prefix}2${Font_color_suffix} 新增      ${Green_font_prefix}3${Font_color_suffix} 查看      ${Green_font_prefix}4${Font_color_suffix} 删除"
  echo -e "    ${Green_font_prefix}5${Font_color_suffix} 重启      ${Green_font_prefix}6${Font_color_suffix} 卸载      ${Cyan_font_prefix}0${Font_color_suffix} 退出"
  echo -e "  ------------------------------------------------------------"
  echo
}

check_root
show_banner
read -r -e -p " 请输入数字 [0-6]:" num
case "$num" in
1) Install_ct ;;
2) add_rule ;;
3) list_rules ;;
4) delete_rule ;;
5) restart_all ;;
6) Uninstall_ct ;;
0) exit 0 ;;
*) echo "  请输入正确数字 [0-6]" ;;
esac
