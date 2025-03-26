#!/bin/bash

set -e

ACTION=$1
BACKUP_DIR="/docker-backup"

if [ "$ACTION" == "backup" ]; then

    echo "🔄 Parando todos os containers..."
    docker ps -q | xargs -r docker stop

    mkdir -p "$BACKUP_DIR"

    echo "📦 Fazendo backup das imagens..."
    docker save $(docker images -q) -o "$BACKUP_DIR/docker-images.tar"

    echo "📂 Fazendo backup dos volumes..."
    sudo tar -czf "$BACKUP_DIR/docker-volumes.tar.gz" /var/lib/docker/volumes

    echo "🗃️ Fazendo backup dos containers..."
    docker ps -a --format '{{.Names}}' | xargs -I {} docker export {} -o "$BACKUP_DIR/{}_container.tar"

    echo "🌐 Fazendo backup das redes..."
    docker network ls --format '{{.Name}}' > "$BACKUP_DIR/docker-networks.txt"

    echo "📁 Fazendo backup do diretório /docker..."
    sudo tar -czf "$BACKUP_DIR/docker-files.tar.gz" /docker

    echo "✅ Backup concluído"
    exit 0
fi

if [ "$ACTION" == "restore" ]; then
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "❌ ERRO: Nenhum backup encontrado em $BACKUP_DIR"
        exit 1
    fi

    echo "📦 Restaurando imagens Docker..."
    docker load -i "$BACKUP_DIR/docker-images.tar"

    echo "📂 Restaurando volumes..."
    sudo tar -xzf "$BACKUP_DIR/docker-volumes.tar.gz" -C /

    echo "🗃️ Restaurando containers..."
    for file in $BACKUP_DIR/*_container.tar; do
        CONTAINER_NAME=$(basename "$file" _container.tar)
        docker import "$file" "$CONTAINER_NAME"
    done

    echo "🌐 Restaurando redes..."
    cat "$BACKUP_DIR/docker-networks.txt" | xargs -I {} docker network create {}

    echo "📁 Restaurando arquivos do diretório /docker..."
    sudo tar -xzf "$BACKUP_DIR/docker-files.tar.gz" -C /

    echo "✅ Restauração concluída!"
    exit 0
fi

echo "❌ ERRO: Opção inválida. Use:"
echo "   ./migracao_docker.sh backup usuario@ip-do-destino  # Para backup"
echo "   ./migracao_docker.sh restore                       # Para restauração"
exit 1
