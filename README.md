<p align="center">
  <img src="pequizero.svg" alt="pequizero" width="180">
</p>

<h1 align="center">pequizero</h1>

<p align="center">
  Sobe projetos/módulos Spring Boot (Maven) em uma sessão <strong>tmux</strong>,
  sem precisar de IntelliJ ou qualquer IDE. Cada serviço roda em sua própria janela tmux.
</p>

## Pré-requisitos

`tmux`, `maven` (`mvn`) e `java` instalados e no `PATH`. O script avisa se faltar algum.

## Começando

```bash
cd scripts
./pequizero.sh
```

Na **primeira execução** ele cria as configurações zeradas (`services.conf` e
`services.local.conf`) e pergunta o caminho de uma pasta de projetos. Essa pasta
é o **workspace de scan** — onde a opção `[N]` procura módulos Spring Boot para
registrar. Você começa sem nenhum serviço e cadastra os seus pelo `[N]`.

Ao escolher a pasta, o seletor oferece três formas (sem precisar saber o caminho
de cor):

- **Histórico** — os últimos workspaces usados aparecem numerados; digite o
  número para reusar.
- **`[b]` navegar** — lista as subpastas na tela; número entra, `..` sobe,
  `.` seleciona a pasta atual, `q` cancela.
- **`[d]` digitar** — digite o caminho com **autocompletar por Tab** (como no
  terminal). `~` é expandido.

> **Cada API guarda o próprio caminho.** Você pode registrar APIs de pastas
> diferentes e subir todas juntas — elas não precisam estar na mesma raiz. O
> "workspace" é só a pasta que o scanner está olhando no momento.

## O menu

```
[1..n]  os serviços cadastrados — digite os números na ordem em que quer subir
[g1..n] os grupos — sobem a seleção do grupo na ordem gravada
[A]     todas na ordem padrão (ou só Enter)
[G]     grupos de APIs — criar, editar, remover
[N]     adicionar serviços — um, vários ou todos os detectados no workspace
[E]     editar serviços
[R]     remover serviço
[W]     trocar o workspace (escanear outra pasta)
```

A ordem dos números define a ordem de execução: `6 1 3` sobe o 6º, depois o 1º,
depois o 3º. Serviços com `wait=true` seguram a fila até terminarem de subir
(ou até o timeout — ver [Timeout de startup](#timeout-de-startup)).

Os prompts do menu aceitam edição de linha: `←`/`→` andam com o cursor,
`Backspace`/`Delete` apagam, `Home`/`End` (ou `Ctrl-a`/`Ctrl-e`) vão para as
pontas e `Ctrl-w` apaga a última palavra — dá para corrigir a digitação antes
de confirmar com `Enter`.

## Grupos de APIs — `[G]`

Um **grupo** é uma seleção de APIs com **ordem fixa**, salva com um nome. Em vez
de digitar os mesmos 20 números toda vez, você monta o grupo uma vez e depois
sobe tudo com `g1`.

```
Grupos (sobem na ordem gravada):

[g1] painel-completo (20 API(s): seguranca-api → autenticacao-api → painel-api → categoria-api → …+16)
[g2] minimo          (2 API(s): seguranca-api → worker)
```

**Como usar na seleção:**

| Você digita | O que sobe |
| --- | --- |
| `g1` | as APIs do grupo 1, na ordem gravada |
| `g1 7 2` | o grupo 1 e, depois, o 7º e o 2º serviço |
| `4 g2` | o 4º serviço e, depois, o grupo 2 |
| `g1 g2` | os dois grupos em sequência |

Serviço que apareceria duas vezes (porque está no grupo e você digitou o número
dele também) entra **só na primeira posição** — a ordem não duplica janela.

**Como criar:**

- **`[G]` → `[N]`** — pede o nome e a seleção (`6 1 3`, na ordem de subida).
  Dentro da seleção, outros grupos (`gN`) também valem como atalho.
- **direto da confirmação** — depois de digitar uma ordem no menu, a pergunta
  `Confirma? (S/n) — [g] salva esta ordem como grupo:` aceita `g`: você dá um
  nome e aquela ordem fica salva como grupo.

**Editar e remover:** `[G]` → `[E]` traz o nome e os números atuais
**pré-preenchidos** (edite com as setas e Enter grava) e `[G]` → `[R]` apaga só
o atalho, nunca as APIs.

Os grupos ficam em `groups.conf`, uma linha por grupo:

```
painel-completo|seguranca-api|autenticacao-api|painel-api
```

Como o grupo guarda **nomes** (não posições), reordenar ou adicionar serviços no
`services.conf` não quebra nada. Renomear um serviço pelo `[E]` renomeia dentro
dos grupos; removê-lo pelo `[R]` tira ele dos grupos (e descarta grupo que ficou
vazio). Se algum nome sobrar órfão — por edição à mão, por exemplo — ele aparece
marcado com `(?)` na listagem e é ignorado com aviso na hora de subir.

## Subir, reiniciar e derrubar

Confirmada a seleção, cada serviço é compilado e iniciado em uma **janela tmux**
própria, na sessão `apis`.

- Dentro do tmux: `Ctrl-b n`/`Ctrl-b p` alterna entre as janelas,
  `Ctrl-b d` desanexa sem derrubar nada.
- `Ctrl-C` no terminal do script **só encerra o script** — as APIs continuam
  rodando na sessão `apis` (reanexe com `tmux attach -t apis`).
- Para derrubar tudo de fato: `tmux kill-session -t apis` (ou `[r]` no menu,
  que recria a sessão do zero).

### Sessão já aberta — reiniciar uma API

Se a sessão `apis` já existir quando você confirmar a seleção, o script pergunta
o que fazer:

- **`[u]` Usar a sessão** — sobe os serviços selecionados **na sessão atual**;
  quem já tem janela é **reiniciado** (a janela antiga é substituída, as demais
  não são tocadas). É o jeito de reiniciar uma API que caiu sem derrubar as
  outras: rode o script, selecione só ela e escolha `[u]`.
- **`[r]` Recriar** — mata a sessão e sobe tudo do zero.
- **`[a]` Só anexar** — entra na sessão como está, sem subir nada.
- **`[c]` Cancelar** — não faz nada.

### Build limpo (padrão) e `SKIP_CLEAN=1`

Por padrão o build é **limpo**: `mvn clean install` do módulo e dos módulos de
que ele depende (`-pl <modulo> -am clean install -DskipTests`). Assim renomear
ou remover classes/contratos nunca deixa artefato velho em `target/`.

Se você só mexeu no corpo de métodos e quer o build incremental (bem mais
rápido), pule o `clean`:

```bash
SKIP_CLEAN=1 ./pequizero.sh
```

### Timeout de startup

O tempo máximo aguardando cada serviço subir é **300s** por padrão. Para mudar,
defina no `services.local.conf`:

```bash
TIMEOUT_SECONDS=600
```

## Adicionar serviços — `[N]`

O script **escaneia automaticamente** os módulos Spring Boot executáveis do
workspace atual (módulos com `spring-boot-maven-plugin` e packaging diferente de
`pom`), inclusive módulos aninhados (ex.: `apps/web`). A opção `[N]` lista os
detectados que ainda **não** estão cadastrados, agrupados por projeto:

```
[1] projetoA-api  ▸ categoria-api
[2] projetoB-api  ▸ teste-api
[3] projetoC-api  ▸ apps/web
[A] Registrar TODAS as 3 APIs do workspace
[0] Voltar
```

- **um número** — registra aquele módulo e pergunta o nome do menu (o sugerido
  vem entre `[colchetes]`);
- **vários números** (ex.: `1 3`) — registra em lote, com os nomes sugeridos;
- **`[A]`** — registra de uma vez **todas** as APIs detectadas no workspace.

Em qualquer caso o serviço é gravado no `services.conf` com os padrões: build
incremental do módulo, sem profile, `wait=true`. Depois ajuste
`profile`/`jvm_args` pelo `[E]` se precisar.

### Registrar todas de uma vez — `[A]`

O lote não pergunta nada por módulo: ele mostra a lista com os nomes já
resolvidos e pede **uma** confirmação antes de gravar.

```
--- Registrar 3 API(s) de uma vez ---

  categoria-api  (projetoA-api ▸ categoria-api)
  teste-api      (projetoB-api ▸ teste-api)
  apps/web       (projetoC-api ▸ apps/web)

Registrar essas 3 API(s) no services.conf? (S/n):
```

O nome sai do **módulo** (ou do **projeto**, quando o módulo é a raiz). Se ele
colidir com um serviço já cadastrado ou com outro do mesmo lote, ganha o projeto
como prefixo (`projetoB-api-teste-api`) e, se ainda colidir, um sufixo numérico. Renomeie
depois pelo `[E]` — nada é sobrescrito.

Como o default é `wait=true`, subir tudo com `[A]` no menu principal aguarda cada
API terminar de inicializar antes da próxima. Para paralelizar, mude `wait` para
`false` nas que não precisam segurar a fila.

Para registrar APIs de **outra pasta**, troque o workspace com `[W]` (os
serviços já cadastrados são preservados) e use o `[N]` de novo. Pela linha de
comando, o equivalente ao `[W]` é `./pequizero.sh --reconfigure`.

## Editar um serviço — `[E]`

Todos os campos — inclusive **nome** e **path** — aparecem **pré-preenchidos**
com o valor atual:

- edite o texto direto na linha;
- **apague tudo para limpar o campo** (ex.: remover um profile);
- Enter sem mexer mantém o valor.

O editor valida na hora: nome não pode ficar vazio nem duplicar outro serviço,
`wait` só aceita `true`/`false`, e nenhum campo pode conter `|` (separador do
arquivo). No fim ele mostra o que mudou e pede confirmação antes de gravar.

## Remover um serviço — `[R]`

Lista os serviços cadastrados; você escolhe um e confirma (padrão "não"). Remove
só a linha do `services.conf` — nenhum arquivo do projeto é tocado.

## Arquivos de configuração

| Arquivo | O que guarda | Versionado? |
|---|---|---|
| `services.conf` | A definição dos serviços (uma linha por serviço) | sim (começa vazio) |
| `groups.conf` | Os grupos de APIs (nome + seleção em ordem) — criado no 1º grupo | não (só na sua máquina) |
| `services.local.conf` | `BASE_DIR`, `TIMEOUT_SECONDS`, histórico de workspaces e as variáveis dos `jvm_args` | não (só na sua máquina) |

Prefira o menu (`[N]`/`[E]`/`[R]`), mas dá para editar o `services.conf` à mão.
Cada linha:

```
nome | path | projeto | modulo | build_modules | profile | jvm_args | wait
```

- **path** — caminho **absoluto** do projeto (onde roda o `cd`). Quem registra
  pelo `[N]` já preenche automaticamente.
- **modulo** — módulo do `spring-boot:run` (relativo à raiz do projeto, ex.:
  `apps/web`). Vazio = projeto na raiz.
- **build_modules** — módulos extras para o `mvn clean install`. Vazio = build do
  módulo (com dependências) ou do projeto todo se `modulo` também for vazio.
- **profile** — Spring profile. Vazio = nenhum.
- **jvm_args** — argumentos JVM; pode referenciar variáveis (abaixo).
- **wait** — `true`/`false`: aguardar o startup antes do próximo serviço.

### Variáveis e segredos nos `jvm_args`

Os `jvm_args` podem referenciar **qualquer** variável definida no
`services.local.conf` (ex.: `-Dtoken=$API_TOKEN`). O valor **não** vai para o
comando: a referência `$VAR` fica literal e o valor é injetado no ambiente da
janela tmux na hora de subir — não passa por `eval` e não aparece no
comando nem no scrollback. Coloque só a referência no `services.conf`; os
valores ficam no `services.local.conf`, que não é versionado.

Há um modelo comentado em `services.local.conf.example`.

## Dicas

- `-h`/`--help` mostra um resumo de tudo isso no terminal.
- A saída é colorida; as cores desligam sozinhas fora de terminal (pipe,
  redirecionamento) ou com `NO_COLOR=1`.
- Se um serviço com `wait=true` falhar ao subir, o script pergunta se continua
  com os próximos ou aborta — a janela tmux dele fica aberta com o log do erro.

## Testes (para quem for mexer no script)

```bash
./tests/run_tests.sh        # sem dependências
bats tests/pequizero.bats   # com bats-core instalado
```
