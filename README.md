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

## Como usar

```bash
cd scripts
./pequizero.sh
```

Na **primeira execução** ele cria as duas configurações zeradas
(`services.conf` e `services.local.conf`) e pergunta o caminho de uma pasta de
projetos (repetindo até você informar uma pasta que exista). Essa pasta é o
**workspace de scan** — onde o `[N]` procura módulos para adicionar. Se algum
serviço precisar de variáveis nos `jvm_args`, adicione-as no `services.local.conf`.
As configs ficam só na sua máquina (não são versionadas); você começa sem
nenhum serviço e registra os seus pelo `[N]`.

> **Cada API guarda o próprio caminho.** Você pode registrar APIs de pastas
> diferentes e subir todas juntas — elas não precisam estar na mesma raiz. O
> "workspace" é só a pasta que o scanner está olhando no momento.

Para **escanear outra pasta** e registrar APIs de lá, use **`[W] Trocar
workspace`** no menu (os serviços já registrados são preservados). Pela linha de
comando, o equivalente é:

```bash
./pequizero.sh --reconfigure
```

Ao escolher a pasta, o seletor oferece três formas (sem precisar saber o caminho
de cor):

- **Histórico** — os últimos workspaces escaneados aparecem numerados; digite o
  número para reusar.
- **`[b]` navegar** — lista as subpastas; número entra, `..` sobe, `.` seleciona
  a pasta atual.
- **`[d]` digitar** — digita o caminho com **autocompletar por Tab** (como no
  terminal). `~` é expandido.

No menu você digita os números dos serviços **na ordem** que quer subir
(ex: `6 1 3`), ou `A`/Enter para todos na ordem padrão.

- `Ctrl-C` no terminal derruba a sessão tmux inteira.
- Dentro do tmux: `Ctrl-b n`/`Ctrl-b p` alterna entre as janelas,
  `Ctrl-b d` desanexa sem derrubar.

A saída é colorida em terminal. As cores são desligadas automaticamente quando
a saída não é um terminal (pipe, redirecionamento) ou quando `NO_COLOR=1` está
definido no ambiente.

## Configurar serviços

Edite `services.conf` à mão ou pela opção **`[E]`** do menu. Cada linha:

```
nome | path | projeto | modulo | build_modules | profile | jvm_args | wait
```

O `path` é o caminho **absoluto** do projeto (onde roda o `cd`) — por isso cada
API pode vir de uma pasta diferente. Quem registra pelo `[N]` já preenche o
`path` automaticamente.

Os `jvm_args` podem referenciar **qualquer** variável que você defina no
`services.local.conf` (ex.: `-Dtoken=$API_TOKEN`). O valor não é colocado no
comando: a referência `$VAR` fica literal e o valor é injetado no ambiente da
janela tmux na hora de subir. Assim o conteúdo nunca passa por `eval` e valores
sensíveis não aparecem no comando nem no scrollback do tmux. Coloque só a
referência `$VAR` no `services.conf`; os valores vão no `services.local.conf`.

## Testes

As funções de parsing/montagem têm testes. Rodar sem dependências:

```bash
./tests/run_tests.sh
```

Ou, com [bats-core](https://github.com/bats-core/bats-core) instalado:

```bash
bats tests/pequizero.bats
```

## Adicionar um sistema novo

O script **escaneia automaticamente** todos os módulos Spring Boot executáveis
do workspace atual (módulos com `spring-boot-maven-plugin` e packaging diferente
de `pom`). Para escanear outra pasta, troque o workspace com **`[W]`** antes. No
menu, a opção **`[N] Adicionar novo serviço`** lista os módulos detectados que
ainda **não** estão no `services.conf`, agrupados por projeto:

```
[1] projetoA-api  ▸ categoria-api
[2] projetoB-api  ▸ teste-api
[3] projetoC-api  ▸ server
...
```

Você escolhe um, dá um nome (ou aceita o sugerido) e ele é gravado no
`services.conf` com os padrões: build completo (`mvn install` sem `-pl`),
`mvn -pl <modulo> spring-boot:run`, sem profile, `wait=true`. Depois é só
ajustar `profile`/`jvm_args` pela opção **`[E] Editar`** se aquele serviço
precisar.

Assim a ferramenta consegue subir **qualquer** sistema da pasta, não só os
pré-cadastrados.

## Remover um serviço

A opção **`[R] Remover serviço`** no menu lista os serviços cadastrados; você
escolhe um, confirma (a remoção pede confirmação, padrão "não") e ele é apagado
do `services.conf`. Remover não toca em nenhum arquivo do projeto — só na
configuração.
