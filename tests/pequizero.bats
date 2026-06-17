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

@test "build_command: build full quando build_modules vazio" {
  S_PATH=(/ws/p) S_PROJ=(p) S_MOD=(srv) S_BUILD=("") S_PROFILE=("") S_JVM=("")
  run build_command 0
  [[ "$output" == *'cd "/ws/p"'* ]]
  [[ "$output" == *"mvn clean install -DskipTests"* ]]
  [[ "$output" == *"mvn -pl srv spring-boot:run"* ]]
}

@test "build_command: usa -pl no install quando build_modules definido" {
  S_PATH=(/ws/p) S_PROJ=(p) S_MOD=(a) S_BUILD=("core,security,a") S_PROFILE=("") S_JVM=("")
  run build_command 0
  [[ "$output" == *"mvn -pl core,security,a clean install"* ]]
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

# --- trim -----------------------------------------------------------------

@test "trim: remove espaços nas pontas, preserva no meio" {
  run trim "  a b  "
  [ "$output" = "a b" ]
}
