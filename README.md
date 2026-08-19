<p align="center">
  <img src="pequizero.svg" alt="pequizero" width="180">
</p>

<h1 align="center">pequizero</h1>

<p align="center">
  <strong>Sobe seus microsserviços Spring Boot em uma sessão tmux — sem IDE.</strong>
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green.svg"></a>
  <img alt="Bash" src="https://img.shields.io/badge/shell-bash%204%2B-4EAA25?logo=gnubash&logoColor=white">
  <img alt="tmux" src="https://img.shields.io/badge/tmux-required-1BB91F?logo=tmux&logoColor=white">
</p>

---

Rodar um monorepo de microsserviços na mão é repetitivo: um `mvn install` aqui,
um `spring-boot:run` ali, uma aba de terminal para cada, na ordem certa, e ainda
esperar cada um subir antes do próximo.

O **pequizero** faz isso por você. Ele escaneia suas pastas, encontra os módulos
Spring Boot executáveis, e sobe os que você escolher — cada um em sua própria
janela `tmux`, na ordem que você definir, aguardando o startup quando necessário.

Um único script Bash, sem dependências além de `tmux`, `maven` e `java`.

## Recursos

- **Descoberta automática** — encontra módulos com `spring-boot-maven-plugin`,
  inclusive aninhados, em qualquer pasta que você aponte.
- **Ordem de execução explícita** — `6 1 3` sobe o 6º, depois o 1º, depois o 3º.
- **Grupos nomeados** — salve uma seleção com ordem fixa e suba tudo com `g1`.
- **Espera de startup** — serviços marcados com `wait=true` seguram a fila até
  terminarem de inicializar (com timeout configurável).
- **Restart cirúrgico** — reinicie um serviço que caiu sem derrubar os outros.
- **Multi-repositório** — cada serviço guarda seu próprio caminho; eles não
  precisam estar sob a mesma raiz.
- **Segredos fora do comando** — variáveis dos `jvm_args` são injetadas no
  ambiente da janela tmux, sem aparecer na linha de comando nem no scrollback.
- **Menu interativo** com edição de linha, autocompletar de caminhos e cores.

## Sumário

- [Requisitos](#requisitos)
- [Instalação](#instalação)
- [Primeira execução](#primeira-execução)
- [O menu](#o-menu)
- [Grupos de APIs](#grupos-de-apis--g)
- [Subir, reiniciar e derrubar](#subir-reiniciar-e-derrubar)
- [Build](#build)
- [Cadastrar serviços](#cadastrar-serviços--n)
- [Editar e remover](#editar-um-serviço--e)
- [Configuração](#configuração)
- [Referência de CLI](#referência-de-cli)
- [Desenvolvimento](#desenvolvimento)
- [Licença](#licença)

## Requisitos

| Dependência | Observação |
|---|---|
| `bash` 4+ | arrays associativos, `mapfile`, `${var,,}` |
| `tmux` | uma janela por serviço |
| `maven` (`mvn`) | build e `spring-boot:run` |
| `java` | o JDK que seus projetos exigem |

O script verifica tudo na inicialização e avisa o que estiver faltando.

## Instalação

```bash
git clone https://github.com/RenanOfugi/pequizero.git
cd pequizero
./pequizero.sh
```

Opcionalmente, coloque no `PATH`. O script resolve symlinks, então os arquivos
de configuração continuam ao lado do script real:

```bash
ln -s "$PWD/pequizero.sh" ~/.local/bin/pequizero
```

## Primeira execução

Na primeira vez, o pequizero cria as configurações **zeradas** e pergunta o
caminho de uma pasta de projetos. Essa pasta é o **workspace de scan** — onde a
opção `[N]` procura módulos Spring Boot para registrar. Você começa sem nenhum
serviço e cadastra os seus pelo `[N]`.

Para escolher a pasta há três caminhos (nenhum exige saber o path de cor):

- **Histórico** — os últimos workspaces usados aparecem numerados; digite o
  número para reusar.
- **`[b]` navegar** — lista as subpastas na tela; número entra, `..` sobe,
  `.` seleciona a pasta atual, `q` cancela.
- **`[d]` digitar** — digite o caminho com **autocompletar por Tab** (como no
  terminal). `~` é expandido.

> [!TIP]
> **Cada serviço guarda o próprio caminho.** Você pode registrar serviços de
> pastas diferentes e subir todos juntos — eles não precisam estar na mesma
> raiz. O "workspace" é só a pasta que o scanner está olhando no momento.

## O menu

```
[1..n]  os serviços cadastrados — digite os números na ordem em que quer subir
[g1..n] os grupos — sobem a seleção do grupo na ordem gravada
[A]     todos na ordem padrão (ou só Enter)
[G]     grupos de APIs — criar, editar, remover
[N]     adicionar serviços — um, vários ou todos os detectados no workspace
[E]     editar serviços
[R]     remover serviço
[W]     trocar o workspace (escanear outra pasta)
```

A ordem dos números define a ordem de execução: `6 1 3` sobe o 6º, depois o 1º,
depois o 3º. Serviços com `wait=true` seguram a fila até terminarem de subir
(ou até o timeout — ver [Timeout de startup](#timeout-de-startup)).

Os prompts aceitam edição de linha: `←`/`→` andam com o cursor,
`Backspace`/`Delete` apagam, `Home`/`End` (ou `Ctrl-a`/`Ctrl-e`) vão para as
pontas e `Ctrl-w` apaga a última palavra — dá para corrigir a digitação antes
de confirmar com `Enter`.

## Grupos de APIs — `[G]`

Um **grupo** é uma seleção de serviços com **ordem fixa**, salva com um nome. Em
vez de digitar os mesmos 20 números toda vez, você monta o grupo uma vez e
depois sobe tudo com `g1`.

```
Grupos (sobem na ordem gravada):

[g1] stack-completa (12 API(s): auth-api → gateway-api → pedidos-api → estoque-api → …+8)
[g2] minimo         (2 API(s): auth-api → worker)
```

**Como usar na seleção:**

| Você digita | O que sobe |
| --- | --- |
| `g1` | os serviços do grupo 1, na ordem gravada |
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
o atalho, nunca os serviços.

Os grupos ficam em `groups.conf`, uma linha por grupo:

```
stack-completa|auth-api|gateway-api|pedidos-api
```

Como o grupo guarda **nomes** (não posições), reordenar ou adicionar serviços no
`services.conf` não quebra nada. Renomear um serviço pelo `[E]` renomeia dentro
dos grupos; removê-lo pelo `[R]` tira ele dos grupos (e descarta grupo que ficou
vazio). Se algum nome sobrar órfão — por edição à mão, por exemplo — ele aparece
marcado com `(?)` na listagem e é ignorado com aviso na hora de subir.

## Subir, reiniciar e derrubar

Confirmada a seleção, cada serviço é compilado e iniciado em uma **janela tmux**
própria, na sessão `apis`.

- Dentro do tmux: `Ctrl-b n`/`Ctrl-b p` alternam entre as janelas,
  `Ctrl-b d` desanexa sem derrubar nada.
- `Ctrl-C` no terminal do script **só encerra o script** — os serviços continuam
  rodando na sessão `apis` (reanexe com `tmux attach -t apis`).
- Para derrubar tudo: `tmux kill-session -t apis`.

### Sessão já aberta — reiniciar um serviço

Se a sessão `apis` já existir quando você confirmar a seleção, o script pergunta
o que fazer:

- **`[u]` Usar a sessão** — sobe os serviços selecionados **na sessão atual**;
  quem já tem janela é **reiniciado** (a janela antiga é substituída, as demais
  não são tocadas). É o jeito de reiniciar um serviço que caiu sem derrubar os
  outros: rode o script, selecione só ele e escolha `[u]`.
- **`[r]` Recriar** — mata a sessão e sobe tudo do zero.
- **`[a]` Só anexar** — entra na sessão como está, sem subir nada.
- **`[c]` Cancelar** — não faz nada.

Se um serviço com `wait=true` falhar ao subir, o script pergunta se continua com
os próximos ou aborta — a janela tmux dele fica aberta com o log do erro.

## Build

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

O startup é detectado lendo a saída da janela tmux (`Started ... in ... seconds`,
`Tomcat started on port`, `ACCEPTING_TRAFFIC`); falhas são detectadas por
`BUILD FAILURE`, `APPLICATION FAILED TO START` e afins.

## Cadastrar serviços — `[N]`

O script **escaneia automaticamente** os módulos Spring Boot executáveis do
workspace atual (módulos com `spring-boot-maven-plugin` e packaging diferente de
`pom`), inclusive módulos aninhados (ex.: `apps/web`). A opção `[N]` lista os
detectados que ainda **não** estão cadastrados, agrupados por projeto:

```
[1] loja       ▸ pedidos-api
[2] loja       ▸ estoque-api
[3] backoffice ▸ apps/web
[A] Registrar TODAS as 3 APIs do workspace
[0] Voltar
```

- **um número** — registra aquele módulo e pergunta o nome do menu (o sugerido
  vem entre `[colchetes]`);
- **vários números** (ex.: `1 3`) — registra em lote, com os nomes sugeridos;
- **`[A]`** — registra de uma vez **todos** os módulos detectados no workspace.

Em qualquer caso o serviço é gravado no `services.conf` com os padrões: build do
módulo mais suas dependências, sem profile, `wait=true`. Depois ajuste
`profile`/`jvm_args` pelo `[E]` se precisar.

### Registrar todos de uma vez — `[A]`

O lote não pergunta nada por módulo: ele mostra a lista com os nomes já
resolvidos e pede **uma** confirmação antes de gravar.

```
--- Registrar 3 API(s) de uma vez ---

  pedidos-api  (loja ▸ pedidos-api)
  estoque-api  (loja ▸ estoque-api)
  apps/web     (backoffice ▸ apps/web)

Registrar essas 3 API(s) no services.conf? (S/n):
```

O nome sai do **módulo** (ou do **projeto**, quando o módulo é a raiz). Se ele
colidir com um serviço já cadastrado ou com outro do mesmo lote, ganha o projeto
como prefixo (`backoffice-pedidos-api`) e, se ainda colidir, um sufixo numérico.
Renomeie depois pelo `[E]` — nada é sobrescrito.

Como o default é `wait=true`, subir tudo com `[A]` no menu principal aguarda
cada serviço terminar de inicializar antes do próximo. Para paralelizar, mude
`wait` para `false` nos que não precisam segurar a fila.

Para registrar serviços de **outra pasta**, troque o workspace com `[W]` (os
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
só a linha do `services.conf` — nenhum arquivo do seu projeto é tocado.

## Configuração

A configuração é **individual de cada usuário**: os três arquivos são gerados
pela própria ferramenta, na sua máquina, com os seus projetos e caminhos. Por
isso **nenhum deles é versionado** — todos estão no `.gitignore`, e o que você
cadastra nunca vai para o repositório. Cada pessoa que clona o pequizero começa
com a configuração zerada e monta a sua.

| Arquivo | O que guarda | Criado quando |
|---|---|---|
| `services.conf` | A definição dos serviços (uma linha por serviço) | 1ª execução |
| `services.local.conf` | `BASE_DIR`, `TIMEOUT_SECONDS`, histórico de workspaces e as variáveis dos `jvm_args` | 1ª execução |
| `groups.conf` | Os grupos (nome + seleção em ordem) | no 1º grupo criado |

Há um modelo comentado em [`services.local.conf.example`](services.local.conf.example).

### Formato do `services.conf`

Prefira o menu (`[N]`/`[E]`/`[R]`), mas dá para editar à mão. Cada linha:

```
nome | path | projeto | modulo | build_modules | profile | jvm_args | wait
```

| Campo | Descrição |
|---|---|
| `nome` | Nome exibido no menu e na janela tmux |
| `path` | Caminho **absoluto** do projeto (onde roda o `cd`). O `[N]` preenche |
| `projeto` | Nome curto do projeto — usado em rótulos e desambiguação |
| `modulo` | Módulo do `spring-boot:run`, relativo à raiz (ex.: `apps/web`). Vazio = raiz |
| `build_modules` | Módulos extras para o `mvn install`. Vazio = módulo + dependências |
| `profile` | Spring profile. Vazio = nenhum |
| `jvm_args` | Argumentos JVM; pode referenciar variáveis (abaixo) |
| `wait` | `true`/`false`: aguardar o startup antes do próximo serviço |

Linhas em branco e comentários (`#`) são ignorados. O formato antigo de 7 campos
(sem `path`) é migrado automaticamente para 8, reconstruindo
`path = $BASE_DIR/$projeto`.

### Variáveis e segredos nos `jvm_args`

Os `jvm_args` podem referenciar **qualquer** variável definida no
`services.local.conf` (ex.: `-Dtoken=$API_TOKEN`).

O valor **não** vai para o comando: a referência `$VAR` fica literal e o valor é
injetado no ambiente da janela tmux na hora de subir — não passa por `eval` e
não aparece no comando nem no scrollback. Coloque só a referência no
`services.conf`; os valores ficam no `services.local.conf`.

```bash
# services.local.conf
API_TOKEN="valor-real-aqui"
```

```
# services.conf
gateway-api|/home/eu/projetos/loja|loja|gateway||dev|-Dtoken=$API_TOKEN|true
```

Se um `jvm_args` referencia uma variável que não existe no conf local, o script
avisa na inicialização (ela expandiria para vazio).

> [!WARNING]
> Segredos são gravados em texto puro no `services.local.conf`. O arquivo é
> criado com permissão `600`, mas trate-o como qualquer arquivo de credenciais:
> nunca o versione nem o compartilhe.

## Referência de CLI

```
Uso: pequizero.sh [opções]
```

| Opção | Efeito |
|---|---|
| _(nenhuma)_ | Abre o menu interativo |
| `-h`, `--help` | Resumo da ajuda no terminal |
| `--reconfigure` | Refaz a pergunta do workspace e regrava a escolha |

| Variável de ambiente | Efeito |
|---|---|
| `SKIP_CLEAN=1` | Build incremental (`mvn install`, sem `clean`) |
| `NO_COLOR=1` | Desliga as cores (também desligam sozinhas fora de terminal) |

## Desenvolvimento

O projeto é um único script Bash (`pequizero.sh`) com suíte de testes. As funções
são carregáveis por `source` sem executar nada — o `main` só roda quando o script
é invocado diretamente.

```bash
./tests/run_tests.sh        # runner standalone, sem dependências
bats tests/pequizero.bats   # suíte completa (requer bats-core)
```

Contribuições são bem-vindas. Antes de abrir um PR:

1. rode as duas suítes de teste;
2. adicione teste para o comportamento que você mudou;
3. mantenha o estilo do script (`set -uo pipefail`, funções pequenas, mensagens
   pelos helpers `die`/`warn`/`info`/`success`);
4. não versione configuração local.

## Licença

[MIT](LICENSE).
