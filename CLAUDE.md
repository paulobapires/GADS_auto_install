# CLAUDE.md: contexto do projeto gads_install

## O que é

Dois instaladores bash autocontidos para um ambiente GADS (device farm) em
Ubuntu amd64, executados como root e configurados como serviços systemd:

- `gads-hub-install.sh` + `gads-hub.conf`: hub (UI/API) e MongoDB via Docker (opcional)
- `gads-provider-install.sh` + `gads-provider.conf`: provider, com Appium 2 e
  toolchains de Android, Android TV, iOS, Tizen e webOS

Cada script é **autocontido de propósito**: o usuário copia só o par
`script + .conf` para o host. Não extraia uma lib compartilhada. Os helpers
duplicados (`set_kv`, `download`, `resolve_gads_tag`, `install_gads_binary`...)
devem ser mantidos iguais nos dois scripts.

Documentação para o usuário: `README.md` e `docs/` (em pt-BR). O **porquê** das
escolhas está em `docs/decisoes-tecnicas.md`; leia antes de mudar versões ou fluxos.

## Convenções

- Mensagens, comentários e docs em **português (pt-BR)**.
- `set -Eeuo pipefail` + trap de ERR. Em pipelines que podem não casar nada
  (`grep`), use `|| true`, senão o pipefail dispara o trap.
- Idempotência é requisito: toda etapa verifica o estado atual antes de agir
  (versão instalada, arquivo presente, contêiner existente).
- `/etc/sysconfig/gads` é compartilhado por hub e provider. Altere apenas via
  `set_kv`/`unset_kv` (chave a chave), nunca sobrescrevendo o arquivo. O systemd
  não expande variáveis ali.
- `.gitattributes` força LF em `*.sh`/`*.conf`/`*.md` (o Windows do autor usa
  `core.autocrlf=true`).
- Rode `shellcheck -S warning` nos dois scripts antes de concluir qualquer
  alteração (há shellcheck instalado na VM de teste).

## Armadilhas já conhecidas (não regredir)

- **A API do hub muda entre releases.** `opus-test` (a mais recente) embrulha
  as respostas em `{"success","message","result"}`, envia o WDA por
  `/admin/files/webdriveragent` e o referencia por id (`web_driver_agent_ipa`),
  além de ter `provide_androidtv`/`provide_roku`. A `main` antiga responde sem
  envelope e usa `/admin/upload-file`. Use `hub_call` + `hub_result`
  (`(.result? // .)`).
- **O provider não inicia** sem a configuração dele no hub e, com iOS
  habilitado, sem um WDA `.ipa` no MongoDB. Por isso o registro desabilita o
  iOS quando não há WDA.
- **Appium precisa ser 2.x**: `appium-tizen-tv-driver` e `appium-lg-webos-driver`
  só têm peer Appium 2. As versões fixadas estão em `gads-provider.conf`.
- **Plugin `appium-gads`**: a release do GADS fixa a versão (ex.: 0.0.11) e a
  instala ao iniciar. Não pré-instale por padrão.
- **Instalador do Tizen recusa root** (checa `whoami`): contornado com um
  `whoami` falso no PATH apenas durante a execução.
- **O webOS CLI npm (`@webos-tools/cli`) não tem `ares-extend-dev`**, que o
  driver webOS chama por padrão. Existe um substituto (`GADS_SHIM`) em
  `CLI/bin`.
- **cmdline-tools 23+** (2026): o `sdkmanager` está deprecated e lista pacotes
  como `build-tools/X.Y.Z` (antes `build-tools;X.Y.Z`). A instalação com `;`
  ainda funciona.
- `appium driver doctor` localiza o `bundletool.jar` com `which`, então o jar
  precisa ter bit de execução.
- Units systemd não aceitam comentário no fim da linha (a documentação oficial
  tem `WorkingDirectory=/root/GADS  # Adjust...`).

## Ambiente de teste

- VM VirtualBox **gadssandbox**, `192.168.76.224`, Ubuntu 24.04.1, 4 vCPU,
  7,8 GB de RAM, CPU com AVX.
- SSH: `ssh -i ~/.ssh/gads_install_vm -o IdentitiesOnly=yes root@192.168.76.224`
  (chave criada para este projeto; não confundir com `~/.ssh/gads_vm`, que é de
  outra VM).
- Na VM: arquivos de teste em `/root/sandbox/`; `vm-provider.conf` é o
  `gads-provider.conf` com nickname `gadssandbox`, hub
  `http://192.168.76.224:10000` e Mongo `192.168.76.224:27017`. Hub e provider
  estão instalados no mesmo host.
- Fluxo de teste: `scp` dos scripts para `/root/sandbox/`, `shellcheck`, rodar
  com `nohup ... > log &` e acompanhar o log (o provider leva cerca de 10 min
  na primeira execução).
- Sem dispositivos físicos na VM: o teste valida instalação, serviços,
  registro no hub e ferramentas (`adb`, `sdb`, `ares`, `appium driver list`),
  não sessões reais.

## Referências

- Releases: https://github.com/gifflet/GADS/releases
- Docs oficiais: https://github.com/gifflet/GADS/tree/main/docs (hub.md,
  provider.md, linux-service.md)
- Código da release instalada: `https://raw.githubusercontent.com/gifflet/GADS/<tag>/...`.
  Consulte o código da **tag**, não o da `main`.
- Projeto irmão `../gads_docker`: hub em Docker (build a partir da tag).
