#!/usr/bin/env bash
set -euo pipefail

ZABBIX_CONF="/etc/zabbix/zabbix_agent2.conf"
ZABBIX_D_DIR="/etc/zabbix/zabbix_agent2.d"
ZABBIX_SCRIPT_DIR="/etc/zabbix/scripts"
ZFS_SCRIPT="${ZABBIX_SCRIPT_DIR}/zfs.py"
ZFS_USERPARAM="${ZABBIX_D_DIR}/zfs.conf"

ZFS_PY_URL="https://raw.githubusercontent.com/blind-oracle/zabbix-zfs/master/zfs.py"

echo "==> Validando comandos necessários..."

if ! command -v zpool >/dev/null 2>&1; then
    echo "ERRO: comando zpool não encontrado."
    exit 1
fi

if ! command -v zfs >/dev/null 2>&1; then
    echo "ERRO: comando zfs não encontrado."
    exit 1
fi

if ! command -v zabbix_agent2 >/dev/null 2>&1; then
    echo "ERRO: zabbix_agent2 não encontrado. Instale o Zabbix Agent 2 antes."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "ERRO: curl não encontrado."
    echo "Instale com: apt install -y curl"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERRO: python3 não encontrado."
    echo "Instale com: apt install -y python3"
    exit 1
fi

ZPOOL_BIN="$(command -v zpool)"
ZFS_BIN="$(command -v zfs)"

echo "zpool: ${ZPOOL_BIN}"
echo "zfs:   ${ZFS_BIN}"

echo "==> Criando diretórios..."

mkdir -p "${ZABBIX_D_DIR}"
mkdir -p "${ZABBIX_SCRIPT_DIR}"

echo "==> Baixando script zfs.py..."

curl -fsSL "${ZFS_PY_URL}" -o "${ZFS_SCRIPT}"
chmod +x "${ZFS_SCRIPT}"

echo "==> Ajustando caminhos do zpool/zfs no script..."

sed -i "s|/sbin/zpool|${ZPOOL_BIN}|g" "${ZFS_SCRIPT}"
sed -i "s|/sbin/zfs|${ZFS_BIN}|g" "${ZFS_SCRIPT}"

echo "==> Criando UserParameter..."

cat > "${ZFS_USERPARAM}" <<EOF
UserParameter=zfs,${ZFS_SCRIPT}
EOF

echo "==> Verificando Include do Zabbix Agent 2..."

if ! grep -qE '^Include=/etc/zabbix/zabbix_agent2\.d/\*.conf' "${ZABBIX_CONF}"; then
    echo "Include=/etc/zabbix/zabbix_agent2.d/*.conf" >> "${ZABBIX_CONF}"
    echo "Include adicionado em ${ZABBIX_CONF}"
else
    echo "Include já existe."
fi

echo "==> Testando script como root..."

if "${ZFS_SCRIPT}" >/tmp/zfs_test_root.json; then
    echo "OK: script executou como root."
else
    echo "ERRO: script falhou como root."
    exit 1
fi

echo "==> Testando script como usuário zabbix..."

if id zabbix >/dev/null 2>&1; then
    if sudo -u zabbix "${ZFS_SCRIPT}" >/tmp/zfs_test_zabbix.json 2>/tmp/zfs_test_zabbix.err; then
        echo "OK: script executou como usuário zabbix."
    else
        echo "AVISO: script falhou como usuário zabbix."
        echo "Erro:"
        cat /tmp/zfs_test_zabbix.err
        echo
        echo "Se for erro de permissão, será necessário liberar zpool/zfs via sudoers ou ajustar permissões."
        exit 1
    fi
else
    echo "ERRO: usuário zabbix não existe."
    exit 1
fi

echo "==> Reiniciando Zabbix Agent 2..."

systemctl restart zabbix-agent2

sleep 2

echo "==> Validando status do serviço..."

if systemctl is-active --quiet zabbix-agent2; then
    echo "OK: zabbix-agent2 está ativo."
else
    echo "ERRO: zabbix-agent2 não iniciou corretamente."
    systemctl status zabbix-agent2 --no-pager
    exit 1
fi

echo "==> Testando key zfs no Agent 2..."

if zabbix_agent2 -t zfs >/tmp/zfs_agent2_test.out 2>&1; then
    cat /tmp/zfs_agent2_test.out
    echo
    echo "OK: key zfs funcionando localmente."
else
    echo "ERRO: key zfs falhou no zabbix_agent2."
    cat /tmp/zfs_agent2_test.out
    exit 1
fi

echo
echo "==> Instalação concluída."
echo
echo "Teste agora a partir do Zabbix Proxy:"
echo "zabbix_get -s IP_DO_HOST -p 10050 -k zfs"