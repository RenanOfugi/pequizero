#!/bin/bash
#
# pequizero.sh — sobe projetos/módulos Spring Boot (Maven) em uma sessão tmux.
#
# Uso:
#   ./pequizero.sh        menu interativo de seleção/ordem
#   ./pequizero.sh -h     ajuda
#
set -uo pipefail

SESSION="apis"
# Timeout aguardando o startup de cada serviço; pode ser sobrescrito definindo
# TIMEOUT_SECONDS=<segundos> no services.local.conf.
TIMEOUT_SECONDS=300

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONF_FILE="$SCRIPT_DIR/services.conf"
LOCAL_CONF="$SCRIPT_DIR/services.local.conf"

# S_PATH = caminho absoluto do projeto (usado no 'cd'); S_PROJ = nome curto.
S_NAME=() S_PATH=() S_PROJ=() S_MOD=() S_BUILD=() S_PROFILE=() S_JVM=() S_WAIT=()

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
  --reconfigure   Refaz a pergunta do caminho da pasta e regrava a escolha.

Variáveis de ambiente:
  CLEAN=1         Força 'mvn clean install' nos builds (recompila do zero).
                  Use ao renomear/remover classes ou mudar contratos entre
                  módulos. Padrão: build incremental (mais rápido).

Arquivos:
  services.conf         Definição dos serviços.
  services.local.conf   BASE_DIR, TIMEOUT_SECONDS e variáveis dos jvm_args
                        (criado na 1ª execução).

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
  local subs sel i msg=""
  while true; do
    subs=()
    while IFS= read -r d; do subs+=("$d"); done \
      < <(find "$cur" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' 2>/dev/null | sort)

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

    read -rp "  > " sel >&2
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
  suggested="$(dirname "$SCRIPT_DIR")"

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
    read -rp "  > " choice >&2

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

# Monta o comando (install + run) de um serviço pelo índice.
build_command() {
  local i="$1"
  local dir="${S_PATH[$i]}"
  local mod="${S_MOD[$i]}" build="${S_BUILD[$i]}"
  local profile="${S_PROFILE[$i]}" jvm="${S_JVM[$i]}"

  local goals="install"
  [ -n "${CLEAN:-}" ] && goals="clean install"

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
  declare -A seen=()

  local d proj p moddir mod pack
  for d in "$BASE_DIR"/*/; do
    proj="$(basename "$d")"
    [ "$proj" = "scripts" ] && continue
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
      [ -n "${seen["$key"]:-}" ] && continue
      seen["$key"]=1
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

  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
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
  read -rp "Serviço '${S_NAME[$i]}' falhou/expirou. Continuar mesmo assim? (s/N): " cont
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
    read -rp "  Adicionar qual módulo? " sel
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
  echo "  ${C_DIM}Defaults de cada serviço: build incremental do módulo (-pl -am),${C_RESET}"
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
  read -rp "  Registrar essas ${#names[@]} API(s) no services.conf? (S/n): " confirm
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
  echo "  Defaults: build incremental do módulo (-pl -am), sem profile, wait=true."
  echo "  Enter aceita o valor entre [colchetes]."
  echo ""

  local name
  read -rp "    nome no menu [$default_name]: " name; name="${name:-$default_name}"
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
  read -rp "  Adicionar '$name' (projeto=$proj, modulo=${mod:-raiz}) ao services.conf? (S/n): " confirm
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
    read -rp "  Editar qual serviço? " sel
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
    read -rp "  Remover qual serviço? " sel
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
  read -rp "  Confirmar remoção? (s/N): " confirm
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
  read -rp "  Salvar alterações em services.conf? (S/n): " confirm
  if [[ "${confirm^^}" == "N" ]]; then
    echo "  Alterações descartadas."
    return 0
  fi

  S_NAME[$i]="$name"; S_PATH[$i]="$path"
  S_MOD[$i]="$mod"; S_BUILD[$i]="$build"; S_PROFILE[$i]="$profile"
  S_JVM[$i]="$jvm"; S_WAIT[$i]="$wait"
  save_services
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

cleanup() {
  echo ""
  echo "${C_YELLOW}🛑 Derrubando todas as APIs...${C_RESET}"
  tmux kill-session -t "$SESSION" 2>/dev/null
  exit 0
}
trap cleanup SIGINT SIGTERM

handle_existing_session() {
  tmux has-session -t "$SESSION" 2>/dev/null || return 0
  echo ""
  echo "A sessão tmux '$SESSION' já existe."
  echo "  ${C_DIM}[u]${C_RESET} Usar a sessão — sobe a seleção nela (reinicia janelas de mesmo nome)"
  echo "  ${C_DIM}[r]${C_RESET} Recriar do zero (mata a sessão atual)"
  echo "  ${C_DIM}[a]${C_RESET} Só anexar (descarta a seleção)"
  echo "  ${C_DIM}[c]${C_RESET} Cancelar"
  local ans
  read -rp "  > " ans
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
  echo ""
  echo "  ${C_DIM}[A]${C_RESET} Todas na ordem padrão (Enter)"
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
  echo ""
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --reconfigure)
      [ -f "$LOCAL_CONF" ] && source "$LOCAL_CONF"
      reconfigure_base_dir
      exit 0 ;;
  esac

  check_prereqs
  bootstrap_local_conf
  load_local_conf
  load_services
  warn_undefined_vars
  refresh_scan_count

  # [N]/[E]/[R]/[W] e o "não confirmar" voltam ao menu; só sai ao confirmar.
  local INPUT EXEC_ORDER=()
  while true; do
    print_menu
    read -rp "Escolha: " INPUT
    case "${INPUT^^}" in
      N) add_new_service; refresh_scan_count; pause; continue ;;
      E) edit_services;   pause; continue ;;
      R) remove_service;  refresh_scan_count; pause; continue ;;
      W) change_workspace; pause; continue ;;
    esac

    EXEC_ORDER=()
    local SEEN=" " i warned=0
    if [[ -z "$INPUT" || "${INPUT^^}" == "A" ]]; then
      for i in "${!S_NAME[@]}"; do EXEC_ORDER+=("$i"); done
    else
      local num idx
      for num in $INPUT; do
        if ! [[ "$num" =~ ^[0-9]+$ ]]; then
          echo "AVISO: '$num' não é número, ignorando."; warned=1; continue
        fi
        idx=$((num - 1))
        if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#S_NAME[@]}" ]; then
          echo "AVISO: número '$num' inválido, ignorando."; warned=1; continue
        fi
        [[ "$SEEN" == *" $idx "* ]] && continue
        EXEC_ORDER+=("$idx"); SEEN+="$idx "
      done
      [ "$warned" -eq 1 ] && pause
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

    echo ""
    local CONFIRM
    read -rp "Confirma? (S/n): " CONFIRM
    if [[ "${CONFIRM^^}" == "N" ]]; then
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
}

# Executa main só quando rodado diretamente (não quando "sourced", ex.: testes).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
