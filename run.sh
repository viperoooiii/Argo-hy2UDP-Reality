#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/jd-node
BIN_DIR="$APP_DIR/bin"
STATE_DIR="$APP_DIR/state"
CONFIG_DIR="$APP_DIR/config"
SYSTEMD_DIR=/etc/systemd/system
SNI=www.bing.com
REALITY_SNI=www.amd.com
HY2_HOP_START=2053
HY2_HOP_END=2083
RAW_SCRIPT_URL='https://raw.githubusercontent.com/viperoooiii/Argo-hy2UDP-Reality/main/run.sh'

trap 'printf "\n错误：第 %s 行执行失败。请查看 systemctl status jd-argo jd-xray jd-hy2 jd-reality。\n" "$LINENO" >&2' ERR

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 运行；查看节点可执行 sudo jd。'
}

require_system() {
  command -v systemctl >/dev/null || die '仅支持使用 systemd 的 Linux 发行版。'
  [[ -r /etc/os-release ]] || die '无法识别操作系统。'
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die '目前只支持 Ubuntu 和 Debian。' ;;
  esac
  case "$(uname -m)" in
    x86_64) ARCH=amd64; XRAY_ARCH=64 ;;
    aarch64|arm64) ARCH=arm64; XRAY_ARCH=arm64-v8a ;;
    *) die '目前只支持 x86_64 和 ARM64。' ;;
  esac
}

prepare() {
  require_root
  require_system
  local missing=() item
  for item in curl unzip openssl python3; do
    command -v "$item" >/dev/null || missing+=("$item")
  done
  if ((${#missing[@]})); then
    info "安装依赖：${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates "${missing[@]}"
  fi
  umask 077
  mkdir -p "$BIN_DIR" "$STATE_DIR" "$CONFIG_DIR"
  chmod 700 "$APP_DIR" "$STATE_DIR" "$CONFIG_DIR"
  install_self
}

install_self() {
  local command_path source_file temp_source=''
  for command_path in /usr/local/bin/jd /usr/local/bin/jdxz; do
    if [[ -e $command_path || -L $command_path ]] \
      && ! grep -q 'jd-node-managed' "$command_path" 2>/dev/null; then
      die "$command_path 已被其他程序占用，请先处理命令冲突。"
    fi
  done
  source_file=$0
  # `bash <(curl ...)` executes from a pipe. Reading $0 again copies only the
  # unread tail, so fetch a complete copy for the persistent jd/jdxz commands.
  if [[ ! -f $source_file || -L $source_file || $source_file == /dev/fd/* ]]; then
    temp_source=$(mktemp)
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 60 \
      -o "$temp_source" "$RAW_SCRIPT_URL"; then
      rm -f "$temp_source"
      die '无法下载完整管理脚本。'
    fi
    source_file=$temp_source
  fi
  [[ -s $source_file ]] || die '管理脚本为空，已停止安装。'
  bash -n "$source_file" || die '管理脚本语法检查失败，已停止安装。'
  install -m 755 "$source_file" "$APP_DIR/run.sh"
  [[ -z $temp_source ]] || rm -f "$temp_source"
  cat >/usr/local/bin/jd <<'EOF'
#!/usr/bin/env bash
# jd-node-managed
exec /opt/jd-node/run.sh --show "$@"
EOF
  chmod 755 /usr/local/bin/jd
  cat >/usr/local/bin/jdxz <<'EOF'
#!/usr/bin/env bash
# jd-node-managed
exec /opt/jd-node/run.sh --uninstall "$@"
EOF
  chmod 755 /usr/local/bin/jdxz
}

download() {
  local url=$1 target=$2 temp
  temp=$(mktemp "$BIN_DIR/.download.XXXXXX")
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 -o "$temp" "$url"; then
    rm -f "$temp"
    die "下载失败：$url"
  fi
  [[ -s $temp ]] || { rm -f "$temp"; die "下载文件为空：$url"; }
  install -m 755 "$temp" "$target"
  rm -f "$temp"
}

install_xray() {
  [[ -x $BIN_DIR/xray ]] && return
  info '下载 Xray'
  local temp
  temp=$(mktemp -d)
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
    -o "$temp/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"; then
    rm -rf "$temp"
    die 'Xray 下载失败。'
  fi
  unzip -q "$temp/xray.zip" xray -d "$temp"
  install -m 755 "$temp/xray" "$BIN_DIR/xray"
  rm -rf "$temp"
}

install_cloudflared() {
  [[ -x $BIN_DIR/cloudflared ]] && return
  info '下载 cloudflared'
  download "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" "$BIN_DIR/cloudflared"
}

install_hysteria() {
  [[ -x $BIN_DIR/hysteria && ${1:-} != --latest ]] && return
  info '下载 Hysteria2'
  download "https://download.hysteria.network/app/latest/hysteria-linux-${ARCH}" "$BIN_DIR/hysteria"
}

random_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
}

udp_hop_ports_available() {
  python3 - "$1" "$HY2_HOP_START" "$HY2_HOP_END" <<'PY'
import socket, sys
base, start, end = map(int, sys.argv[1:])
for port in (base, *range(start, end + 1)):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.bind(('0.0.0.0', port))
        except OSError:
            sys.exit(f'错误：UDP {port} 已被占用或无法绑定，不能启用 HY2 端口跳跃。')
PY
}

ensure_hy2_hop_backend() {
  if ! command -v iptables >/dev/null; then
    info '安装 HY2 端口跳跃所需的 iptables'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables
  fi
  iptables -w 5 -t nat -L PREROUTING -n >/dev/null || die '无法使用 iptables NAT，不能启用 HY2 端口跳跃。'
}

install_hy2_hop_helper() {
  cat >"$BIN_DIR/hy2-hop" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# jd-node-managed
. /opt/jd-node/state/hy2.env
: "${HY2_HOP_RANGE:?}"
iptables -w 5 -t nat -L PREROUTING -n >/dev/null
rule=(-p udp --dport "${HY2_HOP_RANGE/-/:}" -m comment --comment jd-node-hy2-hop -j REDIRECT --to-ports "$HY2_PORT")
case "${1:-}" in
  start)
    if ! iptables -w 5 -t nat -C PREROUTING "${rule[@]}" >/dev/null 2>&1; then
      iptables -w 5 -t nat -I PREROUTING 1 "${rule[@]}"
    fi
    ;;
  stop)
    while iptables -w 5 -t nat -C PREROUTING "${rule[@]}" >/dev/null 2>&1; do
      iptables -w 5 -t nat -D PREROUTING "${rule[@]}"
    done
    ;;
  *) printf '用法：hy2-hop start|stop\n' >&2; exit 2 ;;
esac
EOF
  chmod 755 "$BIN_DIR/hy2-hop"
}

tcp_port_available() {
  python3 - "$1" <<'PY'
import socket, sys
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    try:
        sock.bind(('0.0.0.0', int(sys.argv[1])))
    except OSError:
        sys.exit(1)
PY
}

persist_ipv4_firewall() {
  if command -v netfilter-persistent >/dev/null; then
    netfilter-persistent save >/dev/null ||
      printf '警告：iptables 规则已生效，但持久化失败。\n' >&2
  elif [[ -f /etc/iptables/rules.v4 ]] && command -v iptables-save >/dev/null; then
    iptables-save >/etc/iptables/rules.v4 ||
      printf '警告：iptables 规则已生效，但写入 rules.v4 失败。\n' >&2
  else
    printf '警告：iptables 规则已生效，但未找到持久化工具；重启后可能失效。\n' >&2
  fi
}

ensure_hy2_firewall() {
  local port=$1
  local -a rule=(-p udp --dport "$port" -m comment --comment jd-node-hy2 -j ACCEPT)
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    if ! ufw status | grep -Eq "^${port}/udp[[:space:]]+ALLOW"; then
      ufw allow "$port/udp" comment 'jd-node'
      printf 'HY2_UFW_MANAGED=1\n' >>"$STATE_DIR/hy2.env"
    fi
  elif command -v iptables >/dev/null; then
    # Oracle Ubuntu can filter UDP with iptables even when UFW is inactive.
    # Put this narrow rule first so a later REJECT cannot shadow it.
    if iptables -C INPUT "${rule[@]}" >/dev/null 2>&1; then
      iptables -D INPUT "${rule[@]}"
    fi
    iptables -I INPUT 1 "${rule[@]}"
    if ! grep -q '^HY2_IPTABLES_MANAGED=1$' "$STATE_DIR/hy2.env"; then
      printf 'HY2_IPTABLES_MANAGED=1\n' >>"$STATE_DIR/hy2.env"
    fi
    persist_ipv4_firewall
  else
    printf '警告：未找到可用的系统防火墙命令，请检查 UDP %s 入站规则。\n' "$port" >&2
  fi
}

ensure_reality_firewall() {
  local port=$1
  local -a rule=(-p tcp --dport "$port" -m comment --comment jd-node-reality -j ACCEPT)
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    if ! ufw status | grep -Eq "^${port}/tcp[[:space:]]+ALLOW"; then
      ufw allow "$port/tcp" comment 'jd-node'
      printf 'REALITY_UFW_MANAGED=1\n' >>"$STATE_DIR/reality.env"
    fi
  elif command -v iptables >/dev/null; then
    if iptables -C INPUT "${rule[@]}" >/dev/null 2>&1; then
      iptables -D INPUT "${rule[@]}"
    fi
    iptables -I INPUT 1 "${rule[@]}"
    if ! grep -q '^REALITY_IPTABLES_MANAGED=1$' "$STATE_DIR/reality.env"; then
      printf 'REALITY_IPTABLES_MANAGED=1\n' >>"$STATE_DIR/reality.env"
    fi
    persist_ipv4_firewall
  else
    printf '警告：未找到可用的系统防火墙命令，请检查 TCP %s 入站规则。\n' "$port" >&2
  fi
}

public_ipv4() {
  local ip
  ip=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org || true)
  if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$ip"
  else
    hostname -I | awk '{print $1}'
  fi
}

install_argo() {
  if [[ -f $STATE_DIR/argo.env ]] \
    && systemctl is-active --quiet jd-xray.service \
    && systemctl is-active --quiet jd-argo.service; then
    info 'Argo 已安装并运行，保留现有节点。'
    return
  fi
  install_xray
  install_cloudflared
  local ARGO_UUID ARGO_PATH ARGO_PORT
  if [[ -f $STATE_DIR/argo.env ]]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/argo.env"
  else
    ARGO_UUID=$(cat /proc/sys/kernel/random/uuid)
    ARGO_PATH="/$(openssl rand -hex 12)"
    ARGO_PORT=$(random_port)
    printf 'ARGO_UUID=%s\nARGO_PATH=%s\nARGO_PORT=%s\n' \
      "$ARGO_UUID" "$ARGO_PATH" "$ARGO_PORT" >"$STATE_DIR/argo.env"
  fi

  cat >"$CONFIG_DIR/xray.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": $ARGO_PORT,
    "protocol": "vless",
    "settings": {"clients": [{"id": "$ARGO_UUID"}], "decryption": "none"},
    "streamSettings": {"network": "ws", "wsSettings": {"path": "$ARGO_PATH"}}
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF
  "$BIN_DIR/xray" run -test -config "$CONFIG_DIR/xray.json"

  cat >"$SYSTEMD_DIR/jd-xray.service" <<EOF
# jd-node-managed
[Unit]
Description=JD Xray Argo origin
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/xray run -config $CONFIG_DIR/xray.json
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  cat >"$SYSTEMD_DIR/jd-argo.service" <<EOF
# jd-node-managed
[Unit]
Description=JD Cloudflare Quick Tunnel
After=network-online.target jd-xray.service
Wants=network-online.target
Requires=jd-xray.service

[Service]
Type=simple
Environment=HOME=$APP_DIR
ExecStart=$BIN_DIR/cloudflared tunnel --url http://127.0.0.1:$ARGO_PORT --no-autoupdate
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now jd-xray.service jd-argo.service
  systemctl is-active --quiet jd-xray.service || die 'Xray 服务启动失败。'
  systemctl is-active --quiet jd-argo.service || die 'Argo 隧道服务启动失败。'
  info '等待临时隧道分配域名（最多 45 秒）'
  local i
  for ((i=0; i<23; i++)); do
    [[ -n $(current_argo_host) ]] && break
    sleep 2
  done
}

current_argo_host() {
  local invocation
  invocation=$(systemctl show -P InvocationID jd-argo.service 2>/dev/null || true)
  [[ -n $invocation ]] || return 0
  journalctl "_SYSTEMD_INVOCATION_ID=$invocation" --no-pager -o cat 2>/dev/null \
    | grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -n 1 | sed 's#https://##' || true
}

install_hy2() {
  local HY2_PORT HY2_PASSWORD HY2_PIN HY2_HOP_RANGE hop_service_lines=''
  if [[ -f $STATE_DIR/hy2.env ]] \
    && systemctl is-active --quiet jd-hy2.service \
    && systemctl is-enabled --quiet jd-hy2.service; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/hy2.env"
    ensure_hy2_firewall "$HY2_PORT"
    if [[ -z ${HY2_HOP_RANGE:-} ]] || { [[ -x $BIN_DIR/hy2-hop ]] \
      && grep -Fq "ExecStartPre=$BIN_DIR/hy2-hop start" "$SYSTEMD_DIR/jd-hy2.service" 2>/dev/null; }; then
      if [[ -n ${HY2_HOP_RANGE:-} ]]; then
        "$BIN_DIR/hy2-hop" start
      fi
      info 'Hysteria2 已安装并运行，保留现有节点。'
      return
    fi
  fi
  if [[ -f $STATE_DIR/hy2.env ]]; then
    install_hysteria
    # shellcheck disable=SC1091
    . "$STATE_DIR/hy2.env"
  else
    HY2_PORT=443
    HY2_HOP_RANGE=$HY2_HOP_START-$HY2_HOP_END
    udp_hop_ports_available "$HY2_PORT"
    ensure_hy2_hop_backend
    install_hysteria --latest
    HY2_PASSWORD=$(openssl rand -hex 24)
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "$CONFIG_DIR/hy2.key" -out "$CONFIG_DIR/hy2.crt" \
      -days 3650 -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1
    HY2_PIN=$(openssl x509 -in "$CONFIG_DIR/hy2.crt" -noout -fingerprint -sha256 | cut -d= -f2)
    printf 'HY2_PORT=%s\nHY2_HOP_RANGE=%s\nHY2_PASSWORD=%s\nHY2_PIN=%s\n' \
      "$HY2_PORT" "$HY2_HOP_RANGE" "$HY2_PASSWORD" "$HY2_PIN" >"$STATE_DIR/hy2.env"
  fi

  if [[ -n ${HY2_HOP_RANGE:-} ]]; then
    install_hy2_hop_helper
    hop_service_lines="ExecStartPre=$BIN_DIR/hy2-hop start
ExecStopPost=-$BIN_DIR/hy2-hop stop"
  fi

  cat >"$CONFIG_DIR/hy2.yaml" <<EOF
listen: :$HY2_PORT
tls:
  cert: $CONFIG_DIR/hy2.crt
  key: $CONFIG_DIR/hy2.key
auth:
  type: password
  password: $HY2_PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF
  cat >"$SYSTEMD_DIR/jd-hy2.service" <<EOF
# jd-node-managed
[Unit]
Description=JD Hysteria2 server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
$hop_service_lines
ExecStart=$BIN_DIR/hysteria server -c $CONFIG_DIR/hy2.yaml
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ensure_hy2_firewall "$HY2_PORT"
  systemctl enable --now jd-hy2.service
  sleep 2
  systemctl is-active --quiet jd-hy2.service || die 'Hysteria2 服务启动失败。'
  if [[ -n ${HY2_HOP_RANGE:-} ]]; then
    "$BIN_DIR/hy2-hop" start
  fi
}

install_reality() {
  local REALITY_PORT REALITY_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
  local requested key_output line
  if [[ -f $STATE_DIR/reality.env ]] \
    && systemctl is-active --quiet jd-reality.service \
    && systemctl is-enabled --quiet jd-reality.service; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/reality.env"
    ensure_reality_firewall "$REALITY_PORT"
    info 'Reality 已安装并运行，保留现有节点。'
    return
  fi
  install_xray
  if [[ -f $STATE_DIR/reality.env ]]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/reality.env"
  else
    read -r -p 'Reality TCP 端口 [443]：' requested
    REALITY_PORT=${requested:-443}
    [[ $REALITY_PORT =~ ^[0-9]+$ ]] && ((REALITY_PORT >= 1 && REALITY_PORT <= 65535)) \
      || die '端口必须是 1 到 65535 之间的数字。'
    tcp_port_available "$REALITY_PORT" || die "TCP $REALITY_PORT 已被占用，请重新运行并选择其他端口。"
    REALITY_UUID=$(cat /proc/sys/kernel/random/uuid)
    REALITY_SHORT_ID=$(openssl rand -hex 8)
    key_output=$("$BIN_DIR/xray" x25519)
    REALITY_PRIVATE_KEY=''
    REALITY_PUBLIC_KEY=''
    while IFS= read -r line; do
      case $line in
        PrivateKey:*|Private\ key:*) REALITY_PRIVATE_KEY=${line#*:}; REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY# } ;;
        'Password (PublicKey):'*|Password:*|PublicKey:*|Public\ key:*) REALITY_PUBLIC_KEY=${line#*:}; REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY# } ;;
      esac
    done <<<"$key_output"
    [[ $REALITY_PRIVATE_KEY =~ ^[A-Za-z0-9_-]{43}$ && $REALITY_PUBLIC_KEY =~ ^[A-Za-z0-9_-]{43}$ ]] \
      || die '无法解析 Xray Reality 密钥。'
    printf 'REALITY_PORT=%s\nREALITY_UUID=%s\nREALITY_PRIVATE_KEY=%s\nREALITY_PUBLIC_KEY=%s\nREALITY_SHORT_ID=%s\n' \
      "$REALITY_PORT" "$REALITY_UUID" "$REALITY_PRIVATE_KEY" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" \
      >"$STATE_DIR/reality.env"
  fi

  cat >"$CONFIG_DIR/reality.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $REALITY_PORT,
    "protocol": "vless",
    "settings": {"clients": [{"id": "$REALITY_UUID", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "target": "$REALITY_SNI:443",
        "xver": 0,
        "serverNames": ["$REALITY_SNI"],
        "privateKey": "$REALITY_PRIVATE_KEY",
        "shortIds": ["$REALITY_SHORT_ID"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF
  "$BIN_DIR/xray" run -test -config "$CONFIG_DIR/reality.json"

  cat >"$SYSTEMD_DIR/jd-reality.service" <<EOF
# jd-node-managed
[Unit]
Description=JD VLESS Reality server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/xray run -config $CONFIG_DIR/reality.json
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now jd-reality.service
  systemctl is-active --quiet jd-reality.service || die 'Reality 服务启动失败。'
  ensure_reality_firewall "$REALITY_PORT"
}

uninstall_all() {
  require_root
  command -v systemctl >/dev/null || die '找不到 systemctl，无法安全停止服务。'
  local service unit command_path managed=0 HY2_UFW_MANAGED=0 HY2_IPTABLES_MANAGED=0 REALITY_UFW_MANAGED=0 REALITY_IPTABLES_MANAGED=0

  # Only stop units created by this project. Older releases had no marker,
  # so their ExecStart path is also accepted as proof of ownership.
  for service in jd-argo jd-xray jd-hy2 jd-reality; do
    unit="$SYSTEMD_DIR/$service.service"
    if [[ -f $unit ]] && grep -Fq "$APP_DIR/" "$unit"; then
      systemctl stop "$service.service" || die "无法停止 $service，未继续删除其文件。"
      if systemctl is-active --quiet "$service.service"; then
        die "$service 仍在运行，已停止卸载。"
      fi
      systemctl disable "$service.service" >/dev/null
      rm -f -- "$unit"
      managed=1
    elif [[ -f $unit ]]; then
      printf '保留非本脚本创建的服务：%s\n' "$unit" >&2
    fi
  done
  systemctl daemon-reload
  systemctl reset-failed jd-argo.service jd-xray.service jd-hy2.service jd-reality.service >/dev/null 2>&1 || true

  if [[ -x $BIN_DIR/hy2-hop && -f $STATE_DIR/hy2.env ]]; then
    "$BIN_DIR/hy2-hop" stop || die '无法清除 HY2 端口跳跃规则，已停止卸载。'
  fi

  if [[ -f $STATE_DIR/hy2.env ]]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/hy2.env"
    if [[ ${HY2_UFW_MANAGED:-0} == 1 ]] && command -v ufw >/dev/null; then
      ufw --force delete allow "$HY2_PORT/udp" >/dev/null 2>&1 || \
        printf '未能移除 UFW 的 UDP %s 规则，请手动检查。\n' "$HY2_PORT" >&2
    fi
    if [[ ${HY2_IPTABLES_MANAGED:-0} == 1 ]] && command -v iptables >/dev/null; then
      local -a rule=(-p udp --dport "$HY2_PORT" -m comment --comment jd-node-hy2 -j ACCEPT)
      while iptables -C INPUT "${rule[@]}" >/dev/null 2>&1; do
        iptables -D INPUT "${rule[@]}" || break
      done
      persist_ipv4_firewall
    fi
  fi

  if [[ -f $STATE_DIR/reality.env ]]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/reality.env"
    if [[ ${REALITY_UFW_MANAGED:-0} == 1 ]] && command -v ufw >/dev/null; then
      ufw --force delete allow "$REALITY_PORT/tcp" >/dev/null 2>&1 || \
        printf '未能移除 UFW 的 TCP %s 规则，请手动检查。\n' "$REALITY_PORT" >&2
    fi
    if [[ ${REALITY_IPTABLES_MANAGED:-0} == 1 ]] && command -v iptables >/dev/null; then
      local -a reality_rule=(-p tcp --dport "$REALITY_PORT" -m comment --comment jd-node-reality -j ACCEPT)
      while iptables -C INPUT "${reality_rule[@]}" >/dev/null 2>&1; do
        iptables -D INPUT "${reality_rule[@]}" || break
      done
      persist_ipv4_firewall
    fi
  fi

  [[ $APP_DIR == /opt/jd-node ]] || die '应用目录不符合预期，停止删除。'
  if [[ -d $APP_DIR || -L $APP_DIR ]]; then
    rm -rf -- "$APP_DIR"
    managed=1
  fi
  for command_path in /usr/local/bin/jd /usr/local/bin/jdxz; do
    if [[ -f $command_path ]] && grep -q 'jd-node-managed' "$command_path" 2>/dev/null; then
      rm -f -- "$command_path"
      managed=1
    fi
  done
  if ((managed)); then
    printf 'JD 节点服务、文件和命令已卸载。\n'
  else
    printf '未找到由本脚本安装的内容。\n'
  fi
}

show_nodes() {
  require_root
  local found=0 host ip hy2_status reality_status
  if [[ -f $STATE_DIR/argo.env ]]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/argo.env"
    host=$(current_argo_host)
    printf '\nArgo：%s\n' "$(systemctl is-active jd-argo.service 2>/dev/null || true)"
    if [[ -n $host ]]; then
      printf 'vless://%s@%s:443?encryption=none&type=ws&path=%%2F%s&host=%s&security=tls&sni=%s#JD-Argo\n' \
        "$ARGO_UUID" "$host" "${ARGO_PATH#/}" "$host" "$host"
    else
      printf '暂未取得临时域名。请稍后执行 jd，或检查 journalctl -u jd-argo。\n'
    fi
    found=1
  fi
  if [[ -f $STATE_DIR/hy2.env ]]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/hy2.env"
    hy2_status=$(systemctl is-active jd-hy2.service 2>/dev/null || true)
    printf '\nHysteria2：%s\n' "$hy2_status"
    if [[ $hy2_status != active ]]; then
      printf '服务未运行，节点暂不可用。执行 sudo systemctl enable --now jd-hy2 后重试 sudo jd。\n'
      printf '若启动失败，执行 sudo journalctl -u jd-hy2 -n 50 --no-pager 查看原因。\n'
    else
      ip=$(public_ipv4)
      if [[ -n $ip ]]; then
        if [[ -n ${HY2_HOP_RANGE:-} ]]; then
          printf 'hysteria2://%s@%s:%s/?insecure=1&sni=%s&pinSHA256=%s#JD-HY2-Hop\n' \
            "$HY2_PASSWORD" "$ip" "$HY2_HOP_RANGE" "$SNI" "$HY2_PIN"
        fi
        printf 'hysteria2://%s@%s:%s/?insecure=1&sni=%s&pinSHA256=%s#JD-HY2\n' \
          "$HY2_PASSWORD" "$ip" "$HY2_PORT" "$SNI" "$HY2_PIN"
      else
        printf '无法识别公网 IPv4；请检查网络后重试 jd。\n'
      fi
    fi
    found=1
  fi
  if [[ -f $STATE_DIR/reality.env ]]; then
    # shellcheck disable=SC1091
    . "$STATE_DIR/reality.env"
    reality_status=$(systemctl is-active jd-reality.service 2>/dev/null || true)
    printf '\nVLESS Reality：%s\n' "$reality_status"
    if [[ $reality_status != active ]]; then
      printf '服务未运行。执行 sudo journalctl -u jd-reality -n 50 --no-pager 查看原因。\n'
    else
      ip=$(public_ipv4)
      if [[ -n $ip ]]; then
        printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#JD-Reality\n' \
          "$REALITY_UUID" "$ip" "$REALITY_PORT" "$REALITY_SNI" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID"
      else
        printf '无法识别公网 IPv4；请检查网络后重试 jd。\n'
      fi
    fi
    found=1
  fi
  ((found)) || printf '尚未安装节点。\n'
}

main() {
  if [[ ${1:-} == --uninstall ]]; then
    [[ $# -eq 1 ]] || die 'jdxz 不接受额外参数。'
    uninstall_all
    return
  fi
  if [[ ${1:-} == --show ]]; then
    show_nodes
    return
  fi
  if [[ ${1:-} == --help ]]; then
    printf '用法：bash run.sh（交互菜单）；安装后执行 sudo jd 查看节点，sudo jdxz 完全卸载。\n'
    return
  fi
  [[ $# -eq 0 ]] || die '未知参数。运行 bash run.sh --help 查看用法。'
  require_root
  printf '\n========== Viper ==========\n\nJD 节点部署\n  1) Argo 临时隧道 (VLESS)\n  2) Hysteria2\n  3) VLESS Raw Reality\n  4) 安装全部\n  5) 退出\n\n'
  local choice
  read -r -p '请选择 [1/2/3/4/5]：' choice
  case "$choice" in
    5) return ;;
    1|2|3|4) prepare ;;
    *) die '无效选项。' ;;
  esac
  case "$choice" in
    1) install_argo ;;
    2) install_hy2 ;;
    3) install_reality ;;
    4) install_argo; install_hy2; install_reality ;;
  esac
  show_nodes
  printf '\n以后运行 sudo jd 可查看当前节点链接。\n'
}

main "$@"
