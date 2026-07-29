#!/usr/bin/env bats
#
# Testes do pequizero.sh. Requer bats-core (https://github.com/bats-core/bats-core).
#   Instalar:  sudo apt install bats   (ou)  brew install bats-core
#   Rodar:     bats tests/pequizero.bats
#
# O script é "sourced" (graças ao guard `if [[ BASH_SOURCE == $0 ]]` no final),
# então as funções ficam disponíveis sem executar o menu. mvn/tmux/java não são
# chamados aqui — testamos apenas as funções puras (parsing, montagem, validação).

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../pequizero.sh"
  source "$SCRIPT"
  BASE_DIR="$BATS_TEST_TMPDIR"
  LOCAL_VARS=()
}

# --- build_command --------------------------------------------------------

@test "build_command: build do módulo (-pl -am) quando build_modules vazio" {
  S_PATH=(/ws/p) S_PROJ=(p) S_MOD=(srv) S_BUILD=("") S_PROFILE=("") S_JVM=("")
  run build_command 0
  [[ "$output" == *'cd "/ws/p"'* ]]
  [[ "$output" == *"mvn -pl srv -am install -DskipTests"* ]]
  [[ "$output" == *"mvn -pl srv spring-boot:run"* ]]
}

@test "build_command: build full quando modulo e build_modules vazios" {
  S_PATH=(/ws/p) S_PROJ=(p) S_MOD=("") S_BUILD=("") S_PROFILE=("") S_JVM=("")
  run build_command 0
  [[ "$output" == *"mvn install -DskipTests"* ]]
}

@test "build_command: usa -pl no install quando build_modules definido" {
  S_PATH=(/ws/p) S_PROJ=(p) S_MOD=(a) S_BUILD=("core,security,a") S_PROFILE=("") S_JVM=("")
  run build_command 0
  [[ "$output" == *"mvn -pl core,security,a -am install"* ]]
}

@test "build_command: CLEAN=1 força clean install" {
  S_PATH=(/ws/p) S_PROJ=(p) S_MOD=("") S_BUILD=("") S_PROFILE=("") S_JVM=("")
  CLEAN=1 run build_command 0
  [[ "$output" == *"mvn clean install -DskipTests"* ]]
}

@test "build_command: adiciona profile quando definido" {
  S_PATH=(/ws/p) S_PROJ=(p) S_MOD=(a) S_BUILD=("") S_PROFILE=("local") S_JVM=("")
  run build_command 0
  [[ "$output" == *"-Dspring-boot.run.profiles=local"* ]]
}

@test "build_command: REGRESSÃO P0.1 — \$(...) no jvm_args NÃO é executado" {
  S_PATH=(/ws/p) S_PROJ=(p) S_MOD=(a) S_BUILD=("") S_PROFILE=("") S_WAIT=(true)
  S_JVM=('-Dx=$(touch '"$BATS_TEST_TMPDIR"'/pwned)')
  run build_command 0
  [ ! -f "$BATS_TEST_TMPDIR/pwned" ]            # nada foi executado
  [[ "$output" == *'$(touch'* ]]                # ficou literal
}

@test "build_command: valor de variável NÃO vaza no comando" {
  LOCAL_VARS=(TOKEN)
  TOKEN="segredo123"
  S_PATH=(/ws/p) S_PROJ=(p) S_MOD=(a) S_BUILD=("") S_PROFILE=("") S_JVM=('-Dt=$TOKEN')
  run build_command 0
  [[ "$output" != *"segredo123"* ]]             # valor não aparece
  [[ "$output" == *'-Dt=$TOKEN'* ]]             # referência literal
}

# --- service_env_flags ----------------------------------------------------

@test "service_env_flags: injeta variável referenciada que está definida" {
  LOCAL_VARS=(TOKEN) ; TOKEN="abc"
  S_NAME=(s) S_JVM=('-Dt=$TOKEN')
  run service_env_flags 0
  [[ "$output" == *"-e"* ]]
  [[ "$output" == *"TOKEN=abc"* ]]
}

@test "service_env_flags: ignora variável não referenciada" {
  LOCAL_VARS=(TOKEN OUTRA) ; TOKEN="abc" OUTRA="x"
  S_NAME=(s) S_JVM=('-Dt=$TOKEN')
  run service_env_flags 0
  [[ "$output" != *"OUTRA"* ]]
}

# --- load_services (parsing + validação) ----------------------------------

@test "load_services: rejeita linha com nº de campos inválido" {
  CONF_FILE="$BATS_TEST_TMPDIR/c.conf"
  printf 'ok|p|true\n' > "$CONF_FILE"   # 3 campos
  run load_services
  [ "$status" -ne 0 ]
  [[ "$output" == *"campos (esperado 7 ou 8)"* ]]
}

@test "load_services: aceita 8 campos (novo formato com path)" {
  CONF_FILE="$BATS_TEST_TMPDIR/c.conf"
  printf 'ok|/ws/p|p|m||||true\n' > "$CONF_FILE"
  load_services
  [ "${#S_NAME[@]}" -eq 1 ]
  [ "${S_NAME[0]}" = "ok" ]
  [ "${S_PATH[0]}" = "/ws/p" ]
  [ "${S_WAIT[0]}" = "true" ]
}

@test "load_services: MIGRA 7 campos -> path = BASE_DIR/projeto" {
  BASE_DIR="/ws"
  CONF_FILE="$BATS_TEST_TMPDIR/c.conf"
  printf 'old|p|m||||true\n' > "$CONF_FILE"
  load_services 2>/dev/null
  [ "${S_PATH[0]}" = "/ws/p" ]
  grep -q 'old|/ws/p|p|' "$CONF_FILE"     # conf regravado em 8 campos
}

@test "load_services: wait inválido vira false com aviso" {
  CONF_FILE="$BATS_TEST_TMPDIR/c.conf"
  printf 'ok|/ws/p|p|m||||talvez\n' > "$CONF_FILE"
  load_services 2>/dev/null
  [ "${S_WAIT[0]}" = "false" ]
}

@test "load_services: ignora comentários e linhas em branco" {
  CONF_FILE="$BATS_TEST_TMPDIR/c.conf"
  printf '# comentário\n\nok|/ws/p|p|m||||true\n' > "$CONF_FILE"
  load_services
  [ "${#S_NAME[@]}" -eq 1 ]
}

# --- remove_one_service ---------------------------------------------------

@test "remove_one_service: remove do meio e realinha os arrays" {
  CONF_FILE="$BATS_TEST_TMPDIR/r.conf"
  printf 'a|/ws/a|a|m||||true\nb|/ws/b|b|m||||true\nc|/ws/c|c|m||||true\n' > "$CONF_FILE"
  load_services 2>/dev/null
  remove_one_service 1 <<<'s' >/dev/null      # remove 'b', confirma
  [ "${S_NAME[*]}" = "a c" ]
  [ "${S_PATH[*]}" = "/ws/a /ws/c" ]
  run grep -c '^b|' "$CONF_FILE"
  [ "$output" -eq 0 ]
}

@test "remove_one_service: cancelar (N) mantém o serviço" {
  CONF_FILE="$BATS_TEST_TMPDIR/r.conf"
  printf 'a|/ws/a|a|m||||true\n' > "$CONF_FILE"
  load_services 2>/dev/null
  remove_one_service 0 <<<'n' >/dev/null
  [ "${#S_NAME[@]}" -eq 1 ]
}

# --- edit_one_service -------------------------------------------------------
# Sem tty o 'read -e -i' não pré-preenche: cada linha do heredoc é o valor
# final do campo (linha vazia = campo limpo).

@test "edit_one_service: renomeia, muda path e apaga profile/jvm_args" {
  CONF_FILE="$BATS_TEST_TMPDIR/e.conf"
  printf 'a|/ws/a|a|srv|core|local|-Dx=1|true\n' > "$CONF_FILE"
  load_services 2>/dev/null
  edit_one_service 0 >/dev/null 2>&1 <<'EOF'
a-novo
/ws/novo
srv
core


false
s
EOF
  [ "${S_NAME[0]}" = "a-novo" ]
  [ "${S_PATH[0]}" = "/ws/novo" ]
  [ -z "${S_PROFILE[0]}" ]
  [ -z "${S_JVM[0]}" ]
  [ "${S_WAIT[0]}" = "false" ]
  grep -q '^a-novo|/ws/novo|a|srv|core|||false$' "$CONF_FILE"
}

@test "edit_one_service: rejeita nome duplicado e re-pergunta" {
  CONF_FILE="$BATS_TEST_TMPDIR/e.conf"
  printf 'a|/ws/a|a|m||||true\nb|/ws/b|b|m||||true\n' > "$CONF_FILE"
  load_services 2>/dev/null
  edit_one_service 0 >/dev/null 2>&1 <<'EOF'
b
a2
/ws/a
m


x
true
s
EOF
  [ "${S_NAME[0]}" = "a2" ]
  [ "${S_JVM[0]}" = "x" ]
}

@test "edit_one_service: campo com '|' não é gravado" {
  CONF_FILE="$BATS_TEST_TMPDIR/e.conf"
  printf 'a|/ws/a|a|m||local||true\n' > "$CONF_FILE"
  load_services 2>/dev/null
  edit_one_service 0 >/dev/null 2>&1 <<'EOF'
a
/ws/a
m

tem|pipe

true
EOF
  [ "${S_PROFILE[0]}" = "local" ]
}

# --- scan_executable_modules ------------------------------------------------

@test "scan: detecta módulo aninhado com -pl relativo" {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/proj/apps/web"
  printf '<project><packaging>pom</packaging></project>\n' > "$ws/proj/pom.xml"
  printf '<project><build><plugins><plugin><artifactId>spring-boot-maven-plugin</artifactId></plugin></plugins></build></project>\n' \
    > "$ws/proj/apps/web/pom.xml"
  BASE_DIR="$ws"
  S_NAME=() S_PATH=() S_MOD=()
  scan_executable_modules
  [ "${#SCAN_MOD[@]}" -eq 1 ]
  [ "${SCAN_MOD[0]}" = "apps/web" ]
  [ "${SCAN_PATH[0]}" = "$ws/proj" ]
}

@test "service_key: barra final e barras duplicadas dão a mesma chave" {
  run service_key "/ws/a//" "srv"
  local a="$output"
  run service_key "/ws/a" "srv"
  [ "$output" = "$a" ]
}

@test "service_key: módulo com barra sobrando ou espaço normaliza igual" {
  run service_key "/ws/a" "/apps/web/"
  local a="$output"
  run service_key "/ws/a" "apps/ web"
  [ "$output" = "$a" ]
}

@test "service_key: módulo raiz como '.' equivale a vazio" {
  run service_key "/ws/a" "."
  local a="$output"
  run service_key "/ws/a" ""
  [ "$output" = "$a" ]
}

@test "service_key: symlink e caminho real dão a mesma chave" {
  local ws="$BATS_TEST_TMPDIR/sl"
  mkdir -p "$ws/real"
  ln -s "$ws/real" "$ws/link"
  run service_key "$ws/link" "srv"
  local a="$output"
  run service_key "$ws/real" "srv"
  [ "$output" = "$a" ]
}

@test "scan: cadastrado com barra final não reaparece como novo" {
  local ws="$BATS_TEST_TMPDIR/ws2"
  mkdir -p "$ws/proj/apps/web"
  printf '<project><packaging>pom</packaging></project>\n' > "$ws/proj/pom.xml"
  printf '<project><build><plugins><plugin><artifactId>spring-boot-maven-plugin</artifactId></plugin></plugins></build></project>\n' \
    > "$ws/proj/apps/web/pom.xml"
  BASE_DIR="$ws"
  S_NAME=(web) S_PATH=("$ws/proj/") S_MOD=("apps/web/")
  scan_executable_modules
  [ "${#SCAN_MOD[@]}" -eq 0 ]
}

@test "scan: cadastrado via symlink não reaparece como novo" {
  local ws="$BATS_TEST_TMPDIR/ws3"
  mkdir -p "$ws/proj/apps/web"
  printf '<project><packaging>pom</packaging></project>\n' > "$ws/proj/pom.xml"
  printf '<project><build><plugins><plugin><artifactId>spring-boot-maven-plugin</artifactId></plugin></plugins></build></project>\n' \
    > "$ws/proj/apps/web/pom.xml"
  ln -s "$ws/proj" "$ws/proj-link"
  BASE_DIR="$ws"
  S_NAME=(web) S_PATH=("$ws/proj-link") S_MOD=("apps/web")
  scan_executable_modules
  [ "${#SCAN_MOD[@]}" -eq 0 ]
}

# --- registro em lote ([A] do menu [N]) -------------------------------------

@test "unique_service_name: mantém o nome quando está livre" {
  S_NAME=(outro)
  run unique_service_name "web" "proj"
  [ "$output" = "web" ]
}

@test "unique_service_name: colidindo com cadastrado, prefixa o projeto" {
  S_NAME=(web)
  run unique_service_name "web" "proj"
  [ "$output" = "proj-web" ]
}

@test "unique_service_name: colidindo com nome pendente, prefixa o projeto" {
  S_NAME=()
  run unique_service_name "web" "proj" "web" "api"
  [ "$output" = "proj-web" ]
}

@test "unique_service_name: colisão dupla vira sufixo numérico" {
  S_NAME=(web proj-web)
  run unique_service_name "web" "proj"
  [ "$output" = "proj-web-2" ]
}

@test "add_modules_bulk: registra todos os detectados com os defaults" {
  CONF_FILE="$BATS_TEST_TMPDIR/b.conf"
  : > "$CONF_FILE"
  load_services 2>/dev/null
  SCAN_PATH=(/ws/a /ws/b) SCAN_PROJ=(a b) SCAN_MOD=("srv" "")
  add_modules_bulk 0 1 <<<'s' >/dev/null

  [ "${#S_NAME[@]}" -eq 2 ]
  [ "${S_NAME[0]}" = "srv" ]        # nome do módulo
  [ "${S_NAME[1]}" = "b" ]          # módulo na raiz -> nome do projeto
  [ "${S_WAIT[0]}" = "true" ]
  [ -z "${S_PROFILE[0]}" ]
  grep -q '^srv|/ws/a|a|srv||||true$' "$CONF_FILE"
  grep -q '^b|/ws/b|b|||||true$' "$CONF_FILE"
}

@test "add_modules_bulk: desambigua módulos de mesmo nome em projetos diferentes" {
  CONF_FILE="$BATS_TEST_TMPDIR/b.conf"
  : > "$CONF_FILE"
  load_services 2>/dev/null
  SCAN_PATH=(/ws/a /ws/b) SCAN_PROJ=(a b) SCAN_MOD=(web web)
  add_modules_bulk 0 1 <<<'s' >/dev/null
  [ "${S_NAME[0]}" = "web" ]
  [ "${S_NAME[1]}" = "b-web" ]
}

@test "add_modules_bulk: não colide com serviço já cadastrado" {
  CONF_FILE="$BATS_TEST_TMPDIR/b.conf"
  printf 'web|/ws/x|x|web||||true\n' > "$CONF_FILE"
  load_services 2>/dev/null
  SCAN_PATH=(/ws/a) SCAN_PROJ=(a) SCAN_MOD=(web)
  add_modules_bulk 0 <<<'s' >/dev/null
  [ "${#S_NAME[@]}" -eq 2 ]
  [ "${S_NAME[1]}" = "a-web" ]
}

@test "add_modules_bulk: cancelar (n) não grava nada" {
  CONF_FILE="$BATS_TEST_TMPDIR/b.conf"
  : > "$CONF_FILE"
  load_services 2>/dev/null
  SCAN_PATH=(/ws/a) SCAN_PROJ=(a) SCAN_MOD=(srv)
  add_modules_bulk 0 <<<'n' >/dev/null
  [ "${#S_NAME[@]}" -eq 0 ]
  run grep -c . "$CONF_FILE"
  [ "$output" -eq 0 ]
}

@test "add_modules_bulk: pula módulo com '|' no caminho (quebraria o conf)" {
  CONF_FILE="$BATS_TEST_TMPDIR/b.conf"
  : > "$CONF_FILE"
  load_services 2>/dev/null
  SCAN_PATH=(/ws/a /ws/b) SCAN_PROJ=(a b) SCAN_MOD=('we|b' srv)
  add_modules_bulk 0 1 <<<'s' >/dev/null 2>&1
  [ "${#S_NAME[@]}" -eq 1 ]
  [ "${S_NAME[0]}" = "srv" ]
}

# --- trim -----------------------------------------------------------------

@test "trim: remove espaços nas pontas, preserva no meio" {
  run trim "  a b  "
  [ "$output" = "a b" ]
}
