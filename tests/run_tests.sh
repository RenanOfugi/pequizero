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
check "install do módulo com -pl -am"  '[[ "$out" == *"mvn -pl srv -am install -DskipTests"* ]]'
check "run com -pl do módulo"          '[[ "$out" == *"mvn -pl srv spring-boot:run"* ]]'

S_BUILD=("core,a"); out="$(build_command 0)"
check "install com -pl build_modules"  '[[ "$out" == *"mvn -pl core,a -am install"* ]]'

S_BUILD=(""); S_MOD=(""); out="$(CLEAN=1 build_command 0)"
check "CLEAN=1 força clean install"    '[[ "$out" == *"mvn clean install -DskipTests"* ]]'
S_MOD=(srv)

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

echo "edit_one_service (sem tty: cada linha é o valor final; vazia = limpa)"
CONF_FILE="$TMP/e.conf"
printf 'a|/ws/a|a|srv|core|local|-Dx=1|true\nb|/ws/b|b|m||||true\n' > "$CONF_FILE"
load_services 2>/dev/null
edit_one_service 0 >/dev/null 2>&1 <<'EOF'
a-novo
/ws/novo
srv
core


false
s
EOF
check "renomeia o serviço"              '[ "${S_NAME[0]}" = "a-novo" ]'
check "muda o path"                     '[ "${S_PATH[0]}" = "/ws/novo" ]'
check "apaga profile e jvm_args"        '[ -z "${S_PROFILE[0]}" ] && [ -z "${S_JVM[0]}" ]'
check "conf regravado com os novos valores" 'grep -q "^a-novo|/ws/novo|a|srv|core|||false$" "$CONF_FILE"'
edit_one_service 0 >/dev/null 2>&1 <<'EOF'
b
a2
/ws/novo
srv
core


false
s
EOF
check "nome duplicado é rejeitado"      '[ "${S_NAME[0]}" = "a2" ]'
edit_one_service 0 >/dev/null 2>&1 <<'EOF'
a2
/ws/novo
srv
core
tem|pipe

false
EOF
check "campo com '|' não é gravado"     '[ -z "${S_PROFILE[0]}" ]'

echo "scan_executable_modules (módulo aninhado)"
WS="$TMP/ws"
mkdir -p "$WS/proj/apps/web"
printf '<project><packaging>pom</packaging></project>\n' > "$WS/proj/pom.xml"
printf '<project><build><plugins><plugin><artifactId>spring-boot-maven-plugin</artifactId></plugin></plugins></build></project>\n' \
  > "$WS/proj/apps/web/pom.xml"
BASE_DIR="$WS"
S_NAME=() S_PATH=() S_MOD=()
scan_executable_modules
check "detecta módulo aninhado"         '[ "${#SCAN_MOD[@]}" -eq 1 ] && [ "${SCAN_MOD[0]}" = "apps/web" ]'
check "path é a raiz do projeto"        '[ "${SCAN_PATH[0]:-}" = "$WS/proj" ]'

echo "service_key (dedup normalizada)"
check "barra final == sem barra"        '[ "$(service_key "/ws/a//" srv)" = "$(service_key /ws/a srv)" ]'
check "módulo com barras/espaço iguala" '[ "$(service_key /ws/a "/apps/web/")" = "$(service_key /ws/a "apps/ web")" ]'
check "módulo '.' == raiz (vazio)"      '[ "$(service_key /ws/a .)" = "$(service_key /ws/a "")" ]'
mkdir -p "$TMP/sl/real"; ln -sfn "$TMP/sl/real" "$TMP/sl/link"
check "symlink == caminho real"         '[ "$(service_key "$TMP/sl/link" srv)" = "$(service_key "$TMP/sl/real" srv)" ]'

# Já cadastrado, mas escrito de outra forma: não deve reaparecer como novo.
S_NAME=(web) S_PATH=("$WS/proj/") S_MOD=("apps/web/")
scan_executable_modules
check "cadastrado c/ barra final não reaparece" '[ "${#SCAN_MOD[@]}" -eq 0 ]'

ln -sfn "$WS/proj" "$WS/proj-link"
S_NAME=(web) S_PATH=("$WS/proj-link") S_MOD=("apps/web")
scan_executable_modules
check "cadastrado via symlink não reaparece"    '[ "${#SCAN_MOD[@]}" -eq 0 ]'
rm -f "$WS/proj-link"

echo "registro em lote ([A] do menu [N])"
S_NAME=(web)
check "nome livre é mantido"            '[ "$(S_NAME=(outro); unique_service_name web proj)" = "web" ]'
check "colisão prefixa o projeto"       '[ "$(unique_service_name web proj)" = "proj-web" ]'
check "colisão com pendente prefixa"    '[ "$(S_NAME=(); unique_service_name web proj web)" = "proj-web" ]'
check "colisão dupla usa sufixo"        '[ "$(S_NAME=(web proj-web); unique_service_name web proj)" = "proj-web-2" ]'

CONF_FILE="$TMP/b.conf"
: > "$CONF_FILE"; load_services 2>/dev/null
SCAN_PATH=(/ws/a /ws/b) SCAN_PROJ=(a b) SCAN_MOD=("srv" "")
add_modules_bulk 0 1 <<<'s' >/dev/null
check "registra todos os selecionados"  '[ "${#S_NAME[@]}" -eq 2 ]'
check "nome vem do módulo"              '[ "${S_NAME[0]}" = "srv" ]'
check "módulo na raiz usa o projeto"    '[ "${S_NAME[1]}" = "b" ]'
check "defaults: wait=true, sem profile" '[ "${S_WAIT[0]}" = "true" ] && [ -z "${S_PROFILE[0]}" ]'
check "conf gravado em 8 campos"        'grep -q "^srv|/ws/a|a|srv||||true$" "$CONF_FILE"'

: > "$CONF_FILE"; load_services 2>/dev/null
SCAN_PATH=(/ws/a /ws/b) SCAN_PROJ=(a b) SCAN_MOD=(web web)
add_modules_bulk 0 1 <<<'s' >/dev/null
check "desambigua módulos homônimos"    '[ "${S_NAME[0]}" = "web" ] && [ "${S_NAME[1]}" = "b-web" ]'

: > "$CONF_FILE"; load_services 2>/dev/null
SCAN_PATH=(/ws/a) SCAN_PROJ=(a) SCAN_MOD=(srv)
add_modules_bulk 0 <<<'n' >/dev/null
check "cancelar (n) não grava nada"     '[ "${#S_NAME[@]}" -eq 0 ] && [ ! -s "$CONF_FILE" ]'

: > "$CONF_FILE"; load_services 2>/dev/null
SCAN_PATH=(/ws/a /ws/b) SCAN_PROJ=(a b) SCAN_MOD=("we|b" srv)
add_modules_bulk 0 1 <<<'s' >/dev/null 2>&1
check "pula caminho com '|'"            '[ "${#S_NAME[@]}" -eq 1 ] && [ "${S_NAME[0]}" = "srv" ]'

echo "trim"
check "trim apara pontas"               '[ "$(trim "  a b  ")" = "a b" ]'

echo ""
echo "Resultado: $PASS ok, $FAIL falhas."
[ "$FAIL" -eq 0 ]
