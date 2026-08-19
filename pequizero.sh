#!/bin/bash
#
# pequizero.sh — sobe projetos/módulos Spring Boot (Maven) em uma sessão tmux.
#
# Uso:
#   ./pequizero.sh        menu interativo de seleção/ordem
#   ./pequizero.sh -h     ajuda
#

# Guarda de versão antes de qualquer sintaxe de bash 4 (declare -A, mapfile,
# ${var,,}): sem isso, o bash 3.2 do macOS falha com 'bad substitution' solto.
# O piso é 4.4, não 4.0: até 4.3, expandir array VAZIO com "${arr[@]}" sob
# 'set -u' aborta o script — e é o que acontece em toda janela tmux de serviço
# sem variáveis nos jvm_args.
if [ -z "${BASH_VERSINFO:-}" ] \
   || [ "${BASH_VERSINFO[0]}" -lt 4 ] \
   || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "pequizero: requer bash 4.4+ (encontrado: ${BASH_VERSION:-desconhecido})." >&2
  echo "           macOS: 'brew install bash' e rode com o bash do Homebrew." >&2
  exit 1
fi

set -uo pipefail

VERSION="1.0.0"
REPO="RenanOfugi/pequizero"
RELEASE_URL="https://github.com/$REPO/releases/latest/download/pequizero.sh"

SESSION="apis"
# Timeout aguardando o startup de cada serviço; pode ser sobrescrito definindo
# TIMEOUT_SECONDS=<segundos> no services.local.conf.
TIMEOUT_SECONDS=300

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Padrão: config ao lado do script (instalação via clone). resolve_conf_dir()
# redireciona para o XDG quando o script foi instalado solto no PATH — chamada
# em main(), nunca no source, para os testes não criarem diretório nenhum.
CONF_DIR="$SCRIPT_DIR"
CONF_FILE="$CONF_DIR/services.conf"
LOCAL_CONF="$CONF_DIR/services.local.conf"
GROUPS_FILE="$CONF_DIR/groups.conf"

# Instalação "de repositório": o script está na própria árvore do projeto
# (clone ou tarball extraído), não copiado solto para um diretório do PATH.
# README.md sozinho não serve como pista — um '~/bin' qualquer pode ter um;
# junto do 'tests/' o par só aparece na árvore do projeto.
is_repo_install() {
  [ -d "$SCRIPT_DIR/.git" ] \
    || { [ -f "$SCRIPT_DIR/README.md" ] && [ -d "$SCRIPT_DIR/tests" ]; }
}

# Decide onde ficam os .conf. Mantém o diretório do script quando é clone ou
# quando já existe config lá (instalação antiga, anterior ao XDG) — assim
# ninguém tem a config movida embaixo dos pés ao atualizar.
resolve_conf_dir() {
  if [ -w "$SCRIPT_DIR" ] \
     && { is_repo_install || [ -f "$CONF_FILE" ] || [ -f "$LOCAL_CONF" ]; }; then
    return 0
  fi

  CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pequizero"
  CONF_FILE="$CONF_DIR/services.conf"
  LOCAL_CONF="$CONF_DIR/services.local.conf"
  GROUPS_FILE="$CONF_DIR/groups.conf"
}

# Cria o CONF_DIR só quando alguém vai gravar — '--help' e '--version' não
# devem deixar rastro no disco.
ensure_conf_dir() {
  [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR" || die "falha ao criar '$CONF_DIR'."
}

# S_PATH = caminho absoluto do projeto (usado no 'cd'); S_PROJ = nome curto.
S_NAME=() S_PATH=() S_PROJ=() S_MOD=() S_BUILD=() S_PROFILE=() S_JVM=() S_WAIT=()

# Grupos: G_NAME[i] = nome; G_ITEMS[i] = nomes das APIs separados por '|',
# na ordem de subida.
G_NAME=() G_ITEMS=()

WORKSPACE_HISTORY=()

# Variáveis que jvm_args pode referenciar; preenchido por load_local_conf.
LOCAL_VARS=()

# Cores ANSI — só em terminal e quando NO_COLOR não está definido.
C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_DIM=''
setup_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'   C_BOLD=$'\033[1m'    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'    C_GREEN=$'\033[32m'  C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
  fi
}
setup_colors

die()  { echo "${C_RED}ERRO:${C_RESET} $*" >&2; exit 1; }
warn() { echo "${C_YELLOW}AVISO:${C_RESET} $*" >&2; }
info() { echo "$*"; }
success() { echo "${C_GREEN}✓${C_RESET} $*"; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

clear_screen() {
  [ -t 1 ] && clear
  return 0
}

# Versão para as funções de seleção que rodam em $( ): stdout está capturado
# (só o resultado pode ir nele), então o clear sai pelo stderr.
clear_screen_err() {
  [ -t 2 ] && clear >&2
  return 0
}

pause() {
  [ -t 0 ] || return 0
  echo ""
  read -rp "Pressione Enter para continuar... " _
}

usage() {
  cat <<EOF
Uso: $(basename "$0") [opções]

  Sobe os serviços definidos em services.conf numa sessão tmux ('$SESSION').

  Sem argumentos: abre o menu interativo (seleção, ordem, editor).

Opções:
  -h, --help      Mostra esta ajuda.
  -v, --version   Mostra a versão ($VERSION).
  --update        Baixa a última release por cima deste script (não afeta a
                  config). Em instalação via clone, use 'git pull'.
  --reconfigure   Refaz a pergunta do caminho da pasta e regrava a escolha.

Variáveis de ambiente:
  SKIP_CLEAN=1    Build incremental ('mvn install', sem 'clean') — mais rápido
                  quando você só mexeu no corpo de métodos. Padrão:
                  'mvn clean install' (recompila do zero).

Arquivos (em $CONF_DIR):
  services.conf         Definição dos serviços.
  groups.conf           Grupos de APIs (seleção + ordem fixa), opção [G].
  services.local.conf   BASE_DIR, TIMEOUT_SECONDS e variáveis dos jvm_args
                        (criado na 1ª execução).

  Instalação via clone mantém os .conf ao lado do script; instalado no PATH,
  eles vão para \$XDG_CONFIG_HOME/pequizero (padrão: ~/.config/pequizero).

Grupos de APIs:
  No menu, [G] cria/edita/remove grupos: um grupo é uma seleção de APIs com
  ordem fixa. Para subir, digite 'gN' (ex.: 'g1') no lugar dos números — e dá
  para misturar: 'g1 7 2' sobe o grupo 1 e depois o 7º e o 2º serviço.
  Na confirmação da ordem, [g] grava a seleção que você acabou de digitar.

Sessão existente:
  Se a sessão tmux '$SESSION' já estiver aberta, dá para subir/reiniciar só os
  serviços selecionados nela ([u]), recriar tudo ([r]) ou apenas anexar ([a]).
EOF
}

check_prereqs() {
  local missing=()
  command -v tmux >/dev/null 2>&1 || missing+=("tmux")
  command -v mvn  >/dev/null 2>&1 || missing+=("maven (mvn)")
  command -v java >/dev/null 2>&1 || missing+=("java")
  if [ ${#missing[@]} -gt 0 ]; then
    die "dependências ausentes: ${missing[*]}. Instale-as antes de continuar."
  fi
}

# As funções de seleção abaixo rodam em $( ): interação vai para stderr (>&2),
# só o caminho escolhido é ecoado em stdout.

WORKSPACE_HISTORY_MAX=8

# Adiciona um caminho ao topo do histórico (sem duplicar) e persiste no conf.
remember_workspace() {
  local path="$1" h=() p
  h+=("$path")
  for p in "${WORKSPACE_HISTORY[@]:-}"; do
    [ -z "$p" ] && continue
    [ "$p" = "$path" ] && continue
    h+=("$p")
    [ "${#h[@]}" -ge "$WORKSPACE_HISTORY_MAX" ] && break
  done
  WORKSPACE_HISTORY=("${h[@]}")

  [ -f "$LOCAL_CONF" ] || return 0
  local tmp="$LOCAL_CONF.tmp.$$" line
  umask 077
  {
    grep -v '^WORKSPACE_HISTORY=' "$LOCAL_CONF"
    printf 'WORKSPACE_HISTORY=('
    for p in "${WORKSPACE_HISTORY[@]}"; do printf '%q ' "$p"; done
    printf ')\n'
  } > "$tmp" && mv "$tmp" "$LOCAL_CONF" || { rm -f "$tmp"; warn "não consegui salvar o histórico de workspaces."; }
}

# Navegador de pastas: número entra, '..' sobe, '.' seleciona, 'q' cancela.
# A cada nível a tela é limpa; erros vão em $msg para sobreviver ao redesenho.
browse_dir() {
  local cur="${1:-$PWD}"
  cur="$(cd "$cur" 2>/dev/null && pwd)" || cur="$HOME"
  local subs sel i d msg=""
  while true; do
    # Glob em vez de 'find -printf': o -printf é extensão GNU (busybox e toybox
    # não têm) e falhava calado, deixando o navegador vazio no Alpine. O glob
    # já vem ordenado e ignora oculto sem precisar de filtro.
    subs=()
    for d in "$cur"/*/; do
      [ -d "$d" ] || continue          # glob sem correspondência
      d="${d%/}"
      subs+=("${d##*/}")
    done

    clear_screen_err
    {
      echo ""
      echo "${C_CYAN}${C_BOLD}Navegando:${C_RESET} $cur"
      echo "  ${C_DIM}[.]${C_RESET} selecionar esta pasta   ${C_DIM}[..]${C_RESET} subir   ${C_DIM}[q]${C_RESET} cancelar"
      echo ""
      if [ "${#subs[@]}" -eq 0 ]; then
        echo "  ${C_DIM}(sem subpastas)${C_RESET}"
      else
        for i in "${!subs[@]}"; do
          printf "  ${C_DIM}[%d]${C_RESET} %s/\n" "$((i+1))" "${subs[$i]}"
        done
      fi
      [ -n "$msg" ] && echo "" && echo "  ${C_YELLOW}$msg${C_RESET}"
      echo ""
    } >&2
    msg=""

    read -erp "  > " sel >&2
    case "$sel" in
      q|Q) return 1 ;;
      .)   echo "$cur"; return 0 ;;
      ..)  cur="$(cd "$cur/.." && pwd)" ;;
      ''|*[!0-9]*) msg="Opção inválida." ;;
      *)
        if [ "$sel" -ge 1 ] && [ "$sel" -le "${#subs[@]}" ]; then
          cur="$cur/${subs[$((sel-1))]}"
        else
          msg="Número fora da lista."
        fi ;;
    esac
  done
}

# Seletor unificado de pasta: histórico recente, navegador, ou digitar à mão
# (com autocompletar via Tab). Ecoa o caminho absoluto escolhido; retorna 1 se
# cancelado.
pick_dir() {
  local suggested base i first=1 msg=""
  # No clone, a pasta irmã do repositório costuma ser o workspace. Instalado no
  # PATH, 'dirname' daria '~/.local/bin' — sugere o diretório atual em vez disso.
  if is_repo_install; then
    suggested="$(dirname "$SCRIPT_DIR")"
  else
    suggested="$PWD"
  fi

  while true; do
    # Não limpa na 1ª exibição para manter o cabeçalho de quem chamou.
    if [ "$first" -eq 1 ]; then first=0; else clear_screen_err; fi
    {
      echo ""
      echo "Escolha a pasta para escanear:"
      # histórico recente
      if [ "${#WORKSPACE_HISTORY[@]}" -gt 0 ]; then
        for i in "${!WORKSPACE_HISTORY[@]}"; do
          printf "  ${C_DIM}[%d]${C_RESET} %s\n" "$((i+1))" "${WORKSPACE_HISTORY[$i]}"
        done
      fi
      echo "  ${C_DIM}[b]${C_RESET} navegar pelas pastas"
      echo "  ${C_DIM}[d]${C_RESET} digitar o caminho (Tab completa)"
      echo "  ${C_DIM}[q]${C_RESET} cancelar"
      echo "  ${C_DIM}(Enter usa: $suggested)${C_RESET}"
      [ -n "$msg" ] && echo "" && echo "  ${C_YELLOW}$msg${C_RESET}"
      echo ""
    } >&2
    msg=""

    local choice
    read -erp "  > " choice >&2

    case "$choice" in
      q|Q) return 1 ;;
      '')  base="$suggested" ;;
      b|B) base="$(browse_dir "${WORKSPACE_HISTORY[0]:-$suggested}")" || continue ;;
      d|D)
        read -erp "  Caminho: " base >&2   # -e: autocompletar com Tab
        base="${base/#\~/$HOME}"
        ;;
      *[!0-9]*) msg="Opção inválida."; continue ;;
      *)
        if [ "$choice" -ge 1 ] && [ "$choice" -le "${#WORKSPACE_HISTORY[@]}" ]; then
          base="${WORKSPACE_HISTORY[$((choice-1))]}"
        else
          msg="Número fora da lista."; continue
        fi ;;
    esac

    [ -z "$base" ] && continue
    base="${base/#\~/$HOME}"
    if [ -d "$base" ]; then
      echo "$(cd "$base" && pwd)"
      return 0
    fi
    msg="'$base' não existe. Tente de novo."
  done
}

prompt_base_dir() { pick_dir; }

write_local_conf() {
  local base="$1"
  ensure_conf_dir
  umask 077
  cat > "$LOCAL_CONF" <<EOF || die "falha ao gravar '$LOCAL_CONF'."
BASE_DIR="$base"

# Timeout (segundos) aguardando o startup de cada serviço. Padrão: 300.
# TIMEOUT_SECONDS=300

# Variáveis usadas pelos jvm_args do services.conf, no formato NOME="valor".
EOF
}

# Cria um services.conf zerado (só cabeçalho) se ainda não existir.
bootstrap_services_conf() {
  [ -f "$CONF_FILE" ] && return 0
  ensure_conf_dir
  cat > "$CONF_FILE" <<'EOF' || die "falha ao criar '$CONF_FILE'."
# =============================================================================
# services.conf — definição dos serviços
# =============================================================================
# Registre serviços pela opção [N] do menu ou adicione linhas aqui à mão.
#
# Uma linha por serviço. Linhas em branco e iniciadas com '#' são ignoradas.
#
# Formato (8 campos separados por '|'):
#   nome | path | projeto | modulo | build_modules | profile | jvm_args | wait
#
#   nome           Nome exibido no menu e na janela tmux.
#   path           Caminho ABSOLUTO do projeto (onde roda o 'cd').
#   projeto        Nome curto do projeto (rótulos e detecção de duplicados).
#   modulo         Módulo do 'spring-boot:run' (vira '-pl <modulo>'). Vazio = raiz.
#   build_modules  Módulos do 'mvn install' (vira '-pl ...'). Vazio = projeto todo.
#   profile        Spring profile (-Dspring-boot.run.profiles=...). Vazio = nenhum.
#   jvm_args       Args JVM. Pode referenciar variáveis do services.local.conf
#                  (ex.: -Dtoken=$API_TOKEN); o valor entra via env da janela tmux.
#   wait           true/false — aguardar o startup antes do próximo serviço.
# =============================================================================
EOF
}

bootstrap_local_conf() {
  [ -f "$LOCAL_CONF" ] && return 0

  clear_screen
  echo "${C_CYAN}${C_BOLD}========================================${C_RESET}"
  echo "${C_CYAN}${C_BOLD}  Primeira execução — configuração local${C_RESET}"
  echo "${C_CYAN}${C_BOLD}========================================${C_RESET}"
  echo ""
  echo "Não encontrei '$LOCAL_CONF'. Vou criá-lo com o caminho da pasta raiz."
  echo ""

  local base
  base="$(prompt_base_dir)" || { echo "Cancelado."; exit 0; }
  write_local_conf "$base"

  echo ""
  success "'$LOCAL_CONF' criado com BASE_DIR=\"$base\"."
  echo "   Se algum serviço usar variáveis nos jvm_args, adicione-as nesse arquivo."
  echo ""
}

# Grava o novo BASE_DIR no services.local.conf, preservando as demais variáveis.
persist_base_dir() {
  local base="$1"
  if [ -f "$LOCAL_CONF" ]; then
    local tmp="$LOCAL_CONF.tmp.$$"
    umask 077
    if grep -q '^BASE_DIR=' "$LOCAL_CONF"; then
      sed "s#^BASE_DIR=.*#BASE_DIR=\"$base\"#" "$LOCAL_CONF" > "$tmp" \
        && mv "$tmp" "$LOCAL_CONF" || { rm -f "$tmp"; die "falha ao gravar '$LOCAL_CONF'."; }
    else
      { echo "BASE_DIR=\"$base\""; cat "$LOCAL_CONF"; } > "$tmp" \
        && mv "$tmp" "$LOCAL_CONF" || { rm -f "$tmp"; die "falha ao gravar '$LOCAL_CONF'."; }
    fi
  else
    write_local_conf "$base"
  fi
  BASE_DIR="$base"
  remember_workspace "$base"
}

# --reconfigure: refaz a pergunta do caminho e regrava.
reconfigure_base_dir() {
  echo "Reconfigurar a pasta de projetos para o scan."
  [ -f "$LOCAL_CONF" ] && echo "Atual: ${BASE_DIR:-<não definido>}"
  echo ""
  local base
  base="$(prompt_base_dir)" || { echo "Cancelado. Nada alterado."; exit 0; }
  persist_base_dir "$base"
  echo ""
  success "Pasta de scan atualizada para \"$base\"."
}

# [W] no menu: troca a pasta de scan, persiste e reescaneia. Não mexe nos
# serviços já registrados nem encerra ao cancelar.
change_workspace() {
  clear_screen
  echo "${C_CYAN}${C_BOLD}--- Trocar workspace (pasta de scan) ---${C_RESET}"
  echo "Atual: ${BASE_DIR}"
  echo "Os serviços já registrados são preservados (cada um guarda seu caminho)."
  echo ""
  local base
  if ! base="$(prompt_base_dir)"; then
    echo "Cancelado — nada alterado."
    return 0
  fi
  persist_base_dir "$base"
  refresh_scan_count
  echo ""
  success "Workspace agora é \"$base\" ($SCAN_COUNT módulo(s) novo(s) detectado(s))."
}

load_local_conf() {
  # shellcheck source=/dev/null
  # shellcheck source=/dev/null
  source "$LOCAL_CONF" || die "falha ao ler '$LOCAL_CONF'."
  [ -n "${BASE_DIR:-}" ] || die "BASE_DIR não definido em '$LOCAL_CONF'."
  if [ ! -d "$BASE_DIR" ]; then
    die "BASE_DIR '$BASE_DIR' não existe. Edite '$LOCAL_CONF'."
  fi

  if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
    warn "TIMEOUT_SECONDS='$TIMEOUT_SECONDS' inválido em '$LOCAL_CONF' — usando 300."
    TIMEOUT_SECONDS=300
  fi

  # Nomes das variáveis definidas no conf que jvm_args pode usar (exceto as
  # de configuração do próprio script).
  LOCAL_VARS=()
  local name
  while IFS= read -r name; do
    case "$name" in BASE_DIR|TIMEOUT_SECONDS|WORKSPACE_HISTORY) continue ;; esac
    LOCAL_VARS+=("$name")
  done < <(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$LOCAL_CONF" \
             | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/')
}

# Carrega os serviços do services.conf. Aceita o formato de 8 campos
# (nome|path|projeto|modulo|build_modules|profile|jvm_args|wait) e migra o
# formato antigo de 7 campos (sem path) reconstruindo path = $BASE_DIR/$projeto.
load_services() {
  bootstrap_services_conf

  S_NAME=() S_PATH=() S_PROJ=() S_MOD=() S_BUILD=() S_PROFILE=() S_JVM=() S_WAIT=()
  local line name path proj mod build profile jvm wait lineno=0 nfields migrated=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue

    local seps="${line//[^|]/}"
    nfields=$(( ${#seps} + 1 ))

    if [ "$nfields" -eq 8 ]; then
      IFS='|' read -r name path proj mod build profile jvm wait <<< "$line"
    elif [ "$nfields" -eq 7 ]; then
      IFS='|' read -r name proj mod build profile jvm wait <<< "$line"
      path="${BASE_DIR:-}/$(trim "$proj")"
      migrated=1
    else
      die "$CONF_FILE: linha $lineno tem $nfields campos (esperado 7 ou 8): $line"
    fi

    name="$(trim "$name")"; path="$(trim "$path")"
    proj="$(trim "$proj")"; wait="$(trim "$wait")"
    [ -z "$name" ] && continue

    wait="${wait:-false}"
    if [[ "$wait" != "true" && "$wait" != "false" ]]; then
      warn "$CONF_FILE: linha $lineno — wait='$wait' inválido (use true/false). Assumindo false."
      wait="false"
    fi

    S_NAME+=("$name"); S_PATH+=("$path"); S_PROJ+=("$proj"); S_MOD+=("$mod")
    S_BUILD+=("$build"); S_PROFILE+=("$profile"); S_JVM+=("$jvm")
    S_WAIT+=("$wait")
  done < "$CONF_FILE"

  # Conf vazio não é erro fatal: o usuário pode adicionar serviços com [N].
  if [ ${#S_NAME[@]} -eq 0 ]; then
    warn "nenhum serviço em '$CONF_FILE' — use [N] para adicionar."
  fi

  if [ "$migrated" -eq 1 ]; then
    save_services
    info "services.conf migrado para o novo formato (com caminho por serviço)."
  fi
}

# Versão do tmux como número comparável: '3.2a' -> 302, 'next-3.4' -> 304,
# '1.8' -> 108. Devolve 0 quando não consegue determinar (não bloqueia nada).
tmux_version_code() {
  local v maj min
  v="$(tmux -V 2>/dev/null)" || { echo 0; return 0; }
  v="${v##* }"        # 'tmux 3.2a' -> '3.2a'
  v="${v#next-}"      # 'next-3.4'  -> '3.4'
  maj="${v%%.*}"; maj="${maj//[^0-9]/}"
  min="${v#*.}";  min="${min//[^0-9]/}"
  if [ -z "$maj" ] || [ -z "$min" ]; then echo 0; return 0; fi
  echo $(( maj * 100 + min ))
}

# Monta o comando (install + run) de um serviço pelo índice.
build_command() {
  local i="$1"
  local dir="${S_PATH[$i]}"
  local mod="${S_MOD[$i]}" build="${S_BUILD[$i]}"
  local profile="${S_PROFILE[$i]}" jvm="${S_JVM[$i]}"

  # Padrão: 'clean install' — não reaproveita target/ velho, então renomear ou
  # remover classes/contratos entre módulos não deixa artefato antigo para trás.
  # SKIP_CLEAN=1 volta ao build incremental (mais rápido no dia a dia).
  local goals="clean install"
  [ -n "${SKIP_CLEAN:-}" ] && goals="install"

  local install="mvn $goals -DskipTests"
  if [ -n "${build// /}" ]; then
    install="mvn -pl ${build// /} -am $goals -DskipTests"
  elif [ -n "${mod// /}" ]; then
    install="mvn -pl ${mod// /} -am $goals -DskipTests"
  fi

  local run="mvn"
  [ -n "${mod// /}" ] && run="$run -pl ${mod// /}"
  run="$run spring-boot:run"
  [ -n "${profile// /}" ] && run="$run -Dspring-boot.run.profiles=${profile// /}"
  if [ -n "${jvm// /}" ]; then
    # $VAR fica literal; o shell da janela tmux expande com o env injetado
    # por service_env_flags (sem eval, sem expor valores no comando).
    local jvm_trimmed; jvm_trimmed="$(trim "$jvm")"
    run="$run -Dspring-boot.run.jvmArguments=\"$jvm_trimmed\""
  fi

  echo "cd \"$dir\" && $install && $run"
}

# Para cada variável de LOCAL_VARS referenciada no jvm_args do serviço, ecoa
# os flags '-e NOME=valor' para 'tmux new-window -e' (valor só no env da janela).
service_env_flags() {
  local i="$1"
  local jvm="${S_JVM[$i]}"
  [ -n "${jvm// /}" ] || return 0

  local var val
  for var in "${LOCAL_VARS[@]:-}"; do
    [ -z "$var" ] && continue
    if [[ "$jvm" == *"\$$var"* || "$jvm" == *"\${$var}"* ]]; then
      val="${!var:-}"
      printf -- '-e\n%s=%s\n' "$var" "$val"
    fi
  done
}

# Avisa sobre variáveis referenciadas nos jvm_args que não estão no conf local
# (expandiriam para vazio na janela tmux).
warn_undefined_vars() {
  local defined=" ${LOCAL_VARS[*]:-} "
  local i tok
  for i in "${!S_JVM[@]}"; do
    [ -n "${S_JVM[$i]// /}" ] || continue
    for tok in $(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' <<< "${S_JVM[$i]}" \
                  | tr -d '${}' | sort -u); do
      [[ "$defined" == *" $tok "* ]] && continue
      warn "serviço '${S_NAME[$i]}': \$$tok não está em services.local.conf (expandirá vazio)."
    done
  done
}

# Colapsa barras repetidas e tira a barra final (preserva a raiz '/').
squeeze_slashes() {
  local p="$1"
  while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
  [ "${#p}" -gt 1 ] && p="${p%/}"
  printf '%s' "$p"
}

# Chave canônica de um serviço (path + módulo), usada para detectar que um
# módulo do workspace já está no services.conf. Normaliza para que a mesma
# pasta escrita de formas diferentes — barra final, barras duplicadas, '~',
# './', '..' ou symlink — produza a mesma chave.
service_key() {
  local path="$1" mod="$2" real
  path="${path/#\~/$HOME}"
  if [ -d "$path" ] && real="$(cd -P -- "$path" 2>/dev/null && pwd -P)"; then
    path="$real"
  fi
  path="$(squeeze_slashes "$path")"

  mod="$(squeeze_slashes "${mod// /}")"
  mod="${mod#/}"
  [ "$mod" = "." ] && mod=""

  printf '%s/%s' "$path" "$mod"
}

# Escaneia BASE_DIR e preenche SCAN_PATH/SCAN_PROJ/SCAN_MOD com os módulos
# executáveis (spring-boot-maven-plugin, packaging != pom) ainda não cadastrados.
# SCAN_MOD vazio = módulo na raiz do projeto.
SCAN_PATH=() SCAN_PROJ=() SCAN_MOD=()
scan_executable_modules() {
  SCAN_PATH=() SCAN_PROJ=() SCAN_MOD=()

  local i
  declare -A configured=()
  for i in "${!S_NAME[@]}"; do
    configured["$(service_key "${S_PATH[$i]}" "${S_MOD[$i]}")"]=1
  done
  declare -A seen_keys=()

  local d proj p moddir mod pack
  for d in "$BASE_DIR"/*/; do
    proj="$(basename "$d")"
    [ -f "$d/pom.xml" ] || continue

    while IFS= read -r p; do
      grep -q "spring-boot-maven-plugin" "$p" 2>/dev/null || continue
      pack="$(sed -n 's@.*<packaging>\([^<]*\)</packaging>.*@\1@p' "$p" | head -1)"
      [ "${pack:-jar}" = "pom" ] && continue   # ignora parents/agregadores

      moddir="$(dirname "$p")"
      if [ "$moddir" = "${d%/}" ]; then
        mod=""                       # módulo na raiz do projeto -> sem -pl
      else
        mod="${moddir#"${d%/}"/}"    # caminho relativo à raiz do projeto (vira o -pl)
      fi

      local projpath="${d%/}" key
      key="$(service_key "$projpath" "$mod")"
      [ -n "${configured["$key"]:-}" ] && continue
      [ -n "${seen_keys["$key"]:-}" ] && continue
      seen_keys["$key"]=1
      SCAN_PATH+=("$projpath"); SCAN_PROJ+=("$proj"); SCAN_MOD+=("$mod")
    done < <(find "$d" -maxdepth 4 \
               \( -name target -o -name src -o -name node_modules -o -name '.*' \) -prune \
               -o -name pom.xml -print 2>/dev/null | sort)
  done
}

# Conta de módulos novos detectados, exibida no menu.
SCAN_COUNT=0
refresh_scan_count() {
  scan_executable_modules
  SCAN_COUNT=${#SCAN_PROJ[@]}
}

wait_for_startup() {
  local name="$1" elapsed=0 output
  echo "${C_DIM}Aguardando '$name' inicializar...${C_RESET}"
  while [ $elapsed -lt $TIMEOUT_SECONDS ]; do
    output="$(tmux capture-pane -t "$SESSION:=$name" -p -S - 2>/dev/null)"

    if echo "$output" | grep -qE "(Started .+ in .+ seconds|Tomcat started on port|Application availability state .+ changed to ACCEPTING_TRAFFIC)"; then
      success "'${C_BOLD}$name${C_RESET}' iniciou com sucesso!"
      return 0
    fi
    if echo "$output" | grep -qE "(BUILD FAILURE|Application run failed|Failed to start|APPLICATION FAILED TO START)"; then
      echo "${C_RED}✗ '$name' falhou ao iniciar!${C_RESET} (veja a janela '$name' na sessão tmux)" >&2
      return 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  warn "timeout aguardando '$name' (${TIMEOUT_SECONDS}s). Continuando..."
  return 1
}

# Sobe um serviço: cria a sessão se ainda não existir; se já houver uma janela
# com o mesmo nome (serviço rodando/parado), mata e recria — vale como restart.
start_service() {
  local i="$1"
  local name="${S_NAME[$i]}"
  local dir="${S_PATH[$i]}"
  local cmd; cmd="$(build_command "$i")"

  if [ ! -d "$dir" ]; then
    warn "diretório '$dir' não existe — pulando '$name'."
    return 1
  fi

  local env_flags=()
  mapfile -t env_flags < <(service_env_flags "$i")

  local new_session=0
  tmux has-session -t "$SESSION" 2>/dev/null || new_session=1

  # O '-e' (variáveis no ambiente da janela) chegou ao tmux em versões
  # diferentes: new-window em 3.0, new-session só em 3.2. Sem variáveis nos
  # jvm_args o flag nem aparece, e tmux 2.x serve — então só cobra quando
  # este serviço realmente injeta algo.
  if [ "${#env_flags[@]}" -gt 0 ]; then
    local need=300 need_label="3.0" vcode
    if [ "$new_session" -eq 1 ]; then need=302; need_label="3.2"; fi
    vcode="$(tmux_version_code)"
    # vcode=0 é 'não sei dizer' (fork exótico): não bloqueia, deixa o tmux falar.
    if [ "$vcode" -gt 0 ] && [ "$vcode" -lt "$need" ]; then
      warn "'$name' injeta variáveis dos jvm_args e isso exige tmux $need_label+ (você tem $(tmux -V 2>/dev/null || echo '?'))."
      warn "  opções: atualizar o tmux, ou tirar as variáveis do jvm_args deste serviço."
      return 1
    fi
  fi

  if [ "$new_session" -eq 1 ]; then
    tmux new-session -d -s "$SESSION" -n "$name" "${env_flags[@]}" \
      || die "falha ao criar a sessão tmux '$SESSION'."
  else
    # Se o serviço já tem janela, cria a nova ANTES de matar a antiga (matar
    # primeiro derrubaria a sessão quando ela fosse a única janela).
    local line old_id=""
    while IFS= read -r line; do
      if [ "${line#* }" = "$name" ]; then old_id="${line%% *}"; break; fi
    done < <(tmux list-windows -t "$SESSION" -F '#{window_id} #{window_name}' 2>/dev/null)
    [ -n "$old_id" ] && echo "${C_DIM}Janela '$name' já existe — reiniciando o serviço.${C_RESET}"
    tmux new-window -t "$SESSION" -n "$name" "${env_flags[@]}"
    [ -n "$old_id" ] && tmux kill-window -t "$old_id" 2>/dev/null
  fi
  tmux send-keys -t "$SESSION:=$name" "$cmd" C-m

  if [ "${S_WAIT[$i]}" = "true" ]; then
    wait_for_startup "$name"
    return $?
  fi
  return 0
}

# Quando um serviço com wait=true falha, pergunta se continua ou aborta.
handle_service_failure() {
  local i="$1"
  [ "${S_WAIT[$i]}" = "true" ] || return 0
  [ -t 0 ] || return 0
  local cont
  read -erp "Serviço '${S_NAME[$i]}' falhou/expirou. Continuar mesmo assim? (s/N): " cont
  [[ "${cont,,}" == "s" ]] || die "abortado após falha de '${S_NAME[$i]}'."
}

add_new_service() {
  while true; do
    # Reescaneia a cada volta: o que acabou de ser registrado sai da lista.
    scan_executable_modules
    if [ ${#SCAN_PROJ[@]} -eq 0 ]; then
      echo ""
      echo "  Nenhum módulo executável novo detectado em '$BASE_DIR'."
      echo "  (Todos os módulos Spring Boot encontrados já estão no services.conf.)"
      return 0
    fi

    clear_screen
    echo "  ${C_CYAN}${C_BOLD}--- Adicionar serviços (módulos detectados no workspace) ---${C_RESET}"
    local k label
    for k in "${!SCAN_PROJ[@]}"; do
      if [ -n "${SCAN_MOD[$k]}" ]; then
        label="${SCAN_PROJ[$k]}  ▸ ${SCAN_MOD[$k]}"
      else
        label="${SCAN_PROJ[$k]}  ▸ (raiz)"
      fi
      printf "    ${C_DIM}[%d]${C_RESET} %s\n" "$((k+1))" "$label"
    done
    echo "    ${C_DIM}[A]${C_RESET} Registrar TODAS as ${#SCAN_PROJ[@]} APIs do workspace"
    echo "    ${C_DIM}[0]${C_RESET} Voltar"
    echo ""
    echo "  ${C_DIM}Um número registra com nome à escolha; vários números ou [A]${C_RESET}"
    echo "  ${C_DIM}registram em lote com os nomes sugeridos.${C_RESET}"
    echo ""
    local sel
    read -erp "  Adicionar qual módulo? " sel
    [[ "$sel" == "0" || -z "$sel" ]] && return 0

    if [[ "${sel^^}" == "A" ]]; then
      local all=()
      for k in "${!SCAN_PROJ[@]}"; do all+=("$k"); done
      add_modules_bulk "${all[@]}"
      pause; continue
    fi

    # Aceita um número (fluxo com nome interativo) ou vários (lote).
    local idxs=() seen=" " num idx invalid=0
    for num in $sel; do
      if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#SCAN_PROJ[@]}" ]; then
        echo "  Ignorando '$num' — fora da lista."; invalid=1; continue
      fi
      idx=$((num-1))
      [[ "$seen" == *" $idx "* ]] && continue
      idxs+=("$idx"); seen+="$idx "
    done
    if [ "${#idxs[@]}" -eq 0 ]; then
      echo "  Opção inválida."; pause; continue
    fi
    [ "$invalid" -eq 1 ] && pause

    if [ "${#idxs[@]}" -eq 1 ]; then
      add_one_module "${idxs[0]}"
    else
      add_modules_bulk "${idxs[@]}"
    fi
    pause
  done
}

# 0 (sucesso) se o nome já está em uso — por um serviço cadastrado ou por um
# dos nomes ainda não gravados passados em $2...
name_taken() {
  local name="$1"; shift
  local n
  for n in "${S_NAME[@]:-}"; do [ "$n" = "$name" ] && return 0; done
  for n in "$@"; do [ "$n" = "$name" ] && return 0; done
  return 1
}

# Nome livre para um serviço no registro em lote: parte de $1 (o módulo, ou o
# projeto quando o módulo é a raiz); se colidir, prefixa com o projeto ($2) e,
# em último caso, acrescenta um sufixo numérico. $3... = nomes desta rodada.
unique_service_name() {
  local base="$1" proj="$2"; shift 2
  local cand="$base" n=2
  if ! name_taken "$cand" "$@"; then printf '%s' "$cand"; return 0; fi
  cand="$proj-$base"
  while name_taken "$cand" "$@"; do
    cand="$proj-$base-$n"; n=$((n+1))
  done
  printf '%s' "$cand"
}

# Registra vários módulos detectados de uma vez, sem perguntar nome por módulo:
# mostra a lista com os nomes já resolvidos e grava tudo após uma confirmação.
add_modules_bulk() {
  local idxs=("$@") k path proj mod name
  local names=() paths=() projs=() mods=()

  for k in "${idxs[@]}"; do
    path="${SCAN_PATH[$k]}"; proj="${SCAN_PROJ[$k]}"; mod="${SCAN_MOD[$k]}"
    # '|' é o separador do services.conf: caminho assim não é representável.
    if [[ "$path$proj$mod" == *'|'* ]]; then
      warn "'$proj ▸ ${mod:-raiz}' tem '|' no caminho — pulando (registre à mão)."
      continue
    fi
    name="$(unique_service_name "${mod:-$proj}" "$proj" "${names[@]:-}")"
    names+=("$name"); paths+=("$path"); projs+=("$proj"); mods+=("$mod")
  done

  if [ "${#names[@]}" -eq 0 ]; then
    echo "  Nenhum módulo registrável na seleção."
    return 0
  fi

  clear_screen
  echo "  ${C_CYAN}${C_BOLD}--- Registrar ${#names[@]} API(s) de uma vez ---${C_RESET}"
  echo "  ${C_DIM}Defaults de cada serviço: build do módulo e das dependências (-pl -am),${C_RESET}"
  echo "  ${C_DIM}sem profile, wait=true. Nome repetido ganha o projeto como prefixo.${C_RESET}"
  echo "  ${C_DIM}Ajuste nome/profile/jvm_args depois pelo [E].${C_RESET}"
  echo ""
  local i
  for i in "${!names[@]}"; do
    printf "    ${C_BOLD}%s${C_RESET}  ${C_DIM}(%s ▸ %s)${C_RESET}\n" \
      "${names[$i]}" "${projs[$i]}" "${mods[$i]:-raiz}"
  done
  echo ""
  local confirm
  read -erp "  Registrar essas ${#names[@]} API(s) no services.conf? (S/n): " confirm
  if [[ "${confirm^^}" == "N" ]]; then
    echo "  Cancelado — nada gravado."
    return 0
  fi

  for i in "${!names[@]}"; do
    S_NAME+=("${names[$i]}"); S_PATH+=("${paths[$i]}"); S_PROJ+=("${projs[$i]}")
    S_MOD+=("${mods[$i]}"); S_BUILD+=(""); S_PROFILE+=(""); S_JVM+=(""); S_WAIT+=("true")
  done
  save_services
  success "${C_BOLD}${#names[@]}${C_RESET} serviço(s) adicionado(s) ao services.conf."
}

add_one_module() {
  local k="$1"
  local proj="${SCAN_PROJ[$k]}" mod="${SCAN_MOD[$k]}" path="${SCAN_PATH[$k]}"

  local default_name="${mod:-$proj}"
  echo ""
  echo "  Novo serviço — projeto '$proj', módulo '${mod:-(raiz)}'."
  echo "  Caminho: $path"
  echo "  Defaults: build do módulo e das dependências (-pl -am), sem profile, wait=true."
  echo "  Enter aceita o valor entre [colchetes]."
  echo ""

  local name
  read -erp "    nome no menu [$default_name]: " name; name="${name:-$default_name}"
  if [[ "$name" == *'|'* ]]; then
    echo "  O nome não pode conter '|' (separador do services.conf)."
    return 0
  fi

  local i
  for i in "${!S_NAME[@]}"; do
    if [ "${S_NAME[$i]}" = "$name" ]; then
      echo "  Já existe um serviço chamado '$name'. Escolha outro nome."
      return 0
    fi
  done

  local confirm
  read -erp "  Adicionar '$name' (projeto=$proj, modulo=${mod:-raiz}) ao services.conf? (S/n): " confirm
  if [[ "${confirm^^}" == "N" ]]; then
    echo "  Cancelado."
    return 0
  fi

  S_NAME+=("$name"); S_PATH+=("$path"); S_PROJ+=("$proj"); S_MOD+=("$mod")
  S_BUILD+=(""); S_PROFILE+=(""); S_JVM+=(""); S_WAIT+=("true")
  save_services
  success "'${C_BOLD}$name${C_RESET}' adicionado ao services.conf. Ajuste profile/jvm_args pelo [E] se precisar."
}

# Editor de serviços ([E]).
edit_services() {
  while true; do
    clear_screen
    echo "  ${C_CYAN}${C_BOLD}--- Editor de serviços (grava em services.conf) ---${C_RESET}"
    local i
    for i in "${!S_NAME[@]}"; do
      printf "    [%d] %s ${C_DIM}( %s )${C_RESET}\n" "$((i+1))" "${S_NAME[$i]}" "${S_PROJ[$i]}"
    done
    echo "    [0] Voltar"
    echo ""
    local sel
    read -erp "  Editar qual serviço? " sel
    [[ "$sel" == "0" || -z "$sel" ]] && return 0
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#S_NAME[@]}" ]; then
      echo "  Opção inválida."; pause; continue
    fi
    local idx=$((sel-1))
    edit_one_service "$idx"
    pause
  done
}

# Remover serviço ([R]), com confirmação.
remove_service() {
  while true; do
    clear_screen
    echo "  ${C_CYAN}${C_BOLD}--- Remover serviço (apaga do services.conf) ---${C_RESET}"
    if [ "${#S_NAME[@]}" -eq 0 ]; then
      echo "  Nenhum serviço cadastrado."
      return 0
    fi
    local i
    for i in "${!S_NAME[@]}"; do
      printf "    ${C_DIM}[%d]${C_RESET} %s ${C_DIM}( %s )${C_RESET}\n" \
        "$((i+1))" "${S_NAME[$i]}" "${S_PROJ[$i]}"
    done
    echo "    ${C_DIM}[0]${C_RESET} Voltar"
    echo ""
    local sel
    read -erp "  Remover qual serviço? " sel
    [[ "$sel" == "0" || -z "$sel" ]] && return 0
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#S_NAME[@]}" ]; then
      echo "  Opção inválida."; pause; continue
    fi
    remove_one_service "$((sel-1))"
    pause
  done
}

remove_one_service() {
  local i="$1"
  echo ""
  echo "  Remover '${C_BOLD}${S_NAME[$i]}${C_RESET}'"
  echo "  ${C_DIM}projeto: ${S_PROJ[$i]}  |  módulo: ${S_MOD[$i]:-(raiz)}  |  caminho: ${S_PATH[$i]}${C_RESET}"
  echo ""
  local confirm
  read -erp "  Confirmar remoção? (s/N): " confirm
  if [[ "${confirm,,}" != "s" ]]; then
    echo "  Mantido — nada removido."
    return 0
  fi

  local name="${S_NAME[$i]}"
  S_NAME=("${S_NAME[@]:0:i}" "${S_NAME[@]:i+1}")
  S_PATH=("${S_PATH[@]:0:i}" "${S_PATH[@]:i+1}")
  S_PROJ=("${S_PROJ[@]:0:i}" "${S_PROJ[@]:i+1}")
  S_MOD=("${S_MOD[@]:0:i}" "${S_MOD[@]:i+1}")
  S_BUILD=("${S_BUILD[@]:0:i}" "${S_BUILD[@]:i+1}")
  S_PROFILE=("${S_PROFILE[@]:0:i}" "${S_PROFILE[@]:i+1}")
  S_JVM=("${S_JVM[@]:0:i}" "${S_JVM[@]:i+1}")
  S_WAIT=("${S_WAIT[@]:0:i}" "${S_WAIT[@]:i+1}")

  save_services
  groups_drop_service "$name"
  success "'$name' removido do services.conf."
}

edit_one_service() {
  local i="$1"
  echo ""
  echo "  Serviço '${S_NAME[$i]}' (projeto: ${S_PROJ[$i]})"
  echo "  O valor atual já vem preenchido: edite, apague (deixa vazio) ou Enter mantém."
  echo ""
  local name path mod build profile jvm wait
  while true; do
    read -erp "    nome          : " -i "${S_NAME[$i]}" name
    if [ -z "$(trim "$name")" ]; then
      echo "  O nome não pode ficar vazio."; continue
    fi
    local j dup=0
    for j in "${!S_NAME[@]}"; do
      [ "$j" -eq "$i" ] && continue
      [ "${S_NAME[$j]}" = "$name" ] && { dup=1; break; }
    done
    [ "$dup" -eq 1 ] && { echo "  Já existe outro serviço chamado '$name'."; continue; }
    break
  done
  read -erp "    path          : " -i "${S_PATH[$i]}" path
  path="${path/#\~/$HOME}"
  path="$(squeeze_slashes "$path")"
  [ -d "$path" ] || warn "o caminho '$path' não existe hoje — o serviço será pulado ao subir."
  read -erp "    modulo        : " -i "${S_MOD[$i]}" mod
  read -erp "    build_modules : " -i "${S_BUILD[$i]}" build
  read -erp "    profile       : " -i "${S_PROFILE[$i]}" profile
  read -erp "    jvm_args      : " -i "${S_JVM[$i]}" jvm
  while true; do
    read -erp "    wait (true/false) : " -i "${S_WAIT[$i]}" wait
    [[ "$wait" == "true" || "$wait" == "false" ]] && break
    echo "  Valor inválido — use 'true' ou 'false'."
  done

  if [[ "$name$path$mod$build$profile$jvm" == *'|'* ]]; then
    echo "  Os campos não podem conter '|' (separador do services.conf). Nada gravado."
    return 0
  fi

  if [[ "$name" == "${S_NAME[$i]}" && "$path" == "${S_PATH[$i]}" \
     && "$mod" == "${S_MOD[$i]}" && "$build" == "${S_BUILD[$i]}" \
     && "$profile" == "${S_PROFILE[$i]}" && "$jvm" == "${S_JVM[$i]}" \
     && "$wait" == "${S_WAIT[$i]}" ]]; then
    echo "  (Nenhuma alteração — nada gravado.)"
    return 0
  fi

  local confirm
  read -erp "  Salvar alterações em services.conf? (S/n): " confirm
  if [[ "${confirm^^}" == "N" ]]; then
    echo "  Alterações descartadas."
    return 0
  fi

  local old_name="${S_NAME[$i]}"
  S_NAME[$i]="$name"; S_PATH[$i]="$path"
  S_MOD[$i]="$mod"; S_BUILD[$i]="$build"; S_PROFILE[$i]="$profile"
  S_JVM[$i]="$jvm"; S_WAIT[$i]="$wait"
  save_services
  # Grupos guardam nomes: renomear aqui tem de renomear lá também.
  [ "$name" != "$old_name" ] && groups_rename_service "$old_name" "$name"
  success "Salvo em services.conf."
}

# Regrava o services.conf preservando o cabeçalho de comentários.
save_services() {
  local tmp="$CONF_FILE.tmp.$$"
  {
    # preserva só o bloco de comentários do topo
    local line seen_data=0
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "${line#"${line%%[![:space:]]*}"}" == \#* || -z "${line//[[:space:]]/}" ]]; then
        [ "$seen_data" -eq 0 ] && echo "$line"
      else
        seen_data=1
      fi
    done < "$CONF_FILE"

    local i
    for i in "${!S_NAME[@]}"; do
      echo "${S_NAME[$i]}|${S_PATH[$i]}|${S_PROJ[$i]}|${S_MOD[$i]}|${S_BUILD[$i]}|${S_PROFILE[$i]}|${S_JVM[$i]}|${S_WAIT[$i]}"
    done
  } > "$tmp" && mv "$tmp" "$CONF_FILE" || { rm -f "$tmp"; die "falha ao gravar '$CONF_FILE'."; }
}

# =============================================================================
# Grupos de APIs
# =============================================================================
# Um grupo é um atalho para uma seleção em ordem fixa: no menu, 'g1' expande
# para as APIs do grupo 1, na ordem gravada. Os grupos guardam NOMES (não
# índices), então reordenar/adicionar serviços no services.conf não os quebra.

groups_header() {
  cat <<'EOF'
# =============================================================================
# groups.conf — grupos de APIs (gerenciado pela opção [G] do menu)
# =============================================================================
# Uma linha por grupo, campos separados por '|':
#   nome_do_grupo | api1 | api2 | api3 | ...
#
# A ordem das APIs na linha É a ordem de subida. Os nomes são os do
# services.conf; nome que não existe mais é ignorado (com aviso) ao subir.
#
# Dá para editar à mão — o menu [G] regrava este arquivo.
# =============================================================================
EOF
}

# Nº de APIs de um grupo (pelo índice).
group_count() {
  local items=(); IFS='|' read -r -a items <<< "${G_ITEMS[$1]}"
  printf '%s' "${#items[@]}"
}

# Resumo "a → b → c" de um grupo. $2 = máx. de nomes exibidos (0 = todos);
# API que não está mais no services.conf sai marcada com '(?)'.
group_summary() {
  local i="$1" max="${2:-0}" out="" n=0 m
  local items=(); IFS='|' read -r -a items <<< "${G_ITEMS[$i]}"
  for m in "${items[@]}"; do
    n=$((n + 1))
    if [ "$max" -gt 0 ] && [ "$n" -gt "$max" ]; then
      out+=" → …+$(( ${#items[@]} - max ))"
      break
    fi
    service_index "$m" >/dev/null || m="$m(?)"
    out+="${out:+ → }$m"
  done
  printf '%s' "$out"
}

# Números do menu correspondentes às APIs do grupo, na ordem dele. Serve para
# pré-preencher a edição (as órfãs simplesmente não aparecem).
group_numbers() {
  local i="$1" out="" m idx
  local items=(); IFS='|' read -r -a items <<< "${G_ITEMS[$i]}"
  for m in "${items[@]}"; do
    idx="$(service_index "$m")" || continue
    out+="${out:+ }$((idx + 1))"
  done
  printf '%s' "$out"
}

load_groups() {
  G_NAME=() G_ITEMS=()
  [ -f "$GROUPS_FILE" ] || return 0

  local line name rest lineno=0 norm it
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue

    if [[ "$line" != *'|'* ]]; then
      warn "$GROUPS_FILE: linha $lineno sem '|' — esperado 'grupo|api1|api2|...'."
      continue
    fi
    name="$(trim "${line%%|*}")"
    rest="${line#*|}"

    norm=""
    while IFS= read -r it; do
      it="$(trim "$it")"
      [ -z "$it" ] && continue
      norm+="${norm:+|}$it"
    done < <(printf '%s\n' "${rest//|/$'\n'}")

    if [ -z "$name" ] || [ -z "$norm" ]; then
      warn "$GROUPS_FILE: linha $lineno ignorada (grupo sem nome ou sem APIs)."
      continue
    fi
    G_NAME+=("$name"); G_ITEMS+=("$norm")
  done < "$GROUPS_FILE"
}

save_groups() {
  ensure_conf_dir
  local tmp="$GROUPS_FILE.tmp.$$" i
  {
    groups_header
    for i in "${!G_NAME[@]}"; do
      echo "${G_NAME[$i]}|${G_ITEMS[$i]}"
    done
  } > "$tmp" && mv "$tmp" "$GROUPS_FILE" \
    || { rm -f "$tmp"; die "falha ao gravar '$GROUPS_FILE'."; }
}

# Índice do serviço com esse nome (stdout); 1 se não existir.
service_index() {
  local name="$1" i
  for i in "${!S_NAME[@]}"; do
    if [ "${S_NAME[$i]}" = "$name" ]; then printf '%s' "$i"; return 0; fi
  done
  return 1
}

# Traduz a entrada do menu ("3 1 g2 7") em índices de S_NAME: na ordem digitada,
# sem repetir, expandindo 'gN' na ordem gravada do grupo. Resultado em SEL_IDX;
# SEL_WARNED=1 se algo foi ignorado. Retorna 1 se sobrou nada válido.
SEL_IDX=() SEL_WARNED=0
expand_selection() {
  local input="$1"
  SEL_IDX=(); SEL_WARNED=0

  local seen=" " tok idx gi m
  for tok in $input; do
    if [[ "$tok" =~ ^[Gg]([0-9]+)$ ]]; then
      gi=$(( ${BASH_REMATCH[1]} - 1 ))
      if [ "$gi" -lt 0 ] || [ "$gi" -ge "${#G_NAME[@]}" ]; then
        warn "grupo '$tok' não existe, ignorando."; SEL_WARNED=1; continue
      fi
      local items=(); IFS='|' read -r -a items <<< "${G_ITEMS[$gi]}"
      for m in "${items[@]}"; do
        [ -z "$m" ] && continue
        if ! idx="$(service_index "$m")"; then
          warn "grupo '${G_NAME[$gi]}' cita '$m', que não está no services.conf — ignorando."
          SEL_WARNED=1; continue
        fi
        [[ "$seen" == *" $idx "* ]] && continue
        SEL_IDX+=("$idx"); seen+="$idx "
      done
      continue
    fi

    if ! [[ "$tok" =~ ^[0-9]+$ ]]; then
      warn "'$tok' não é número nem grupo (gN), ignorando."; SEL_WARNED=1; continue
    fi
    idx=$((tok - 1))
    if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#S_NAME[@]}" ]; then
      warn "número '$tok' inválido, ignorando."; SEL_WARNED=1; continue
    fi
    [[ "$seen" == *" $idx "* ]] && continue
    SEL_IDX+=("$idx"); seen+="$idx "
  done

  [ "${#SEL_IDX[@]}" -gt 0 ]
}

# Lista numerada dos serviços, para as telas que pedem uma seleção.
print_service_list() {
  local i
  if [ "${#S_NAME[@]}" -eq 0 ]; then
    echo "    ${C_DIM}(nenhum serviço cadastrado)${C_RESET}"
    return 0
  fi
  for i in "${!S_NAME[@]}"; do
    printf "    ${C_DIM}[%d]${C_RESET} %s ${C_DIM}( %s )${C_RESET}\n" \
      "$((i+1))" "${S_NAME[$i]}" "${S_PROJ[$i]}"
  done
}

# Pede um nome de grupo válido (não vazio, sem '|', não repetido). Ecoa o nome;
# retorna 1 se cancelado (Enter vazio). $1 = pré-preenchido, $2 = índice a
# ignorar na checagem de duplicado (-1 ao criar). Interação vai para stderr.
read_group_name() {
  local initial="$1" skip="${2:--1}" name j dup
  while true; do
    read -erp "  Nome do grupo (Enter cancela): " -i "$initial" name >&2
    name="$(trim "$name")"
    [ -z "$name" ] && return 1
    if [[ "$name" == *'|'* ]]; then
      echo "  O nome não pode conter '|' (separador do groups.conf)." >&2; continue
    fi
    dup=0
    for j in "${!G_NAME[@]}"; do
      [ "$j" -eq "$skip" ] && continue
      [ "${G_NAME[$j]}" = "$name" ] && { dup=1; break; }
    done
    [ "$dup" -eq 1 ] && { echo "  Já existe um grupo chamado '$name'." >&2; continue; }
    printf '%s' "$name"; return 0
  done
}

# Pede a seleção ordenada de APIs do grupo e ecoa os nomes juntados por '|'.
# Retorna 1 se cancelado. $1 = pré-preenchimento (números). Interação em stderr.
read_group_items() {
  local initial="$1" sel out idx
  while true; do
    {
      echo ""
      echo "  Digite os números na ordem de subida (ex.: 6 1 3)."
      echo "  ${C_DIM}Outros grupos também valem como atalho (gN). Enter cancela.${C_RESET}"
    } >&2
    read -erp "  Seleção: " -i "$initial" sel >&2
    [ -z "${sel//[[:space:]]/}" ] && return 1
    if ! expand_selection "$sel"; then
      echo "  Nenhuma API válida na seleção." >&2; continue
    fi
    out=""
    for idx in "${SEL_IDX[@]}"; do out+="${out:+|}${S_NAME[$idx]}"; done
    printf '%s' "$out"; return 0
  done
}

create_group() {
  if [ "${#S_NAME[@]}" -eq 0 ]; then
    echo "  Nenhum serviço cadastrado — use [N] no menu antes de criar grupos."
    return 0
  fi
  clear_screen
  echo "  ${C_CYAN}${C_BOLD}--- Novo grupo de APIs ---${C_RESET}"
  echo "  ${C_DIM}O grupo guarda a seleção E a ordem; depois basta digitar 'gN' no menu.${C_RESET}"
  echo ""
  print_service_list

  local name items
  name="$(read_group_name "" -1)" || { echo "  Cancelado — grupo não criado."; return 0; }
  items="$(read_group_items "")"  || { echo "  Cancelado — grupo não criado."; return 0; }

  G_NAME+=("$name"); G_ITEMS+=("$items")
  save_groups
  success "grupo '${C_BOLD}$name${C_RESET}' criado com $(group_count $(( ${#G_NAME[@]} - 1 ))) API(s) — use '${C_BOLD}g${#G_NAME[@]}${C_RESET}' no menu."
}

edit_one_group() {
  local i="$1"
  clear_screen
  echo "  ${C_CYAN}${C_BOLD}--- Editar grupo '${G_NAME[$i]}' ---${C_RESET}"
  echo "  ${C_DIM}Ordem atual: $(group_summary "$i" 0)${C_RESET}"
  echo "  ${C_DIM}A seleção vem pré-preenchida com os números atuais: edite e Enter grava.${C_RESET}"
  echo ""
  print_service_list

  local name items
  name="$(read_group_name "${G_NAME[$i]}" "$i")" || { echo "  Cancelado — nada alterado."; return 0; }
  items="$(read_group_items "$(group_numbers "$i")")" || { echo "  Cancelado — nada alterado."; return 0; }

  if [ "$name" = "${G_NAME[$i]}" ] && [ "$items" = "${G_ITEMS[$i]}" ]; then
    echo "  (Nenhuma alteração — nada gravado.)"
    return 0
  fi
  G_NAME[$i]="$name"; G_ITEMS[$i]="$items"
  save_groups
  success "grupo '$name' atualizado."
}

remove_one_group() {
  local i="$1"
  echo ""
  echo "  Remover o grupo '${C_BOLD}${G_NAME[$i]}${C_RESET}' ($(group_count "$i") API(s))"
  echo "  ${C_DIM}$(group_summary "$i" 0)${C_RESET}"
  echo "  ${C_DIM}As APIs em si não são removidas — só o atalho.${C_RESET}"
  echo ""
  local confirm
  read -erp "  Confirmar remoção? (s/N): " confirm
  if [[ "${confirm,,}" != "s" ]]; then
    echo "  Mantido — nada removido."
    return 0
  fi
  local name="${G_NAME[$i]}"
  G_NAME=("${G_NAME[@]:0:i}" "${G_NAME[@]:i+1}")
  G_ITEMS=("${G_ITEMS[@]:0:i}" "${G_ITEMS[@]:i+1}")
  save_groups
  success "grupo '$name' removido."
}

# [G] no menu: cria, edita e remove grupos.
manage_groups() {
  while true; do
    clear_screen
    echo "  ${C_CYAN}${C_BOLD}--- Grupos de APIs (grava em groups.conf) ---${C_RESET}"
    echo "  ${C_DIM}Um grupo = uma seleção de APIs com ordem fixa, chamada por 'gN' no menu.${C_RESET}"
    echo ""
    local i
    if [ "${#G_NAME[@]}" -eq 0 ]; then
      echo "    ${C_DIM}(nenhum grupo criado ainda)${C_RESET}"
    else
      for i in "${!G_NAME[@]}"; do
        printf "    ${C_DIM}[g%d]${C_RESET} ${C_BOLD}%s${C_RESET} ${C_DIM}(%s API(s))${C_RESET}\n" \
          "$((i+1))" "${G_NAME[$i]}" "$(group_count "$i")"
        echo "         ${C_DIM}$(group_summary "$i" 6)${C_RESET}"
      done
    fi
    echo ""
    echo "    ${C_DIM}[N]${C_RESET} Criar grupo"
    echo "    ${C_DIM}[E]${C_RESET} Editar grupo (nome/seleção/ordem)"
    echo "    ${C_DIM}[R]${C_RESET} Remover grupo"
    echo "    ${C_DIM}[0]${C_RESET} Voltar ao menu"
    echo ""

    local sel
    read -erp "  > " sel
    case "${sel^^}" in
      0|'') return 0 ;;
      N) create_group; pause; continue ;;
      E|R) ;;
      *) echo "  Opção inválida."; pause; continue ;;
    esac

    if [ "${#G_NAME[@]}" -eq 0 ]; then
      echo "  Nenhum grupo para ${sel^^} — use [N] primeiro."; pause; continue
    fi
    local action="${sel^^}" num
    read -erp "  Qual grupo? (número, 0 volta) " num
    [[ -z "$num" || "$num" == "0" ]] && continue
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#G_NAME[@]}" ]; then
      echo "  Opção inválida."; pause; continue
    fi
    if [ "$action" = "E" ]; then
      edit_one_group "$((num-1))"
    else
      remove_one_group "$((num-1))"
    fi
    pause
  done
}

# [g] na confirmação da ordem: grava a seleção recém-digitada como grupo novo.
save_order_as_group() {
  local idxs=("$@") name items="" i
  echo ""
  name="$(read_group_name "" -1)" || { echo "Grupo não criado."; return 0; }
  for i in "${idxs[@]}"; do items+="${items:+|}${S_NAME[$i]}"; done
  G_NAME+=("$name"); G_ITEMS+=("$items")
  save_groups
  success "grupo '${C_BOLD}$name${C_RESET}' criado com ${#idxs[@]} API(s) — na próxima vez, digite '${C_BOLD}g${#G_NAME[@]}${C_RESET}'."
}

# Mantém os grupos coerentes quando um serviço é renomeado pelo [E].
groups_rename_service() {
  local old="$1" new="$2" i m out changed=0
  for i in "${!G_NAME[@]}"; do
    local items=(); IFS='|' read -r -a items <<< "${G_ITEMS[$i]}"
    out=""
    for m in "${items[@]}"; do
      [ "$m" = "$old" ] && { m="$new"; changed=1; }
      out+="${out:+|}$m"
    done
    G_ITEMS[$i]="$out"
  done
  if [ "$changed" -eq 1 ]; then
    save_groups
    info "  Grupos atualizados: '$old' -> '$new'."
  fi
  return 0
}

# Idem para o [R]: tira a API dos grupos e descarta grupo que ficou vazio.
groups_drop_service() {
  local name="$1" i m out changed=0
  local keep_name=() keep_items=() dropped=()
  for i in "${!G_NAME[@]}"; do
    local items=(); IFS='|' read -r -a items <<< "${G_ITEMS[$i]}"
    out=""
    for m in "${items[@]}"; do
      [ "$m" = "$name" ] && { changed=1; continue; }
      out+="${out:+|}$m"
    done
    if [ -z "$out" ]; then
      dropped+=("${G_NAME[$i]}"); changed=1; continue
    fi
    keep_name+=("${G_NAME[$i]}"); keep_items+=("$out")
  done
  [ "$changed" -eq 0 ] && return 0

  if [ "${#keep_name[@]}" -eq 0 ]; then
    G_NAME=(); G_ITEMS=()
  else
    G_NAME=("${keep_name[@]}"); G_ITEMS=("${keep_items[@]}")
  fi
  save_groups
  info "  '$name' saiu dos grupos que a citavam."
  [ "${#dropped[@]}" -gt 0 ] && warn "grupo(s) removido(s) por ficar(em) vazio(s): ${dropped[*]}"
  return 0
}

# Ctrl-C (e SIGTERM) encerram apenas ESTE script — as janelas tmux seguem de pé.
# Derrubar as APIs passa a ser sempre explícito ('tmux kill-session' ou [r] no
# menu): antes, um Ctrl-C dado fora do tmux matava serviços que já rodavam.
on_interrupt() {
  echo ""
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "${C_YELLOW}⏹ Saindo do pequizero — as APIs continuam rodando.${C_RESET}"
    echo "  ${C_DIM}Reanexar: tmux attach -t $SESSION${C_RESET}"
    echo "  ${C_DIM}Derrubar: tmux kill-session -t $SESSION${C_RESET}"
  else
    echo "${C_YELLOW}⏹ Cancelado — nada foi iniciado.${C_RESET}"
  fi
  exit 130
}
trap on_interrupt SIGINT SIGTERM

handle_existing_session() {
  tmux has-session -t "$SESSION" 2>/dev/null || return 0
  echo ""
  echo "A sessão tmux '$SESSION' já existe."
  echo "  ${C_DIM}[u]${C_RESET} Usar a sessão — sobe a seleção nela (reinicia janelas de mesmo nome)"
  echo "  ${C_DIM}[r]${C_RESET} Recriar do zero (mata a sessão atual)"
  echo "  ${C_DIM}[a]${C_RESET} Só anexar (descarta a seleção)"
  echo "  ${C_DIM}[c]${C_RESET} Cancelar"
  local ans
  read -erp "  > " ans
  case "${ans,,}" in
    u) ;;
    r) tmux kill-session -t "$SESSION" 2>/dev/null ;;
    a) exec tmux attach -t "$SESSION" ;;
    *) echo "Cancelado."; exit 0 ;;
  esac
}

print_menu() {
  clear_screen
  echo "${C_CYAN}${C_BOLD}========================================${C_RESET}"
  echo "${C_CYAN}${C_BOLD}  Selecione as APIs e a ordem de execução${C_RESET}"
  echo "${C_CYAN}${C_BOLD}========================================${C_RESET}"
  echo "  ${C_DIM}workspace (scan): ${BASE_DIR}${C_RESET}"
  echo ""
  echo "  APIs disponíveis:"
  echo ""
  local i
  if [ "${#S_NAME[@]}" -eq 0 ]; then
    echo "  ${C_DIM}(nenhuma cadastrada — use [N] para adicionar)${C_RESET}"
  else
    for i in "${!S_NAME[@]}"; do
      printf "  ${C_DIM}[%d]${C_RESET} ${C_BOLD}%s${C_RESET} ${C_DIM}( %s )${C_RESET}\n" \
        "$((i+1))" "${S_NAME[$i]}" "${S_PROJ[$i]}"
    done
  fi
  if [ "${#G_NAME[@]}" -gt 0 ]; then
    echo ""
    echo "  Grupos (sobem na ordem gravada):"
    echo ""
    for i in "${!G_NAME[@]}"; do
      printf "  ${C_DIM}[g%d]${C_RESET} ${C_BOLD}%s${C_RESET} ${C_DIM}(%s API(s): %s)${C_RESET}\n" \
        "$((i+1))" "${G_NAME[$i]}" "$(group_count "$i")" "$(group_summary "$i" 4)"
    done
  fi
  echo ""
  echo "  ${C_DIM}[A]${C_RESET} Todas na ordem padrão (Enter)"
  echo "  ${C_DIM}[G]${C_RESET} Grupos de APIs (criar/editar/remover)"
  echo "  ${C_DIM}[N]${C_RESET} Adicionar serviços (um, vários ou todos os detectados)"
  echo "  ${C_DIM}[E]${C_RESET} Editar serviços"
  echo "  ${C_DIM}[R]${C_RESET} Remover serviço"
  echo "  ${C_DIM}[W]${C_RESET} Trocar workspace p/ escanear outra pasta"
  if [ "$SCAN_COUNT" -gt 0 ]; then
    echo ""
    echo "  ${C_CYAN}ℹ $SCAN_COUNT módulo(s) Spring Boot detectado(s) ainda não cadastrado(s) —${C_RESET}"
    echo "  ${C_CYAN}  use [N] para registrar (lá dentro, [A] registra todos de uma vez).${C_RESET}"
  fi
  echo ""
  echo "  A ordem dos números define a ordem de execução."
  echo "  Ex: '6 1 3' inicia o 6º, depois o 1º, depois o 3º."
  echo "  Grupos entram como 'gN' e podem se misturar aos números:"
  echo "  ${C_DIM}'g1' sobe o grupo 1 na ordem dele; 'g1 7 2' sobe o grupo e mais o 7º e o 2º.${C_RESET}"
  echo ""
}

# Temporário do --update, em escopo global: a trap EXIT roda depois de
# self_update() retornar, quando um 'local' já não existiria mais (e 'set -u'
# transformaria a limpeza em erro).
SELF_UPDATE_TMP=""
cleanup_self_update() {
  [ -n "$SELF_UPDATE_TMP" ] && rm -f "$SELF_UPDATE_TMP"
  return 0
}

# Baixa a última release por cima do próprio script (--update).
# Não mexe nos .conf: eles vivem no CONF_DIR, fora do caminho do binário.
self_update() {
  local target target_dir
  target="$(readlink -f "${BASH_SOURCE[0]}")"
  target_dir="$(dirname "$target")"

  if is_repo_install; then
    die "instalação via repositório — atualize com: git -C \"$SCRIPT_DIR\" pull"
  fi
  if [ ! -w "$target" ] || [ ! -w "$target_dir" ]; then
    die "'$target' não é gravável — atualize pelo gerenciador de pacotes."
  fi
  command -v curl >/dev/null 2>&1 || die "curl não encontrado — necessário para --update."

  # Temporário no MESMO diretório do alvo: assim o 'mv' final é um rename no
  # mesmo filesystem (atômico), sem cópia parcial se algo falhar no meio.
  local tmp
  tmp="$(mktemp "$target_dir/.pequizero.XXXXXX")" \
    || die "falha ao criar arquivo temporário em '$target_dir'."
  SELF_UPDATE_TMP="$tmp"
  trap cleanup_self_update EXIT

  info "baixando a última release de $REPO..."
  curl -fsSL "$RELEASE_URL" -o "$tmp" || die "download falhou — nada foi alterado."

  # Um download truncado que já foi movido para o PATH deixa o usuário sem
  # ferramenta e sem diagnóstico: valida a sintaxe antes de instalar.
  bash -n "$tmp" 2>/dev/null \
    || die "download corrompido (sintaxe inválida) — nada foi alterado."

  # 'bash -n' só pega truncagem que quebra a sintaxe; um corte em ponto
  # sintaticamente válido passaria. Confirma que o arquivo chegou até o fim.
  grep -q '^  main "\$@"$' "$tmp" \
    || die "download incompleto (faltou o fim do script) — nada foi alterado."

  local new_version
  new_version="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -1)"
  if [ -n "$new_version" ] && [ "$new_version" = "$VERSION" ]; then
    cleanup_self_update
    SELF_UPDATE_TMP=""
    success "já está na versão mais recente ($VERSION)."
    return 0
  fi

  # Preserva o modo do arquivo atual (o mktemp nasce 600).
  chmod --reference="$target" "$tmp" 2>/dev/null || chmod +x "$tmp" \
    || die "falha ao ajustar permissões de '$tmp'."

  # 'mv' troca o inode: o bash lê o script incrementalmente enquanto executa,
  # então sobrescrever o mesmo inode corromperia esta execução.
  mv "$tmp" "$target" || die "falha ao substituir '$target'."
  SELF_UPDATE_TMP=""

  success "atualizado: $VERSION -> ${new_version:-desconhecida}"
}

main() {
  resolve_conf_dir

  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "pequizero $VERSION"; exit 0 ;;
    --update) self_update; exit 0 ;;
    --reconfigure)
      # shellcheck source=/dev/null
      [ -f "$LOCAL_CONF" ] && source "$LOCAL_CONF"
      reconfigure_base_dir
      exit 0 ;;
  esac

  check_prereqs
  bootstrap_local_conf
  load_local_conf
  load_services
  load_groups
  warn_undefined_vars
  refresh_scan_count

  # [G]/[N]/[E]/[R]/[W] e o "não confirmar" voltam ao menu; só sai ao confirmar.
  local INPUT EXEC_ORDER=()
  while true; do
    print_menu
    read -erp "Escolha: " INPUT
    case "${INPUT^^}" in
      G) manage_groups; continue ;;
      N) add_new_service; refresh_scan_count; pause; continue ;;
      E) edit_services;   pause; continue ;;
      R) remove_service;  refresh_scan_count; pause; continue ;;
      W) change_workspace; pause; continue ;;
    esac

    EXEC_ORDER=()
    local i
    if [[ -z "$INPUT" || "${INPUT^^}" == "A" ]]; then
      for i in "${!S_NAME[@]}"; do EXEC_ORDER+=("$i"); done
    else
      # Aceita números e grupos ('gN') misturados, na ordem digitada.
      expand_selection "$INPUT" && EXEC_ORDER=("${SEL_IDX[@]}")
      [ "$SEL_WARNED" -eq 1 ] && pause
    fi

    if [ "${#EXEC_ORDER[@]}" -eq 0 ]; then
      echo ""
      echo "Nenhuma API válida selecionada."
      pause; continue
    fi

    clear_screen
    echo "${C_CYAN}${C_BOLD}Ordem de execução:${C_RESET}"
    local step=1
    for i in "${EXEC_ORDER[@]}"; do
      echo "  ${C_DIM}${step}°${C_RESET} -> ${C_BOLD}${S_NAME[$i]}${C_RESET}"
      step=$((step + 1))
    done

    local CONFIRM confirmed=0
    while true; do
      echo ""
      read -erp "Confirma? (S/n) — [g] salva esta ordem como grupo: " CONFIRM
      case "${CONFIRM,,}" in
        n) break ;;
        g) save_order_as_group "${EXEC_ORDER[@]}"; continue ;;
        *) confirmed=1; break ;;
      esac
    done
    if [ "$confirmed" -eq 0 ]; then
      echo "Cancelado — voltando ao menu."
      pause; continue
    fi
    break
  done

  handle_existing_session

  echo ""
  echo "${C_CYAN}${C_BOLD}Iniciando APIs...${C_RESET}"
  for i in "${EXEC_ORDER[@]}"; do
    start_service "$i" || handle_service_failure "$i"
  done

  tmux has-session -t "$SESSION" 2>/dev/null \
    || die "nenhum serviço subiu (verifique os caminhos no services.conf)."

  echo ""
  success "${C_BOLD}APIs iniciadas!${C_RESET}"
  tmux attach -t "$SESSION"

  # Chega aqui quando você desanexa (Ctrl-b d) — a sessão continua viva.
  echo ""
  echo "${C_DIM}Sessão '$SESSION' segue rodando. Reanexar: tmux attach -t $SESSION${C_RESET}"
  echo "${C_DIM}Derrubar todas: tmux kill-session -t $SESSION${C_RESET}"
}

# Executa main só quando rodado diretamente (não quando "sourced", ex.: testes).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
