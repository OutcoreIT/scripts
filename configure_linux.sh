#!/bin/bash

set -e

# Função para perguntar ao usuário se deseja instalar o Docker
perguntar_docker() {
    while true; do
        read -p "🐳 Deseja instalar o Docker? (s/n): " resposta
        case $resposta in
            [SsyY]* ) instalar_docker=true; break;;
            [Nn]* ) instalar_docker=false; break;;
            * ) echo "Por favor, responda com 's' para sim ou 'n' para não.";;
        esac
    done
}

# Perguntar ao usuário se deseja instalar o Docker
perguntar_docker

# Remover pacotes conflitantes do Docker apenas se o usuário optou por instalá-lo
if [ "$instalar_docker" = true ]; then
    echo "🔄 Removendo pacotes conflitantes..."
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        sudo apt-get remove -y "$pkg" || true
    done
else
    echo "🔄 Ignorando instalação do Docker conforme solicitado..."
fi

# Configurar timezone
echo "🌎 Configurando timezone para America/Sao_Paulo..."
sudo timedatectl set-timezone America/Sao_Paulo

# Atualizar pacotes e instalar dependências essenciais
echo "📦 Atualizando pacotes e instalando dependências..."
sudo apt update && sudo apt install -y \
    ca-certificates curl python3-venv iputils-ping net-tools traceroute zsh python3-pip coreutils vim gawk moreutils unzip git ruby ruby-dev

sudo apt-get install -y btop || true

sudo snap install btop || true

# Configurar repositório oficial do Docker apenas se o usuário optou por instalá-lo
if [ "$instalar_docker" = true ]; then
    echo "🐳 Adicionando repositório oficial do Docker..."
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Instalar Docker e plugins
    echo "🐳 Instalando Docker e plugins..."
    sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Instalar Docker Compose manualmente
    echo "🐳 Instalando Docker Compose..."
    curl -SL https://github.com/docker/compose/releases/download/v2.34.0/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi
echo "💻 Desabilitando Mouse no Vim..."
echo "set mouse-=a" >> ~/.vimrc

# Instalar e configurar Zsh sem iniciar automaticamente
echo "💻 Instalando e configurando Zsh..."
sudo chsh -s $(which zsh) $(whoami) || true

if [ -d "$HOME/.oh-my-zsh" ]; then
    echo "🚀 Oh My Zsh já está instalado. Removendo e reinstalando..."
    rm -rf "$HOME/.oh-my-zsh"
fi

echo "⏳ Instalando Oh My Zsh..."
RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" || echo "⚠️ Falha ao baixar/instalar Oh My Zsh, continuando..."

# Configurar logotipo personalizado da OutCore no Oh My Zsh
echo "🎨 Configurando logotipo da OutCore no Oh My Zsh..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
BANNER_SCRIPT="${SCRIPT_DIR}/outcore_banner.sh"

if [ ! -f "$BANNER_SCRIPT" ]; then
    echo "📥 Baixando outcore_banner.sh..."
    curl -fsSL "https://raw.githubusercontent.com/OutcoreIT/scripts/main/outcore_banner.sh" -o /tmp/outcore_banner.sh || true
    BANNER_SCRIPT="/tmp/outcore_banner.sh"
fi

if [ -f "$BANNER_SCRIPT" ]; then
    mkdir -p "$HOME/.oh-my-zsh/custom"
    cp "$BANNER_SCRIPT" "$HOME/.oh-my-zsh/custom/outcore_banner.zsh"
    chmod +x "$HOME/.oh-my-zsh/custom/outcore_banner.zsh"
    bash "$HOME/.oh-my-zsh/custom/outcore_banner.zsh" --patch-omz || echo "⚠️ Falha ao aplicar patch do banner no Oh My Zsh, continuando..."

    # O banner de acesso é responsabilidade do MOTD. Remove chamadas legadas
    # no Zsh para impedir uma segunda impressão depois de "Last login".
    if [ -f "$HOME/.zshrc" ]; then
        sed -i -E '/^[[:space:]]*(bash[[:space:]]+)?[^#]*outcore_banner\.zsh([[:space:]].*)?$/d' "$HOME/.zshrc"
    fi

    # Configurar MOTD global para sessões SSH. O banner fica fora do diretório
    # do usuário para funcionar para qualquer conta autorizada no servidor.
    echo "🔐 Configurando banner OutCore no login SSH..."
    sudo install -m 0755 "$BANNER_SCRIPT" /usr/local/bin/outcore_banner

    # Desabilita somente os scripts padrão do Ubuntu, preservando eventuais
    # MOTDs personalizados criados pelo administrador.
    for motd_script in \
        00-header 10-help-text 50-landscape-sysinfo 50-motd-news 85-fwupd \
        88-esm-announce 91-contract-ua-esm-status 91-release-upgrade \
        92-unattended-upgrades 95-hwe-eol 97-overlayroot 98-fsck-at-reboot; do
        sudo chmod a-x "/etc/update-motd.d/${motd_script}" 2>/dev/null || true
    done

    sudo install -m 0755 /dev/stdin /etc/update-motd.d/99-outcore <<'EOF'
#!/usr/bin/env bash

/usr/local/bin/outcore_banner "Servidor administrado pela OutCore · acesso monitorado"

printf '  host      %s\n' "$(hostname -f 2>/dev/null || hostname)"
printf '  uptime    %s\n' "$(uptime -p)"
printf '  disco     %s\n' "$(df -h / | awk 'NR == 2 {print $3 " de " $2 " (" $5 ")"}')"
printf '  memória   %s\n\n' "$(free -h | awk '/^Mem:/ {print $3 " de " $2}')"
EOF

    # Mantém a informação de último login fora de todas as sessões SSH.
    sudo install -d -m 0755 /etc/ssh/sshd_config.d
    printf '%s\\n' 'PrintLastLog no' | sudo tee /etc/ssh/sshd_config.d/99-outcore.conf >/dev/null
    sudo sshd -t && sudo systemctl reload ssh || echo "⚠️ Não foi possível recarregar o SSH; valide a configuração manualmente."
fi

# Instalar temas e plugins do Zsh
echo "🎨 Instalando Powerlevel10k..."
if [ ! -d "$HOME/.oh-my-zsh/custom/themes/powerlevel10k" ]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ~/.oh-my-zsh/custom/themes/powerlevel10k || echo "⚠️ Falha ao instalar Powerlevel10k, continuando..."
else
    echo "ℹ️ Powerlevel10k já está instalado."
fi

echo "🎨 Instalando Zsh Syntax Highlighting e Autosuggestions..."
if [ ! -d "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting || echo "⚠️ Falha ao instalar Zsh Syntax Highlighting, continuando..."
else
    echo "ℹ️ Zsh Syntax Highlighting já está instalado."
fi

if [ ! -d "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions" ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions.git ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions || echo "⚠️ Falha ao instalar Zsh Autosuggestions, continuando..."
else
    echo "ℹ️ Zsh Autosuggestions já está instalado."
fi

# Instalar plugins adicionais do Oh My Zsh
echo "🔌 Instalando plugins adicionais do Oh My Zsh..."
mkdir -p ~/.oh-my-zsh/custom/plugins
for plugin in git composer z docker docker-compose docker-machine jump sudo; do
    if [ ! -d "$HOME/.oh-my-zsh/custom/plugins/$plugin" ]; then
        echo "📥 Baixando plugin: $plugin"
        git clone "https://github.com/ohmyzsh/ohmyzsh.git" --depth=1 ~/.oh-my-zsh/custom/plugins/$plugin || echo "⚠️ Falha ao baixar plugin: $plugin, continuando..."
    fi
done
    
# Instalar TheFuck (ignora erros se falhar e continua)
echo "🤦 Instalando TheFuck..."
(
    set +e
    if ! command -v pipx >/dev/null 2>&1; then
        sudo apt install -y pipx 2>/dev/null
    fi

    if command -v pipx >/dev/null 2>&1; then
        pipx ensurepath
        pipx install thefuck --force
    elif command -v pip3 >/dev/null 2>&1; then
        pip3 install thefuck --user || pip3 install thefuck --user --break-system-packages
    fi
) || true

if ! command -v thefuck >/dev/null 2>&1; then
    echo "⚠️ TheFuck não pôde ser instalado. Ignorando e continuando..."
else
    echo "✅ TheFuck instalado com sucesso!"
fi

# Instalar ColorLS via RubyGems (ignora erros se falhar e continua)
echo "🌈 Verificando se é possível instalar ColorLS..."
(
    set +e
    if command -v ruby >/dev/null 2>&1; then
        ruby_version=$(ruby -e 'puts RUBY_VERSION' 2>/dev/null || echo "0.0.0")
        required_version="3.0.0"

        if [ "$(printf '%s\n' "$required_version" "$ruby_version" | sort -V | head -n1)" = "$required_version" ]; then
            echo "🌈 Instalando ColorLS..."
            sudo gem install colorls || echo "⚠️ Falha ao instalar ColorLS via gem, continuando..."
        else
            echo "⚠️ Versão do Ruby ($ruby_version) é mais antiga que a necessária para ColorLS (3.0.0+)"
            echo "⚠️ ColorLS não será instalado automaticamente"
            echo "ℹ️ Para instalar ColorLS no futuro, atualize o Ruby para a versão 3.0.0 ou superior e depois execute: sudo gem install colorls"
        fi
    else
        echo "⚠️ Ruby não encontrado. ColorLS não será instalado."
    fi
) || true

# Adicionado Chaves de Autenticação
echo "💻 Adicionado Chaves de Autenticação..."
cat <<EOL > ~/.ssh/authorized_keys
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDjLGbe8A9uF2GGbwrE2DxLMGWblJKBXV+NoopaELzxluUqaw92ow4t2or6VFf0Ls0ez9sC17QdfX+7Qu18FeJKChihjVmlKjLSX5rfLvjzY8jzr61RNWszEfpHIl5YhrbblfkpEgJ1RmqTNQNjDJj4e+0i/+dHlY1ogxb7wnOidNVOhOrhymOLIRxtlk8n4sxIwRSl2fGwyC07I89MS69HOs0nFe/Zhb8L5z4RM6OZNr4spwBTt8i8Mb/5KAxFgyuiGSMqziBhUymCYMLnwHdQYYzma7iNegv14e6QMilEYl28fkoNF2uNdRifdk7wkV1LTIXsBWDz6oPSR+9y6q8DODFsoNTmCW/Hv6uaUK5twtB//XpC6GIXQvDFzgieKUnFYqVnltwah+VBuGEF8pBX63AKXyRmBQDYUsgDBPKqlzhPDbf998v5n0XNgx8Fhy55mC39njo7iYHMsS5LLzZPsOeUhdxylNhezTA3ovYbSvdlsYqMux196xQFJPx8bbU= root@ADV-AZ-SRV01
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDE7x+8n8pd5IADfox5kS3KChhWsQbXjmBRrJCes+zDJfOtGtLBthu/oIKe7kMQRWmL4GwGNTw7bk6/qzfLGAtY9aujDziNz8dE5UprSKKOAT+NdVABQSEMUGP/VGegmS0sW9AOcS+xc55nZ6yd4IptknTUN/KVvbp1dbjddFrJRlRmDZScIpl6sE/PJvpfuaeMQeZPG8UW4OPQqIlDFYoNV3fb4powVi3DR4NaFJ7XyXXqIkDpL1yd6kKodHaqIRq5sES9o2Rjy2Ml1dPQFam7h1eMtZk/3/LSUUCHDmaLhRhhznUhj4FUwqcWkyhLMzxeKElIUqt1g7W5Znshl5OF6e20pALUlxSoqUU3OCWuahLhwM6qCBj/1zJBTwXEJTddHhG100XWhdgHRZzv/iMH9KzCZnpbZXcsBQnWyt76G5Q1Ago0FzlSJi3SPFXpoDWlh1uG3InvNIZpILg2j5zWSujkCuzzHeqJns1LpzPNw1aGtIm+mJnRIGE09tzZe9k= hurbybr@MAQUEN
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCelwm/MQfLfbFEgenth32D72dCswd7nNCDH9HfUuD6PQXu9cJbIZkyU+6zkVu+j001gp8ws1hdt+H58N2yvnApcNaJHdse+urrin+zKW7TFyyaURjYmd8nqwdoe5pdmcWOEtiSXdizTHUaXZqhMshPxwPs1KHVEZJd2ERopd+ebXEwkhrYbI1vZXoD59FRv51NvkI0QC4i/IchiDTSkOF7SmGz40RJE1sWhk83JvSHpr8GmQ1rOGgcPRE+WvHYH8YDKZV+e4WAzkpdj9Mo3cT9/X2qb9RJX+tbMvNbg4FkTSp/rQRvFCpAvcVr1MfYDQYcNbDuHprlT5XnLb/Toa8P hurby@MAQUEN
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDBxczQsEDiKQ6/COlSBFZyebgioSiOjT5QaIEzWTrpS6IpySbi3pfM3jKN7PUKo8EVTns4vDPw0N+AIYdfe3vyuFU85aQ8Vq0mBRqgIJsicDxOcUF4SpA0EaKgu8G7APb94jijeqkWTPeQPIlElbLJnEOlw4QDu+oPIQdkvq+KyZsNGECnHlwPWd1/74QEb9FeE63c5WEDa4NtqAf4WjbcEZd5GQhKNkDBXf+X4/qXo7sw6ymNF8AruB4EpyoEQsXODhdivAOB3nw1g2iUkBGNStSOy5fvHwGttQXxZfu/1xYMbAwQRQlZD8jsvqMr9LnmLOSnFlxZsYR7AdWzgk995DL1hVuQc/HykjoD8C1YQLEx1puPXtEq3Hh6gAWDh5aPqZIMmBwTftBgnhnqLlV/EdR0NscuaZTTWqQqz3hfSkyDA7e+jhqVWpQKIaOIyynS5sDNZmyTcvHRGnKVRRqm+w3VciKjfaPh1063T/2ONqB9ofcAxJPZRpFRsBCI/nM= hurby@MAQUEN
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDGgxIjRNIan6vPfB+HdspAHcOko+cRKTeXoLXFSjIES7H15bd+VSvHgIGRQ5Aw8jdbzTSFMmESj/YEb6kfoDUxPY4XvTZhT++p3KHtBY/DpbYKaZz3DDMqjODfmZoCvPXDPpO8bn8JagM5QOsG4Bn8BIU+7JwJ/G3z4tVfsuZWxsnDSvUv3QwdI+KksQ/AL8105pdMWVGIdPKjxbVMfZadvFV9qU+W88eFedxKHBD/qz/9DhRqA0jKVZ590bLhObGAQjtQy9vm7F+D6m1WE7WJLJ2BrAvzrRJJ8cGM5BIlDg8I+0ZSLxT9fcEL3ka2D8eAcSSZPEYgMgBUgUH9o7B45eH8+pUOowDoiJ9lXb/rKygMUkYRIj5AjaIOMLz2ZAbCaCDEYbTDFvr1Gdr+vLhtbqCS0ZEUvPXeQBq62Rtu9doaPVjNJ2mbSjrgcW+LA/gyoD2eKT9yvOgkgX+s7CEgp9jPo2oXPcLFD+h6cVEQOyXYVanpHBv3IZG8vOjxEeU= ealcay@MacBook-Air-Eduardo.local
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDJSUqvUO8kcSNjPkyoiMbu0ZSijZpM2kxvZKcGQrH9jHYC2cuUYSAHfU41FAtuCMXBgAqavViQm9WnwuqkrZYG5IKUy+mJRc8wgBDcTzxPSol4amTK0BYIJ8dHU6gFWDEw8t5hmvkltXBfzdtvdjFiSeE5kKHQR6rHd0ozM2kL2PFaVWKxsgcFi1DIGE9xwWg1/kyAmmI7y2Tbjd4f66MhiigAL/203/DWublXhFbUJc2sdi5XhnL23s4ZL3VYzivhSLBDiMrdPV25uuU0YWaiXUj7XqyFDBjF0rKVfRAX83n/sD9t44bYWqJ4cce4KmaHHGDn2Yd9DVfewYzpGkD92UXjvQkEcs6QJPrE3pIHTaIhMWIuZRMuK2lJIE/UtCU7oD8AAcnUyNRAdvFu0GPphzi252BHJPr8XvPZ/1ALxDlYAQBJgR243z5ORJURvLNcyE63oEjg4tIRShFgo5LIQ+oeTGszaqJRGJQfiGKwvlrxhPur+yCvqxgXJI3Vssc= suporte@adv-srv018
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDqiZA68XoTyOF1ryEiVnWcKKrwyoVjvsE08lrMFL6ME2r+w2hqnpxcGFdOZ9CK0nQTeMsY8ASnZp0iFMJMmjHvbxoD1rF1MgI1j0lBgqD4LsGhEsYHqAkCUEXOSOON7G0cPdE1bJYNI8XyXcFl4xTo6nfaL/xy5CQCDBpUvQvdx5fwTo/rVHgogYEOUBedLjOI4Rfi1we7JNS7Vpaml9GCMvWQjYJf81+vSoiKCsXCoti4zU7K+TOSZ1jn2QhlON6mYYt71xTfregsju+X5BYyXAdqTYBwfJ/m+ABoS5nHd/XQPzI1G/cFK+xadVvclGo0FtiTnzYQRl3+Oz/18CZNEuyjVfFqehsVIUC4qnLeMe4+6X+JYR43cvV/corq9hMCXxIPyoNzbhPELlmZFDF+aDLQoIswt5Vgjbic5Lkr/vqAkLIkY/KDs9x4//wMfDMqFhxWfzTwRtfIy7a/kPvBZIpjx20oKT52dnqcaSkcGIq1XtW2A5NX7KaRkY2vu1OOarr7MJ3n++sRAgnQSdQJPUFFyJ5+buvNwq8x72eh+zKWuce/vmaU6qBvHw90C5aCFGT+7/W3uA4MVWBJT237+vhfzBjFGJR+aGQTKITd/fIs5Bkd3QULKRXPz00N3MH3AI8lde+R7mwAFkGTFjfZ3mex7ts9lZrWdJbppD2WAQ== root@suporte
EOL

# Criar arquivo de configuração do Powerlevel10k
echo "⚙️ Criando configuração padrão do Powerlevel10k..."
cat <<EOL > ~/.p10k.zsh
# Minimalista: apenas usuário@host, diretório e prompt char
typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(context dir prompt_char)
typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=()

# Mostra usuário@hostname sempre
typeset -g POWERLEVEL9K_CONTEXT_TEMPLATE='%n@%m'
typeset -g POWERLEVEL9K_CONTEXT_FOREGROUND=7  # Branco
typeset -g POWERLEVEL9K_CONTEXT_ROOT_FOREGROUND=7
typeset -g POWERLEVEL9K_CONTEXT_REMOTE_FOREGROUND=7
typeset -g POWERLEVEL9K_CONTEXT_REMOTE_SUDO_FOREGROUND=7

# Mostra diretório atual, branco
typeset -g POWERLEVEL9K_DIR_FOREGROUND=7
typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=7
typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=7

# Remove ícones e encurtamentos no diretório
typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=80
typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=none

# Mostra ❯ para usuários comuns e # para root
typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION='%(!.#.❯)'
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_CONTENT_EXPANSION='%(!.#.❯)'
typeset -g POWERLEVEL9K_PROMPT_CHAR_FOREGROUND=7

# Sem espaços ou separadores adicionais
typeset -g POWERLEVEL9K_LEFT_PROMPT_FIRST_SEGMENT_START_SYMBOL=''
typeset -g POWERLEVEL9K_LEFT_PROMPT_LAST_SEGMENT_END_SYMBOL=''
typeset -g POWERLEVEL9K_RIGHT_PROMPT_FIRST_SEGMENT_START_SYMBOL=''
typeset -g POWERLEVEL9K_RIGHT_PROMPT_LAST_SEGMENT_END_SYMBOL=''
typeset -g POWERLEVEL9K_LEFT_SUBSEGMENT_SEPARATOR=''
typeset -g POWERLEVEL9K_RIGHT_SUBSEGMENT_SEPARATOR=''
typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_PREFIX=''
typeset -g POWERLEVEL9K_MULTILINE_LAST_PROMPT_PREFIX=''
typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=false

# Remove ícones no contexto
typeset -g POWERLEVEL9K_CONTEXT_VISUAL_IDENTIFIER_EXPANSION=''

# Deixa o fundo transparente
typeset -g POWERLEVEL9K_BACKGROUND=

# Desativa hot reload
typeset -g POWERLEVEL9K_DISABLE_HOT_RELOAD=true

# Finaliza carregamento
(( ! $+functions[p10k] )) || p10k reload
EOL

# Adicionar corretamente o PATH no Zsh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc

# Configurar Oh My Zsh corretamente
echo "🛠️ Configurando Oh My Zsh com plugins e tema Powerlevel10k..."
echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> ~/.zshrc
echo "[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh" >> ~/.zshrc

# Configurar plugins do Oh My Zsh, ajustando conforme a opção de Docker
if [ "$instalar_docker" = true ]; then
    echo "plugins=(git composer z zsh-autosuggestions zsh-syntax-highlighting docker docker-compose docker-machine jump sudo)" >> ~/.zshrc
else
    echo "plugins=(git composer z zsh-autosuggestions zsh-syntax-highlighting jump sudo)" >> ~/.zshrc
fi

echo "source ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" >> ~/.zshrc
echo "source ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" >> ~/.zshrc
echo "source ~/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme" >> ~/.zshrc

# Instalar iterm2
echo "💻 Instalando shell integration do iTerm2..."
curl -fsSL https://iterm2.com/shell_integration/install_shell_integration_and_utilities.sh | bash || echo "⚠️ Falha ao instalar shell integration do iTerm2, continuando..."

# Exibir banner da OutCore
if [ -f "$HOME/.oh-my-zsh/custom/outcore_banner.zsh" ]; then
    bash "$HOME/.oh-my-zsh/custom/outcore_banner.zsh" "Ambiente configurado com sucesso pela OutCore!" || true
fi

# Mensagem final para o usuário
echo -e "\n✅ Configuração concluída!"
if [ "$instalar_docker" = true ]; then
    echo -e "🐳 Docker foi instalado com sucesso!"
else
    echo -e "ℹ️ Docker não foi instalado conforme solicitado."
fi
echo -e "👉 Para aplicar as mudanças, execute:\n"
echo -e "   exec zsh\n"
