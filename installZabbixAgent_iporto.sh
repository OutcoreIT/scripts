#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Instalação do Zabbix Agent 2
# Ubuntu 22/24 e Debian 11/12/13
# =============================================================================

ZABBIX_SERVER="monitoramento.iporto.net.br"
ZABBIX_HOST_META_DATA="linux"

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERRO] $*" >&2; }

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "${ID,,}"
  else
    log_error "Não foi possível detectar o sistema operacional."
    exit 1
  fi
}

check_os() {
  local os
  os="$(detect_os)"
  case "$os" in
    ubuntu|debian)
      log_info "Sistema detectado: ${os^}"
      ;;
    *)
      log_error "Sistema operacional não suportado: $os. Use Ubuntu ou Debian."
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
  local os pkg_url zabbix_ver version_id

  # shellcheck source=/dev/null
  source /etc/os-release

  os="${ID,,}"
  version_id="${VERSION_ID}"
  zabbix_ver="7.0"

  case "$os" in
    ubuntu)
      pkg_url="https://repo.zabbix.com/zabbix/${zabbix_ver}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${zabbix_ver}-2+ubuntu${version_id}_all.deb"
      ;;
    debian)
      pkg_url="https://repo.zabbix.com/zabbix/${zabbix_ver}/debian/pool/main/z/zabbix-release/zabbix-release_${zabbix_ver}-2+debian${version_id}_all.deb"
      ;;
    *)
      pkg_url=""
      ;;
  esac

  if [[ -z "$pkg_url" ]]; then
    log_error "Não foi possível determinar a URL do pacote Zabbix."
    return 1
  fi

  local tmp_deb
  tmp_deb="$(mktemp).deb"
  curl -fsSL "$pkg_url" -o "$tmp_deb"
  dpkg -i "$tmp_deb" || apt-get install -f -y
  rm -f "$tmp_deb"

  apt-get update -qq
}

install_zabbix_agent() {
  apt-get install -y zabbix-agent2
}

configure_zabbix_agent() {
  local conf="/etc/zabbix/zabbix_agent2.conf"

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
  systemctl restart zabbix-agent2
  systemctl enable zabbix-agent2
}

main() {
  check_root
  check_os

  # Pergunta o nome do cliente
  read -r -p "Digite o nome do cliente [Default: MCK]: " input_client
  CLIENT_NAME="${input_client:-MCK}"

  # Obtém o hostname da máquina automaticamente
  local default_hostname
  default_hostname="$(hostname -f 2>/dev/null || hostname)"
  read -r -p "Digite o hostname para o Zabbix Agent [Default: $default_hostname]: " input_hostname
  ZABBIX_HOST_NAME="${input_hostname:-$default_hostname}"

  log_info "Cliente: ${CLIENT_NAME}"
  log_info "Hostname Zabbix: ${ZABBIX_HOST_NAME}"

  [[ -z "$ZABBIX_SERVER" ]] && { log_error "ZABBIX_SERVER não informado."; exit 1; }

  add_zabbix_repo
  install_zabbix_agent
  configure_zabbix_agent
  start_zabbix_agent

  log_info "Concluído: Instalação e configuração do Zabbix Agent."
}

main "$@"