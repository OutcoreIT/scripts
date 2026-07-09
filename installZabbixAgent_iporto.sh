#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Instalação do Zabbix Agent 2
# Ubuntu 22/24, Debian 11/12/13, CentOS/RHEL/AlmaLinux/Rocky 8/9
# =============================================================================

ZABBIX_SERVER="zabbix.iporto.net.br"
ZABBIX_HOST_META_DATA="linux"
ZABBIX_PROXY_IP=""

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERRO] $*" >&2; }

wait_for_dpkg_lock() {
  local lock_files=("/var/lib/dpkg/lock" "/var/lib/dpkg/lock-frontend" "/var/cache/apt/archives/lock")
  local locked=1
  local count=0

  while [[ $locked -ne 0 ]]; do
    locked=0
    for lock_file in "${lock_files[@]}"; do
      if [[ -f "$lock_file" ]]; then
        if command -v fuser &>/dev/null; then
          if fuser "$lock_file" &>/dev/null; then
            locked=1
            break
          fi
        elif command -v lsof &>/dev/null; then
          if lsof "$lock_file" &>/dev/null; then
            locked=1
            break
          fi
        else
          if ! flock -n "$lock_file" true 2>/dev/null; then
            locked=1
            break
          fi
        fi
      fi
    done

    if [[ $locked -eq 1 ]]; then
      if [[ $count -eq 0 ]]; then
        log_info "O APT/dpkg está bloqueado por outro processo (por exemplo, unattended-upgrades). Aguardando liberação..."
      fi
      sleep 3
      count=$((count + 1))
      if [[ $count -gt 100 ]]; then
        log_warn "Timeout aguardando o bloqueio do APT/dpkg. Continuando mesmo assim..."
        break
      fi
    fi
  done
  if [[ $count -gt 0 ]]; then
    log_info "Bloqueio liberado."
  fi
}

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
  local os pkg_url zabbix_ver version_id major_ver arch repo_arch rpm_arch

  load_os_info

  os="${ID,,}"
  version_id="${VERSION_ID}"
  zabbix_ver="7.0"
  major_ver="${version_id%%.*}"

  arch="$(uname -m)"
  if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
    repo_arch="-arm64"
    rpm_arch="aarch64"
  else
    repo_arch=""
    rpm_arch="x86_64"
  fi

  case "$os" in
    ubuntu)
      wait_for_dpkg_lock
      # Temporariamente desabilita o ESM hook para evitar falhas no apt update (comum em containers/WSL/sistemas mínimos)
      local esm_hook="/etc/apt/apt.conf.d/20apt-esm-hook.conf"
      local esm_hook_bak="${esm_hook}.bak"
      if [[ -f "$esm_hook" ]]; then
        log_info "Desabilitando temporariamente o ESM hook do APT..."
        mv "$esm_hook" "$esm_hook_bak"
      fi

      # Garante que gnupg está instalado para evitar erros do apt-key em repositórios antigos
      log_info "Instalando gnupg para compatibilidade de chaves GPG..."
      apt-get update -qq || true
      apt-get install -y gnupg || log_warn "Não foi possível instalar o pacote gnupg."

      pkg_url="https://repo.zabbix.com/zabbix/${zabbix_ver}/ubuntu${repo_arch}/pool/main/z/zabbix-release/zabbix-release_${zabbix_ver}-2+ubuntu${version_id}_all.deb"
      local tmp_deb
      tmp_deb="$(mktemp).deb"
      curl -fsSL "$pkg_url" -o "$tmp_deb"

      # Purga o pacote anterior para garantir que conffiles deletados (como o zabbix.list/zabbix.sources) sejam recriados
      log_info "Removendo configurações anteriores do repositório Zabbix..."
      dpkg -P zabbix-release || true

      log_info "Instalando repositório do Zabbix..."
      dpkg -i --force-confmiss "$tmp_deb" || apt-get install -f -y
      rm -f "$tmp_deb"

      if [[ -n "$repo_arch" ]]; then
        log_info "Ajustando configuração do repositório Zabbix para arquitetura ARM..."
        for file in /etc/apt/sources.list.d/zabbix.list /etc/apt/sources.list.d/zabbix.sources; do
          if [[ -f "$file" ]]; then
            sed -i "s|ubuntu-arm64|ubuntu|g; s|ubuntu|ubuntu-arm64|g" "$file"
          fi
        done
      fi

      log_info "Atualizando os repositórios APT..."
      apt-get update -qq || log_warn "Aviso: apt-get update encontrou erros em repositórios secundários, prosseguindo com a instalação do agente."

      # Restaura o ESM hook se foi desabilitado
      if [[ -f "$esm_hook_bak" ]]; then
        log_info "Restaurando o ESM hook do APT..."
        mv "$esm_hook_bak" "$esm_hook"
      fi
      ;;
    debian)
      wait_for_dpkg_lock
      # Garante que gnupg está instalado
      log_info "Instalando gnupg para compatibilidade de chaves GPG..."
      apt-get update -qq || true
      apt-get install -y gnupg || log_warn "Não foi possível instalar o pacote gnupg."

      pkg_url="https://repo.zabbix.com/zabbix/${zabbix_ver}/debian${repo_arch}/pool/main/z/zabbix-release/zabbix-release_${zabbix_ver}-2+debian${version_id}_all.deb"
      local tmp_deb
      tmp_deb="$(mktemp).deb"
      curl -fsSL "$pkg_url" -o "$tmp_deb"

      # Purga o pacote anterior para garantir que conffiles deletados sejam recriados
      log_info "Removendo configurações anteriores do repositório Zabbix..."
      dpkg -P zabbix-release || true

      log_info "Instalando repositório do Zabbix..."
      dpkg -i --force-confmiss "$tmp_deb" || apt-get install -f -y
      rm -f "$tmp_deb"

      if [[ -n "$repo_arch" ]]; then
        log_info "Ajustando configuração do repositório Zabbix para arquitetura ARM..."
        for file in /etc/apt/sources.list.d/zabbix.list /etc/apt/sources.list.d/zabbix.sources; do
          if [[ -f "$file" ]]; then
            sed -i "s|debian-arm64|debian|g; s|debian|debian-arm64|g" "$file"
          fi
        done
      fi

      log_info "Atualizando os repositórios APT..."
      apt-get update -qq || log_warn "Aviso: apt-get update encontrou erros em repositórios secundários, prosseguindo com a instalação do agente."
      ;;
    centos|rhel|almalinux|rocky|ol)
      _fix_centos_vault
      pkg_url="https://repo.zabbix.com/zabbix/${zabbix_ver}/rhel/${major_ver}/${rpm_arch}/zabbix-release-${zabbix_ver}-1.el${major_ver}.noarch.rpm"
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
      wait_for_dpkg_lock
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
  local is_agentd=0
  if [[ ("${ID,,}" == "centos" || "${ID,,}" == "rhel") && "$major_ver" == "6" ]]; then
    conf="/etc/zabbix/zabbix_agentd.conf"
    is_agentd=1
  fi

  # Backup da configuração existente se houver
  if [[ -f "$conf" ]]; then
    log_info "Fazendo backup da configuração existente em ${conf}.bak"
    cp "$conf" "${conf}.bak"
  fi

  log_info "Escrevendo nova configuração do Zabbix Agent..."

  local servers="${ZABBIX_SERVER}"
  if [[ -n "${ZABBIX_PROXY_IP:-}" ]]; then
    servers="${ZABBIX_SERVER},${ZABBIX_PROXY_IP}"
  fi

  # Garante que o diretório pai existe
  mkdir -p "$(dirname "$conf")"

  if [[ $is_agentd -eq 1 ]]; then
    # Configuração do Zabbix Agentd (v1) para CentOS/RHEL 6
    cat > "$conf" <<EOF
PidFile=/var/run/zabbix/zabbix_agentd.pid
LogFile=/var/log/zabbix/zabbix_agentd.log
LogFileSize=10

Server=${servers}
ServerActive=${servers}
Hostname=${ZABBIX_HOST_NAME}
HostMetadata=${ZABBIX_HOST_META_DATA}

Include=/etc/zabbix/zabbix_agentd.d/*.conf
EOF
  else
    # Configuração do Zabbix Agent 2
    cat > "$conf" <<EOF
PidFile=/run/zabbix/zabbix_agent2.pid
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10

Server=${servers}
ServerActive=${servers}
Hostname=${ZABBIX_HOST_NAME}
HostMetadata=${ZABBIX_HOST_META_DATA}

PluginSocket=/run/zabbix/agent.plugin.sock
ControlSocket=/run/zabbix/agent.sock

Include=/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf
Include=/etc/zabbix/zabbix_agent2.d/*.conf
EOF
  fi
}

start_zabbix_agent() {
  load_os_info
  local major_ver="${VERSION_ID%%.*}"

  if getent group docker &>/dev/null; then
    log_info "Adicionando o usuário zabbix ao grupo docker..."
    usermod -aG docker zabbix || log_warn "Não foi possível adicionar o usuário zabbix ao grupo docker."
  fi

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

add_iptables_rules_for_ip() {
  local ip="$1"
  local name="$2"

  log_info "Configurando regras de firewall para $name IP: $ip"

  local has_out=0
  local has_in=0
  local has_in_10050=0

  if command -v iptables-save &>/dev/null; then
    local rules
    rules=$(iptables-save)
    if echo "$rules" | grep -F -- "-A OUTPUT -p tcp -d $ip/32 --dport 10051 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT" &>/dev/null || \
       echo "$rules" | grep -F -- "-A OUTPUT -p tcp -d $ip --dport 10051 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT" &>/dev/null; then
      has_out=1
    fi
    if echo "$rules" | grep -F -- "-A INPUT -p tcp -s $ip/32 --sport 10051 -m conntrack --ctstate ESTABLISHED -j ACCEPT" &>/dev/null || \
       echo "$rules" | grep -F -- "-A INPUT -p tcp -s $ip --sport 10051 -m conntrack --ctstate ESTABLISHED -j ACCEPT" &>/dev/null; then
      has_in=1
    fi
    if echo "$rules" | grep -F -- "-s $ip" | grep -F -- "--dport 10050" &>/dev/null; then
      has_in_10050=1
    fi
  fi

  if [[ $has_out -eq 0 ]]; then
    iptables -I OUTPUT -p tcp -d "$ip" --dport 10051 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
    log_info "Regra OUTPUT inserida para $ip:10051"
  else
    log_info "Regra OUTPUT para $ip:10051 já existe."
  fi

  if [[ $has_in -eq 0 ]]; then
    iptables -I INPUT -p tcp -s "$ip" --sport 10051 -m conntrack --ctstate ESTABLISHED -j ACCEPT
    log_info "Regra INPUT inserida para $ip:10051"
  else
    log_info "Regra INPUT para $ip:10051 já existe."
  fi

  if [[ $has_in_10050 -eq 0 ]]; then
    iptables -I INPUT 1 \
      -s "$ip" \
      -p tcp \
      --dport 10050 \
      -m conntrack --ctstate NEW,ESTABLISHED \
      -j ACCEPT
    log_info "Regra INPUT 1 (liberação da porta 10050) inserida no início da cadeia para $ip"
  else
    log_info "Regra INPUT (liberação da porta 10050) para $ip já existe."
  fi
}

configure_iptables() {
  if ! command -v iptables &>/dev/null; then
    log_warn "iptables não encontrado. Pulando configuração do firewall."
    return
  fi

  local zabbix_ip
  zabbix_ip=$(get_zabbix_server_ip "$ZABBIX_SERVER")

  if [[ -n "$zabbix_ip" ]]; then
    add_iptables_rules_for_ip "$zabbix_ip" "Zabbix Server ($ZABBIX_SERVER)"
  else
    log_warn "Não foi possível resolver o IP do Zabbix Server ($ZABBIX_SERVER)."
  fi

  if [[ -n "${ZABBIX_PROXY_IP:-}" ]]; then
    local proxy_ip
    proxy_ip=$(get_zabbix_server_ip "$ZABBIX_PROXY_IP")
    if [[ -n "$proxy_ip" ]]; then
      add_iptables_rules_for_ip "$proxy_ip" "Zabbix Proxy ($ZABBIX_PROXY_IP)"
    else
      log_warn "Não foi possível resolver o IP do Zabbix Proxy ($ZABBIX_PROXY_IP)."
    fi
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

  # Pergunta se existe um proxy
  read -r -p "Digite o IP do proxy do Zabbix (deixe vazio se não houver): " input_proxy_ip
  ZABBIX_PROXY_IP="${input_proxy_ip:-}"

  log_info "Cliente: ${CLIENT_NAME}"
  log_info "Hostname Zabbix: ${ZABBIX_HOST_NAME}"
  if [[ -n "$ZABBIX_PROXY_IP" ]]; then
    log_info "Proxy Zabbix: ${ZABBIX_PROXY_IP}"
  fi

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