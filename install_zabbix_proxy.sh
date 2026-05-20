#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIGURAÇÕES
# ============================================================

PROXY_NAME="${1:-}"
ZABBIX_SERVER_HOST="${2:-zabbix.outcore.com.br}"
ZABBIX_SERVER_PORT="${3:-10051}"

STACK_DIR="/opt/zabbix-proxy"
ZABBIX_VERSION="alpine-7.0-latest"
TZ="America/Sao_Paulo"

CONFIG_FREQUENCY="60"
DATA_SENDER_FREQUENCY="5"
PROXY_OFFLINE_BUFFER="72"

CACHE_SIZE="256M"
HISTORY_CACHE_SIZE="128M"
TIMEOUT="10"

if [ -z "$PROXY_NAME" ]; then
  echo "Uso:"
  echo "  $0 NOME_DO_PROXY [ZABBIX_SERVER_HOST] [ZABBIX_SERVER_PORT]"
  echo
  echo "Exemplos:"
  echo "  $0 proxy-cliente-x"
  echo "  $0 proxy-vilarica-poa zabbix.outcore.com.br"
  echo "  $0 proxy-vilarica-poa zabbix.outcore.com.br 10051"
  exit 1
fi

# ============================================================
# FUNÇÕES
# ============================================================

ask_yes_no() {
  local prompt="$1"
  local answer

  while true; do
    read -rp "$prompt [s/N]: " answer
    case "$answer" in
      [sS]|[sS][iI][mM]) return 0 ;;
      [nN]|[nN][aA][oO]|[nN][ãÃ][oO]|"") return 1 ;;
      *) echo "Responda com s ou n." ;;
    esac
  done
}

install_docker_debian_ubuntu() {
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings

  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/"$(. /etc/os-release && echo "$ID")"/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  . /etc/os-release

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker
}

install_docker_rhel_compatible() {
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  elif command -v yum >/dev/null 2>&1; then
    yum install -y yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    echo "Não foi encontrado dnf ou yum."
    exit 1
  fi

  systemctl enable docker
  systemctl start docker
}

install_docker() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Execute como root para instalar o Docker."
    exit 1
  fi

  if [ ! -f /etc/os-release ]; then
    echo "Não foi possível identificar o sistema operacional."
    exit 1
  fi

  . /etc/os-release

  case "$ID" in
    debian|ubuntu)
      install_docker_debian_ubuntu
      ;;
    almalinux|rocky|centos|rhel|fedora)
      install_docker_rhel_compatible
      ;;
    *)
      echo "Sistema operacional não suportado automaticamente: ${ID}"
      echo "Instale Docker e Docker Compose manualmente e rode o script novamente."
      exit 1
      ;;
  esac
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker não encontrado."

    if ask_yes_no "Deseja instalar o Docker automaticamente?"; then
      install_docker
    else
      echo "Instalação cancelada. Instale o Docker manualmente e rode novamente."
      exit 1
    fi
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin não encontrado."

    if ask_yes_no "Deseja tentar instalar o Docker Compose plugin automaticamente?"; then
      install_docker
    else
      echo "Instalação cancelada. Instale o Docker Compose plugin manualmente e rode novamente."
      exit 1
    fi
  fi
}

# ============================================================
# EXECUÇÃO
# ============================================================

check_docker

mkdir -p "${STACK_DIR}"
cd "${STACK_DIR}"

cat > .env <<ENVEOF
PROXY_NAME=${PROXY_NAME}
ZABBIX_SERVER_HOST=${ZABBIX_SERVER_HOST}
ZABBIX_SERVER_PORT=${ZABBIX_SERVER_PORT}
ZABBIX_VERSION=${ZABBIX_VERSION}
TZ=${TZ}
CONFIG_FREQUENCY=${CONFIG_FREQUENCY}
DATA_SENDER_FREQUENCY=${DATA_SENDER_FREQUENCY}
PROXY_OFFLINE_BUFFER=${PROXY_OFFLINE_BUFFER}
CACHE_SIZE=${CACHE_SIZE}
HISTORY_CACHE_SIZE=${HISTORY_CACHE_SIZE}
TIMEOUT=${TIMEOUT}
ENVEOF

chmod 600 .env

cat > docker-compose.yml <<'YAMLEOF'
services:
  zabbix-proxy:
    image: zabbix/zabbix-proxy-sqlite3:${ZABBIX_VERSION}
    container_name: zabbix-proxy
    restart: unless-stopped
    network_mode: host
    environment:
      TZ: ${TZ}

      ZBX_PROXYMODE: 0
      ZBX_HOSTNAME: ${PROXY_NAME}

      ZBX_SERVER_HOST: ${ZABBIX_SERVER_HOST}
      ZBX_SERVER_PORT: ${ZABBIX_SERVER_PORT}

      ZBX_CONFIGFREQUENCY: ${CONFIG_FREQUENCY}
      ZBX_DATASENDERFREQUENCY: ${DATA_SENDER_FREQUENCY}
      ZBX_PROXYOFFLINEBUFFER: ${PROXY_OFFLINE_BUFFER}

      ZBX_CACHESIZE: ${CACHE_SIZE}
      ZBX_HISTORYCACHESIZE: ${HISTORY_CACHE_SIZE}
      ZBX_TIMEOUT: ${TIMEOUT}

      ZBX_STARTPOLLERS: 10
      ZBX_STARTPINGERS: 5
      ZBX_STARTDISCOVERERS: 3
      ZBX_STARTHTTPPOLLERS: 5
      ZBX_STARTSNMPPOLLERS: 5

    volumes:
      - zabbix-proxy-data:/var/lib/zabbix
      - zabbix-proxy-externalscripts:/usr/lib/zabbix/externalscripts
      - zabbix-proxy-enc:/var/lib/zabbix/enc
      - zabbix-proxy-ssh-keys:/var/lib/zabbix/ssh_keys
      - zabbix-proxy-ssl-certs:/var/lib/zabbix/ssl/certs
      - zabbix-proxy-ssl-keys:/var/lib/zabbix/ssl/keys
      - zabbix-proxy-ssl-ca:/var/lib/zabbix/ssl/ssl_ca
      - zabbix-proxy-snmptraps:/var/lib/zabbix/snmptraps
      - /etc/localtime:/etc/localtime:ro

volumes:
  zabbix-proxy-data:
  zabbix-proxy-externalscripts:
  zabbix-proxy-enc:
  zabbix-proxy-ssh-keys:
  zabbix-proxy-ssl-certs:
  zabbix-proxy-ssl-keys:
  zabbix-proxy-ssl-ca:
  zabbix-proxy-snmptraps:
YAMLEOF

docker compose pull
docker compose up -d

echo
echo "============================================================"
echo "Zabbix Proxy criado."
echo "============================================================"
echo
echo "Diretório:"
echo "  ${STACK_DIR}"
echo
echo "Nome do proxy:"
echo "  ${PROXY_NAME}"
echo
echo "Zabbix Server:"
echo "  ${ZABBIX_SERVER_HOST}:${ZABBIX_SERVER_PORT}"
echo
echo "Cadastre no Zabbix Server:"
echo "  Administration > Proxies > Create proxy"
echo "  Proxy name: ${PROXY_NAME}"
echo "  Proxy mode: Active"
echo
echo "Comandos úteis:"
echo "  cd ${STACK_DIR} && docker compose ps"
echo "  cd ${STACK_DIR} && docker compose logs -f"
echo "  docker logs -f zabbix-proxy"
echo