#!/usr/bin/env bash
# ==============================================================================
# OutCore IT Solutions - Custom Banner for Terminal & Oh My Zsh
# Colors based on official OutCore logo (https://www.outcore.com.br/static/images/logo.svg)
# #DA1F43 (Crimson Red) & #FFFFFF (White)
# ==============================================================================

# Detect color capabilities
setup_colors() {
    local has_truecolor=false
    case "${COLORTERM:-}" in
        truecolor|24bit) has_truecolor=true ;;
    esac
    case "${TERM:-}" in
        iterm*|tmux-truecolor*|linux-truecolor*|xterm-truecolor*|screen-truecolor*) has_truecolor=true ;;
    esac

    if [ "$has_truecolor" = true ]; then
        COLOR_RED=$'\033[38;2;218;31;67m'
        COLOR_WHITE=$'\033[38;2;255;255;255m'
        COLOR_GRAY=$'\033[38;2;160;160;160m'
    elif [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ] 2>/dev/null; then
        COLOR_RED=$'\033[38;5;197m'
        COLOR_WHITE=$'\033[38;5;231m'
        COLOR_GRAY=$'\033[38;5;244m'
    else
        COLOR_RED=$'\033[1;31m'
        COLOR_WHITE=$'\033[1;37m'
        COLOR_GRAY=$'\033[0;37m'
    fi

    COLOR_BOLD=$'\033[1m'
    COLOR_RESET=$'\033[0m'
}

# Function to print the OutCore logo banner
print_outcore_banner() {
    setup_colors
    local custom_msg="${1:-Hooray! Oh My Zsh has been updated!}"

    printf '\n'
    printf "%s   _..._         %s         __                              %s\n" \
        "$COLOR_RED" "$COLOR_WHITE" "$COLOR_RESET"
    printf "%s .' %s.-. %s'.       %s ____   __  __  / /_   %s_____  ____    _____  ___ %s\n" \
        "$COLOR_RED" "$COLOR_WHITE" "$COLOR_RED" "$COLOR_WHITE" "$COLOR_RED" "$COLOR_RESET"
    printf "%s/  %s/   \\%s  \\     %s/ __ \\ / / / / / __/  %s/ ___/ / __ \\  / ___/ / _ \\%s\n" \
        "$COLOR_RED" "$COLOR_WHITE" "$COLOR_RED" "$COLOR_WHITE" "$COLOR_RED" "$COLOR_RESET"
    printf "%s\\  %s\\___/%s  /    %s/ /_/ // /_/ / / /_   %s/ /__  / /_/ / / /    /  __/%s\n" \
        "$COLOR_RED" "$COLOR_WHITE" "$COLOR_RED" "$COLOR_WHITE" "$COLOR_RED" "$COLOR_RESET"
    printf "%s '. ___ .'     %s\\____/ \\__,_/  \\__/   %s\\___/  \\____/ /_/     \\___/ %s\n" \
        "$COLOR_RED" "$COLOR_WHITE" "$COLOR_RED" "$COLOR_RESET"
    printf '\n'

    if [ -n "$custom_msg" ]; then
        printf "%s%s%s%s\n\n" "$COLOR_BOLD" "$COLOR_WHITE" "$custom_msg" "$COLOR_RESET"
    fi

    printf "%sSoluções em TI: %s%shttps://www.outcore.com.br%s\n\n" \
        "$COLOR_GRAY" "$COLOR_BOLD" "$COLOR_RED" "$COLOR_RESET"
}

# Function to patch Oh My Zsh tools/upgrade.sh
patch_ohmyzsh() {
    local zsh_dir="${ZSH:-$HOME/.oh-my-zsh}"
    local upgrade_script="${zsh_dir}/tools/upgrade.sh"

    if [ ! -f "$upgrade_script" ]; then
        echo "⚠️ Arquivo ${upgrade_script} não encontrado. Certifique-se de que o Oh My Zsh está instalado."
        return 1
    fi

    # Check if already patched
    if grep -q "outcore_banner" "$upgrade_script" 2>/dev/null; then
        echo "ℹ️ O banner da OutCore já está aplicado em ${upgrade_script}."
        return 0
    fi

    echo "🎨 Aplicando logotipo da OutCore em ${upgrade_script}..."

    # Use Python3 if available for reliable multi-line replacement, or sed/awk fallback
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<EOF
import re

upgrade_path = "$upgrade_script"
try:
    with open(upgrade_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Pattern covering the default rainbow ASCII banner and links in Oh My Zsh upgrade.sh
    pattern = r'if \[\[ \\\$verbose_mode == default \]\]; then\s+printf \'%s\s+%s__.*?elif \[\[ \\\$verbose_mode == minimal \]\]; then'
    
    replacement = '''if [[ \\\$verbose_mode == default ]]; then
    if [ -f "\\\$ZSH/custom/outcore_banner.zsh" ]; then
      "\\\$ZSH/custom/outcore_banner.zsh" "\\\$message"
    elif [ -f "\\\$HOME/.oh-my-zsh/custom/outcore_banner.zsh" ]; then
      "\\\$HOME/.oh-my-zsh/custom/outcore_banner.zsh" "\\\$message"
    else
      printf "\\\${BLUE}%s\\\${RESET}\\\\n\\\\n" "\\\$message"
    fi
  elif [[ \\\$verbose_mode == minimal ]]; then'''

    new_content, count = re.subn(pattern, replacement, content, flags=re.DOTALL)
    if count > 0:
        with open(upgrade_path, "w", encoding="utf-8") as f:
            f.write(new_content)
        print("✅ Patch aplicado com sucesso via Python!")
    else:
        # Fallback simpler replacement if pattern didn't match
        alt_pattern = r'printf \'%s\s+%s__.*?printf "\${BLUE}%s\${RESET}\\n\\n" "\$message"'
        alt_replacement = '''if [ -f "\$ZSH/custom/outcore_banner.zsh" ]; then "\$ZSH/custom/outcore_banner.zsh" "\$message"; else printf "\${BLUE}%s\${RESET}\\n\\n" "\$message"; fi'''
        new_content, alt_count = re.subn(alt_pattern, alt_replacement, content, flags=re.DOTALL)
        if alt_count > 0:
            with open(upgrade_path, "w", encoding="utf-8") as f:
                f.write(new_content)
            print("✅ Patch alternativo aplicado com sucesso via Python!")
        else:
            print("⚠️ Padrão não encontrado para substituição automática.")
except Exception as e:
    print(f"⚠️ Erro ao aplicar patch: {e}")
EOF
    fi

    # Mark as assume-unchanged in git so git pull --rebase won't conflict
    if [ -d "${zsh_dir}/.git" ]; then
        git -C "${zsh_dir}" update-index --assume-unchanged tools/upgrade.sh 2>/dev/null || true
    fi

    echo "✅ Oh My Zsh configurado para exibir o banner da OutCore!"
}

# Alias / helper for sourcing
outcore_banner() {
    print_outcore_banner "$@"
}

# If executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${BASH_SOURCE[0]}" ]; then
    case "${1:-}" in
        --patch-omz|--patch|--install)
            patch_ohmyzsh
            ;;
        --help|-h)
            echo "Uso: $0 [MENSAGEM | --patch-omz | --help]"
            echo "Exibe o banner OutCore ou aplica o patch de atualização no Oh My Zsh."
            ;;
        *)
            print_outcore_banner "$@"
            ;;
    esac
else
    # When sourced as Oh My Zsh custom plugin/script (~/.oh-my-zsh/custom/outcore_banner.zsh)
    # Ensure upgrade.sh remains patched even after upstream git pulls
    if [ -n "${ZSH:-}" ] && [ -f "${ZSH}/tools/upgrade.sh" ]; then
        if ! grep -q "outcore_banner" "${ZSH}/tools/upgrade.sh" 2>/dev/null; then
            patch_ohmyzsh >/dev/null 2>&1 || true
        fi
    fi
fi
