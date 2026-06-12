#!/usr/bin/env bash
set -euo pipefail

echo "[1/6] Instalando dependências..."
apt update
apt install -y jq smartmontools sudo

echo "[2/6] Criando script de SMART MegaRAID..."
cat > /usr/local/bin/pbs-smart-health.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

DISK_ID="${1:-}"

if [[ -z "$DISK_ID" ]]; then
  echo 0
  exit 1
fi

RESULT=$(/usr/sbin/smartctl -H -d "megaraid,${DISK_ID}" /dev/bus/0 2>/dev/null \
  | awk -F: '
      /SMART overall-health|SMART Health Status/ {
        gsub(/^[ \t]+/, "", $2);
        print $2;
        found=1
      }
      END {
        if (!found) print "UNKNOWN"
      }
    ')

case "$RESULT" in
  PASSED|OK)
    echo 1
    ;;
  *)
    echo 0
    ;;
esac
EOF
chmod +x /usr/local/bin/pbs-smart-health.sh

echo "[3/6] Criando script de resumo de tasks PBS..."
cat > /usr/local/bin/pbs-task-summary.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

DAYS="${1:-30}"
SINCE="$(date -d "${DAYS} days ago" +%s)"

/usr/bin/proxmox-backup-manager task list --all --output-format json \
  | jq --argjson since "$SINCE" '
      def task_type:
        if .type then .type
        elif .worker_type then .worker_type
        elif .upid then (.upid | split(":")[5])
        else "unknown"
        end;

      def task_state:
        if (.status // "") == "OK" then "ok"
        elif (.status // "") == "" then "running"
        elif ((.status // "") | test("warn|warning"; "i")) then "warning"
        else "failed"
        end;

      [
        .[]
        | select((.starttime // 0) >= $since)
      ] as $tasks
      |
      {
        total: ($tasks | length),
        failed: ($tasks | map(select(task_state == "failed")) | length),
        warning: ($tasks | map(select(task_state == "warning")) | length),
        ok: ($tasks | map(select(task_state == "ok")) | length),
        running: ($tasks | map(select(task_state == "running")) | length),
        by_type: (
          $tasks
          | group_by(task_type)
          | map({
              key: (.[0] | task_type),
              value: {
                total: length,
                failed: (map(select(task_state == "failed")) | length),
                warning: (map(select(task_state == "warning")) | length),
                ok: (map(select(task_state == "ok")) | length),
                running: (map(select(task_state == "running")) | length)
              }
            })
          | from_entries
        ),
        failed_tasks: (
          $tasks
          | map(
              select(task_state == "failed")
              | {
                  type: task_type,
                  worker_id: (.worker_id // ""),
                  user: (.user // ""),
                  status: (.status // ""),
                  upid: (.upid // ""),
                  starttime: (.starttime // 0),
                  endtime: (.endtime // 0)
                }
            )
        )
      }
    '
EOF
chmod +x /usr/local/bin/pbs-task-summary.sh

echo "[4/6] Configurando sudoers para Zabbix..."
cat > /etc/sudoers.d/zabbix-pbs-monitoring <<'EOF'
zabbix ALL=(root) NOPASSWD: /usr/sbin/smartctl, /usr/local/bin/pbs-smart-health.sh, /usr/local/bin/pbs-task-summary.sh
EOF
chmod 440 /etc/sudoers.d/zabbix-pbs-monitoring

echo "[5/6] Criando UserParameters do Zabbix Agent 2..."
mkdir -p /etc/zabbix/zabbix_agent2.d

cat > /etc/zabbix/zabbix_agent2.d/pbs-smart.conf <<'EOF'
UserParameter=pbs.smart.health[*],sudo /usr/local/bin/pbs-smart-health.sh $1
UserParameter=pbs.smart.raw[*],sudo /usr/sbin/smartctl -A -d megaraid,$1 /dev/bus/0
EOF

cat > /etc/zabbix/zabbix_agent2.d/pbs-tasks.conf <<'EOF'
UserParameter=pbs.tasks.summary[*],sudo /usr/local/bin/pbs-task-summary.sh $1
UserParameter=pbs.tasks.failed.count[*],sudo /usr/local/bin/pbs-task-summary.sh $1 | /usr/bin/jq -r '.failed'
UserParameter=pbs.tasks.warning.count[*],sudo /usr/local/bin/pbs-task-summary.sh $1 | /usr/bin/jq -r '.warning'
UserParameter=pbs.tasks.running.count[*],sudo /usr/local/bin/pbs-task-summary.sh $1 | /usr/bin/jq -r '.running'
UserParameter=pbs.tasks.failed.list[*],sudo /usr/local/bin/pbs-task-summary.sh $1 | /usr/bin/jq -c '.failed_tasks'
EOF

echo "[6/6] Reiniciando Zabbix Agent 2..."
systemctl restart zabbix-agent2

echo
echo "Testes sugeridos:"
echo "zabbix_agent2 -t 'pbs.tasks.failed.count[30]'"
echo "zabbix_agent2 -t 'pbs.tasks.failed.list[30]'"
echo "zabbix_agent2 -t 'pbs.smart.health[0]'"
echo "zabbix_agent2 -t 'pbs.smart.health[1]'"
