#!/usr/bin/env bash
# XS-Onkey - Xray / sing-box multi-protocol one-click deployment script
# No Argo, WARP, Cloudflare, CDN or cloudflared integration.

set -Eeuo pipefail
IFS=$'\n\t'

readonly BASE_DIR="/etc/xs-onekey"
readonly ENV_FILE="$BASE_DIR/config.env"
readonly XRAY_CONFIG="$BASE_DIR/xray.json"
readonly SING_CONFIG="$BASE_DIR/sing-box.json"
readonly SHARE_FILE="$BASE_DIR/share.txt"
readonly SUB_FILE="$BASE_DIR/subscription.txt"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly SING_BIN="/usr/local/bin/sing-box"
readonly MANAGER_BIN="/usr/local/sbin/xs-onekey"
readonly INSTALL_URL="https://raw.githubusercontent.com/xxyy3130/XS-Onkey/main/install.sh"
readonly BBR_CONF="/etc/sysctl.d/99-xs-onekey-bbr.conf"
readonly BBR_STATE_DIR="/var/lib/xs-onekey-bbr"
readonly BBR_PREVIOUS="$BBR_STATE_DIR/previous.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
INSTALL_COMPLETED=false
UNINSTALL_COMPLETED=false
INSTALL_IN_PROGRESS=false
XRAY_PREEXISTED=false
SING_PREEXISTED=false
log()  { printf "%b[xs-onkey]%b %s\n" "$CYAN" "$NC" "$*"; }
ok()   { printf "%b[xs-onkey]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[xs-onkey] 警告:%b %s\n" "$YELLOW" "$NC" "$*" >&2; }
die()  {
  printf "%b[xs-onkey] 错误:%b %s\n" "$RED" "$NC" "$*" >&2
  cleanup_partial_install
  exit 1
}
on_error() {
  local status=$?
  local line=$1 command=$2
  printf "%b[xs-onkey] 错误:%b 第 %s 行命令失败（状态 %s）：%s\n" "$RED" "$NC" "$line" "$status" "$command" >&2
  cleanup_partial_install
  exit "$status"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 权限运行。"; }
have() { command -v "$1" >/dev/null 2>&1; }
cleanup_partial_install() {
  [[ $INSTALL_IN_PROGRESS == true ]] || return 0
  INSTALL_IN_PROGRESS=false
  warn "安装未完成，正在清理本次创建的文件。"
  if have systemctl; then
    systemctl disable --now xs-onekey-xray.service xs-onekey-sing-box.service >/dev/null 2>&1 || true
  fi
  rm -f /etc/systemd/system/xs-onekey-xray.service /etc/systemd/system/xs-onekey-sing-box.service
  have systemctl && systemctl daemon-reload >/dev/null 2>&1 || true
  [[ $BASE_DIR == /etc/xs-onekey ]] && rm -rf -- "$BASE_DIR"
  rm -f "$MANAGER_BIN"
  [[ $XRAY_PREEXISTED == true ]] || rm -f "$XRAY_BIN"
  [[ $SING_PREEXISTED == true ]] || rm -f "$SING_BIN"
}
csv_has() { [[ ",${PROTOCOLS}," == *",$1,"* ]]; }
b64_nowrap() { base64 | tr -d '\r\n'; }
b64url() { b64_nowrap | tr '+/' '-_' | tr -d '='; }
random_hex() { openssl rand -hex "${1:-16}"; }
random_char() {
  local alphabet=$1 byte index
  byte=$(openssl rand -hex 1) || return 1
  index=$((16#$byte % ${#alphabet}))
  printf '%s' "${alphabet:index:1}"
}
random_password() {
  local upper lower digit symbol body
  upper=$(random_char 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') || return 1
  lower=$(random_char 'abcdefghijklmnopqrstuvwxyz') || return 1
  digit=$(random_char '0123456789') || return 1
  symbol=$(random_char '._~-') || return 1
  body=$(openssl rand -base64 18) || return 1
  body=${body//$'\n'/}
  body=${body//+/.}; body=${body//\//_}; body=${body//=/-}
  printf '%s%s%s%s%s' "$upper" "$body" "$lower" "$digit" "$symbol"
}
new_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  elif [[ -x $SING_BIN ]]; then "$SING_BIN" generate uuid
  else "$XRAY_BIN" uuid
  fi
}
uri_host() { [[ $1 == *:* ]] && printf '[%s]' "$1" || printf '%s' "$1"; }

load_env() {
  [[ -r "$ENV_FILE" ]] || die "尚未安装，找不到 ${ENV_FILE}。"
  # Values are generated or character-validated before being persisted.
  # shellcheck disable=SC1090
  source "$ENV_FILE"
}

managed_install_available() {
  [[ -r $ENV_FILE ]]
}

managed_artifacts_available() {
  [[ -d $BASE_DIR || -e $ENV_FILE || -e /etc/systemd/system/xs-onekey-xray.service ||
     -e /etc/systemd/system/xs-onekey-sing-box.service || -e $MANAGER_BIN ]]
}

managed_services_available() {
  local missing=''
  if [[ $NEED_XRAY == true ]] && ! systemctl cat xs-onekey-xray.service >/dev/null 2>&1; then
    missing='xs-onekey-xray.service'
  fi
  if [[ $NEED_SING == true ]] && ! systemctl cat xs-onekey-sing-box.service >/dev/null 2>&1; then
    missing=${missing:+$missing, }'xs-onekey-sing-box.service'
  fi
  [[ -z $missing ]] || { warn "找不到服务：$missing，已返回主菜单。"; return 1; }
}

detect_os() {
  [[ -r /etc/os-release ]] || die "无法识别 Linux 发行版。"
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-} ${ID_LIKE:-}" in
    *debian*|*ubuntu*) PKG_FAMILY=debian ;;
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) PKG_FAMILY=rhel ;;
    *alpine*) PKG_FAMILY=alpine ;;
    *) die "仅支持 Debian/Ubuntu、RHEL 系和带 systemd 的 Alpine。" ;;
  esac
  have systemctl || die "当前系统没有 systemd。"
}

install_dependencies() {
  local package pm
  local -a packages=() missing=()
  case "$PKG_FAMILY" in
    debian)
      packages=(ca-certificates curl jq openssl unzip tar iproute2 bind9-dnsutils cron)
      for package in "${packages[@]}"; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
          log "依赖已安装，跳过：$package"
        else
          missing+=("$package")
        fi
      done
      ((${#missing[@]})) || { log "基础依赖均已安装，跳过安装。"; return 0; }
      log "准备安装 ${#missing[@]} 个缺少的基础依赖。"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y "${missing[@]}"
      ;;
    rhel)
      packages=(ca-certificates curl jq openssl unzip tar iproute bind-utils cronie)
      for package in "${packages[@]}"; do
        if rpm -q "$package" >/dev/null 2>&1; then log "依赖已安装，跳过：$package"; else missing+=("$package"); fi
      done
      ((${#missing[@]})) || { log "基础依赖均已安装，跳过安装。"; return 0; }
      log "准备安装 ${#missing[@]} 个缺少的基础依赖。"
      pm=dnf; have dnf || pm=yum
      "$pm" install -y "${missing[@]}"
      ;;
    alpine)
      packages=(ca-certificates curl jq openssl unzip tar iproute2 bind-tools bash cronie)
      for package in "${packages[@]}"; do
        if apk info -e "$package" >/dev/null 2>&1; then log "依赖已安装，跳过：$package"; else missing+=("$package"); fi
      done
      ((${#missing[@]})) || { log "基础依赖均已安装，跳过安装。"; return 0; }
      log "准备安装 ${#missing[@]} 个缺少的基础依赖。"
      apk add --no-cache "${missing[@]}"
      ;;
  esac
  return 0
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) XRAY_ARCH=64; SING_ARCH=amd64 ;;
    aarch64|arm64) XRAY_ARCH=arm64-v8a; SING_ARCH=arm64 ;;
    armv7l|armv7) XRAY_ARCH=arm32-v7a; SING_ARCH=armv7 ;;
    s390x) XRAY_ARCH=s390x; SING_ARCH=s390x ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

github_latest_tag() {
  local repo=$1 tag
  tag=$(curl -fsSL --retry 3 --connect-timeout 15 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name // empty') || return 1
  [[ -n "$tag" ]] || return 1
  printf '%s' "$tag"
}

installed_core_version() {
  local binary=$1 line version
  [[ -x $binary ]] || return 1
  line=$("$binary" version 2>/dev/null | sed -n '1p') || return 1
  version=$(sed -n 's/^[^0-9]*\([0-9][0-9.]*\).*/\1/p' <<<"$line")
  [[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  printf '%s' "$version"
}

compare_numeric_versions() {
  local left=${1#v} right=${2#v} i max lv rv
  local -a left_parts=() right_parts=()
  [[ $left =~ ^([0-9]+(\.[0-9]+)*) ]] || return 1
  left=${BASH_REMATCH[1]}
  [[ $right =~ ^([0-9]+(\.[0-9]+)*) ]] || return 1
  right=${BASH_REMATCH[1]}
  IFS='.' read -r -a left_parts <<<"$left"
  IFS='.' read -r -a right_parts <<<"$right"
  max=${#left_parts[@]}
  if (( ${#right_parts[@]} > max )); then max=${#right_parts[@]}; fi
  for ((i=0; i<max; i++)); do
    lv=${left_parts[i]:-0}; rv=${right_parts[i]:-0}
    if (( 10#$lv < 10#$rv )); then printf '%s' -1; return 0; fi
    if (( 10#$lv > 10#$rv )); then printf '%s' 1; return 0; fi
  done
  printf '%s' 0
}

install_xray() {
  local requested_tag=${1:-} tmp tag url installed comparison
  tmp=$(mktemp -d /tmp/xs-onekey-xray.XXXXXX) || return 1
  if [[ -n $requested_tag ]]; then tag=$requested_tag
  else tag=$(github_latest_tag XTLS/Xray-core) || { rm -rf -- "$tmp"; return 1; }
  fi
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${XRAY_ARCH}.zip"
  log "下载 Xray ${tag}..."
  curl -fL --retry 3 --connect-timeout 15 --max-time 600 -o "$tmp/xray.zip" "$url" || { rm -rf -- "$tmp"; return 1; }
  unzip -oq "$tmp/xray.zip" xray -d "$tmp" || { rm -rf -- "$tmp"; return 1; }
  install -m 0755 "$tmp/xray" "$XRAY_BIN" || { rm -rf -- "$tmp"; return 1; }
  installed=$(installed_core_version "$XRAY_BIN" || true)
  comparison=$(compare_numeric_versions "$installed" "$tag" || printf '%s' -1)
  [[ $comparison == 0 ]] || { warn "Xray 下载版本与请求版本不一致：${installed:-未知} != ${tag}"; rm -rf -- "$tmp"; return 1; }
  "$XRAY_BIN" version | sed -n '1p'
  rm -rf -- "$tmp"
}

install_sing() {
  local requested_tag=${1:-} tmp tag ver url extracted installed comparison
  tmp=$(mktemp -d /tmp/xs-onekey-sing.XXXXXX) || return 1
  if [[ -n $requested_tag ]]; then tag=$requested_tag
  else tag=$(github_latest_tag SagerNet/sing-box) || { rm -rf -- "$tmp"; return 1; }
  fi
  ver=${tag#v}
  url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${SING_ARCH}.tar.gz"
  log "下载 sing-box ${tag}..."
  curl -fL --retry 3 --connect-timeout 15 --max-time 600 -o "$tmp/sing.tar.gz" "$url" || { rm -rf -- "$tmp"; return 1; }
  tar -xzf "$tmp/sing.tar.gz" -C "$tmp" || { rm -rf -- "$tmp"; return 1; }
  extracted="$tmp/sing-box-${ver}-linux-${SING_ARCH}/sing-box"
  [[ -f "$extracted" ]] || { rm -rf -- "$tmp"; return 1; }
  install -m 0755 "$extracted" "$SING_BIN" || { rm -rf -- "$tmp"; return 1; }
  installed=$(installed_core_version "$SING_BIN" || true)
  comparison=$(compare_numeric_versions "$installed" "$tag" || printf '%s' -1)
  [[ $comparison == 0 ]] || { warn "sing-box 下载版本与请求版本不一致：${installed:-未知} != ${tag}"; rm -rf -- "$tmp"; return 1; }
  "$SING_BIN" version | sed -n '1p'
  rm -rf -- "$tmp"
}

install_required_cores() {
  detect_arch
  if [[ $NEED_XRAY == true ]]; then
    if [[ -x $XRAY_BIN ]] && "$XRAY_BIN" version >/dev/null 2>&1; then
      log "检测到现有 Xray，安装时跳过核心下载，仅更新配置。"
    else
      install_xray
    fi
  fi
  if [[ $NEED_SING == true ]]; then
    if [[ -x $SING_BIN ]] && "$SING_BIN" version >/dev/null 2>&1; then
      log "检测到现有 sing-box，安装时跳过核心下载，仅更新配置。"
    else
      install_sing
    fi
  fi
  return 0
}

expand_protocols() {
  local raw=$1 token expanded=''
  raw=${raw//[[:space:]]/}
  IFS=',' read -r -a requested <<<"$raw"
  for token in "${requested[@]}"; do
    case "$token" in
      vless) token='vless-reality-vision,vless-xhttp-reality-enc,vless-xhttp,vless-tcp-tls,vless-xhttp-tls' ;;
      xray) token='vless,hy2,trojan,socks'; token=$(expand_protocols "$token") ;;
      sing) token='tuic,anytls,any-reality,ss2022' ;;
      all) token='vless,hy2,tuic,anytls,any-reality,ss2022,trojan,socks'; token=$(expand_protocols "$token") ;;
    esac
    expanded=${expanded:+$expanded,}$token
  done
  local result='' item
  IFS=',' read -r -a requested <<<"$expanded"
  for item in "${requested[@]}"; do
    case ",$result," in *",$item,"*) ;; *) result=${result:+$result,}$item ;; esac
  done
  printf '%s' "$result"
}

validate_protocols() {
  local item
  IFS=',' read -r -a requested <<<"$PROTOCOLS"
  for item in "${requested[@]}"; do
    case "$item" in
      vless-reality-vision|vless-xhttp-reality-enc|vless-xhttp|vless-tcp-tls|vless-xhttp-tls|\
      hy2|tuic|anytls|any-reality|ss2022|trojan|socks) ;;
      *) die "未知协议档：$item，请重新选择安装协议。" ;;
    esac
  done
  [[ -n "$PROTOCOLS" ]] || die "至少选择一个协议。"
}

install_protocol_menu() {
  cat <<'EOF'

请选择要安装的协议（可多选，用英文逗号,分隔）：
 1) vless-reality-vision
 2) vless-xhttp-reality-enc
 3) vless-xhttp
 4) vless-tcp-tls
 5) vless-xhttp-tls
 6) hy2
 7) tuic
 8) anytls
 9) any-reality
10) ss2022
11) trojan
12) socks
 0) 返回
EOF
}

protocol_from_number() {
  case "$1" in
    1) printf vless-reality-vision ;; 2) printf vless-xhttp-reality-enc ;; 3) printf vless-xhttp ;;
    4) printf vless-tcp-tls ;; 5) printf vless-xhttp-tls ;; 6) printf hy2 ;;
    7) printf tuic ;; 8) printf anytls ;; 9) printf any-reality ;;
    10) printf ss2022 ;; 11) printf trojan ;; 12) printf socks ;; *) return 1 ;;
  esac
}

select_protocols() {
  local raw='' answer token mapped selected=''
  local -a choices=()
  [[ -t 0 ]] || die "本脚本仅支持交互终端运行。"
  install_protocol_menu
  read -r -p '请输入编号: ' answer
  [[ $answer != 0 ]] || { warn "已取消安装，返回主菜单。"; return 1; }
  answer=${answer//，/,}; answer=${answer//[[:space:]]/,}
  IFS=',' read -r -a choices <<<"$answer"
  for token in "${choices[@]}"; do
    [[ -n "$token" ]] || continue
    mapped=$(protocol_from_number "$token") || die "无效协议编号：$token"
    selected=${selected:+$selected,}$mapped
  done
  [[ -n "$selected" ]] || die "至少选择一个协议。"
  raw=$selected
  PROTOCOLS=$(expand_protocols "$raw")
  validate_protocols
}

determine_cores() {
  NEED_XRAY=false; NEED_SING=false
  local item
  IFS=',' read -r -a requested <<<"$PROTOCOLS"
  for item in "${requested[@]}"; do
    case "$item" in
      tuic|anytls|any-reality|ss2022) NEED_SING=true ;;
      vless-*|hy2|trojan|socks) NEED_XRAY=true ;;
    esac
  done
  [[ $NEED_XRAY == true ]] && CORE_SUMMARY=Xray || CORE_SUMMARY=''
  [[ $NEED_SING == true ]] && CORE_SUMMARY=${CORE_SUMMARY:+$CORE_SUMMARY+}sing-box
  log "协议选择：$PROTOCOLS"
  log "核心计划：$CORE_SUMMARY"
}

valid_host() { [[ $1 =~ ^[A-Za-z0-9._:-]+$ ]] && [[ $1 != -* ]] && [[ $1 != *..* ]]; }
valid_domain() { [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
valid_uuid() { [[ $1 =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-8][0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]]; }
valid_password() { [[ $1 =~ ^[A-Za-z0-9._~-]{8,128}$ ]]; }
public_ip() {
  local ip=''
  ip=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
  [[ -n "$ip" ]] || ip=$(curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)
  printf '%s' "$ip"
}

set_feature_flags() {
  TLS_REQUIRED=false; REALITY_REQUIRED=false; VLESS_ENC_REQUIRED=false
  UUID_REQUIRED=false
  local item
  IFS=',' read -r -a requested <<<"$PROTOCOLS"
  for item in "${requested[@]}"; do
    case "$item" in
      *-tls|hy2|tuic|anytls|trojan) TLS_REQUIRED=true ;;
    esac
    case "$item" in vless-reality-vision|vless-xhttp-reality-enc|any-reality) REALITY_REQUIRED=true ;; esac
    case "$item" in vless-*|tuic) UUID_REQUIRED=true ;; esac
    case "$item" in vless-xhttp-reality-enc|vless-xhttp) VLESS_ENC_REQUIRED=true ;; esac
  done
  return 0
}

declare -A RESERVED_PORTS=()
RANDOM_PORT_RESULT=''

random_available_port() {
  local port attempts=0
  while (( attempts < 5000 )); do
    ((attempts+=1))
    port=$((10000 + ((RANDOM * 32768 + RANDOM) % 45001)))
    [[ -z ${RESERVED_PORTS[$port]+x} ]] || continue
    if ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . || ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .; then
      continue
    fi
    RESERVED_PORTS[$port]=1
    RANDOM_PORT_RESULT=$port
    return 0
  done
  die "无法在范围10000-55000内找到可用随机端口。"
}

prompt_protocol_port() {
  local profile=$1 variable=$2 default_port answer
  csv_has "$profile" || { printf -v "$variable" 0; return 0; }
  random_available_port
  default_port=$RANDOM_PORT_RESULT
  read -r -p "${profile} 端口 [${default_port}]: " answer
  answer=${answer:-$default_port}
  valid_port "$answer" || die "无效端口：$answer"
  (( 10000 <= 10#$answer && 10#$answer <= 55000 )) || die "端口必须在范围10000-55000内。"
  if [[ $answer != "$default_port" && -n ${RESERVED_PORTS[$answer]+x} ]]; then die "端口 $answer 已被其他协议使用。"; fi
  RESERVED_PORTS[$answer]=1
  printf -v "$variable" '%s' "$answer"
  return 0
}

set_ports() {
  RESERVED_PORTS=()
  printf '\n端口设置（默认端口随机生成，范围10000-55000）：\n'
  prompt_protocol_port vless-reality-vision VLESS_REALITY_VISION_PORT
  prompt_protocol_port vless-xhttp-reality-enc VLESS_XHTTP_REALITY_ENC_PORT
  prompt_protocol_port vless-xhttp VLESS_XHTTP_PORT
  prompt_protocol_port vless-tcp-tls VLESS_TCP_TLS_PORT
  prompt_protocol_port vless-xhttp-tls VLESS_XHTTP_TLS_PORT
  prompt_protocol_port hy2 HY2_PORT
  prompt_protocol_port tuic TUIC_PORT
  prompt_protocol_port anytls ANYTLS_PORT
  prompt_protocol_port any-reality ANY_REALITY_PORT
  prompt_protocol_port ss2022 SS2022_PORT
  prompt_protocol_port trojan TROJAN_PORT
  prompt_protocol_port socks SOCKS_PORT
  return 0
}

prompt_settings() {
  local answer detected
  detected=$(public_ip)
  SERVER_ADDR=$detected
  read -r -p "客户端连接地址（域名或公网 IP）[${SERVER_ADDR}]: " answer
  SERVER_ADDR=${answer:-$SERVER_ADDR}
  [[ -n "$SERVER_ADDR" ]] || die "客户端连接地址不能为空。"
  valid_host "$SERVER_ADDR" || die "连接地址包含非法字符。"
  [[ $SERVER_ADDR == *:* ]] && LISTEN_ADDR='::' || LISTEN_ADDR='0.0.0.0'
  SNI=apple.com
  if [[ $REALITY_REQUIRED == true || $TLS_REQUIRED == true ]]; then
    read -r -p "SNI [${SNI}]: " answer
    SNI=${answer:-$SNI}
  fi
  valid_domain "$SNI" || die "SNI 必须是有效域名。"

  if [[ $TLS_REQUIRED == true ]]; then
    TLS_MODE=selfsigned
    printf 'TLS：1) 自签名/IP（默认）  2) ACME 域名证书\n'
    read -r -p '请选择 [1]: ' answer
    [[ ${answer:-1} == 2 ]] && TLS_MODE=acme || TLS_MODE=selfsigned
    if [[ $TLS_MODE == acme ]]; then
      DOMAIN=$SNI; ACME_EMAIL=''
      read -r -p 'ACME 邮箱: ' ACME_EMAIL
      [[ $ACME_EMAIL =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "ACME 邮箱格式错误。"
      SERVER_ADDR=$DOMAIN; TLS_INSECURE=false
    elif [[ $TLS_MODE == selfsigned ]]; then
      DOMAIN=''; ACME_EMAIL=''; TLS_INSECURE=true
    fi
  else
    TLS_MODE=none; DOMAIN=''; ACME_EMAIL=''; TLS_INSECURE=false
  fi
  set_ports
  return 0
}

make_certificate() {
  CERT_FILE="$BASE_DIR/tls/fullchain.pem"; KEY_FILE="$BASE_DIR/tls/private.key"
  CERT_SHA256=''
  [[ $TLS_REQUIRED == true ]] || { CERT_FILE=''; KEY_FILE=''; return; }
  install -d -m 0700 "$BASE_DIR/tls"
  if [[ $TLS_MODE == acme ]]; then
    if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow 80/tcp >/dev/null
    elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent --add-service=http >/dev/null; firewall-cmd --reload >/dev/null; fi
    ss -H -ltn 'sport = :80' 2>/dev/null | grep -q . && die "ACME standalone 需要 TCP/80，但端口已占用。"
    curl -fsSL --retry 3 https://get.acme.sh | sh -s email="$ACME_EMAIL"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" --keylength ec-256
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" \
      --reloadcmd "systemctl try-restart xs-onekey-xray.service xs-onekey-sing-box.service >/dev/null 2>&1 || true"
  else
    local san_type=DNS
    [[ $SNI =~ ^[0-9.]+$ || $SNI == *:* ]] && san_type=IP
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" \
      -subj "/CN=${SNI}" -addext "subjectAltName=${san_type}:${SNI}" \
      -addext 'basicConstraints=critical,CA:FALSE' \
      -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
      -addext 'extendedKeyUsage=serverAuth' >/dev/null 2>&1
  fi
  chmod 0600 "$KEY_FILE" "$CERT_FILE"
  CERT_SHA256=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 | sed 's/^.*=//; s/://g' | tr '[:upper:]' '[:lower:]')
  [[ $CERT_SHA256 =~ ^[0-9a-f]{64}$ ]] || die "无法计算 TLS 证书 SHA-256 指纹。"
}

generate_vless_encryption_pair() {
  local encryption_var=$1 decryption_var=$2 output encryption decryption
  output=$("$XRAY_BIN" vlessenc) || return 1
  encryption=$(printf '%s\n' "$output" | awk 'tolower($0) ~ /"encryption"/ {sub(/^[^:]*:/,""); gsub(/[[:space:]",]/,""); print; exit}')
  decryption=$(printf '%s\n' "$output" | awk 'tolower($0) ~ /"decryption"/ {sub(/^[^:]*:/,""); gsub(/[[:space:]",]/,""); print; exit}')
  [[ -n "$encryption" && -n "$decryption" ]] || return 1
  printf -v "$encryption_var" '%s' "$encryption"
  printf -v "$decryption_var" '%s' "$decryption"
}

generate_credentials() {
  local answer default_uuid name password
  local -A used_passwords=()
  default_uuid=$(new_uuid)
  UUID=$default_uuid
  if [[ $UUID_REQUIRED == true ]]; then
    read -r -p "UUID [${default_uuid}]: " answer
    UUID=${answer:-$default_uuid}
  fi
  valid_uuid "$UUID" || die "UUID 格式错误。"
  UUID=$(printf '%s' "$UUID" | tr '[:upper:]' '[:lower:]')

  TUIC_UUID=$UUID
  for name in TROJAN_PASSWORD HY2_PASSWORD TUIC_PASSWORD ANYTLS_PASSWORD ANY_REALITY_PASSWORD SOCKS_PASSWORD; do
    while :; do
      password=$(random_password)
      [[ -z ${used_passwords[$password]+x} ]] || continue
      used_passwords[$password]=1
      printf -v "$name" '%s' "$password"
      break
    done
  done
  SOCKS_USER="xsonekey$(random_hex 3)"
  SS2022_PASSWORD=$(openssl rand 16 | b64_nowrap)
  REALITY_SHORT_ID=$(random_hex 8)
  PATH_VLESS_XHTTP_REALITY_ENC="/$(random_hex 8)"
  PATH_VLESS_XHTTP="/$(random_hex 8)"
  while [[ $PATH_VLESS_XHTTP == "$PATH_VLESS_XHTTP_REALITY_ENC" ]]; do PATH_VLESS_XHTTP="/$(random_hex 8)"; done
  PATH_VLESS_XHTTP_TLS="/$(random_hex 8)"
  while [[ $PATH_VLESS_XHTTP_TLS == "$PATH_VLESS_XHTTP_REALITY_ENC" || $PATH_VLESS_XHTTP_TLS == "$PATH_VLESS_XHTTP" ]]; do PATH_VLESS_XHTTP_TLS="/$(random_hex 8)"; done
  REALITY_PRIVATE=''; REALITY_PUBLIC=''
  VLESS_XHTTP_REALITY_ENCRYPTION=none; VLESS_XHTTP_REALITY_DECRYPTION=none
  VLESS_XHTTP_ENCRYPTION=none; VLESS_XHTTP_DECRYPTION=none
  if [[ $REALITY_REQUIRED == true ]]; then
    local keys
    if [[ $NEED_SING == true ]]; then keys=$("$SING_BIN" generate reality-keypair)
    else keys=$("$XRAY_BIN" x25519)
    fi
    REALITY_PRIVATE=$(printf '%s\n' "$keys" | awk 'tolower($0) ~ /private.?key/ {gsub(/["()]/,"",$NF); print $NF; exit}')
    REALITY_PUBLIC=$(printf '%s\n' "$keys" | awk 'tolower($0) ~ /public.?key|password/ {gsub(/["()]/,"",$NF); print $NF; exit}')
    [[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" ]] || die "无法解析 REALITY 密钥输出。"
  fi
  if csv_has vless-xhttp-reality-enc; then
    generate_vless_encryption_pair VLESS_XHTTP_REALITY_ENCRYPTION VLESS_XHTTP_REALITY_DECRYPTION || die "无法生成 VLESS-XHTTP-Reality-ENC 密钥。"
  fi
  if csv_has vless-xhttp; then
    generate_vless_encryption_pair VLESS_XHTTP_ENCRYPTION VLESS_XHTTP_DECRYPTION || die "无法生成 VLESS-XHTTP-ENC 密钥。"
  fi
}

write_env() {
  umask 077
  local vars=(SERVER_ADDR LISTEN_ADDR PROTOCOLS NEED_XRAY NEED_SING CORE_SUMMARY TLS_REQUIRED REALITY_REQUIRED VLESS_ENC_REQUIRED UUID_REQUIRED TLS_MODE DOMAIN ACME_EMAIL SNI TLS_INSECURE CERT_FILE KEY_FILE CERT_SHA256 UUID TUIC_UUID TROJAN_PASSWORD HY2_PASSWORD TUIC_PASSWORD ANYTLS_PASSWORD ANY_REALITY_PASSWORD SOCKS_USER SOCKS_PASSWORD SS2022_PASSWORD REALITY_SHORT_ID REALITY_PRIVATE REALITY_PUBLIC VLESS_XHTTP_REALITY_DECRYPTION VLESS_XHTTP_REALITY_ENCRYPTION VLESS_XHTTP_DECRYPTION VLESS_XHTTP_ENCRYPTION PATH_VLESS_XHTTP_REALITY_ENC PATH_VLESS_XHTTP PATH_VLESS_XHTTP_TLS VLESS_REALITY_VISION_PORT VLESS_XHTTP_REALITY_ENC_PORT VLESS_XHTTP_PORT VLESS_TCP_TLS_PORT VLESS_XHTTP_TLS_PORT TROJAN_PORT HY2_PORT TUIC_PORT ANYTLS_PORT ANY_REALITY_PORT SS2022_PORT SOCKS_PORT)
  : >"$ENV_FILE"
  local name; for name in "${vars[@]}"; do printf '%s=%q\n' "$name" "${!name}" >>"$ENV_FILE"; done
  chmod 0600 "$ENV_FILE"
}

xray_add() {
  local object=$1 tmp
  tmp=$(mktemp "$BASE_DIR/.xray.XXXXXX")
  jq --argjson object "$object" '.inbounds += [$object]' "$XRAY_CONFIG" >"$tmp"
  mv -f "$tmp" "$XRAY_CONFIG"
}

xray_vless_object() {
  local tag=$1 port=$2 flow=$3 decrypt=$4 stream=$5
  jq -cn --arg tag "$tag" --arg listen "$LISTEN_ADDR" --argjson port "$port" --arg id "$UUID" --arg flow "$flow" --arg decrypt "$decrypt" --argjson stream "$stream" '
    {tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:[{id:$id,email:$tag}+if $flow=="" then {} else {flow:$flow} end],decryption:$decrypt},streamSettings:$stream,sniffing:{enabled:true,destOverride:["http","tls","quic"]}}'
}
tls_json() { jq -cn --arg sni "$SNI" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" --argjson alpn "$1" '{serverName:$sni,alpn:$alpn,certificates:[{certificateFile:$cert,keyFile:$key}]}'; }
reality_json() { jq -cn --arg target "${SNI}:443" --arg sni "$SNI" --arg key "$REALITY_PRIVATE" --arg sid "$REALITY_SHORT_ID" '{show:false,target:$target,xver:0,serverNames:[$sni],privateKey:$key,shortIds:[$sid]}'; }

write_xray_config() {
  [[ $NEED_XRAY == true ]] || return 0
  umask 077
  printf '%s\n' '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],"routing":{"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","protocol":["bittorrent"],"outboundTag":"block"}]}}' >"$XRAY_CONFIG"
  local stream tls reality obj
  reality=$(reality_json); tls=$(tls_json '["h2","http/1.1"]')
  if csv_has vless-reality-vision; then stream=$(jq -cn --argjson r "$reality" '{network:"raw",security:"reality",realitySettings:$r,rawSettings:{header:{type:"none"}}}'); obj=$(xray_vless_object vless-reality-vision "$VLESS_REALITY_VISION_PORT" xtls-rprx-vision none "$stream"); xray_add "$obj"; fi
  if csv_has vless-xhttp-reality-enc; then stream=$(jq -cn --argjson r "$reality" --arg path "$PATH_VLESS_XHTTP_REALITY_ENC" '{network:"xhttp",security:"reality",realitySettings:$r,xhttpSettings:{path:$path,mode:"auto"}}'); obj=$(xray_vless_object vless-xhttp-reality-enc "$VLESS_XHTTP_REALITY_ENC_PORT" '' "$VLESS_XHTTP_REALITY_DECRYPTION" "$stream"); xray_add "$obj"; fi
  if csv_has vless-xhttp; then stream=$(jq -cn --arg path "$PATH_VLESS_XHTTP" '{network:"xhttp",security:"none",xhttpSettings:{path:$path,mode:"auto"}}'); obj=$(xray_vless_object vless-xhttp "$VLESS_XHTTP_PORT" '' "$VLESS_XHTTP_DECRYPTION" "$stream"); xray_add "$obj"; fi
  if csv_has vless-tcp-tls; then stream=$(jq -cn --argjson t "$tls" '{network:"raw",security:"tls",tlsSettings:$t,rawSettings:{header:{type:"none"}}}'); obj=$(xray_vless_object vless-tcp-tls "$VLESS_TCP_TLS_PORT" xtls-rprx-vision none "$stream"); xray_add "$obj"; fi
  if csv_has vless-xhttp-tls; then stream=$(jq -cn --argjson t "$tls" --arg path "$PATH_VLESS_XHTTP_TLS" '{network:"xhttp",security:"tls",tlsSettings:$t,xhttpSettings:{path:$path,mode:"auto"}}'); obj=$(xray_vless_object vless-xhttp-tls "$VLESS_XHTTP_TLS_PORT" '' none "$stream"); xray_add "$obj"; fi

  if csv_has hy2; then stream=$(jq -cn --argjson t "$(tls_json '["h3"]')" '{network:"hysteria",security:"tls",tlsSettings:$t,hysteriaSettings:{version:2}}'); obj=$(jq -cn --arg listen "$LISTEN_ADDR" --argjson port "$HY2_PORT" --arg pass "$HY2_PASSWORD" --argjson stream "$stream" '{tag:"hy2",listen:$listen,port:$port,protocol:"hysteria",settings:{version:2,users:[{auth:$pass,email:"hy2"}]},streamSettings:$stream}'); xray_add "$obj"; fi
  if csv_has trojan; then stream=$(jq -cn --argjson t "$(tls_json '["http/1.1"]')" '{network:"raw",security:"tls",tlsSettings:$t,rawSettings:{header:{type:"none"}}}'); obj=$(jq -cn --arg listen "$LISTEN_ADDR" --argjson port "$TROJAN_PORT" --arg pass "$TROJAN_PASSWORD" --argjson stream "$stream" '{tag:"trojan",listen:$listen,port:$port,protocol:"trojan",settings:{clients:[{password:$pass,email:"trojan"}]},streamSettings:$stream}'); xray_add "$obj"; fi
  if csv_has socks; then obj=$(jq -cn --arg listen "$LISTEN_ADDR" --argjson port "$SOCKS_PORT" --arg user "$SOCKS_USER" --arg pass "$SOCKS_PASSWORD" '{tag:"socks",listen:$listen,port:$port,protocol:"socks",settings:{auth:"password",accounts:[{user:$user,pass:$pass}],udp:true}}'); xray_add "$obj"; fi
  chmod 0600 "$XRAY_CONFIG"
}

sing_add() {
  local object=$1 tmp
  tmp=$(mktemp "$BASE_DIR/.sing.XXXXXX")
  jq --argjson object "$object" '.inbounds += [$object]' "$SING_CONFIG" >"$tmp"
  mv -f "$tmp" "$SING_CONFIG"
}

write_sing_config() {
  [[ $NEED_SING == true ]] || return 0
  printf '%s\n' '{"log":{"level":"warn","timestamp":true},"inbounds":[],"route":{"rules":[{"protocol":"bittorrent","action":"reject"},{"ip_is_private":true,"action":"reject"}]}}' >"$SING_CONFIG"
  local tls reality obj
  tls=$(jq -cn --arg sni "$SNI" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" '{enabled:true,server_name:$sni,certificate_path:$cert,key_path:$key}')
  reality=$(jq -cn --arg sni "$SNI" --arg key "$REALITY_PRIVATE" --arg sid "$REALITY_SHORT_ID" '{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$key,short_id:[$sid]}}')
  if csv_has tuic; then obj=$(jq -cn --arg listen "$LISTEN_ADDR" --argjson port "$TUIC_PORT" --arg uuid "$TUIC_UUID" --arg pass "$TUIC_PASSWORD" --argjson tls "$tls" '{type:"tuic",tag:"tuic",listen:$listen,listen_port:$port,users:[{name:"xs-onekey",uuid:$uuid,password:$pass}],congestion_control:"bbr",zero_rtt_handshake:false,heartbeat:"10s",tls:($tls+{alpn:["h3"]})}'); sing_add "$obj"; fi
  if csv_has anytls; then obj=$(jq -cn --arg listen "$LISTEN_ADDR" --argjson port "$ANYTLS_PORT" --arg pass "$ANYTLS_PASSWORD" --argjson tls "$tls" '{type:"anytls",tag:"anytls",listen:$listen,listen_port:$port,users:[{name:"xs-onekey",password:$pass}],tls:$tls}'); sing_add "$obj"; fi
  if csv_has any-reality; then obj=$(jq -cn --arg listen "$LISTEN_ADDR" --argjson port "$ANY_REALITY_PORT" --arg pass "$ANY_REALITY_PASSWORD" --argjson reality "$reality" '{type:"anytls",tag:"any-reality",listen:$listen,listen_port:$port,users:[{name:"xs-onekey",password:$pass}],tls:$reality}'); sing_add "$obj"; fi
  if csv_has ss2022; then obj=$(jq -cn --arg listen "$LISTEN_ADDR" --argjson port "$SS2022_PORT" --arg pass "$SS2022_PASSWORD" '{type:"shadowsocks",tag:"ss2022",listen:$listen,listen_port:$port,method:"2022-blake3-aes-128-gcm",password:$pass}'); sing_add "$obj"; fi
  chmod 0600 "$SING_CONFIG"
}

generate_links() {
  local host label insecure_num ss_userinfo xray_pin_query='' hy2_pin_query=''
  host=$(uri_host "$SERVER_ADDR"); label=$(hostname -s 2>/dev/null | tr -cd 'A-Za-z0-9._-'); label=${label:-server}
  [[ $TLS_INSECURE == true ]] && insecure_num=1 || insecure_num=0
  if [[ $TLS_MODE == selfsigned ]]; then
    xray_pin_query="&pcs=${CERT_SHA256}"
    hy2_pin_query="&pinSHA256=${CERT_SHA256}&pcs=${CERT_SHA256}"
  fi
  : >"$SHARE_FILE"
  csv_has vless-reality-vision && printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s-VLESS-Reality-Vision\n' "$UUID" "$host" "$VLESS_REALITY_VISION_PORT" "$SNI" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$label" >>"$SHARE_FILE"
  csv_has vless-xhttp-reality-enc && printf 'vless://%s@%s:%s?encryption=%s&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&mode=auto&path=%s#%s-VLESS-XHTTP-Reality-ENC\n' "$UUID" "$host" "$VLESS_XHTTP_REALITY_ENC_PORT" "$VLESS_XHTTP_REALITY_ENCRYPTION" "$SNI" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$PATH_VLESS_XHTTP_REALITY_ENC" "$label" >>"$SHARE_FILE"
  csv_has vless-xhttp && printf 'vless://%s@%s:%s?encryption=%s&security=none&type=xhttp&mode=auto&path=%s#%s-VLESS-XHTTP-ENC\n' "$UUID" "$host" "$VLESS_XHTTP_PORT" "$VLESS_XHTTP_ENCRYPTION" "$PATH_VLESS_XHTTP" "$label" >>"$SHARE_FILE"
  csv_has vless-tcp-tls && printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=tls&sni=%s&type=tcp%s#%s-VLESS-TCP-TLS\n' "$UUID" "$host" "$VLESS_TCP_TLS_PORT" "$SNI" "$xray_pin_query" "$label" >>"$SHARE_FILE"
  csv_has vless-xhttp-tls && printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=xhttp&mode=auto&path=%s%s#%s-VLESS-XHTTP-TLS\n' "$UUID" "$host" "$VLESS_XHTTP_TLS_PORT" "$SNI" "$PATH_VLESS_XHTTP_TLS" "$xray_pin_query" "$label" >>"$SHARE_FILE"

  csv_has trojan && printf 'trojan://%s@%s:%s?security=tls&sni=%s%s#%s-Trojan\n' "$TROJAN_PASSWORD" "$host" "$TROJAN_PORT" "$SNI" "$xray_pin_query" "$label" >>"$SHARE_FILE"
  csv_has hy2 && printf 'hysteria2://%s@%s:%s?security=tls&sni=%s&alpn=h3%s#%s-Hysteria2\n' "$HY2_PASSWORD" "$host" "$HY2_PORT" "$SNI" "$hy2_pin_query" "$label" >>"$SHARE_FILE"
  csv_has tuic && printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=%s&allow_insecure=%s#%s-TUIC\n' "$TUIC_UUID" "$TUIC_PASSWORD" "$host" "$TUIC_PORT" "$SNI" "$insecure_num" "$label" >>"$SHARE_FILE"
  csv_has anytls && printf 'anytls://%s@%s:%s?security=tls&sni=%s&insecure=%s#%s-AnyTLS\n' "$ANYTLS_PASSWORD" "$host" "$ANYTLS_PORT" "$SNI" "$insecure_num" "$label" >>"$SHARE_FILE"
  csv_has any-reality && printf 'anytls://%s@%s:%s?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s#%s-AnyTLS-Reality\n' "$ANY_REALITY_PASSWORD" "$host" "$ANY_REALITY_PORT" "$SNI" "$REALITY_PUBLIC" "$REALITY_SHORT_ID" "$label" >>"$SHARE_FILE"
  if csv_has ss2022; then ss_userinfo=$(printf '2022-blake3-aes-128-gcm:%s' "$SS2022_PASSWORD" | b64url); printf 'ss://%s@%s:%s#%s-SS2022\n' "$ss_userinfo" "$host" "$SS2022_PORT" "$label" >>"$SHARE_FILE"; fi
  csv_has socks && printf 'socks://%s:%s@%s:%s#%s-SOCKS5\n' "$SOCKS_USER" "$SOCKS_PASSWORD" "$host" "$SOCKS_PORT" "$label" >>"$SHARE_FILE"
  b64_nowrap <"$SHARE_FILE" >"$SUB_FILE"
  chmod 0600 "$SHARE_FILE" "$SUB_FILE"
}

profile_socket() {
  case "$1" in
    vless-reality-vision) echo tcp:$VLESS_REALITY_VISION_PORT ;; vless-xhttp-reality-enc) echo tcp:$VLESS_XHTTP_REALITY_ENC_PORT ;; vless-xhttp) echo tcp:$VLESS_XHTTP_PORT ;;
    vless-tcp-tls) echo tcp:$VLESS_TCP_TLS_PORT ;; vless-xhttp-tls) echo tcp:$VLESS_XHTTP_TLS_PORT ;;
    trojan) echo tcp:$TROJAN_PORT ;; hy2) echo udp:$HY2_PORT ;; tuic) echo udp:$TUIC_PORT ;; anytls) echo tcp:$ANYTLS_PORT ;; any-reality) echo tcp:$ANY_REALITY_PORT ;;
    ss2022) printf 'tcp:%s\nudp:%s\n' "$SS2022_PORT" "$SS2022_PORT" ;; socks) printf 'tcp:%s\nudp:%s\n' "$SOCKS_PORT" "$SOCKS_PORT" ;;
  esac
}

selected_sockets() {
  local item; IFS=',' read -r -a requested <<<"$PROTOCOLS"
  for item in "${requested[@]}"; do profile_socket "$item"; done
}

check_ports_available() {
  declare -A seen=(); local spec proto port
  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    [[ -z ${seen[$spec]+x} ]] || die "配置中重复使用 $spec，请为相关协议选择不同端口。"
    seen[$spec]=1; proto=${spec%%:*}; port=${spec##*:}
    if [[ $proto == tcp ]]; then ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . && die "TCP/$port 已被占用。"
    else ss -H -lun "sport = :${port}" 2>/dev/null | grep -q . && die "UDP/$port 已被占用。"; fi
  done < <(selected_sockets)
  return 0
}

open_firewall() {
  local spec proto port
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    while IFS= read -r spec; do proto=${spec%%:*}; port=${spec##*:}; ufw allow "$port/$proto" >/dev/null; done < <(selected_sockets)
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    while IFS= read -r spec; do proto=${spec%%:*}; port=${spec##*:}; firewall-cmd --permanent --add-port="$port/$proto" >/dev/null; done < <(selected_sockets)
    firewall-cmd --reload >/dev/null
  else warn "未发现启用的 UFW/firewalld；请手动放行所列端口和云安全组。"; fi
}

write_services() {
  if [[ $NEED_XRAY == true ]]; then
    cat >/etc/systemd/system/xs-onekey-xray.service <<EOF
[Unit]
Description=XS-Onkey Xray Service
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStartPre=${XRAY_BIN} run -test -config ${XRAY_CONFIG}
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
[Install]
WantedBy=multi-user.target
EOF
  fi
  if [[ $NEED_SING == true ]]; then
    cat >/etc/systemd/system/xs-onekey-sing-box.service <<EOF
[Unit]
Description=XS-Onkey sing-box Service
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStartPre=${SING_BIN} check -c ${SING_CONFIG}
ExecStart=${SING_BIN} run -c ${SING_CONFIG}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
[Install]
WantedBy=multi-user.target
EOF
  fi
  systemctl daemon-reload
  [[ $NEED_XRAY == true ]] && systemctl enable xs-onekey-xray.service >/dev/null
  [[ $NEED_SING == true ]] && systemctl enable xs-onekey-sing-box.service >/dev/null
  return 0
}

validate_configs() {
  [[ $NEED_XRAY == true ]] && { jq -e . "$XRAY_CONFIG" >/dev/null; "$XRAY_BIN" run -test -config "$XRAY_CONFIG"; }
  [[ $NEED_SING == true ]] && { jq -e . "$SING_CONFIG" >/dev/null; "$SING_BIN" check -c "$SING_CONFIG"; }
  return 0
}

service_action() {
  local action=$1
  [[ $NEED_XRAY == true ]] && systemctl "$action" xs-onekey-xray.service
  [[ $NEED_SING == true ]] && systemctl "$action" xs-onekey-sing-box.service
  return 0
}

services_active() {
  [[ $NEED_XRAY == false ]] || systemctl is-active --quiet xs-onekey-xray.service || return 1
  [[ $NEED_SING == false ]] || systemctl is-active --quiet xs-onekey-sing-box.service || return 1
}

install_self() {
  local source=${BASH_SOURCE[0]} tmp first_line=''
  if [[ -f $source ]]; then
    install -m 0755 "$source" "$MANAGER_BIN"
  else
    log "检测到进程替换运行方式，正在下载本地管理脚本。"
    tmp=$(mktemp /tmp/xs-onekey-manager.XXXXXX) || die "无法创建管理脚本临时文件。"
    if ! curl -fsSL --retry 3 --connect-timeout 15 "$INSTALL_URL" -o "$tmp"; then
      rm -f "$tmp"
      die "无法从项目地址下载管理脚本。"
    fi
    IFS= read -r first_line <"$tmp" || true
    if [[ $first_line != '#!/usr/bin/env bash' ]] || ! grep -q '^main() {' "$tmp" || ! bash -n "$tmp"; then
      rm -f "$tmp"
      die "下载的管理脚本校验失败。"
    fi
    if ! install -m 0755 "$tmp" "$MANAGER_BIN"; then
      rm -f "$tmp"
      die "无法安装本地管理脚本。"
    fi
    rm -f "$tmp"
  fi
}

install_all() {
  INSTALL_COMPLETED=false
  need_root; detect_os
  ! managed_artifacts_available || { warn "检测到现有安装或残留文件；请使用删除卸载后再安装。"; return 0; }
  select_protocols || return 0
  determine_cores
  set_feature_flags
  [[ -e $XRAY_BIN ]] && XRAY_PREEXISTED=true || XRAY_PREEXISTED=false
  [[ -e $SING_BIN ]] && SING_PREEXISTED=true || SING_PREEXISTED=false
  INSTALL_IN_PROGRESS=true
  install_dependencies
  install_required_cores
  prompt_settings
  check_ports_available
  install -d -m 0700 "$BASE_DIR"
  make_certificate
  generate_credentials
  write_env
  write_xray_config
  write_sing_config
  generate_links
  write_services
  validate_configs
  open_firewall
  install_self
  service_action restart
  sleep 1
  [[ $NEED_XRAY == false ]] || systemctl is-active --quiet xs-onekey-xray.service || die "Xray 启动失败。"
  [[ $NEED_SING == false ]] || systemctl is-active --quiet xs-onekey-sing-box.service || die "sing-box 启动失败。"
  ok "安装完成：$CORE_SUMMARY"
  INSTALL_IN_PROGRESS=false
  INSTALL_COMPLETED=true
  show_info
}

print_share_links() {
  local link
  printf '\n%b分享链接%b\n' "$CYAN" "$NC"
  while IFS= read -r link || [[ -n $link ]]; do
    [[ -n $link ]] || continue
    printf '%s\n' "$link"
  done <"$SHARE_FILE"
}

show_info() {
  need_root
  managed_install_available || { warn "尚未安装，已返回主菜单。"; return 0; }
  [[ -s $SHARE_FILE ]] || { warn "没有可显示的节点，已返回主菜单。"; return 0; }
  load_env
  printf '\n%b核心%b  %s\n%b协议档%b  %s\n\n' "$CYAN" "$NC" "$CORE_SUMMARY" "$CYAN" "$NC" "$PROTOCOLS"
  [[ -z ${CERT_SHA256:-} ]] || printf '%bTLS 证书 SHA-256%b  %s\n\n' "$CYAN" "$NC" "$CERT_SHA256"
  printf '%b节点信息文件：%s%b\n' "$CYAN" "$SHARE_FILE" "$NC"
  print_share_links
  printf '\nBase64 订阅内容：%s\n' "$SUB_FILE"
}

status_all() {
  load_env
  if [[ $NEED_XRAY == true ]]; then printf 'Xray: '; systemctl is-active xs-onekey-xray.service || true; "$XRAY_BIN" version 2>/dev/null | sed -n '1p' || true; fi
  if [[ $NEED_SING == true ]]; then printf 'sing-box: '; systemctl is-active xs-onekey-sing-box.service || true; "$SING_BIN" version 2>/dev/null | sed -n '1p' || true; fi
}

restart_all() {
  need_root
  managed_install_available || { warn "尚未安装，已返回主菜单。"; return 0; }
  load_env; managed_services_available || return 0
  validate_configs; service_action restart; status_all
}

start_all() {
  need_root
  managed_install_available || { warn "尚未安装，已返回主菜单。"; return 0; }
  load_env; managed_services_available || return 0
  validate_configs; service_action start; status_all
}

stop_all() {
  need_root
  managed_install_available || { warn "尚未安装，已返回主菜单。"; return 0; }
  load_env; managed_services_available || return 0
  service_action stop; status_all
}

update_all() {
  need_root
  managed_install_available || { warn "尚未安装，无法更新核心，已返回主菜单。"; return 0; }
  detect_os; load_env; detect_arch
  local backup xray_current='' xray_latest='' sing_current='' sing_latest='' comparison
  local update_xray=false update_sing=false

  if [[ $NEED_XRAY == true ]]; then
    xray_latest=$(github_latest_tag XTLS/Xray-core) || die "无法获取 Xray 最新版本。"
    xray_current=$(installed_core_version "$XRAY_BIN" || true)
    if [[ -z $xray_current ]]; then
      warn "无法识别本地 Xray 版本，将安装最新版本 ${xray_latest}。"; update_xray=true
    else
      comparison=$(compare_numeric_versions "$xray_current" "$xray_latest" || printf '%s' -1)
      case "$comparison" in
        -1) log "Xray：${xray_current} -> ${xray_latest}"; update_xray=true ;;
         0) log "Xray 已是最新版本：${xray_current}" ;;
         1) warn "本地 Xray ${xray_current} 高于最新稳定版 ${xray_latest}，跳过降级。" ;;
      esac
    fi
  fi

  if [[ $NEED_SING == true ]]; then
    sing_latest=$(github_latest_tag SagerNet/sing-box) || die "无法获取 sing-box 最新版本。"
    sing_current=$(installed_core_version "$SING_BIN" || true)
    if [[ -z $sing_current ]]; then
      warn "无法识别本地 sing-box 版本，将安装最新版本 ${sing_latest}。"; update_sing=true
    else
      comparison=$(compare_numeric_versions "$sing_current" "$sing_latest" || printf '%s' -1)
      case "$comparison" in
        -1) log "sing-box：${sing_current} -> ${sing_latest}"; update_sing=true ;;
         0) log "sing-box 已是最新版本：${sing_current}" ;;
         1) warn "本地 sing-box ${sing_current} 高于最新稳定版 ${sing_latest}，跳过降级。" ;;
      esac
    fi
  fi

  if [[ $update_xray == false && $update_sing == false ]]; then
    ok "已安装核心均无需更新。"
    status_all
    return 0
  fi

  backup=$(mktemp -d /tmp/xs-onekey-backup.XXXXXX)
  [[ $update_xray == true && -x $XRAY_BIN ]] && cp -p "$XRAY_BIN" "$backup/xray"
  [[ $update_sing == true && -x $SING_BIN ]] && cp -p "$SING_BIN" "$backup/sing-box"
  if { [[ $update_xray == false ]] || install_xray "$xray_latest"; } &&
     { [[ $update_sing == false ]] || install_sing "$sing_latest"; } &&
     validate_configs && service_action restart && sleep 1 && services_active; then
    ok "核心更新完成。"
  else
    local rollback_ok=true
    warn "新版下载、校验或重启失败，正在回滚。"
    if [[ -e $backup/xray ]]; then install -m 0755 "$backup/xray" "$XRAY_BIN" || rollback_ok=false
    elif [[ $update_xray == true ]]; then rm -f "$XRAY_BIN" || rollback_ok=false
    fi
    if [[ -e $backup/sing-box ]]; then install -m 0755 "$backup/sing-box" "$SING_BIN" || rollback_ok=false
    elif [[ $update_sing == true ]]; then rm -f "$SING_BIN" || rollback_ok=false
    fi
    if [[ $rollback_ok == true ]] && validate_configs && service_action restart && sleep 1 && services_active; then
      rm -rf -- "$backup"
      die "更新失败，已恢复旧核心并重新启动服务。"
    fi
    rm -rf -- "$backup"
    die "更新失败，旧核心或服务也未能完整恢复，请检查 systemd 日志。"
  fi
  rm -rf -- "$backup"; status_all
}

bbr_save_previous() {
  [[ -r $BBR_PREVIOUS ]] && return 0
  install -d -o root -g root -m 0700 "$BBR_STATE_DIR"
  local key value tmp
  local -a keys=(
    net.core.default_qdisc net.ipv4.tcp_congestion_control
    net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min
    net.core.somaxconn net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog
    net.ipv4.tcp_notsent_lowat net.ipv4.tcp_tw_reuse net.ipv4.tcp_timestamps
    net.ipv4.tcp_fin_timeout net.ipv4.ip_local_port_range net.ipv4.tcp_max_tw_buckets
    net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
    net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_tcp_timeout_established
    net.netfilter.nf_conntrack_tcp_timeout_time_wait fs.file-max vm.swappiness
    net.ipv4.tcp_mtu_probing net.ipv4.tcp_syncookies
  )
  tmp=$(mktemp "$BBR_STATE_DIR/.previous.XXXXXX")
  for key in "${keys[@]}"; do
    value=$(sysctl -n "$key" 2>/dev/null) || continue
    printf '%s = %s\n' "$key" "$value" >>"$tmp"
  done
  install -m 0600 "$tmp" "$BBR_PREVIOUS"
  rm -f "$tmp"
}

bbr_status() {
  local cc qdisc available virt port_range conntrack swappiness tw_reuse
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '不可用')
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || printf '不可用')
  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf '未知')
  port_range=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || printf '不可用')
  conntrack=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || printf '不可用')
  swappiness=$(sysctl -n vm.swappiness 2>/dev/null || printf '不可用')
  tw_reuse=$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null || printf '不可用')
  if have systemd-detect-virt; then virt=$(systemd-detect-virt 2>/dev/null || true); else virt='未知'; fi
  [[ -n $virt ]] || virt='none'
  printf '\n当前拥塞控制: %s\n当前队列算法: %s\n可用拥塞控制: %s\n本地端口范围: %s\nConntrack 上限: %s\nSwappiness: %s\nTIME_WAIT 复用: %s\n虚拟化环境: %s\n持久配置: %s\n' \
    "$cc" "$qdisc" "$available" "$port_range" "$conntrack" "$swappiness" "$tw_reuse" "$virt" \
    "$([[ -r $BBR_CONF ]] && printf '已启用' || printf '未启用')"
  if [[ $cc == bbr && $qdisc == fq ]]; then ok "BBR + FQ 正在生效。"; else warn "BBR + FQ 尚未完整生效。"; fi
}

bbr_restore() {
  local quiet=${1:-false}
  rm -f "$BBR_CONF"
  sysctl --system >/dev/null 2>&1 || true
  if [[ -r $BBR_PREVIOUS ]]; then
    sysctl -e -p "$BBR_PREVIOUS" >/dev/null 2>&1 || warn "部分原始网络参数无法即时恢复，重启后将按系统配置加载。"
    rm -f "$BBR_PREVIOUS"
  fi
  rmdir "$BBR_STATE_DIR" >/dev/null 2>&1 || true
  [[ $quiet == true ]] || { ok "已移除 XS-Onkey BBR 配置并恢复启用前参数。"; bbr_status; }
}

keep_higher_sysctl_value() {
  local key=$1 proposed=$2 current
  current=$(sysctl -n "$key" 2>/dev/null || true)
  if [[ $current =~ ^[0-9]+$ ]] && (( 10#$current > 10#$proposed )); then
    printf '%s' "$current"
  else
    printf '%s' "$proposed"
  fi
}

bbr_enable() {
  need_root
  have sysctl || die "系统缺少 sysctl。"
  local available total_mem_mb buffer_max somax backlog_max syn_backlog file_max conntrack_max tmp
  have modprobe && {
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true
    modprobe nf_conntrack >/dev/null 2>&1 || true
  }
  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  [[ " $available " == *' bbr '* ]] || die "当前内核或宿主机未提供 BBR；容器内无法自行更换宿主机拥塞控制模块。"

  total_mem_mb=$(( $(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo) / 1024 ))
  if (( total_mem_mb <= 512 )); then
    buffer_max=16777216; somax=4096; file_max=65535; conntrack_max=65536
  elif (( total_mem_mb <= 1024 )); then
    buffer_max=33554432; somax=16384; file_max=524288; conntrack_max=262144
  elif (( total_mem_mb <= 4096 )); then
    buffer_max=67108864; somax=32768; file_max=1048576; conntrack_max=524288
  else
    buffer_max=134217728; somax=65535; file_max=2097152; conntrack_max=1048576
  fi
  buffer_max=$(keep_higher_sysctl_value net.core.rmem_max "$buffer_max")
  buffer_max=$(keep_higher_sysctl_value net.core.wmem_max "$buffer_max")
  backlog_max=$(keep_higher_sysctl_value net.core.netdev_max_backlog "$somax")
  syn_backlog=$(keep_higher_sysctl_value net.ipv4.tcp_max_syn_backlog "$somax")
  somax=$(keep_higher_sysctl_value net.core.somaxconn "$somax")
  file_max=$(keep_higher_sysctl_value fs.file-max "$file_max")
  conntrack_max=$(keep_higher_sysctl_value net.netfilter.nf_conntrack_max "$conntrack_max")

  bbr_save_previous
  tmp=$(mktemp /tmp/xs-onekey-bbr.XXXXXX)
  cat >"$tmp" <<EOF
# XS-Onkey BBR/FQ network tuning; generated automatically.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $buffer_max
net.core.wmem_max = $buffer_max
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 8192 262144 $buffer_max
net.ipv4.tcp_wmem = 8192 262144 $buffer_max
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.somaxconn = $somax
net.core.netdev_max_backlog = $backlog_max
net.ipv4.tcp_max_syn_backlog = $syn_backlog
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_max_tw_buckets = 500000
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.netfilter.nf_conntrack_max = $conntrack_max
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120
fs.file-max = $file_max
vm.swappiness = 10
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
EOF
  install -o root -g root -m 0644 "$tmp" "$BBR_CONF"
  rm -f "$tmp"
  if ! sysctl -e -p "$BBR_CONF" >/dev/null; then
    warn "BBR 参数应用失败，正在恢复原设置。"
    bbr_restore true
    die "当前内核、容器或宿主机不允许应用 BBR 配置。"
  fi
  if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true) != bbr || $(sysctl -n net.core.default_qdisc 2>/dev/null || true) != fq ]]; then
    bbr_restore true
    die "BBR/FQ 验证失败，已恢复原设置。"
  fi
  ok "BBR + FQ 及自适应网络缓冲区优化已启用。"
  bbr_status
}

bbr_menu() {
  local choice
  while true; do
    printf '\n1) 启用/刷新 BBR 优化\n2) 查看 BBR 状态\n3) 关闭并恢复\n0) 返回\n'
    read -r -p '请选择: ' choice
    case "$choice" in
      1) bbr_enable; return ;; 2) bbr_status; return ;; 3) need_root; bbr_restore; return ;;
      0) return ;; *) warn "无效选择。" ;;
    esac
  done
}

uninstall_all() {
  UNINSTALL_COMPLETED=false
  need_root
  managed_artifacts_available || { warn "尚未安装，无需删除卸载，已返回主菜单。"; return 0; }
  local confirm=''
  read -r -p '将删除服务、配置、证书、凭据和已安装核心，输入 Y 确认: ' confirm
  case "$confirm" in Y|y) ;; *) warn "已取消卸载。"; return ;; esac
  systemctl disable --now xs-onekey-xray.service xs-onekey-sing-box.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xs-onekey-xray.service /etc/systemd/system/xs-onekey-sing-box.service
  systemctl daemon-reload
  rm -f "$XRAY_BIN" "$SING_BIN"
  [[ $BASE_DIR == /etc/xs-onekey ]] || die "内部路径校验失败。"
  rm -rf -- "$BASE_DIR"; rm -f "$MANAGER_BIN"
  ok "已卸载服务、配置以及 Xray/sing-box 核心；BBR/网络优化、系统内核、防火墙规则与 acme.sh 账户均未改动。"
  UNINSTALL_COMPLETED=true
}

menu() {
  local choice
  while true; do
    printf '\n%bXS-Onkey 一键部署脚本%b\n1) 一键安装\n2) 删除卸载\n3) 重启服务\n4) 启动服务\n5) 停止服务\n6) 更新核心\n7) 查看节点\n8) BBR\n0) 退出\n' "$CYAN" "$NC"
    read -r -p '请选择: ' choice
    case "$choice" in
      1) install_all; if [[ $INSTALL_COMPLETED == true ]]; then exit 0; fi ;;
      2) uninstall_all; if [[ $UNINSTALL_COMPLETED == true ]]; then exit 0; fi ;;
      3) restart_all ;;
      4) start_all ;; 5) stop_all ;; 6) update_all ;;
      7) show_info ;; 8) bbr_menu ;;
      0) exit 0 ;; *) warn "无效选择。" ;;
    esac
  done
}

main() {
  [[ $# -eq 0 ]] || die "本脚本不接受命令行参数，请直接运行 install.sh 或 xs-onekey 管理命令。"
  [[ -t 0 ]] || die "本脚本仅支持交互终端运行。"
  menu
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
