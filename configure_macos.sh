#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "❌ Este script deve ser executado no macOS."
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "❌ Execute como usuário normal, não como root. O script solicitará sudo quando necessário."
    exit 1
fi

ask_yes_no() {
    local resposta
    while true; do
        read -r -p "$1 (s/n): " resposta
        case "$resposta" in
            [SsYy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Por favor, responda com 's' para sim ou 'n' para não." ;;
        esac
    done
}

install_homebrew() {
    if command -v brew >/dev/null 2>&1; then
        return
    fi

    echo "🍺 Homebrew não encontrado."
    if ! ask_yes_no "Deseja instalar o Homebrew"; then
        echo "❌ O Homebrew é necessário para instalar as dependências no macOS."
        exit 1
    fi

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

install_homebrew

BREW_PREFIX="$(brew --prefix)"
if [ -x "${BREW_PREFIX}/bin/brew" ]; then
    eval "$("${BREW_PREFIX}/bin/brew" shellenv)"
fi

echo "📦 Atualizando o Homebrew e instalando dependências..."
brew update
brew install ca-certificates curl python zsh coreutils gawk moreutils unzip git ruby btop pipx

echo "🌎 Configurando timezone para America/Sao_Paulo..."
if command -v systemsetup >/dev/null 2>&1; then
    sudo systemsetup -settimezone America/Sao_Paulo || \
        echo "⚠️ Não foi possível alterar o timezone automaticamente; ajuste-o nas Configurações do Sistema."
fi

instalar_docker=false
if ask_yes_no "Deseja instalar o Docker Desktop"; then
    instalar_docker=true
    echo "🐳 Instalando Docker Desktop..."
    brew install --cask docker
    open -a Docker
    echo "ℹ️ O Docker Desktop pode levar alguns instantes para iniciar e pode solicitar aprovação no macOS."
else
    echo "ℹ️ Docker Desktop não será instalado."
fi

echo "💻 Configurando Vim e Zsh..."
touch "$HOME/.vimrc"
if ! grep -Fqx 'set mouse-=a' "$HOME/.vimrc" 2>/dev/null; then
    printf '%s\n' 'set mouse-=a' >> "$HOME/.vimrc"
fi

if command -v zsh >/dev/null 2>&1; then
    chsh -s "$(command -v zsh)" "$(whoami)" 2>/dev/null || \
        echo "⚠️ Não foi possível definir o Zsh como shell padrão automaticamente."
fi

if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "⏳ Instalando Oh My Zsh..."
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
else
    echo "ℹ️ Oh My Zsh já está instalado."
fi

OMZ_CUSTOM="$HOME/.oh-my-zsh/custom"
mkdir -p "$OMZ_CUSTOM/plugins" "$OMZ_CUSTOM/themes"

clone_if_missing() {
    local repository="$1"
    local destination="$2"
    if [ ! -d "$destination" ]; then
        echo "📥 Instalando $(basename "$destination")..."
        git clone --depth=1 "$repository" "$destination"
    fi
}

clone_if_missing \
    https://github.com/romkatv/powerlevel10k.git \
    "$OMZ_CUSTOM/themes/powerlevel10k"
clone_if_missing \
    https://github.com/zsh-users/zsh-syntax-highlighting.git \
    "$OMZ_CUSTOM/plugins/zsh-syntax-highlighting"
clone_if_missing \
    https://github.com/zsh-users/zsh-autosuggestions.git \
    "$OMZ_CUSTOM/plugins/zsh-autosuggestions"

echo "🤦 Instalando TheFuck..."
pipx ensurepath || true
if ! command -v thefuck >/dev/null 2>&1; then
    pipx install thefuck || echo "⚠️ TheFuck não pôde ser instalado."
fi

echo "🌈 Instalando ColorLS..."
RUBY_PREFIX="$(brew --prefix ruby)"
export PATH="${RUBY_PREFIX}/bin:${BREW_PREFIX}/opt/coreutils/libexec/gnubin:${HOME}/.local/bin:${PATH}"
if ! command -v colorls >/dev/null 2>&1; then
    gem install colorls --user-install || echo "⚠️ ColorLS não pôde ser instalado."
fi

echo "🎨 Instalando banner da OutCore..."
BANNER_SOURCE="${SCRIPT_DIR}/outcore_banner.sh"
BANNER_TARGET="${OMZ_CUSTOM}/outcore_banner.sh"
if [ -f "$BANNER_SOURCE" ]; then
    cp "$BANNER_SOURCE" "$BANNER_TARGET"
elif [ ! -f "$BANNER_TARGET" ]; then
    curl -fsSL https://raw.githubusercontent.com/OutcoreIT/scripts/main/outcore_banner.sh \
        -o "$BANNER_TARGET" || echo "⚠️ Banner da OutCore não pôde ser baixado."
fi
if [ -f "$BANNER_TARGET" ]; then
    chmod +x "$BANNER_TARGET"
fi

P10K_FILE="$HOME/.p10k.zsh"
if [ ! -f "$P10K_FILE" ]; then
    cat > "$P10K_FILE" <<'EOF'
typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(context dir prompt_char)
typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=()
typeset -g POWERLEVEL9K_CONTEXT_TEMPLATE='%n@%m'
typeset -g POWERLEVEL9K_CONTEXT_FOREGROUND=7
typeset -g POWERLEVEL9K_CONTEXT_ROOT_FOREGROUND=7
typeset -g POWERLEVEL9K_CONTEXT_REMOTE_FOREGROUND=7
typeset -g POWERLEVEL9K_CONTEXT_REMOTE_SUDO_FOREGROUND=7
typeset -g POWERLEVEL9K_DIR_FOREGROUND=7
typeset -g POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=7
typeset -g POWERLEVEL9K_DIR_SHORTENED_FOREGROUND=7
typeset -g POWERLEVEL9K_DIR_MAX_LENGTH=80
typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=none
typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION='%(!.#.❯)'
typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_CONTENT_EXPANSION='%(!.#.❯)'
typeset -g POWERLEVEL9K_PROMPT_CHAR_FOREGROUND=7
typeset -g POWERLEVEL9K_LEFT_PROMPT_FIRST_SEGMENT_START_SYMBOL=''
typeset -g POWERLEVEL9K_LEFT_PROMPT_LAST_SEGMENT_END_SYMBOL=''
typeset -g POWERLEVEL9K_LEFT_SUBSEGMENT_SEPARATOR=''
typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=false
typeset -g POWERLEVEL9K_CONTEXT_VISUAL_IDENTIFIER_EXPANSION=''
typeset -g POWERLEVEL9K_BACKGROUND=
typeset -g POWERLEVEL9K_DISABLE_HOT_RELOAD=true
EOF
fi

ZSH_MARKER="# Configuração OutCore macOS"
if ! grep -Fqx "$ZSH_MARKER" "$HOME/.zshrc" 2>/dev/null; then
    plugins_line='plugins=(git z zsh-autosuggestions zsh-syntax-highlighting sudo)'
    if [ "$instalar_docker" = true ]; then
        plugins_line='plugins=(git z zsh-autosuggestions zsh-syntax-highlighting docker docker-compose sudo)'
    fi
    {
        printf '\n%s\n' "$ZSH_MARKER"
        printf '%s\n' "export PATH=\"\$HOME/.local/bin:${BREW_PREFIX}/opt/coreutils/libexec/gnubin:\$PATH\""
        printf 'ZSH_THEME="powerlevel10k/powerlevel10k"\n'
        printf '%s\n' "$plugins_line"
        printf '%s\n' "[[ -f \"\$HOME/.p10k.zsh\" ]] && source \"\$HOME/.p10k.zsh\""
        printf '[[ -f "%s/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] && source "%s/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"\n' "$OMZ_CUSTOM" "$OMZ_CUSTOM"
        printf '[[ -f "%s/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] && source "%s/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"\n' "$OMZ_CUSTOM" "$OMZ_CUSTOM"
        if [ -f "$BANNER_TARGET" ]; then
            printf '[[ -x "%s" ]] && bash "%s" "Ambiente configurado com sucesso pela OutCore!"\n' "$BANNER_TARGET" "$BANNER_TARGET"
        fi
    } >> "$HOME/.zshrc"
fi

echo "💻 Instalando shell integration do iTerm2..."
curl -fsSL https://iterm2.com/shell_integration/install_shell_integration_and_utilities.sh | bash || \
    echo "⚠️ Shell integration do iTerm2 não pôde ser instalada."

echo
echo "✅ Configuração do macOS concluída!"
if [ "$instalar_docker" = true ]; then
    echo "🐳 Docker Desktop foi instalado e está sendo iniciado."
fi
echo "👉 Para aplicar as alterações do Zsh nesta sessão, execute: exec zsh"
