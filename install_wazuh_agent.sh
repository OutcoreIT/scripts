#!/usr/bin/env bash
set -euo pipefail

# Instala e registra o Wazuh Agent sem credenciais versionadas.
# O manager deve aceitar registro sem senha na porta TCP 1515.

readonly DEFAULT_MANAGER="wazuh.outcore.com.br"
MANAGER="$DEFAULT_MANAGER"
AGENT_NAME="$(hostname -f 2>/dev/null || hostname)"
AGENT_GROUP=""

usage() {
    cat <<'EOF'
Uso: sudo ./install_wazuh_agent.sh [opções]

Opções:
  --manager HOST       Wazuh Manager (padrão: wazuh.outcore.com.br)
  --agent-name NAME    Nome exibido para o agente (padrão: hostname FQDN)
  --group GROUP        Grupo Wazuh opcional atribuído no registro
  -h, --help           Exibe esta ajuda

O registro é feito sem senha. Não inclua chaves, tokens ou senhas neste repositório.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manager)
            MANAGER="${2:?Informe o hostname do manager após --manager}"
            shift 2
            ;;
        --agent-name)
            AGENT_NAME="${2:?Informe o nome do agente após --agent-name}"
            shift 2
            ;;
        --group)
            AGENT_GROUP="${2:?Informe o grupo após --group}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Opção inválida: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    sudo_args=(sudo -- "$0" --manager "$MANAGER" --agent-name "$AGENT_NAME")
    if [[ -n "$AGENT_GROUP" ]]; then
        sudo_args+=(--group "$AGENT_GROUP")
    fi
    exec "${sudo_args[@]}"
fi

if [[ ! -r /etc/os-release ]]; then
    echo "ERRO: não foi possível identificar o sistema operacional." >&2
    exit 1
fi

. /etc/os-release
if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* && "${ID:-}" != "debian" ]]; then
    echo "ERRO: este instalador suporta Debian e Ubuntu." >&2
    exit 1
fi

if [[ ! "$MANAGER" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "ERRO: informe apenas o hostname ou IP do Wazuh Manager." >&2
    exit 2
fi

echo "[1/6] Validando conectividade com ${MANAGER}..."
getent hosts "$MANAGER" >/dev/null
for port in 1514 1515; do
    timeout 5 bash -c "</dev/tcp/${MANAGER}/${port}" || {
        echo "ERRO: ${MANAGER}:${port}/TCP não está acessível." >&2
        exit 1
    }
done

echo "[2/6] Instalando dependências e auditd..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg auditd

echo "[3/6] Configurando o repositório oficial do Wazuh..."
curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
    | gpg --dearmor --yes --output /usr/share/keyrings/wazuh.gpg
chmod 0644 /usr/share/keyrings/wazuh.gpg
printf '%s\n' 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main' \
    > /etc/apt/sources.list.d/wazuh.list
apt-get update

echo "[4/6] Instalando o Wazuh Agent..."
install_env=(
    "WAZUH_MANAGER=${MANAGER}"
    "WAZUH_REGISTRATION_SERVER=${MANAGER}"
    "WAZUH_AGENT_NAME=${AGENT_NAME}"
)
if [[ -n "$AGENT_GROUP" ]]; then
    install_env+=("WAZUH_AGENT_GROUP=${AGENT_GROUP}")
fi
env "${install_env[@]}" apt-get install -y wazuh-agent

echo "[5/6] Habilitando auditoria de configurações de acesso..."
install -d -m 0750 /etc/audit/rules.d
install -m 0640 /dev/stdin /etc/audit/rules.d/99-outcore-access.rules <<'EOF'
# Alterações que afetam autenticação e privilégios.
-w /etc/ssh/sshd_config -p wa -k outcore_sshd_config
-w /etc/ssh/sshd_config.d -p wa -k outcore_sshd_config
-w /etc/sudoers -p wa -k outcore_sudoers
-w /etc/sudoers.d -p wa -k outcore_sudoers
-w /root/.ssh/authorized_keys -p wa -k outcore_root_ssh_key
EOF
augenrules --load
systemctl enable --now auditd

# Garante que os eventos do auditd também sejam enviados ao Wazuh.
if ! grep -Fq '<location>/var/log/audit/audit.log</location>' /var/ossec/etc/ossec.conf; then
    sed -i '/<\/ossec_config>/i\  <localfile>\n    <location>/var/log/audit/audit.log</location>\n    <log_format>audit</log_format>\n  </localfile>' /var/ossec/etc/ossec.conf
fi

echo "[6/6] Iniciando o agente..."
systemctl enable --now wazuh-agent
for _ in {1..15}; do
    if systemctl is-active --quiet wazuh-agent; then
        break
    fi
    sleep 2
done

if ! systemctl is-active --quiet wazuh-agent; then
    systemctl --no-pager --full status wazuh-agent || true
    echo "ERRO: o Wazuh Agent não ficou ativo." >&2
    exit 1
fi
systemctl is-active wazuh-agent

echo
echo "Wazuh Agent instalado para ${MANAGER}."
echo "Confirme no dashboard se o agente '${AGENT_NAME}' aparece como Active."
