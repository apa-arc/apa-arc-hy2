#!/usr/bin/env bash
# HY2 / sing-box installer for Debian, Ubuntu, Alpine and RHEL-family systems.
# Generated for apa-arc/apa-arc-hy2. Review before running on production servers.
set -Eeuo pipefail
umask 077

APP="sing-box"
BIN="/usr/local/bin/sing-box"
CONF_DIR="/etc/sing-box"
CONF="${CONF_DIR}/config.json"
DATA_DIR="/etc/sing-box"
EXPORT_DIR="/root/sing-box"
SERVICE="sing-box"
BACKUP_DIR="/var/backups/sing-box"
LOG="/var/log/sing-box-install.log"

say(){ printf '\n\033[1;36m[HY2]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[提示]\033[0m %s\n' "$*" >&2; }
die(){ printf '\n\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo bash install.sh"; }
has(){ command -v "$1" >/dev/null 2>&1; }
ask(){ local p="$1" d="${2:-}"; local v; read -r -p "$p" v; printf '%s' "${v:-$d}"; }
urlencode(){ jq -rn --arg v "$1" '$v|@uri'; }

detect_os(){
  [[ -r /etc/os-release ]] || die "无法识别系统：缺少 /etc/os-release"
  . /etc/os-release
  OS_ID="${ID,,}"; OS_LIKE="${ID_LIKE:-}"
  case "$OS_ID $OS_LIKE" in
    *debian*|*ubuntu*) PM="apt" ;;
    *alpine*) PM="apk" ;;
    *rhel*|*centos*|*rocky*|*almalinux*|*fedora*) PM="$(has dnf && echo dnf || echo yum)" ;;
    *) die "暂不支持该系统：$PRETTY_NAME" ;;
  esac
  ARCH="$(uname -m)"
  case "$ARCH" in x86_64|amd64) SB_ARCH="amd64";; aarch64|arm64) SB_ARCH="arm64";; armv7l) SB_ARCH="armv7";; *) die "暂不支持 CPU 架构：$ARCH";; esac
  say "系统：$PRETTY_NAME；架构：$ARCH；包管理器：$PM"
}
install_deps(){
  say "安装依赖"
  case "$PM" in
    apt) export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y curl jq openssl ca-certificates tar gzip iproute2 ;;
    apk) apk add --no-cache curl jq openssl ca-certificates tar gzip iproute2 bash ;;
    dnf) dnf install -y curl jq openssl ca-certificates tar gzip iproute ;;
    yum) yum install -y curl jq openssl ca-certificates tar gzip iproute ;;
  esac
}
detect_ips(){
  IPV4="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  IPV6="$(curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
  [[ "$IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || IPV4=""
  [[ "$IPV6" == *:* ]] || IPV6=""
  say "公网 IPv4：${IPV4:-不可用}"
  say "公网 IPv6：${IPV6:-不可用}"
  [[ -n "$IPV4$IPV6" ]] || die "未检测到可用公网 IP，请检查网络和出口。"
}
choose_host(){
  echo "选择节点地址："
  echo "1) 自动选择（优先 IPv4，其次 IPv6）"
  echo "2) 手动输入 IPv4/IPv6 地址或域名"
  local c; c="$(ask '请选择 [1/2，默认1]：' 1)"
  if [[ "$c" == 2 ]]; then
    HOST="$(ask '输入节点 IP 或域名：')"
    [[ -n "$HOST" ]] || die "地址不能为空"
  else
    if [[ -n "$IPV4" ]]; then HOST="$IPV4"; else HOST="$IPV6"; fi
  fi
  if [[ "$HOST" == *:* ]]; then IP_FAMILY="ipv6"; else IP_FAMILY="ipv4"; fi
  say "节点地址：$HOST（$IP_FAMILY）"
}
choose_port(){
  PORT="$(ask '请输入 HY2 UDP 端口（1-65535）：')"
  [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>=1 && PORT<=65535)) || die "端口必须为 1-65535"
}
choose_protocols(){
  say "将额外配置协议节点：VLESS Reality、Trojan TLS"
  TROJAN_PORT="$(ask '请输入 Trojan TLS TCP 端口（1-65535）：')"
  for p in "$PORT" "$VLESS_PORT" "$TROJAN_PORT"; do
    [[ "$p" =~ ^[0-9]+$ ]] && ((p>=1 && p<=65535)) || die "端口必须为 1-65535"
  done
  [[ "$PORT" != "$VLESS_PORT" && "$PORT" != "$TROJAN_PORT" && "$VLESS_PORT" != "$TROJAN_PORT" ]] || die "不同服务不能使用相同端口"
     "$VLESS_PORT" != "$TROJAN_PORT" && "$VLESS_PORT" != "$SS_PORT" && "$TROJAN_PORT" != "$SS_PORT" ]] || die "不同服务不能使用相同端口"
  REALITY_SNI="$(ask 'VLESS Reality 伪装 SNI [默认www.microsoft.com]：' www.microsoft.com)"
  [[ "$REALITY_SNI" == *.* && "$REALITY_SNI" != *://* ]] || die "Reality SNI 格式不正确"
}
choose_auth(){
  echo "证书方式："
  echo "1) 使用自己的域名，自动申请 Let's Encrypt 证书（需要域名解析到本机，TCP 80 可用）"
  echo "2) 使用 IP，自动生成自签名证书（客户端需跳过证书验证）"
  local c; c="$(ask '请选择 [1/2，默认2]：' 2)"
  mkdir -p "$CONF_DIR"
  if [[ "$c" == 1 ]]; then
    DOMAIN="$(ask '输入已解析到本机的域名：')"
    [[ "$DOMAIN" == *.* && "$DOMAIN" != *://* ]] || die "域名格式不正确"
    install_acme
    CERT="$CONF_DIR/fullchain.cer"; KEY="$CONF_DIR/private.key"
    "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$DOMAIN" --keylength ec-256 --server letsencrypt
    "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --ecc --fullchain-file "$CERT" --key-file "$KEY" --reloadcmd "systemctl restart sing-box 2>/dev/null || true"
    NODE_HOST="$DOMAIN"; SNI="$DOMAIN"; INSECURE=false
  else
    DOMAIN=""
    CERT="$CONF_DIR/server.crt"; KEY="$CONF_DIR/server.key"
    if [[ "$HOST" == *:* ]]; then SAN="IP:$HOST"; else SAN="IP:$HOST"; fi
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
      -keyout "$KEY" -out "$CERT" -subj "/CN=$HOST" -addext "subjectAltName=$SAN" >/dev/null 2>&1
    NODE_HOST="$HOST"; SNI="$HOST"; INSECURE=true
  fi
}
install_acme(){
  if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
    curl -fsSL https://get.acme.sh | sh -s email="$(ask '证书通知邮箱（可留空）：' '')"
  fi
  [[ -x "$HOME/.acme.sh/acme.sh" ]] || die "acme.sh 安装失败"
}
latest_release(){
  curl -fsSL --retry 3 https://api.github.com/repos/SagerNet/sing-box/releases/latest |
    jq -er '.tag_name' | sed 's/^v//'
}
download_binary(){
  local version="$1" tmp url
  tmp="$(mktemp -d)"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${SB_ARCH}.tar.gz"
  say "下载 sing-box v$version"
  curl -fL --retry 3 "$url" -o "$tmp/sb.tar.gz" || { rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/sb.tar.gz" -C "$tmp"
  local candidate; candidate="$(find "$tmp" -type f -name sing-box -perm -u+x | head -n1)"
  [[ -n "$candidate" ]] || { rm -rf "$tmp"; return 1; }
  install -m 0755 "$candidate" "${tmp}/sing-box.new"
  "${tmp}/sing-box.new" version >/dev/null || { rm -rf "$tmp"; return 1; }
  mkdir -p "$(dirname "$BIN")"
  if [[ -x "$BIN" ]]; then cp -a "$BIN" "${BIN}.bak"; fi
  install -m 0755 "${tmp}/sing-box.new" "$BIN"
  rm -rf "$tmp"
}
configure_service(){
  mkdir -p "$CONF_DIR" "$EXPORT_DIR" "$BACKUP_DIR"
  PASSWORD="$(openssl rand -hex 18)"
  OBFS_PASSWORD="$(openssl rand -hex 18)"
  VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
  TROJAN_PASSWORD="$(openssl rand -hex 20)"
  REALITY_KEYS="$("$BIN" generate reality-keypair)"
  REALITY_PRIVATE="$(printf '%s\n' "$REALITY_KEYS" | awk -F': *' '/PrivateKey/{print $2; exit}')"
  REALITY_PUBLIC="$(printf '%s\n' "$REALITY_KEYS" | awk -F': *' '/PublicKey/{print $2; exit}')"
  REALITY_SHORT_ID="$(openssl rand -hex 4)"
  [[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" ]] || die "Reality 密钥生成失败，请检查 sing-box 版本"
  local listen
  listen="$([[ "$IP_FAMILY" == ipv6 ]] && echo '::' || echo '0.0.0.0')"
  jq -n --arg listen "$listen" --argjson hy2port "$PORT" --arg hy2pass "$PASSWORD" --arg obfs "$OBFS_PASSWORD" \
    --arg cert "$CERT" --arg key "$KEY" --argjson vport "$VLESS_PORT" --arg uuid "$VLESS_UUID" \
    --arg rpriv "$REALITY_PRIVATE" --arg rsid "$REALITY_SHORT_ID" --arg rsni "$REALITY_SNI" \
    --arg tpass "$TROJAN_PASSWORD" --argjson tp "$TROJAN_PORT" \
    '{
      log:{level:"info",timestamp:true},
      inbounds:[
        {type:"hysteria2",tag:"hy2-in",listen:$listen,listen_port:$hy2port,users:[{password:$hy2pass}],obfs:{type:"salamander",password:$obfs},tls:{enabled:true,certificate_path:$cert,key_path:$key}},
        {type:"vless",tag:"vless-reality-in",listen:$listen,listen_port:$vport,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$rsni,reality:{enabled:true,handshake:{server:$rsni,server_port:443},private_key:$rpriv,short_id:[$rsid]}}},
        {type:"trojan",tag:"trojan-in",listen:$listen,listen_port:$tport,users:[{password:$tpass}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}
      ],
      outbounds:[{type:"direct",tag:"direct"}]
    }' > "$CONF"
  chmod 600 "$CONF"
  "$BIN" check -c "$CONF"
  if has systemctl; then
    cat >/etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target
[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now "$SERVICE"
  elif has rc-update; then
    cat >/etc/init.d/sing-box <<'INIT'
#!/sbin/openrc-run
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
depend() { need net; }
INIT
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box restart || rc-service sing-box start
  else
    die "未检测到 systemd/OpenRC，已安装文件但无法注册服务"
  fi
}

write_clients(){
  local uri_host="$NODE_HOST"
  [[ "$uri_host" == *:* ]] && uri_host="[$uri_host]"
  local qpass qobfs qsni qtpass qrsni
  qpass="$(urlencode "$PASSWORD")"; qobfs="$(urlencode "$OBFS_PASSWORD")"; qsni="$(urlencode "$SNI")"
  qtpass="$(urlencode "$TROJAN_PASSWORD")"; qrsni="$(urlencode "$REALITY_SNI")"
  local insecure_param=""; $INSECURE && insecure_param="&insecure=1"
  printf 'hysteria2://%s@%s:%s/?obfs=salamander&obfs-password=%s&sni=%s%s#HY2-%s\n' \
    "$qpass" "$uri_host" "$PORT" "$qobfs" "$qsni" "$insecure_param" "$NODE_HOST" > "$EXPORT_DIR/hy2.txt"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#VLESS-Reality-%s\n' \
    "$VLESS_UUID" "$uri_host" "$VLESS_PORT" "$qrsni" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$NODE_HOST" > "$EXPORT_DIR/vless-reality.txt"
  printf 'trojan://%s@%s:%s?security=tls&sni=%s%s#Trojan-TLS-%s\n' \
    "$qtpass" "$uri_host" "$TROJAN_PORT" "$qsni" "$insecure_param" "$NODE_HOST" > "$EXPORT_DIR/trojan.txt"
  base64 "$EXPORT_DIR/all-nodes.txt" | tr -d '\n' > "$EXPORT_DIR/subscription.txt"
  jq -n --arg host "$NODE_HOST" --argjson hp "$PORT" --arg hpass "$PASSWORD" --arg obfs "$OBFS_PASSWORD" --arg hsni "$SNI" --argjson insecure "$INSECURE" \
    --arg uuid "$VLESS_UUID" --argjson vp "$VLESS_PORT" --arg rsni "$REALITY_SNI" --arg rpub "$REALITY_PUBLIC" --arg rsid "$REALITY_SHORT_ID" \
    --arg tpass "$TROJAN_PASSWORD" --argjson tp "$TROJAN_PORT" \
    '{outbounds:[
      {type:"hysteria2",tag:"HY2",server:$host,server_port:$hp,password:$hpass,obfs:{type:"salamander",password:$obfs},tls:{enabled:true,server_name:$hsni,insecure:$insecure}},
      {type:"vless",tag:"VLESS-Reality",server:$host,server_port:$vp,uuid:$uuid,flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$rsni,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$rpub,short_id:$rsid}}},
      {type:"trojan",tag:"Trojan-TLS",server:$host,server_port:$tp,password:$tpass,tls:{enabled:true,server_name:$hsni,insecure:$insecure}}
    ]}' > "$EXPORT_DIR/sing-box-client.json"
  cat >"$EXPORT_DIR/clash-meta.yaml" <<EOF
proxies:
  - name: HY2-$NODE_HOST
    type: hysteria2
    server: $NODE_HOST
    port: $PORT
    password: "$PASSWORD"
    obfs: salamander
    obfs-password: "$OBFS_PASSWORD"
    sni: "$SNI"
    skip-cert-verify: $INSECURE
  - name: VLESS-Reality-$NODE_HOST
    type: vless
    server: $NODE_HOST
    port: $VLESS_PORT
    uuid: $VLESS_UUID
    network: tcp
    tls: true
    servername: $REALITY_SNI
    client-fingerprint: chrome
    flow: xtls-rprx-vision
    reality-opts:
      public-key: $REALITY_PUBLIC
      short-id: $REALITY_SHORT_ID
  - name: Trojan-TLS-$NODE_HOST
    type: trojan
    server: $NODE_HOST
    port: $TROJAN_PORT
    password: "$TROJAN_PASSWORD"
    sni: $SNI
    skip-cert-verify: $INSECURE
    type: ss
    server: $NODE_HOST
    port: $SS_PORT
EOF
  chmod 600 "$EXPORT_DIR"/*
}

tune_kernel(){
  say "应用基础网络优化（不强制修改不支持的内核参数）"
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/99-sing-box-network.conf <<'SYS'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=2500000
net.core.wmem_max=2500000
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_forward=1
SYS
  sysctl --system >/dev/null 2>&1 || warn "部分 sysctl 参数未能应用，可能是内核不支持"
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    say "BBR 已启用"
  else
    warn "当前内核未启用 BBR；不会强行替换内核"
  fi
  if sysctl net.core.default_qdisc 2>/dev/null | grep -q fq; then say "FQ 队列已设置"; fi
}
install_update_timer(){
  if has systemctl; then
    cat >/usr/local/sbin/sing-box-update <<'UPDATE'
#!/usr/bin/env bash
set -Eeuo pipefail
BIN=/usr/local/bin/sing-box
CONF=/etc/sing-box/config.json
BACK=/var/backups/sing-box
mkdir -p "$BACK"
command -v jq >/dev/null || exit 1
. /etc/os-release
ARCH="$(uname -m)"
case "$ARCH" in x86_64) A=amd64;; aarch64) A=arm64;; armv7l) A=armv7;; *) exit 1;; esac
V="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -er '.tag_name' | sed 's/^v//')"
CUR="$("$BIN" version | awk 'NR==1{print $3}' | sed 's/^v//')"
[[ "$V" == "$CUR" ]] && exit 0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
curl -fL --retry 3 "https://github.com/SagerNet/sing-box/releases/download/v$V/sing-box-$V-linux-$A.tar.gz" -o "$T/sb.tgz"
tar -xzf "$T/sb.tgz" -C "$T"
C="$(find "$T" -type f -name sing-box -perm -u+x | head -n1)"
[[ -n "$C" ]]
"$C" check -c "$CONF"
cp -a "$BIN" "$BACK/sing-box.$(date +%Y%m%d%H%M%S)"
install -m 0755 "$C" "$BIN"
if systemctl restart sing-box && systemctl is-active --quiet sing-box; then
  find "$BACK" -type f -name 'sing-box.*' -printf '%T@ %p\n' | sort -nr | awk 'NR>5{print $2}' | xargs -r rm -f
else
  L="$(ls -1t "$BACK"/sing-box.* | head -n1)"
  cp -a "$L" "$BIN"; systemctl restart sing-box
  exit 1
fi
UPDATE
    chmod 700 /usr/local/sbin/sing-box-update
    cat >/etc/systemd/system/sing-box-update.service <<'UNIT'
[Unit]
Description=Check and update sing-box
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sing-box-update
UNIT
    cat >/etc/systemd/system/sing-box-update.timer <<'UNIT'
[Unit]
Description=Weekly sing-box update check
[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h
[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
    systemctl enable --now sing-box-update.timer
  else
    warn "非 systemd 系统未自动创建更新定时器；可手动运行 /usr/local/sbin/sing-box-update"
  fi
}
show_result(){
  echo
  say "安装完成"
  echo "节点地址：$NODE_HOST"
  echo "密码：$PASSWORD"
  echo "混淆密码：$OBFS_PASSWORD"
  echo "证书验证跳过：$INSECURE"
  echo "节点链接集合：$EXPORT_DIR/all-nodes.txt"
  echo "Base64 订阅：$EXPORT_DIR/subscription.txt"
  echo "sing-box 客户端配置：$EXPORT_DIR/sing-box-client.json"
  echo "Clash Meta 配置：$EXPORT_DIR/clash-meta.yaml"
  echo "服务状态：systemctl status sing-box（OpenRC 使用 rc-service sing-box status）"
  echo "更新命令：/usr/local/sbin/sing-box-update"
  echo "注意：自签名 IP 证书对应的 HY2/Trojan 客户端配置已设置 insecure=true；VLESS Reality 使用独立密钥。"
}
main(){
  need_root
  detect_os
  install_deps
  detect_ips
  choose_host
  choose_port
  choose_protocols
  choose_auth
  local ver; ver="$(latest_release)" || die "无法获取 sing-box 最新版本"
  download_binary "$ver" || die "sing-box 下载或安装失败"
  configure_service
  write_clients
  tune_kernel
  install_update_timer
  show_result
}
case "${1:-install}" in
  install) main ;;
  update) need_root; /usr/local/sbin/sing-box-update ;;
  status) systemctl status sing-box --no-pager 2>/dev/null || rc-service sing-box status ;;
  *) echo "用法：bash install.sh [install|update|status]"; exit 2 ;;
esac
