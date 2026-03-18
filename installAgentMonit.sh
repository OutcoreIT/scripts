#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Telegraf (InfluxDBv2) + Node Exporter (Prometheus)
# + (Opcional) Firewall + (Opcional) Proxmox VM/CT status export
# Ubuntu 22/24 e Debian 11/12/13
#
# Uso:
#   ./script.sh TOKEN_INFLUXDB
# =============================================================================

# ---- Validação de argumentos -----------------------------------------------
if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "Uso: $0 TOKEN_INFLUXDB"
  exit 1
fi

INFLUXDB_TOKEN="$1"

# ---- Variáveis configuráveis -----------------------------------------------
INFLUXDB_URL="http://sentry.outcore.com.br:8087"
INFLUXDB_ORG="outcore"
INFLUXDB_BUCKET="telegraf"

TELEGRAF_CONF="/etc/telegraf/telegraf.conf"
GPG_KEYRING="/usr/share/keyrings/influxdb-archive-keyring.gpg"
APT_LIST="/etc/apt/sources.list.d/influxdata.list"

# Node Exporter
NODE_EXPORTER_VERSION="1.8.1"
NODE_EXPORTER_USER="node_exporter"
NODE_EXPORTER_BIN="/usr/local/bin/node_exporter"
NODE_EXPORTER_PORT="9100"
NODE_EXPORTER_LISTEN_ADDR="0.0.0.0"
NODE_EXPORTER_SERVICE="/etc/systemd/system/node_exporter.service"

# Textfile collector
TEXTFILE_BASE_DIR="/var/lib/node_exporter"
TEXTFILE_DIR="${TEXTFILE_BASE_DIR}/textfile_collector"

# Proxmox VM/CT metrics
PROXMOX_PROM_SCRIPT="/usr/local/bin/proxmox_guest_prom.sh"
PROXMOX_PROM_METRIC_FILE="${TEXTFILE_DIR}/proxmox_guests.prom"
PROXMOX_PROM_TIMER="/etc/systemd/system/proxmox-guest-metric.timer"
PROXMOX_PROM_SERVICE="/etc/systemd/system/proxmox-guest-metric.service"

# Firewall
FIREWALL_ALLOW_IP="20.121.175.191"
FIREWALL_PORT="9100"

# ---- Utilitários -----------------------------------------------------------
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERRO] $*" >&2; }

# ---- Detecção de Sistema Operacional ---------------------------------------
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "${ID,,}"
  else
    log_error "Não foi possível detectar o sistema operacional (/etc/os-release não encontrado)."
    exit 1
  fi
}

check_os() {
  local os
  os="$(detect_os)"
  case "$os" in
    ubuntu|debian)
      log_info "Sistema detectado: ${os^} ($(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"'))"
      ;;
    *)
      log_error "Sistema operacional não suportado: $os. Use Ubuntu ou Debian."
      exit 1
      ;;
  esac
}

ask_yes_no() {
  local prompt="$1"
  local def="${2:-N}"
  local ans

  while true; do
    if [[ "$def" == "Y" ]]; then
      read -r -p "${prompt} [Y/n]: " ans || true
      ans="${ans:-Y}"
    else
      read -r -p "${prompt} [y/N]: " ans || true
      ans="${ans:-N}"
    fi

    case "${ans}" in
      Y|y|yes|YES) return 0 ;;
      N|n|no|NO)  return 1 ;;
      *) log_warn "Resposta inválida. Use Y ou N." ;;
    esac
  done
}

check_root() {
  if [[ ${EUID} -ne 0 ]]; then
    log_error "Este script precisa ser executado como root (sudo)."
    exit 1
  fi
}

is_proxmox_host() {
  command -v qm >/dev/null 2>&1 && command -v pct >/dev/null 2>&1
}

# ---- Firewall (iptables) ---------------------------------------------------
configure_firewall_iptables() {
  log_info "Configurando firewall (iptables) para permitir apenas ${FIREWALL_ALLOW_IP} na porta ${FIREWALL_PORT}/tcp..."

  apt-get update -qq
  apt-get install -y iptables-persistent

  iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  iptables -C INPUT -p tcp -s "${FIREWALL_ALLOW_IP}" --dport "${FIREWALL_PORT}" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 2 -p tcp -s "${FIREWALL_ALLOW_IP}" --dport "${FIREWALL_PORT}" -j ACCEPT

  iptables -C INPUT -p tcp --dport "${FIREWALL_PORT}" -j DROP 2>/dev/null || \
    iptables -I INPUT 3 -p tcp --dport "${FIREWALL_PORT}" -j DROP

  netfilter-persistent save
  systemctl enable --now netfilter-persistent

  log_info "Firewall aplicado e persistido."
}

# ---- Telegraf --------------------------------------------------------------
add_influxdb_repo() {
  log_info "Adicionando chave GPG e repositório do InfluxDB..."

  local os
  os="$(detect_os)"

  rm -f "$APT_LIST" "$GPG_KEYRING"

  apt-get update -qq
  apt-get install -y curl gpg ca-certificates

  local tmp_keyring
  tmp_keyring="$(mktemp)"

  curl -fsSL https://repos.influxdata.com/influxdata-archive_compat.key \
    | gpg --dearmor > "$tmp_keyring"

  local keyserver="hkp://keyserver.ubuntu.com:80"
  gpg --no-default-keyring \
    --keyring "$tmp_keyring" \
    --keyserver "$keyserver" \
    --recv-keys DA61C26A0585BD3B >/dev/null 2>&1 || true

  mv "$tmp_keyring" "$GPG_KEYRING"
  chmod 644 "$GPG_KEYRING"

  local repo_url
  case "$os" in
    ubuntu) repo_url="https://repos.influxdata.com/ubuntu" ;;
    debian) repo_url="https://repos.influxdata.com/debian" ;;
  esac

  echo "deb [signed-by=${GPG_KEYRING}] ${repo_url} stable main" \
    | tee "$APT_LIST" >/dev/null

  log_info "Repositório do InfluxDB adicionado (${os}: ${repo_url})."
}

install_telegraf() {
  log_info "Instalando Telegraf..."
  apt-get update -qq
  apt-get install -y telegraf
  log_info "Telegraf instalado."
}

configure_telegraf() {
  log_info "Escrevendo configuração em ${TELEGRAF_CONF}..."

  cat > "$TELEGRAF_CONF" <<EOF
[agent]
  interval = "10s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"

[[outputs.influxdb_v2]]
  urls = ["${INFLUXDB_URL}"]
  token = "${INFLUXDB_TOKEN}"
  organization = "${INFLUXDB_ORG}"
  bucket = "${INFLUXDB_BUCKET}"

[[inputs.cpu]]
  percpu = true
  totalcpu = true
  collect_cpu_time = false
  report_active = true

[[inputs.mem]]
[[inputs.disk]]
  ignore_fs = ["tmpfs", "devtmpfs", "overlay", "squashfs"]
[[inputs.system]]
EOF

  log_info "Configuração do Telegraf aplicada."
}

start_telegraf() {
  log_info "Reiniciando serviço do Telegraf..."
  systemctl restart telegraf
  systemctl enable telegraf
  log_info "Telegraf ativo e habilitado."
}

# ---- Node Exporter ---------------------------------------------------------
ensure_node_exporter_user() {
  if ! id -u "$NODE_EXPORTER_USER" >/dev/null 2>&1; then
    log_info "Criando usuário ${NODE_EXPORTER_USER}..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "$NODE_EXPORTER_USER"
  fi
}

install_node_exporter() {
  log_info "Instalando Node Exporter v${NODE_EXPORTER_VERSION}..."

  apt-get update -qq
  apt-get install -y curl tar ca-certificates

  local arch
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    armhf) arch="armv7" ;;
    *)
      log_error "Arquitetura não suportada: $(dpkg --print-architecture)"
      exit 1
      ;;
  esac

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap '[[ -n "${tmpdir:-}" ]] && rm -rf "$tmpdir"' RETURN

  local url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${arch}.tar.gz"
  curl -fsSL "$url" -o "${tmpdir}/node_exporter.tar.gz"
  tar -xzf "${tmpdir}/node_exporter.tar.gz" -C "$tmpdir"

  install -m 0755 "${tmpdir}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${arch}/node_exporter" "$NODE_EXPORTER_BIN"
  chown root:root "$NODE_EXPORTER_BIN"

  log_info "Node Exporter instalado em ${NODE_EXPORTER_BIN}."
}

configure_node_exporter_service() {
  log_info "Criando service systemd do Node Exporter..."

  mkdir -p "$TEXTFILE_BASE_DIR"
  mkdir -p "$TEXTFILE_DIR"

  chown root:root "$TEXTFILE_BASE_DIR"
  chmod 755 "$TEXTFILE_BASE_DIR"

  chown -R "${NODE_EXPORTER_USER}:${NODE_EXPORTER_USER}" "$TEXTFILE_DIR"
  chmod 755 "$TEXTFILE_DIR"

  cat > "$NODE_EXPORTER_SERVICE" <<EOF
[Unit]
Description=Prometheus Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=${NODE_EXPORTER_USER}
Group=${NODE_EXPORTER_USER}
Type=simple
ExecStart=${NODE_EXPORTER_BIN} \\
  --web.listen-address=${NODE_EXPORTER_LISTEN_ADDR}:${NODE_EXPORTER_PORT} \\
  --collector.systemd \\
  --collector.processes \\
  --collector.textfile.directory=${TEXTFILE_DIR}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable node_exporter
  systemctl restart node_exporter

  log_info "Node Exporter ativo na porta ${NODE_EXPORTER_PORT} (textfile: ${TEXTFILE_DIR})."
}

# ---- Proxmox VM/CT -> Prometheus (textfile collector) ----------------------
install_proxmox_guest_prom_script() {
  if ! is_proxmox_host; then
    log_warn "Host não parece ser Proxmox (qm/pct ausentes). Pulando métricas de VM/CT."
    return 0
  fi

  log_info "Instalando script de métricas de VMs/CTs do Proxmox..."

  cat > "$PROXMOX_PROM_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

OUT_DIR="/var/lib/node_exporter/textfile_collector"
OUT_FILE="${OUT_DIR}/proxmox_guests.prom"
TMP_FILE="$(mktemp)"
NODE="$(hostname -s)"

mkdir -p "$OUT_DIR"

qemu_total=0
qemu_running=0
qemu_stopped=0
lxc_total=0
lxc_running=0
lxc_stopped=0

{
  echo "# HELP proxmox_qemu_status QEMU VM status (1=running, 0=stopped)"
  echo "# TYPE proxmox_qemu_status gauge"
  echo "# HELP proxmox_lxc_status LXC CT status (1=running, 0=stopped)"
  echo "# TYPE proxmox_lxc_status gauge"
  echo "# HELP proxmox_qemu_count Total QEMU VMs by state"
  echo "# TYPE proxmox_qemu_count gauge"
  echo "# HELP proxmox_lxc_count Total LXC CTs by state"
  echo "# TYPE proxmox_lxc_count gauge"
} > "$TMP_FILE"

if command -v qm >/dev/null 2>&1; then
  while read -r vmid name status rest; do
    [[ -z "${vmid:-}" ]] && continue
    [[ "$vmid" == "VMID" ]] && continue
    [[ ! "$vmid" =~ ^[0-9]+$ ]] && continue

    name="${name:-vm-${vmid}}"
    status="${status:-unknown}"
    esc_name="$(printf '%s' "$name" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"

    qemu_total=$((qemu_total + 1))
    if [[ "$status" == "running" ]]; then
      qemu_running=$((qemu_running + 1))
      val=1
    else
      qemu_stopped=$((qemu_stopped + 1))
      val=0
    fi

    echo "proxmox_qemu_status{node=\"${NODE}\",vmid=\"${vmid}\",name=\"${esc_name}\",status=\"${status}\"} ${val}" >> "$TMP_FILE"
  done < <(qm list 2>/dev/null)
fi

if command -v pct >/dev/null 2>&1; then
  while read -r vmid status lock name rest; do
    [[ -z "${vmid:-}" ]] && continue
    [[ "$vmid" == "VMID" ]] && continue
    [[ ! "$vmid" =~ ^[0-9]+$ ]] && continue

    name="${name:-ct-${vmid}}"
    status="${status:-unknown}"
    esc_name="$(printf '%s' "$name" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"

    lxc_total=$((lxc_total + 1))
    if [[ "$status" == "running" ]]; then
      lxc_running=$((lxc_running + 1))
      val=1
    else
      lxc_stopped=$((lxc_stopped + 1))
      val=0
    fi

    echo "proxmox_lxc_status{node=\"${NODE}\",vmid=\"${vmid}\",name=\"${esc_name}\",status=\"${status}\"} ${val}" >> "$TMP_FILE"
  done < <(pct list 2>/dev/null)
fi

{
  echo "proxmox_qemu_count{node=\"${NODE}\",state=\"total\"} ${qemu_total}"
  echo "proxmox_qemu_count{node=\"${NODE}\",state=\"running\"} ${qemu_running}"
  echo "proxmox_qemu_count{node=\"${NODE}\",state=\"stopped\"} ${qemu_stopped}"
  echo "proxmox_lxc_count{node=\"${NODE}\",state=\"total\"} ${lxc_total}"
  echo "proxmox_lxc_count{node=\"${NODE}\",state=\"running\"} ${lxc_running}"
  echo "proxmox_lxc_count{node=\"${NODE}\",state=\"stopped\"} ${lxc_stopped}"
} >> "$TMP_FILE"

mv "$TMP_FILE" "$OUT_FILE"
chmod 644 "$OUT_FILE"
EOF

  chmod +x "$PROXMOX_PROM_SCRIPT"

  cat > "$PROXMOX_PROM_SERVICE" <<EOF
[Unit]
Description=Export Proxmox VM/CT status for Prometheus (node_exporter textfile collector)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${PROXMOX_PROM_SCRIPT}
EOF

  cat > "$PROXMOX_PROM_TIMER" <<EOF
[Unit]
Description=Run Proxmox guest metric exporter every 60 seconds

[Timer]
OnBootSec=20s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=$(basename "$PROXMOX_PROM_SERVICE")

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$(basename "$PROXMOX_PROM_TIMER")"
  systemctl start "$(basename "$PROXMOX_PROM_SERVICE")"

  log_info "Métricas Proxmox configuradas. Verifique em: curl -s localhost:${NODE_EXPORTER_PORT}/metrics | grep '^proxmox_'"
}

# ---- Execução --------------------------------------------------------------
main() {
  check_root
  check_os

  local DO_FIREWALL="N"
  local DO_EXPORTER="Y"
  local DO_PROXMOX="N"

  if ask_yes_no "Deseja instalar/configurar o Node Exporter (Prometheus)?" "Y"; then
    DO_EXPORTER="Y"
  else
    DO_EXPORTER="N"
  fi

  if is_proxmox_host; then
    if ask_yes_no "Deseja expor métricas de VMs/CTs do Proxmox para Prometheus?" "Y"; then
      DO_PROXMOX="Y"
    else
      DO_PROXMOX="N"
    fi
  fi

  if ask_yes_no "Deseja configurar o firewall (iptables) para restringir a porta ${FIREWALL_PORT}/tcp apenas para ${FIREWALL_ALLOW_IP}?" "N"; then
    DO_FIREWALL="Y"
  else
    DO_FIREWALL="N"
  fi

  add_influxdb_repo
  install_telegraf
  configure_telegraf
  start_telegraf

  if [[ "$DO_EXPORTER" == "Y" ]]; then
    ensure_node_exporter_user
    install_node_exporter
    configure_node_exporter_service

    if [[ "$DO_PROXMOX" == "Y" ]]; then
      install_proxmox_guest_prom_script
    fi

    if [[ "$DO_FIREWALL" == "Y" ]]; then
      configure_firewall_iptables
    fi
  else
    log_warn "Node Exporter não será instalado. Sem Prometheus/alertas por este host."
    if [[ "$DO_PROXMOX" == "Y" ]]; then
      log_warn "Métricas Proxmox para Prometheus requerem Node Exporter. Ignorando Proxmox."
    fi
    if [[ "$DO_FIREWALL" == "Y" ]]; then
      log_warn "Firewall para porta ${FIREWALL_PORT} depende do Node Exporter. Ignorando firewall."
    fi
  fi

  log_info "Concluído: Telegraf (InfluxDBv2) + (opcional) Node Exporter + (opcional) Proxmox VM/CT + (opcional) Firewall."

  if [[ "$DO_EXPORTER" == "Y" ]]; then
    log_info "Próximo passo no Prometheus: adicionar este host como target em :${NODE_EXPORTER_PORT}."
    log_info "Teste rápido: curl -s localhost:${NODE_EXPORTER_PORT}/metrics | head"
    log_info "Teste textfile collector: curl -s localhost:${NODE_EXPORTER_PORT}/metrics | grep node_textfile_scrape_error"

    if [[ "$DO_PROXMOX" == "Y" ]]; then
      log_info "Teste Proxmox: curl -s localhost:${NODE_EXPORTER_PORT}/metrics | grep '^proxmox_'"
    fi
  fi
}

main "$@"