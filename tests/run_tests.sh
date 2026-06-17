#!/bin/bash
#
# Runner de testes standalone — NÃO requer bats. Usa as mesmas funções do
# pequizero.sh (sourced). Para a suíte completa/CI, prefira bats:
#   bats tests/pequizero.bats
#
# Uso: ./tests/run_tests.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/pequizero.sh"

PASS=0 FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
no()   { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE_DIR="$TMP"

echo "build_command (usa S_PATH como cd)"
LOCAL_VARS=()
S_PATH=(/ws/p) S_PROJ=(p) S_MOD=(srv) S_BUILD=("") S_PROFILE=("") S_JVM=("") S_WAIT=(true)
out="$(build_command 0)"
check "cd usa o caminho da API"        '[[ "$out" == *"cd \"/ws/p\""* ]]'
check "install full sem build_modules" '[[ "$out" == *"mvn clean install -DskipTests"* ]]'
check "run com -pl do módulo"          '[[ "$out" == *"mvn -pl srv spring-boot:run"* ]]'

S_BUILD=("core,a"); out="$(build_command 0)"
check "install com -pl build_modules"  '[[ "$out" == *"mvn -pl core,a clean install"* ]]'

S_BUILD=(""); S_PROFILE=("local"); out="$(build_command 0)"
check "adiciona profile"               '[[ "$out" == *"profiles=local"* ]]'

echo "segurança (P0.1 / vazamento)"
S_PROFILE=(""); S_JVM=('-Dx=$(touch '"$TMP"'/pwned)'); rm -f "$TMP/pwned"
out="$(build_command 0)"
check "injeção \$(...) NÃO executa"     '[ ! -f "$TMP/pwned" ]'
check "\$(...) fica literal"            '[[ "$out" == *"\$(touch"* ]]'

LOCAL_VARS=(TOKEN); TOKEN="segredo123"; S_JVM=('-Dt=$TOKEN'); S_NAME=(s)
out="$(build_command 0)"
check "valor não vaza no comando"       '[[ "$out" != *"segredo123"* ]]'
fl="$(service_env_flags 0)"
check "env flag injeta a variável"      '[[ "$fl" == *"TOKEN=segredo123"* ]]'

echo "load_services (formato + migração)"
BASE_DIR="/ws"
CONF_FILE="$TMP/c.conf"
printf 'ok|p|m|true\n' > "$CONF_FILE"          # 4 campos: inválido
( load_services ) 2>/dev/null
check "rejeita nº de campos inválido"   '[ $? -ne 0 ]'
printf 'ok|/ws/p|p|m||||true\n' > "$CONF_FILE"; load_services 2>/dev/null
check "aceita 8 campos (novo)"          '[ "${#S_NAME[@]}" -eq 1 ] && [ "${S_PATH[0]}" = "/ws/p" ]'
printf 'old|p|m||||true\n' > "$CONF_FILE"; load_services 2>/dev/null
check "migra 7 campos -> path=BASE/proj" '[ "${S_PATH[0]}" = "/ws/p" ]'
check "migração regrava 8 campos no conf" 'grep -q "old|/ws/p|p|" "$CONF_FILE"'
printf 'x|/ws/p|p|m||||talvez\n' > "$CONF_FILE"; load_services 2>/dev/null
check "wait inválido -> false"          '[ "${S_WAIT[0]}" = "false" ]'

echo "remove_one_service"
CONF_FILE="$TMP/r.conf"
printf 'a|/ws/a|a|m||||true\nb|/ws/b|b|m||||true\nc|/ws/c|c|m||||true\n' > "$CONF_FILE"
load_services 2>/dev/null
remove_one_service 1 <<<'s' >/dev/null    # remove o do meio (b), confirmando
check "remove do meio (sobra a,c)"      '[ "${S_NAME[*]}" = "a c" ]'
check "arrays alinhados após remover"   '[ "${S_PATH[*]}" = "/ws/a /ws/c" ]'
check "conf regravado sem o removido"   '! grep -q "^b|" "$CONF_FILE"'
remove_one_service 0 <<<'n' >/dev/null    # cancela
check "cancelar (N) mantém"             '[ "${#S_NAME[@]}" -eq 2 ]'

echo "trim"
check "trim apara pontas"               '[ "$(trim "  a b  ")" = "a b" ]'

echo ""
echo "Resultado: $PASS ok, $FAIL falhas."
[ "$FAIL" -eq 0 ]
