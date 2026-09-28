# GADS Install: instalação automatizada de Hub e Provider

Dois scripts shell que instalam e configuram um ambiente
[GADS](https://github.com/gifflet/GADS) (device farm open source) em **Ubuntu**,
como serviços **systemd**, a partir de um arquivo de configuração simples.

| Script | Configuração | Instala |
|---|---|---|
| [`gads-hub-install.sh`](gads-hub-install.sh) | [`gads-hub.conf`](gads-hub.conf) | GADS Hub (UI + API), MongoDB local via Docker (opcional) |
| [`gads-provider-install.sh`](gads-provider-install.sh) | [`gads-provider.conf`](gads-provider.conf) | GADS Provider + Appium 2 com drivers para **Android, Android TV, iOS, Tizen e webOS** |

```
                      ┌──────────────────────────────┐
  navegador / testes ─▶  GADS Hub  :10000            │  gads-hub-install.sh
                      │  UI, API, grid Appium        │
                      └──────┬───────────────┬───────┘
                             │ HTTP          │
                   ┌─────────▼───┐     ┌─────▼──────────┐
                   │  MongoDB    │◀────┤ GADS Provider  │  gads-provider-install.sh
                   │  :27017     │     │ :10001         │
                   └─────────────┘     │ Appium 2 +     │
                                       │ uiautomator2   │── Android / Android TV (adb)
                                       │ xcuitest       │── iOS (usbmuxd + WDA)
                                       │ tizentv        │── Samsung TV (sdb)
                                       │ webos          │── LG TV (ares)
                                       └────────────────┘
```

## Requisitos

- Ubuntu (testado no **24.04.1 LTS**), **amd64**, com systemd
- Execução como **root**
- Acesso à internet (GitHub, nodejs.org, npm, dl.google.com, download.tizen.org)
- Provider: cerca de 3 GB livres em disco (medido: `/root/.tools` 2,1 GB +
  `/root/.appium` 456 MB + pacotes apt)

## Início rápido

### 1. Hub

```bash
sudo -i
cd /caminho/gads_install
nano gads-hub.conf        # HUB_HOST_ADDRESS, HUB_PORT, HUB_MONGO_DB, HUB_AUTH
./gads-hub-install.sh
```

Acesse `http://<HUB_HOST_ADDRESS>:<HUB_PORT>` (login padrão `admin` / `password`,
**troque a senha** em `Admin > Users`).

### 2. Provider (no mesmo host ou em outro)

```bash
sudo -i
cd /caminho/gads_install
nano gads-provider.conf   # PROVIDER_NICKNAME, PROVIDER_HUB, PROVIDER_MONGO_DB
./gads-provider-install.sh
```

O script registra o provider no hub automaticamente, via API, com as credenciais
de admin do `gads-provider.conf`. Depois disso, conecte e cadastre os
dispositivos: veja [docs/dispositivos.md](docs/dispositivos.md).

### Opções dos scripts

```
-c, --config ARQUIVO   arquivo de configuração alternativo
-f, --force-download   baixa o binário do GADS mesmo que a release já esteja instalada
-h, --help             ajuda
```

Os dois scripts são **idempotentes**: reexecute-os para aplicar mudanças do
`.conf`, atualizar a release do GADS ou reparar a instalação.

## Configuração

### Hub (`gads-hub.conf`)

| Variável | Padrão | Descrição |
|---|---|---|
| `HUB_HOST_ADDRESS` | `auto` | IP/hostname em que o hub escuta (`auto` = IP principal; `0.0.0.0` = todas as interfaces) |
| `HUB_PORT` | `10000` | Porta da UI/API |
| `HUB_MONGO_DB` | `localhost:27017` | MongoDB `host:porta` |
| `HUB_AUTH` | `true` | Autenticação na UI/API |
| `MONGO_INSTALL` | `auto` | `auto`: instala MongoDB via Docker se `HUB_MONGO_DB` for local; `true`/`false` |
| `MONGO_IMAGE` | `mongo:6.0` | Imagem do MongoDB (`mongo:4.4` automático em CPU sem AVX) |
| `GADS_VERSION` | `latest` | `latest` (mais recente, inclui pre-release), `stable` ou uma tag |
| `GADS_REPO` | `gifflet/GADS` | Repositório das releases |
| `GADS_DIR` | `/root/GADS` | Diretório do binário (WorkingDirectory) |
| `HUB_FILES_DIR` | `/root/GADS/hub-files` | Onde a UI é descompactada |
| `GADS_CLIENT_ID_PREFIX` | *(vazio)* | Prefixo dos Client IDs de credenciais Appium |
| `HUB_EXTRA_ARGS` | *(vazio)* | Flags extras do `GADS hub` |
| `OPEN_FIREWALL` | `true` | Libera portas no UFW, se ativo |

### Provider (`gads-provider.conf`)

| Variável | Padrão | Descrição |
|---|---|---|
| `PROVIDER_NICKNAME` | **obrigatório** | Nome do provider |
| `PROVIDER_HUB` | **obrigatório** | URL do hub, ex.: `http://192.168.1.10:10000` |
| `PROVIDER_MONGO_DB` | **obrigatório** | MongoDB `host:porta` (o mesmo do hub) |
| `PROVIDER_REGISTER` | `true` | Cria/atualiza a configuração do provider no hub via API |
| `HUB_ADMIN_USER` / `HUB_ADMIN_PASSWORD` | `admin` / `password` | Credenciais usadas no registro |
| `PROVIDER_HOST_ADDRESS` | `auto` | IP deste provider, usado pelo hub |
| `PROVIDER_PORT` | `10001` | Porta do provider |
| `PROVIDE_ANDROID`, `PROVIDE_ANDROID_TV`, `PROVIDE_IOS`, `PROVIDE_TIZEN`, `PROVIDE_WEBOS` | `true` | Plataformas: instalam as dependências e são habilitadas no hub |
| `WDA_IPA_PATH` | *(vazio)* | `.ipa` do WebDriverAgent assinado, enviado ao hub (necessário para iOS) |
| `WDA_BUNDLE_ID` | `com.shamanec.WebDriverAgentRunner` | Bundle ID do WDA |
| `PROVIDER_LOG_LEVEL` | `debug` | `info` ou `debug` |
| `PROVIDER_FOLDER` | `/root/GADS/<nickname>` | Pasta de dados do provider |
| `GADS_VERSION` / `GADS_REPO` / `GADS_DIR` | como no hub | Use a **mesma** release do hub |
| `TOOLS_DIR` | `/root/.tools` | Android SDK, Tizen Studio, webOS CLI, Node |
| `NODE_MAJOR` | `22` | Linha do Node.js |
| `APPIUM_VERSION` | `2.19.0` | Appium (2.x, por causa dos drivers de TV) |
| `APPIUM_DRIVER_*` | ver `.conf` | Drivers `pacote@versão` |
| `APPIUM_PLUGIN_GADS` | *(vazio)* | Vazio: o provider gerencia o plugin `appium-gads` |
| `JAVA_PACKAGE` | `openjdk-17-jdk-headless` | JDK |
| `ANDROID_BUILD_TOOLS` | `latest` | Versão do build-tools |
| `ANDROID_SDK_EXTRA_PACKAGES` | `emulator` | Pacotes extras do sdkmanager (o `emulator` satisfaz o `appium driver doctor`) |
| `BUNDLETOOL_VERSION` | `latest` | bundletool, para instalar `.aab` |
| `TIZEN_INSTALLER_URL` | Tizen Studio 6.1 CLI | Instalador do Tizen |
| `WEBOS_CLI_VERSION` | `latest` | Versão do `@webos-tools/cli` |
| `PROVIDER_EXTRA_ARGS` | *(vazio)* | Flags extras do `GADS provider` (ex.: `--use-ios-pair-cache`) |

## O que fica instalado

| Caminho | Conteúdo |
|---|---|
| `/root/GADS/GADS` | Binário do GADS (hub e provider); `.gads-release` guarda a tag |
| `/root/GADS/<nickname>/` | Dados do provider: logs, apps, `drivers/chromedriver` |
| `/root/GADS/hub-files/` | Arquivos estáticos da UI do hub |
| `/etc/sysconfig/gads` | **Variáveis de ambiente dos serviços** (ver abaixo) |
| `/etc/systemd/system/gads-hub.service`, `gads-provider.service` | Units systemd |
| `/etc/logrotate.d/gads-hub`, `gads-provider` | Rotação diária, 7 dias |
| `/var/log/gads-hub.log`, `gads-provider.log` | Logs dos serviços |
| `/root/.tools/node` | Node.js (+ appium no npm global) |
| `/root/.tools/android-sdk` | cmdline-tools, platform-tools, build-tools, emulator |
| `/root/.tools/bundletool` | `bundletool.jar` |
| `/root/.tools/tizen-studio` (+ `-data`) | Tizen Studio CLI (sdb, tizen) |
| `/root/.tools/webOS_TV_SDK/CLI` | webOS TV CLI (ares) |
| `/root/.appium` | Drivers e plugins do Appium (`APPIUM_HOME`) |
| `/etc/profile.d/gads.sh` | Mesmo ambiente para o shell interativo do root |
| Docker `gads-mongodb` / volume `gads-mongo-data` | MongoDB local (hub) |

### `/etc/sysconfig/gads`

É o arquivo de ambiente carregado pelos dois serviços (`EnvironmentFile=`).
Exemplo com hub e provider no mesmo host:

```ini
PATH=/root/.tools/node/bin:/root/.tools/android-sdk/platform-tools:/root/.tools/android-sdk/cmdline-tools/latest/bin:/root/.tools/bundletool:/root/.tools/tizen-studio/tools:/root/.tools/tizen-studio/tools/ide/bin:/root/.tools/webOS_TV_SDK/CLI/bin:/usr/lib/jvm/java-17-openjdk-amd64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HUB_HOST_ADDRESS=192.168.76.224
HUB_PORT=10000
HUB_MONGO_DB=localhost:27017
HUB_AUTH=true
HUB_FILES_DIR=/root/GADS/hub-files
HUB_EXTRA_ARGS=
JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
APPIUM_HOME=/root/.appium
ANDROID_HOME=/root/.tools/android-sdk
ANDROID_SDK_ROOT=/root/.tools/android-sdk
TIZEN_HOME=/root/.tools/tizen-studio
LG_WEBOS_TV_SDK_HOME=/root/.tools/webOS_TV_SDK
WEBOS_CLI_TV=/root/.tools/webOS_TV_SDK/CLI
PROVIDER_NICKNAME=gadssandbox
PROVIDER_MONGO_DB=192.168.76.224:27017
PROVIDER_HUB=http://192.168.76.224:10000
PROVIDER_FOLDER=/root/GADS/gadssandbox
PROVIDER_LOG_LEVEL=debug
PROVIDER_EXTRA_ARGS=
```

Você pode editar o arquivo à mão e reiniciar o serviço. O systemd **não
expande variáveis** neste arquivo, então os valores precisam estar completos.

## Operação

```bash
systemctl status gads-hub gads-provider
systemctl restart gads-provider          # após cadastrar/alterar dispositivos
tail -f /var/log/gads-provider.log
journalctl -u gads-hub -f
```

- **Atualizar o GADS:** reexecute os scripts (com `GADS_VERSION=latest`, a
  release mais nova é baixada se mudou). Atualize hub e providers juntos.
- **Mudar configuração:** edite o `.conf` e reexecute, ou edite
  `/etc/sysconfig/gads` e reinicie o serviço.

## Validação

Testado em 28/09/2026 numa VM VirtualBox com Ubuntu 24.04.1 LTS (4 vCPU,
8 GB), com hub e provider no mesmo host e release `opus-test`:

| Cenário | Resultado |
|---|---|
| Hub do zero (Docker + `mongo:6.0` + binário + serviço) | OK, cerca de 2 min |
| Provider do zero (todas as plataformas) | OK, cerca de 10 min |
| Reexecução do hub e do provider (idempotência) | OK, provider em 38 s |
| Hub e provider no mesmo host (`/etc/sysconfig/gads` compartilhado) | OK, variáveis mescladas |
| Registro do provider via API (criação e atualização) | OK, heartbeat no hub |
| `WDA_IPA_PATH` -> upload, seleção por id, iOS habilitado | OK |
| WDA removido -> iOS desabilitado e id limpo | OK |
| Senha de admin errada | Falha clara (HTTP 401), serviço intacto |
| Reboot da VM | MongoDB, hub e provider voltam sozinhos, `NRestarts=0` |
| `appium driver doctor uiautomator2` | 0 correções obrigatórias, 0 opcionais |

Versões instaladas: Node.js 22.23.3, Appium 2.19.0, uiautomator2 4.2.9,
xcuitest 9.10.5, tizentv 0.18.1, webos 0.5.0, plugin gads 0.0.11 (instalado
pelo provider), OpenJDK 17, adb 1.0.41 (platform-tools 37.0.1), build-tools
37.0.0, bundletool 1.18.3, sdb 4.2.25, Tizen CLI 2.5.25, webOS CLI 3.2.6.

Não houve teste com dispositivos físicos (a VM não tem nenhum conectado). A
validação cobre instalação, serviços, registro e ferramentas.

## Documentação

- [docs/dispositivos.md](docs/dispositivos.md): como conectar e cadastrar
  Android, Android TV, iOS, Tizen e webOS.
- [docs/troubleshooting.md](docs/troubleshooting.md): problemas comuns, logs e
  reinstalação limpa.
- [docs/decisoes-tecnicas.md](docs/decisoes-tecnicas.md): o porquê de cada
  escolha (versões do Appium, contorno do Tizen como root, webOS CLI, API do hub
  entre releases).
- Documentação oficial: <https://github.com/gifflet/GADS/tree/main/docs>

## Limitações conhecidas

- **iOS** exige um WebDriverAgent `.ipa` assinado com conta Apple, que não pode
  ser gerado pelo script. Sem ele, o iOS fica desabilitado na configuração do
  provider, embora o host fique preparado. No Linux, recursos que dependem do
  Xcode não funcionam.
- **TVs** (Tizen/webOS) suportam só automação Appium, sem controle remoto nem
  vídeo pela UI.
- **Roku**, disponível nas releases recentes do GADS, não é instalado.
- O MongoDB usado pelo GADS não tem autenticação; proteja a porta por firewall.
