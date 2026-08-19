# Changelog

Todas as mudanças relevantes deste projeto. O formato segue
[Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/), e as versões
seguem [SemVer](https://semver.org/lang/pt-BR/).

## [1.0.0]

Primeira release publicada — dá para instalar e atualizar sem clonar o
repositório.

### Adicionado

- **Instalação por release**: um `curl` baixa o script para o `PATH`; o mesmo
  comando atualiza.
- **`--update`**: baixa a última release por cima do próprio script. Valida a
  sintaxe do download antes de instalar, substitui via `mv` (não corrompe a
  execução em curso) e se recusa a sobrescrever uma instalação via clone.
- **`-v` / `--version`**.
- **Configuração em XDG**: instalado no `PATH`, os `.conf` vão para
  `$XDG_CONFIG_HOME/pequizero` (padrão `~/.config/pequizero`) em vez de ficarem
  ao lado do executável. `--help` mostra o diretório em uso.
- **Guarda de `bash` 4.4+** com mensagem legível, em vez de falhar com
  `bad substitution` no bash 3.2 do macOS. O piso é 4.4 (e não 4.0) porque até
  o 4.3 expandir array vazio com `"${arr[@]}"` sob `set -u` aborta o script — o
  que acontecia em toda janela de serviço sem variáveis nos `jvm_args`.
- **Checagem da versão do tmux para o `-e`**: o flag que injeta as variáveis
  dos `jvm_args` chegou ao `new-window` no tmux 3.0 e ao `new-session` só no
  3.2. Agora, quando um serviço usa variáveis, o pequizero avisa qual é e o que
  fazer, em vez de deixar o tmux falhar com `unknown option`. Serviços sem
  variáveis seguem funcionando em tmux 2.x.
- Seção **Desinstalar** no README.

### Corrigido

- **Navegador de pastas (`[b]`) em Alpine/BusyBox**: usava `find -printf`, que
  é extensão GNU. O erro caía em `/dev/null` e a lista aparecia vazia sem
  explicação. Agora usa glob do shell — sem comando externo, já ordenado, e
  passou a listar também symlinks para diretório (o `find -type d` os excluía).

### Alterado

- A sugestão de workspace na 1ª execução agora considera o modo de instalação:
  a pasta irmã do repositório no clone, o diretório atual quando instalado no
  `PATH` (antes sugeria `~/.local/bin`, que não é workspace de nada).

### Compatibilidade

- Requer `bash` 4.4+ e, para serviços com variáveis nos `jvm_args`, `tmux` 3.2+
  (3.0+ se o serviço não for o primeiro a subir). Distros ainda em uso com
  versões abaixo disso: RHEL/CentOS 7 (bash 4.2), Ubuntu 20.04 e Debian 11
  (tmux 3.0/3.1), RHEL 8 (tmux 2.7).
- Instalação via clone segue guardando os `.conf` ao lado do script.
- Instalação anterior que já tenha `.conf` junto do executável continua usando
  aquele diretório — atualizar não move configuração de lugar.
- `services.conf` no formato antigo de 7 campos continua sendo lido e migrado
  automaticamente para 8 campos. A migração regrava o arquivo e preserva apenas
  o bloco de comentários do topo: comentários entre as linhas de serviço são
  descartados.
