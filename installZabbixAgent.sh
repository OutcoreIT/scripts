#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Instalação do Zabbix Agent 2
# Ubuntu 22/24, Debian 11/12/13, CentOS/RHEL/AlmaLinux/Rocky 8/9
# =============================================================================

ZABBIX_SERVER="zabbix.outcore.com.br"
ZABBIX_HOST_META_DATA="linux"

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERRO] $*" >&2; }

ID=""
VERSION_ID=""

load_os_info() {
  if [[ -n "${ID:-}" ]]; then
    return
  fi
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
  elif [[ -f /etc/centos-release ]]; then
    ID="centos"
    VERSION_ID=$(sed -n -e 's/^.*release \([0-9.]*\).*$/\1/p' /etc/centos-release)
  elif [[ -f /etc/redhat-release ]]; then
    ID="rhel"
    VERSION_ID=$(sed -n -e 's/^.*release \([0-9.]*\).*$/\1/p' /etc/redhat-release)
  else
    log_error "Não foi possível detectar o sistema operacional."
    exit 1
  fi
}

detect_os() {
  load_os_info
  echo "${ID,,}"
}

check_os() {
  local os
  os="$(detect_os)"
  case "$os" in
    ubuntu|debian|centos|rhel|almalinux|rocky|ol)
      log_info "Sistema detectado: ${os^}"
      ;;
    *)
      log_error "Sistema operacional não suportado: $os. Use Ubuntu, Debian, CentOS, RHEL, AlmaLinux ou Rocky Linux."
      exit 1
      ;;
  esac
}

check_root() {
  if [[ ${EUID} -ne 0 ]]; then
    log_error "Este script precisa ser executado como root (sudo)."
    exit 1
  fi
}

add_zabbix_repo() {
  local os pkg_url zabbix_ver version_id major_ver

  load_os_info

  os="${ID,,}"
  version_id="${VERSION_ID}"
  zabbix_ver="7.0"
  major_ver="${version_id%%.*}"

  case "$os" in
    ubuntu)
      pkg_url="https://repo.zabbix.com/zabbix/${zabbix_ver}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${zabbix_ver}-2+ubuntu${version_id}_all.deb"
      local tmp_deb
      tmp_deb="$(mktemp).deb"
      curl -fsSL "$pkg_url" -o "$tmp_deb"
      dpkg -i "$tmp_deb" || apt-get install -f -y
      rm -f "$tmp_deb"
      apt-get update -qq
      ;;
    debian)
      pkg_url="https://repo.zabbix.com/zabbix/${zabbix_ver}/debian/pool/main/z/zabbix-release/zabbix-release_${zabbix_ver}-2+debian${version_id}_all.deb"
      local tmp_deb
      tmp_deb="$(mktemp).deb"
      curl -fsSL "$pkg_url" -o "$tmp_deb"
      dpkg -i "$tmp_deb" || apt-get install -f -y
      rm -f "$tmp_deb"
      apt-get update -qq
      ;;
    centos|rhel|almalinux|rocky|ol)
      _fix_centos_vault
      pkg_url="https://repo.zabbix.com/zabbix/${zabbix_ver}/rhel/${major_ver}/x86_64/zabbix-release-${zabbix_ver}-1.el${major_ver}.noarch.rpm"
      rpm -Uvh "$pkg_url" || true
      _rhel_pkg_mgr clean all
      ;;
    *)
      log_error "Não foi possível determinar a URL do pacote Zabbix."
      return 1
      ;;
  esac
}

_rhel_pkg_mgr() {
  load_os_info
  local major_ver="${VERSION_ID%%.*}"
  local skip_opt=""
  if [[ ("${ID,,}" == "centos" || "${ID,,}" == "rhel") && ("$major_ver" == "6" || "$major_ver" == "7") ]]; then
    skip_opt="--setopt=*.skip_if_unavailable=1"
  fi

  if command -v dnf &>/dev/null; then
    if [[ -n "$skip_opt" ]]; then
      dnf "$skip_opt" "$@"
    else
      dnf "$@"
    fi
  else
    if [[ -n "$skip_opt" ]]; then
      yum "$skip_opt" "$@"
    else
      yum "$@"
    fi
  fi
}

# CentOS 6/7 reached EOL — mirrorlist.centos.org is gone; redirect to vault.
_fix_centos_vault() {
  local major_ver
  load_os_info
  major_ver="${VERSION_ID%%.*}"
  if [[ "${ID,,}" == "centos" ]]; then
    if [[ "$major_ver" == "7" ]]; then
      log_info "CentOS 7 EOL detectado. Atualizando repos para vault.centos.org..."
      sed -i \
        -e 's|^mirrorlist=|#mirrorlist=|' \
        -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|' \
        -e 's|^baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|' \
        /etc/yum.repos.d/CentOS-*.repo
    elif [[ "$major_ver" == "6" ]]; then
      log_info "CentOS 6 EOL detectado. Atualizando repos para vault.centos.org..."
      sed -i \
        -e 's|^mirrorlist=|#mirrorlist=|' \
        -e 's|^#baseurl=http://mirror.centos.org/centos/\$releasever|baseurl=http://vault.centos.org/centos/6.10|' \
        -e 's|^baseurl=http://mirror.centos.org/centos/\$releasever|baseurl=http://vault.centos.org/centos/6.10|' \
        -e 's|^#baseurl=http://mirror.centos.org/centos|baseurl=http://vault.centos.org/centos|' \
        -e 's|^baseurl=http://mirror.centos.org/centos|baseurl=http://vault.centos.org/centos|' \
        /etc/yum.repos.d/CentOS-*.repo
    fi
  fi
}

install_zabbix_agent() {
  load_os_info
  local os="${ID,,}"
  local major_ver="${VERSION_ID%%.*}"
  case "$os" in
    ubuntu|debian)
      apt-get install -y zabbix-agent2
      ;;
    centos|rhel|almalinux|rocky|ol)
      if [[ "$major_ver" == "6" ]]; then
        _rhel_pkg_mgr install -y zabbix-agent
      else
        _rhel_pkg_mgr install -y zabbix-agent2
      fi
      ;;
  esac
}

configure_zabbix_agent() {
  load_os_info
  local major_ver="${VERSION_ID%%.*}"
  local conf="/etc/zabbix/zabbix_agent2.conf"
  if [[ ("${ID,,}" == "centos" || "${ID,,}" == "rhel") && "$major_ver" == "6" ]]; then
    conf="/etc/zabbix/zabbix_agentd.conf"
  fi

  if [[ -f "$conf" ]]; then
    cp "$conf" "${conf}.bak"
    sed -i "s/^Server=127.0.0.1/Server=${ZABBIX_SERVER}/" "$conf"
    sed -i "s/^ServerActive=127.0.0.1/ServerActive=${ZABBIX_SERVER}/" "$conf"
    sed -i "s|^[#[:space:]]*HostMetadata\(Item\)\?=.*|HostMetadata=${ZABBIX_HOST_META_DATA}|" "$conf"

    if grep -q '^Hostname=' "$conf"; then
      sed -i "s/^Hostname=.*/Hostname=${ZABBIX_HOST_NAME}/" "$conf"
    else
      echo "Hostname=${ZABBIX_HOST_NAME}" >> "$conf"
    fi
  else
    log_error "Arquivo de configuração ${conf} não encontrado."
  fi
}

start_zabbix_agent() {
  load_os_info
  local major_ver="${VERSION_ID%%.*}"
  if [[ ("${ID,,}" == "centos" || "${ID,,}" == "rhel") && "$major_ver" == "6" ]]; then
    service zabbix-agent restart
    chkconfig zabbix-agent on
  else
    systemctl restart zabbix-agent2
    systemctl enable zabbix-agent2
  fi
}

get_zabbix_server_ip() {
  local host="$1"
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$host"
    return
  fi

  local ip=""
  ip=$(getent hosts "$host" | awk '{print $1}' | head -n 1)
  
  if [[ -z "$ip" ]] && command -v nslookup &>/dev/null; then
    ip=$(nslookup "$host" 2>/dev/null | awk '/^Address: / { print $2 }' | head -n 1)
  fi

  if [[ -z "$ip" ]]; then
    if command -v python3 &>/dev/null; then
      ip=$(python3 -c "import socket; print(socket.gethostbyname('$host'))" 2>/dev/null || true)
    elif command -v python &>/dev/null; then
      ip=$(python -c "import socket; print(socket.gethostbyname('$host'))" 2>/dev/null || true)
    fi
  fi

  if [[ -z "$ip" ]]; then
    ip=$(ping -c 1 -W 2 "$host" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1 || true)
  fi

  echo "$ip"
}

configure_iptables() {
  if ! command -v iptables &>/dev/null; then
    log_warn "iptables não encontrado. Pulando configuração do firewall."
    return
  fi

  local zabbix_ip
  zabbix_ip=$(get_zabbix_server_ip "$ZABBIX_SERVER")

  if [[ -z "$zabbix_ip" ]]; then
    log_warn "Não foi possível resolver o IP do Zabbix Server ($ZABBIX_SERVER). Pulando regras de firewall."
    return
  fi

  log_info "Configurando regras de firewall para Zabbix Server IP: $zabbix_ip"

  local has_out=0
  local has_in=0

  if command -v iptables-save &>/dev/null; then
    local rules
    rules=$(iptables-save)
    if echo "$rules" | grep -F -- "-A OUTPUT -p tcp -d $zabbix_ip/32 --dport 10051 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT" &>/dev/null || \
       echo "$rules" | grep -F -- "-A OUTPUT -p tcp -d $zabbix_ip --dport 10051 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT" &>/dev/null; then
      has_out=1
    fi
    if echo "$rules" | grep -F -- "-A INPUT -p tcp -s $zabbix_ip/32 --sport 10051 -m conntrack --ctstate ESTABLISHED -j ACCEPT" &>/dev/null || \
       echo "$rules" | grep -F -- "-A INPUT -p tcp -s $zabbix_ip --sport 10051 -m conntrack --ctstate ESTABLISHED -j ACCEPT" &>/dev/null; then
      has_in=1
    fi
  fi

  if [[ $has_out -eq 0 ]]; then
    iptables -I OUTPUT -p tcp -d "$zabbix_ip" --dport 10051 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
    log_info "Regra OUTPUT inserida para $zabbix_ip:10051"
  else
    log_info "Regra OUTPUT para $zabbix_ip:10051 já existe."
  fi

  if [[ $has_in -eq 0 ]]; then
    iptables -I INPUT -p tcp -s "$zabbix_ip" --sport 10051 -m conntrack --ctstate ESTABLISHED -j ACCEPT
    log_info "Regra INPUT inserida para $zabbix_ip:10051"
  else
    log_info "Regra INPUT para $zabbix_ip:10051 já existe."
  fi

  # Salvar regras
  if command -v service &>/dev/null && service iptables status &>/dev/null; then
    service iptables save || true
  elif command -v iptables-save &>/dev/null; then
    if [[ -d /etc/iptables ]]; then
      iptables-save > /etc/iptables/rules.v4 || true
    fi
  fi
}

main() {
  check_root
  check_os

  CLIENT_NAME="iPorto"

  # Obtém o hostname da máquina automaticamente
  local default_hostname
  default_hostname="$(hostname -f 2>/dev/null || hostname)"
  read -r -p "Digite o hostname para o Zabbix Agent [Default: $default_hostname]: " input_hostname
  ZABBIX_HOST_NAME="${input_hostname:-$default_hostname}"

  log_info "Cliente: ${CLIENT_NAME}"
  log_info "Hostname Zabbix: ${ZABBIX_HOST_NAME}"

  [[ -z "$ZABBIX_SERVER" ]] && { log_error "ZABBIX_SERVER não informado."; exit 1; }

  load_os_info
  local has_agent=0
  local major_ver="${VERSION_ID%%.*}"
  if [[ ("${ID,,}" == "centos" || "${ID,,}" == "rhel") && "$major_ver" == "6" ]]; then
    if command -v zabbix_agentd &>/dev/null || [[ -f /etc/zabbix/zabbix_agentd.conf ]]; then
      has_agent=1
    fi
  else
    if command -v zabbix_agent2 &>/dev/null || [[ -f /etc/zabbix/zabbix_agent2.conf ]]; then
      has_agent=1
    fi
  fi

  if [[ $has_agent -eq 1 ]]; then
    if [[ ("${ID,,}" == "centos" || "${ID,,}" == "rhel") && "$major_ver" == "6" ]]; then
      log_info "Zabbix Agent já instalado. Atualizando configuração."
    else
      log_info "Zabbix Agent 2 já instalado. Atualizando configuração."
    fi
  else
    add_zabbix_repo
    install_zabbix_agent
  fi
  configure_zabbix_agent
  start_zabbix_agent
  configure_iptables

  log_info "Concluído: Instalação e configuração do Zabbix Agent."
}

main "$@"