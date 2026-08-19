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
- **Guarda de `bash` 4+** com mensagem legível, em vez de falhar com
  `bad substitution` no bash 3.2 do macOS.

### Alterado

- A sugestão de workspace na 1ª execução agora considera o modo de instalação:
  a pasta irmã do repositório no clone, o diretório atual quando instalado no
  `PATH` (antes sugeria `~/.local/bin`, que não é workspace de nada).

### Compatibilidade

- Instalação via clone segue guardando os `.conf` ao lado do script.
- Instalação anterior que já tenha `.conf` junto do executável continua usando
  aquele diretório — atualizar não move configuração de lugar.
- `services.conf` no formato antigo de 7 campos continua sendo lido e migrado
  automaticamente para 8 campos. A migração regrava o arquivo e preserva apenas
  o bloco de comentários do topo: comentários entre as linhas de serviço são
  descartados.
