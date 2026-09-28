#!/usr/bin/env bash
# =============================================================================
# gads-provider-install.sh - instala e configura um GADS PROVIDER como serviço
# systemd, com Appium e dependências para Android, iOS, Tizen e webOS.
#
# Alvo: Ubuntu (amd64), executado como root.
# Uso:  sudo ./gads-provider-install.sh [-c gads-provider.conf] [--force-download]
#
# Etapas:
#   1. Dependências de sistema (Java, usbmuxd, utilitários)
#   2. Node.js + Appium 2 + drivers (uiautomator2, xcuitest, tizentv, webos) + plugin gads
#   3. Android SDK (platform-tools/adb, build-tools)
#   4. Tizen Studio CLI (sdb, tizen)
#   5. webOS TV CLI (ares)
#   6. Binário do GADS (release do GitHub)
#   7. /etc/sysconfig/gads, /etc/profile.d/gads.sh, unit systemd e logrotate
#   8. Registro do provider no hub (via API) e início do serviço
#
# O script é idempotente: pode ser reexecutado para aplicar alterações do
# arquivo de configuração ou atualizar componentes.
# =============================================================================
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/gads-provider.conf"
FORCE_DOWNLOAD="false"

SYSCONFIG_FILE="/etc/sysconfig/gads"
PROFILE_FILE="/etc/profile.d/gads.sh"
SERVICE_NAME="gads-provider"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOGROTATE_FILE="/etc/logrotate.d/${SERVICE_NAME}"
SERVICE_LOG="/var/log/${SERVICE_NAME}.log"
INSTALL_LOG="/var/log/gads-provider-install.log"
CACHE_DIR="/var/cache/gads-install"
BASE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
CHROMEDRIVER_URL="https://chromedriver.storage.googleapis.com/2.36/chromedriver_linux64.zip"

# -----------------------------------------------------------------------------
# Utilitários
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_INFO=$'\e[1;34m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'; C_END=$'\e[0m'
else
    C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_END=""
fi

WARNINGS=()
log()     { printf '%s[%s] %s%s\n' "$C_INFO" "$(date +%H:%M:%S)" "$*" "$C_END"; }
ok()      { printf '%s[ OK ] %s%s\n' "$C_OK" "$*" "$C_END"; }
warn()    { printf '%s[WARN] %s%s\n' "$C_WARN" "$*" "$C_END" >&2; WARNINGS+=("$*"); }
die()     { printf '%s[ERRO] %s%s\n' "$C_ERR" "$*" "$C_END" >&2; exit 1; }
step()    { printf '\n%s==> %s%s\n' "$C_INFO" "$*" "$C_END"; }
is_true() { [[ "${1,,}" =~ ^(true|yes|y|1|sim|s)$ ]]; }
bool()    { if is_true "$1"; then echo true; else echo false; fi; }

trap 'die "Falha inesperada na linha ${LINENO}: ${BASH_COMMAND}"' ERR

usage() {
    cat <<EOF
Uso: sudo ./${SCRIPT_NAME} [opções]

Opções:
  -c, --config ARQUIVO   Arquivo de configuração (padrão: ${SCRIPT_DIR}/gads-provider.conf)
  -f, --force-download   Baixa o binário do GADS mesmo que a release já esteja instalada
  -h, --help             Mostra esta ajuda
EOF
}

# Cria/atualiza uma chave KEY=valor em um arquivo de ambiente sem tocar nas demais.
set_kv() {
    local file="$1" key="$2" value="$3" tmp found=0 line
    tmp="$(mktemp)"
    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "${key}="* ]]; then
                printf '%s=%s\n' "$key" "$value" >>"$tmp"
                found=1
            else
                printf '%s\n' "$line" >>"$tmp"
            fi
        done <"$file"
    fi
    (( found )) || printf '%s=%s\n' "$key" "$value" >>"$tmp"
    install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

unset_kv() {
    local file="$1" key="$2"
    [[ -f "$file" ]] && sed -i "/^${key}=/d" "$file"
    return 0
}

download() {
    local url="$1" dest="$2"
    log "Baixando ${url}"
    curl -fsSL --retry 3 --retry-delay 3 --connect-timeout 20 -o "$dest" "$url" \
        || die "Falha ao baixar ${url}"
}

tcp_open() {
    local host="$1" port="$2"
    timeout 3 bash -c ">/dev/tcp/${host}/${port}" 2>/dev/null
}

primary_ip() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

strip_scheme() {
    local v="${1#http://}"
    v="${v#https://}"
    printf '%s' "${v%%/*}"
}

# -----------------------------------------------------------------------------
# Argumentos, pré-requisitos e configuração
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)         CONFIG_FILE="${2:?Informe o arquivo de configuração}"; shift 2 ;;
            -f|--force-download) FORCE_DOWNLOAD="true"; shift ;;
            -h|--help)           usage; exit 0 ;;
            *)                   usage; die "Opção desconhecida: $1" ;;
        esac
    done
}

check_prerequisites() {
    [[ "$(id -u)" -eq 0 ]] || die "Execute como root (ex.: sudo ./${SCRIPT_NAME})."
    [[ -r /etc/os-release ]] || die "/etc/os-release não encontrado."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "Este script suporta apenas Ubuntu (detectado: ${ID:-desconhecido})."
    [[ "$(uname -m)" == "x86_64" ]] || die "O GADS publica binário Linux apenas para amd64 (detectado: $(uname -m))."
    command -v systemctl >/dev/null || die "systemd é obrigatório."
    log "Sistema: ${PRETTY_NAME}"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Arquivo de configuração não encontrado: ${CONFIG_FILE}"
    log "Carregando configuração de ${CONFIG_FILE}"
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"

    PROVIDER_NICKNAME="${PROVIDER_NICKNAME:-}"
    PROVIDER_HUB="${PROVIDER_HUB:-}"
    PROVIDER_MONGO_DB="${PROVIDER_MONGO_DB:-}"
    PROVIDER_REGISTER="$(bool "${PROVIDER_REGISTER:-true}")"
    HUB_ADMIN_USER="${HUB_ADMIN_USER:-admin}"
    HUB_ADMIN_PASSWORD="${HUB_ADMIN_PASSWORD:-password}"
    PROVIDER_HOST_ADDRESS="${PROVIDER_HOST_ADDRESS:-auto}"
    PROVIDER_PORT="${PROVIDER_PORT:-10001}"
    PROVIDE_ANDROID="$(bool "${PROVIDE_ANDROID:-true}")"
    PROVIDE_ANDROID_TV="$(bool "${PROVIDE_ANDROID_TV:-true}")"
    PROVIDE_IOS="$(bool "${PROVIDE_IOS:-true}")"
    PROVIDE_TIZEN="$(bool "${PROVIDE_TIZEN:-true}")"
    PROVIDE_WEBOS="$(bool "${PROVIDE_WEBOS:-true}")"
    WDA_IPA_PATH="${WDA_IPA_PATH:-}"
    WDA_BUNDLE_ID="${WDA_BUNDLE_ID:-com.shamanec.WebDriverAgentRunner}"
    USE_SELENIUM_GRID="$(bool "${USE_SELENIUM_GRID:-false}")"
    SELENIUM_GRID="${SELENIUM_GRID:-}"
    PROVIDER_LOG_LEVEL="${PROVIDER_LOG_LEVEL:-debug}"
    GADS_VERSION="${GADS_VERSION:-latest}"
    GADS_REPO="${GADS_REPO:-gifflet/GADS}"
    GADS_DIR="${GADS_DIR:-/root/GADS}"
    TOOLS_DIR="${TOOLS_DIR:-/root/.tools}"
    NODE_MAJOR="${NODE_MAJOR:-22}"
    APPIUM_VERSION="${APPIUM_VERSION:-2.19.0}"
    APPIUM_DRIVER_UIAUTOMATOR2="${APPIUM_DRIVER_UIAUTOMATOR2:-appium-uiautomator2-driver@4.2.9}"
    APPIUM_DRIVER_XCUITEST="${APPIUM_DRIVER_XCUITEST:-appium-xcuitest-driver@9.10.5}"
    APPIUM_DRIVER_TIZEN="${APPIUM_DRIVER_TIZEN:-appium-tizen-tv-driver@0.18.1}"
    APPIUM_DRIVER_WEBOS="${APPIUM_DRIVER_WEBOS:-appium-lg-webos-driver@0.5.0}"
    APPIUM_PLUGIN_GADS="${APPIUM_PLUGIN_GADS:-}"
    PROVIDER_EXTRA_ARGS="${PROVIDER_EXTRA_ARGS:-}"
    JAVA_PACKAGE="${JAVA_PACKAGE:-openjdk-17-jdk-headless}"
    ANDROID_BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-latest}"
    ANDROID_SDK_EXTRA_PACKAGES="${ANDROID_SDK_EXTRA_PACKAGES-emulator}"
    BUNDLETOOL_VERSION="${BUNDLETOOL_VERSION:-latest}"
    TIZEN_INSTALLER_URL="${TIZEN_INSTALLER_URL:-https://download.tizen.org/sdk/Installer/tizen-studio_6.1/web-cli_Tizen_Studio_6.1_ubuntu-64.bin}"
    WEBOS_CLI_VERSION="${WEBOS_CLI_VERSION:-latest}"
    OPEN_FIREWALL="${OPEN_FIREWALL:-true}"
    GITHUB_TOKEN="${GITHUB_TOKEN:-}"

    # Validações
    [[ -n "$PROVIDER_NICKNAME" ]] || die "PROVIDER_NICKNAME é obrigatório."
    [[ "$PROVIDER_NICKNAME" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "PROVIDER_NICKNAME deve conter apenas letras, números, '.', '_' ou '-' (atual: ${PROVIDER_NICKNAME})."
    [[ -n "$PROVIDER_HUB" ]] || die "PROVIDER_HUB é obrigatório (ex.: http://192.168.1.10:10000)."
    [[ -n "$PROVIDER_MONGO_DB" ]] || die "PROVIDER_MONGO_DB é obrigatório (ex.: 192.168.1.10:27017)."

    [[ "$PROVIDER_HUB" =~ ^https?:// ]] || PROVIDER_HUB="http://${PROVIDER_HUB}"
    PROVIDER_HUB="${PROVIDER_HUB%/}"

    PROVIDER_MONGO_DB="$(strip_scheme "${PROVIDER_MONGO_DB#mongodb://}")"
    [[ "$PROVIDER_MONGO_DB" == *:* ]] || PROVIDER_MONGO_DB="${PROVIDER_MONGO_DB}:27017"

    if [[ "$PROVIDER_HOST_ADDRESS" == "auto" ]]; then
        PROVIDER_HOST_ADDRESS="$(primary_ip)"
        [[ -n "$PROVIDER_HOST_ADDRESS" ]] || die "Não foi possível detectar o IP principal; defina PROVIDER_HOST_ADDRESS."
    fi
    [[ "$PROVIDER_PORT" =~ ^[0-9]+$ ]] && (( PROVIDER_PORT > 0 && PROVIDER_PORT < 65536 )) \
        || die "PROVIDER_PORT inválida: ${PROVIDER_PORT}"
    PROVIDER_FOLDER="${PROVIDER_FOLDER:-${GADS_DIR}/${PROVIDER_NICKNAME}}"

    if [[ -n "$WDA_IPA_PATH" && ! -f "$WDA_IPA_PATH" ]]; then
        die "WDA_IPA_PATH aponta para um arquivo inexistente: ${WDA_IPA_PATH}"
    fi
    if [[ "$USE_SELENIUM_GRID" == "true" && -z "$SELENIUM_GRID" ]]; then
        die "USE_SELENIUM_GRID=true exige SELENIUM_GRID (ex.: http://192.168.1.10:4444)."
    fi

    # Android e Android TV usam as mesmas ferramentas (adb + uiautomator2)
    NEED_ANDROID="false"
    [[ "$PROVIDE_ANDROID" == "true" || "$PROVIDE_ANDROID_TV" == "true" ]] && NEED_ANDROID="true"

    # Caminhos das ferramentas
    NODE_HOME="${TOOLS_DIR}/node"
    ANDROID_HOME="${TOOLS_DIR}/android-sdk"
    BUNDLETOOL_DIR="${TOOLS_DIR}/bundletool"
    TIZEN_HOME="${TOOLS_DIR}/tizen-studio"
    LG_WEBOS_TV_SDK_HOME="${TOOLS_DIR}/webOS_TV_SDK"
    WEBOS_CLI_TV="${LG_WEBOS_TV_SDK_HOME}/CLI"
    APPIUM_HOME="/root/.appium"
    export APPIUM_HOME

    cat <<EOF

  Provider:       ${PROVIDER_NICKNAME} (http://${PROVIDER_HOST_ADDRESS}:${PROVIDER_PORT})
  Hub:            ${PROVIDER_HUB}
  MongoDB:        ${PROVIDER_MONGO_DB}
  Plataformas:    android=${PROVIDE_ANDROID} androidtv=${PROVIDE_ANDROID_TV} ios=${PROVIDE_IOS} tizen=${PROVIDE_TIZEN} webos=${PROVIDE_WEBOS}
  Appium:         ${APPIUM_VERSION} (Node.js ${NODE_MAJOR}.x)
  Release GADS:   ${GADS_VERSION} (${GADS_REPO})
  Ferramentas:    ${TOOLS_DIR}
  Pasta de dados: ${PROVIDER_FOLDER}

EOF
}

# PATH completo usado pelo serviço, pelo shell interativo e por este script.
build_path() {
    local p="${NODE_HOME}/bin"
    if [[ "$NEED_ANDROID" == "true" ]]; then
        p+=":${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/cmdline-tools/latest/bin:${BUNDLETOOL_DIR}"
    fi
    if [[ "$PROVIDE_TIZEN" == "true" ]]; then
        p+=":${TIZEN_HOME}/tools:${TIZEN_HOME}/tools/ide/bin"
    fi
    if [[ "$PROVIDE_WEBOS" == "true" ]]; then
        p+=":${WEBOS_CLI_TV}/bin"
    fi
    p+=":${JAVA_HOME}/bin:${BASE_PATH}"
    printf '%s' "$p"
}

# -----------------------------------------------------------------------------
# 1. Dependências de sistema
# -----------------------------------------------------------------------------
install_system_packages() {
    step "Instalando dependências de sistema"
    export DEBIAN_FRONTEND=noninteractive
    local pkgs=(ca-certificates curl wget unzip zip xz-utils jq git logrotate iproute2 procps
                "$JAVA_PACKAGE")
    # iOS: usbmuxd faz a ponte USB com os dispositivos (go-ios é embutido no GADS)
    [[ "$PROVIDE_IOS" == "true" ]] && pkgs+=(usbmuxd)
    # Android/iOS: gravação de tela e mídia pelos drivers Appium (itens do `appium driver doctor`)
    if [[ "$NEED_ANDROID" == "true" || "$PROVIDE_IOS" == "true" ]]; then
        pkgs+=(ffmpeg gstreamer1.0-tools)
    fi
    # Tizen: o instalador do Tizen Studio exige zip/grep e usa lspci (pciutils)
    [[ "$PROVIDE_TIZEN" == "true" ]] && pkgs+=(grep pciutils)
    # Tizen/webOS: bibliotecas do chromedriver 2.36 usado pelos drivers de TV
    if [[ "$PROVIDE_TIZEN" == "true" || "$PROVIDE_WEBOS" == "true" ]]; then
        pkgs+=(libglib2.0-0 libnss3 libnspr4 libx11-6 libxcb1)
    fi
    apt-get update -y
    apt-get install -y --no-install-recommends "${pkgs[@]}"

    local javac
    javac="$(dpkg -L "$JAVA_PACKAGE" 2>/dev/null | grep -m1 '/bin/javac$' || true)"
    [[ -n "$javac" ]] || javac="$(readlink -f "$(command -v javac)")"
    JAVA_HOME="$(dirname "$(dirname "$javac")")"
    PATH="$(build_path)"
    export JAVA_HOME PATH
    ok "Dependências instaladas (JAVA_HOME=${JAVA_HOME})"
}

# -----------------------------------------------------------------------------
# 2. Node.js + Appium
# -----------------------------------------------------------------------------
install_node() {
    step "Instalando Node.js ${NODE_MAJOR}.x"
    local base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x" sums tarball version current=""
    sums="$(curl -fsSL "${base}/SHASUMS256.txt")" || die "Não foi possível consultar ${base}"
    tarball="$(grep -oE "node-v[0-9.]+-linux-x64\.tar\.xz" <<<"$sums" | head -n1)"
    [[ -n "$tarball" ]] || die "Não foi encontrada a distribuição linux-x64 do Node.js ${NODE_MAJOR}.x"
    version="${tarball#node-}"; version="${version%-linux-x64.tar.xz}"

    [[ -x "${NODE_HOME}/bin/node" ]] && current="$("${NODE_HOME}/bin/node" --version)"
    if [[ "$current" == "$version" ]]; then
        ok "Node.js ${version} já instalado"
        return 0
    fi

    mkdir -p "$TOOLS_DIR" "$CACHE_DIR"
    download "${base}/${tarball}" "${CACHE_DIR}/${tarball}"
    (cd "$CACHE_DIR" && grep " ${tarball}\$" <<<"$sums" | sha256sum -c --quiet -) \
        || die "Checksum inválido para ${tarball}"
    tar -xJf "${CACHE_DIR}/${tarball}" -C "$TOOLS_DIR"
    ln -sfn "${TOOLS_DIR}/${tarball%.tar.xz}" "$NODE_HOME"
    rm -f "${CACHE_DIR}/${tarball}"
    ok "Node.js $("${NODE_HOME}/bin/node" --version) instalado em ${NODE_HOME}"
}

# Instala (ou ajusta a versão de) uma extensão do Appium: driver|plugin, pacote-npm[@versão]
appium_extension() {
    local type="$1" spec="$2" pkg ver installed entry name current
    if [[ "$spec" =~ ^(@?[^@]+)@(.+)$ ]]; then
        pkg="${BASH_REMATCH[1]}"; ver="${BASH_REMATCH[2]}"
    else
        pkg="$spec"; ver=""
    fi
    installed="$(appium "$type" list --installed --json 2>/dev/null || echo '{}')"
    entry="$(jq -r --arg p "$pkg" 'to_entries[] | select(.value.pkgName == $p) | "\(.key) \(.value.version)"' <<<"$installed" | head -n1)"
    if [[ -n "$entry" ]]; then
        name="${entry%% *}"; current="${entry##* }"
        if [[ -z "$ver" || "$current" == "$ver" ]]; then
            ok "Appium ${type} ${name}@${current} já instalado"
            return 0
        fi
        log "Substituindo ${type} ${name}@${current} por ${pkg}@${ver}"
        appium "$type" uninstall "$name"
    fi
    appium "$type" install --source=npm "$spec"
    ok "Appium ${type} ${spec} instalado"
}

install_appium() {
    step "Instalando Appium ${APPIUM_VERSION}, drivers e plugin do GADS"
    local current=""
    command -v appium >/dev/null && current="$(appium --version 2>/dev/null | tail -n1)"
    if [[ "$current" != "$APPIUM_VERSION" ]]; then
        npm install -g "appium@${APPIUM_VERSION}"
    fi
    ok "Appium $(appium --version | tail -n1) (APPIUM_HOME=${APPIUM_HOME})"

    [[ "$NEED_ANDROID" == "true" ]]  && appium_extension driver "$APPIUM_DRIVER_UIAUTOMATOR2"
    [[ "$PROVIDE_IOS" == "true" ]]   && appium_extension driver "$APPIUM_DRIVER_XCUITEST"
    [[ "$PROVIDE_TIZEN" == "true" ]] && appium_extension driver "$APPIUM_DRIVER_TIZEN"
    [[ "$PROVIDE_WEBOS" == "true" ]] && appium_extension driver "$APPIUM_DRIVER_WEBOS"

    # O plugin appium-gads é gerenciado pelo próprio provider ao iniciar (cada
    # release do GADS fixa a versão que espera e a reinstala se divergir).
    # Só é pré-instalado se APPIUM_PLUGIN_GADS for definido explicitamente.
    if [[ -n "$APPIUM_PLUGIN_GADS" ]]; then
        npm install -g "$APPIUM_PLUGIN_GADS"
        appium_extension plugin "$APPIUM_PLUGIN_GADS"
    fi
}

# -----------------------------------------------------------------------------
# 3. Android SDK
# -----------------------------------------------------------------------------
install_android_sdk() {
    [[ "$NEED_ANDROID" == "true" ]] || return 0
    step "Instalando Android SDK em ${ANDROID_HOME}"
    local sdkm="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" zip tmp bt

    if [[ ! -x "$sdkm" ]]; then
        zip="$(curl -fsSL https://dl.google.com/android/repository/repository2-3.xml \
            | grep -oE 'commandlinetools-linux-[0-9]+_latest\.zip' | sort -t- -k3 -n | tail -n1)"
        [[ -n "$zip" ]] || die "Não foi possível localizar o pacote do Android cmdline-tools"
        tmp="$(mktemp -d)"
        download "https://dl.google.com/android/repository/${zip}" "${tmp}/${zip}"
        unzip -q "${tmp}/${zip}" -d "$tmp"
        mkdir -p "${ANDROID_HOME}/cmdline-tools"
        rm -rf "${ANDROID_HOME}/cmdline-tools/latest"
        mv "${tmp}/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest"
        rm -rf "$tmp"
        ok "Android cmdline-tools instalado (${zip})"
    fi

    # `yes` termina com SIGPIPE quando o sdkmanager fecha a entrada
    (set +o pipefail; yes | "$sdkm" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1) || true

    bt="$ANDROID_BUILD_TOOLS"
    if [[ "$bt" == "latest" ]]; then
        # Formato antigo "build-tools;X.Y.Z" e novo (cmdline-tools 23+) "build-tools/X.Y.Z";
        # a âncora "$" exclui versões -rc.
        bt="$("$sdkm" --sdk_root="$ANDROID_HOME" --list 2>/dev/null | awk '{print $1}' \
            | grep -E '^build-tools[;/][0-9]+\.[0-9]+\.[0-9]+$' \
            | sed 's|^build-tools[;/]||' | sort -uV | tail -n1 || true)"
        [[ -n "$bt" ]] || die "Não foi possível determinar a última versão do build-tools"
    fi
    local -a sdk_pkgs=("platform-tools" "build-tools;${bt}")
    # shellcheck disable=SC2206
    [[ -n "$ANDROID_SDK_EXTRA_PACKAGES" ]] && sdk_pkgs+=($ANDROID_SDK_EXTRA_PACKAGES)
    "$sdkm" --sdk_root="$ANDROID_HOME" --install "${sdk_pkgs[@]}" >/dev/null
    ok "Android SDK pronto: ${sdk_pkgs[*]} ($(adb version | head -n1))"

    # bundletool (instalação de .aab pelo uiautomator2); o doctor procura bundletool.jar no PATH
    local jar="${BUNDLETOOL_DIR}/bundletool.jar" marker="${BUNDLETOOL_DIR}/.version" url tag
    if [[ "$BUNDLETOOL_VERSION" == "latest" ]]; then
        tag="$(curl -fsSL https://api.github.com/repos/google/bundletool/releases/latest | jq -r '.tag_name // empty' || true)"
    else
        tag="$BUNDLETOOL_VERSION"
    fi
    if [[ -z "$tag" ]]; then
        warn "Não foi possível resolver a versão do bundletool; etapa ignorada."
    elif [[ -f "$jar" && "$(cat "$marker" 2>/dev/null)" == "$tag" ]]; then
        chmod 0755 "$jar"
        ok "bundletool ${tag} já instalado"
    else
        url="https://github.com/google/bundletool/releases/download/${tag}/bundletool-all-${tag}.jar"
        mkdir -p "$BUNDLETOOL_DIR"
        download "$url" "${jar}.tmp"
        # O doctor localiza o jar com `which`, que exige o bit de execução
        install -m 0755 "${jar}.tmp" "$jar"
        rm -f "${jar}.tmp"
        printf '%s\n' "$tag" >"$marker"
        ok "bundletool ${tag} instalado em ${jar}"
    fi
}

# -----------------------------------------------------------------------------
# 4. Tizen Studio CLI
# -----------------------------------------------------------------------------
install_tizen() {
    [[ "$PROVIDE_TIZEN" == "true" ]] || return 0
    step "Instalando Tizen Studio CLI em ${TIZEN_HOME}"
    if [[ -x "${TIZEN_HOME}/tools/sdb" && -x "${TIZEN_HOME}/tools/ide/bin/tizen" ]]; then
        ok "Tizen Studio CLI já instalado"
    else
        local installer="${CACHE_DIR}/${TIZEN_INSTALLER_URL##*/}" fakebin
        mkdir -p "$CACHE_DIR" "$TOOLS_DIR"
        [[ -s "$installer" ]] || download "$TIZEN_INSTALLER_URL" "$installer"
        chmod +x "$installer"
        # O instalador recusa rodar como root (checa `whoami`). A instalação é
        # feita como root por padrão, então um `whoami` substituto é colocado
        # no PATH apenas durante a execução do instalador.
        fakebin="$(mktemp -d)"
        printf '#!/bin/sh\necho gads-installer\n' >"${fakebin}/whoami"
        chmod +x "${fakebin}/whoami"
        (cd "$CACHE_DIR" && PATH="${fakebin}:${PATH}" "$installer" --accept-license "$TIZEN_HOME") \
            || die "Falha na instalação do Tizen Studio CLI"
        rm -rf "$fakebin"
        [[ -x "${TIZEN_HOME}/tools/sdb" ]] || die "sdb não encontrado após a instalação do Tizen Studio"
        rm -f "$installer"
    fi
    ok "Tizen pronto: sdb $(sdb version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1) / $(tizen version 2>/dev/null | grep -oiE 'Tizen CLI [0-9.]+' | head -n1)"
}

# -----------------------------------------------------------------------------
# 5. webOS TV CLI
# -----------------------------------------------------------------------------
install_webos_cli() {
    [[ "$PROVIDE_WEBOS" == "true" ]] || return 0
    step "Instalando webOS TV CLI em ${WEBOS_CLI_TV}"
    local want="$WEBOS_CLI_VERSION" current="" pkgjson="${WEBOS_CLI_TV}/lib/node_modules/@webos-tools/cli/package.json"
    [[ "$want" == "latest" ]] && want="$(npm view @webos-tools/cli version 2>/dev/null)"
    [[ -f "$pkgjson" ]] && current="$(jq -r .version "$pkgjson")"
    if [[ -n "$want" && "$current" == "$want" ]]; then
        ok "webOS CLI ${current} já instalado"
    else
        mkdir -p "$WEBOS_CLI_TV"
        npm install -g --prefix "$WEBOS_CLI_TV" "@webos-tools/cli@${want:-latest}"
    fi

    # O appium-lg-webos-driver chama `ares-extend-dev` ao criar sessões
    # (appium:autoExtendDevMode=true por padrão), comando que existia no CLI
    # legado mas não no @webos-tools/cli. Este substituto tenta renovar o
    # Developer Mode da TV e nunca faz a sessão falhar.
    local shim="${WEBOS_CLI_TV}/bin/ares-extend-dev"
    if [[ ! -e "$shim" ]] || grep -q 'GADS_SHIM' "$shim"; then
        cat >"$shim" <<'EOF'
#!/usr/bin/env bash
# GADS_SHIM - criado por gads-provider-install.sh
# Substituto do `ares-extend-dev` do webOS CLI legado. Tenta renovar a sessão
# do Developer Mode (validade de 1000h) usando o token gravado na TV.
# Sempre retorna sucesso para não impedir a criação da sessão Appium.
device=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device) device="$2"; shift 2 ;;
        --device=*)  device="${1#*=}"; shift ;;
        *)           shift ;;
    esac
done
args=()
[[ -n "$device" ]] && args=(--device "$device")
token="$(timeout 20 ares-novacom "${args[@]}" --run 'cat /var/luna/preferences/devmode_enabled' 2>/dev/null | tr -d '[:space:]')"
if [[ -n "$token" ]] && curl -fsS --max-time 15 \
        "https://developer.lge.com/secure/ResetDevModeSession.dev?sessionToken=${token}" >/dev/null 2>&1; then
    echo "ares-extend-dev (GADS): Developer Mode renovado${device:+ para ${device}}"
else
    echo "ares-extend-dev (GADS): não foi possível renovar o Developer Mode${device:+ de ${device}}; seguindo" >&2
fi
exit 0
EOF
        chmod +x "$shim"
    fi
    ok "webOS CLI pronto: $(ares -V 2>/dev/null | head -n1)"
}

# -----------------------------------------------------------------------------
# 6. Binário do GADS
# -----------------------------------------------------------------------------
resolve_gads_tag() {
    local api="https://api.github.com/repos/${GADS_REPO}" tag=""
    local -a auth=()
    [[ -n "$GITHUB_TOKEN" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

    case "$GADS_VERSION" in
        latest)
            tag="$(curl -fsSL "${auth[@]}" "${api}/releases?per_page=50" \
                | jq -r '[.[] | select(.draft == false)
                               | select(any(.assets[]; .name == "gads-linux.zip"))]
                         | sort_by(.published_at) | last | .tag_name // empty')" || true ;;
        stable)
            tag="$(curl -fsSL "${auth[@]}" "${api}/releases/latest" | jq -r '.tag_name // empty')" || true ;;
        *)
            tag="$GADS_VERSION" ;;
    esac
    [[ -n "$tag" ]] || die "Não foi possível resolver a release '${GADS_VERSION}' de ${GADS_REPO} (limite da API do GitHub? defina GITHUB_TOKEN)."
    printf '%s' "$tag"
}

install_gads_binary() {
    step "Instalando o binário do GADS"
    local tag marker="${GADS_DIR}/.gads-release" tmp
    tag="$(resolve_gads_tag)"
    log "Release selecionada: ${tag}"
    mkdir -p "$GADS_DIR" "$PROVIDER_FOLDER"

    GADS_BINARY_CHANGED="false"
    if [[ -x "${GADS_DIR}/GADS" && "$(cat "$marker" 2>/dev/null)" == "$tag" && "$FORCE_DOWNLOAD" != "true" ]]; then
        ok "Release ${tag} já instalada em ${GADS_DIR}/GADS"
    else
        tmp="$(mktemp -d)"
        download "https://github.com/${GADS_REPO}/releases/download/${tag}/gads-linux.zip" "${tmp}/gads-linux.zip"
        unzip -q -o "${tmp}/gads-linux.zip" -d "$tmp"
        [[ -f "${tmp}/GADS" ]] || die "O pacote gads-linux.zip da release ${tag} não contém o binário GADS."
        install -m 0755 "${tmp}/GADS" "${GADS_DIR}/GADS.new"
        mv -f "${GADS_DIR}/GADS.new" "${GADS_DIR}/GADS"
        printf '%s\n' "$tag" >"$marker"
        rm -rf "$tmp"
        GADS_BINARY_CHANGED="true"
        ok "GADS ${tag} instalado ($("${GADS_DIR}/GADS" version 2>/dev/null | tr -d '[:space:]'))"
    fi

    # Chromedriver 2.36 usado pelos drivers de TV; o provider baixa sozinho se
    # faltar, mas deixá-lo pronto evita falhas de rede no primeiro uso.
    if [[ "$PROVIDE_TIZEN" == "true" || "$PROVIDE_WEBOS" == "true" ]] \
            && [[ ! -x "${PROVIDER_FOLDER}/drivers/chromedriver" ]]; then
        tmp="$(mktemp -d)"
        download "$CHROMEDRIVER_URL" "${tmp}/chromedriver.zip"
        mkdir -p "${PROVIDER_FOLDER}/drivers"
        unzip -q -o "${tmp}/chromedriver.zip" -d "${PROVIDER_FOLDER}/drivers"
        chmod +x "${PROVIDER_FOLDER}/drivers/chromedriver"
        rm -rf "$tmp"
    fi
    if [[ -x "${PROVIDER_FOLDER}/drivers/chromedriver" ]]; then
        "${PROVIDER_FOLDER}/drivers/chromedriver" --version >/dev/null 2>&1 \
            && ok "Chromedriver 2.36 pronto em ${PROVIDER_FOLDER}/drivers" \
            || warn "O chromedriver em ${PROVIDER_FOLDER}/drivers não executa (bibliotecas ausentes?)."
    fi
}

# -----------------------------------------------------------------------------
# 7. Ambiente, serviço e logrotate
# -----------------------------------------------------------------------------
write_environment() {
    step "Gravando ${SYSCONFIG_FILE} e ${PROFILE_FILE}"
    local full_path
    full_path="$(build_path)"
    mkdir -p "$(dirname "$SYSCONFIG_FILE")"
    if [[ ! -s "$SYSCONFIG_FILE" ]]; then
        cat >"$SYSCONFIG_FILE" <<'EOF'
# /etc/sysconfig/gads - variáveis de ambiente dos serviços GADS (hub/provider).
# Gerado pelos scripts gads-*-install.sh. Após alterar, reinicie o serviço:
#   systemctl restart gads-provider     (e/ou gads-hub)
# Atenção: o systemd NÃO expande variáveis neste arquivo (ex.: $PATH);
# os valores devem estar completos.
EOF
    fi

    set_kv "$SYSCONFIG_FILE" PATH "$full_path"
    set_kv "$SYSCONFIG_FILE" JAVA_HOME "$JAVA_HOME"
    set_kv "$SYSCONFIG_FILE" APPIUM_HOME "$APPIUM_HOME"
    if [[ "$NEED_ANDROID" == "true" ]]; then
        set_kv "$SYSCONFIG_FILE" ANDROID_HOME "$ANDROID_HOME"
        set_kv "$SYSCONFIG_FILE" ANDROID_SDK_ROOT "$ANDROID_HOME"
    else
        unset_kv "$SYSCONFIG_FILE" ANDROID_HOME
        unset_kv "$SYSCONFIG_FILE" ANDROID_SDK_ROOT
    fi
    if [[ "$PROVIDE_TIZEN" == "true" ]]; then
        set_kv "$SYSCONFIG_FILE" TIZEN_HOME "$TIZEN_HOME"
    else
        unset_kv "$SYSCONFIG_FILE" TIZEN_HOME
    fi
    if [[ "$PROVIDE_WEBOS" == "true" ]]; then
        set_kv "$SYSCONFIG_FILE" LG_WEBOS_TV_SDK_HOME "$LG_WEBOS_TV_SDK_HOME"
        set_kv "$SYSCONFIG_FILE" WEBOS_CLI_TV "$WEBOS_CLI_TV"
    else
        unset_kv "$SYSCONFIG_FILE" LG_WEBOS_TV_SDK_HOME
        unset_kv "$SYSCONFIG_FILE" WEBOS_CLI_TV
    fi
    set_kv "$SYSCONFIG_FILE" PROVIDER_NICKNAME "$PROVIDER_NICKNAME"
    set_kv "$SYSCONFIG_FILE" PROVIDER_MONGO_DB "$PROVIDER_MONGO_DB"
    set_kv "$SYSCONFIG_FILE" PROVIDER_HUB "$PROVIDER_HUB"
    set_kv "$SYSCONFIG_FILE" PROVIDER_FOLDER "$PROVIDER_FOLDER"
    set_kv "$SYSCONFIG_FILE" PROVIDER_LOG_LEVEL "$PROVIDER_LOG_LEVEL"
    set_kv "$SYSCONFIG_FILE" PROVIDER_EXTRA_ARGS "$PROVIDER_EXTRA_ARGS"

    # Mesmo ambiente para shells interativos do root (adb, sdb, ares, appium...).
    {
        echo "# ${PROFILE_FILE} - gerado por ${SCRIPT_NAME}"
        echo "# Ambiente das ferramentas do GADS provider para shells interativos."
        grep -E '^(JAVA_HOME|APPIUM_HOME|ANDROID_HOME|ANDROID_SDK_ROOT|TIZEN_HOME|LG_WEBOS_TV_SDK_HOME|WEBOS_CLI_TV)=' "$SYSCONFIG_FILE" \
            | sed 's/^/export /'
        echo "case \":\${PATH}:\" in"
        echo "    *\":${NODE_HOME}/bin:\"*) ;;"
        echo "    *) export PATH=\"${full_path%":${BASE_PATH}"}:\${PATH}\" ;;"
        echo "esac"
    } >"$PROFILE_FILE"
    chmod 0644 "$PROFILE_FILE"
    grep -qF "$PROFILE_FILE" /root/.bashrc 2>/dev/null \
        || printf '\n# Ambiente do GADS provider\n[ -f %s ] && . %s\n' "$PROFILE_FILE" "$PROFILE_FILE" >>/root/.bashrc
    ok "Ambiente gravado"
}

write_service() {
    step "Configurando serviço systemd ${SERVICE_NAME}"
    cat >"$SERVICE_FILE" <<EOF
# ${SERVICE_FILE} - gerado por ${SCRIPT_NAME}
[Unit]
Description=GADS Provider Service
After=network-online.target
Wants=network-online.target

[Service]
User=root
Group=root
EnvironmentFile=${SYSCONFIG_FILE}
Type=simple
WorkingDirectory=${GADS_DIR}
ExecStart=/bin/bash -c 'trap "" SIGHUP; exec ./GADS provider --nickname=\${PROVIDER_NICKNAME} --mongo-db=\${PROVIDER_MONGO_DB} --hub=\${PROVIDER_HUB} --provider-folder=\${PROVIDER_FOLDER} --log-level=\${PROVIDER_LOG_LEVEL} \${PROVIDER_EXTRA_ARGS} >> ${SERVICE_LOG} 2>&1'
Restart=always
RestartSec=5s
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

    cat >"$LOGROTATE_FILE" <<EOF
${SERVICE_LOG} {
    daily
    rotate 7
    dateext
    dateformat -%Y-%m-%d
    extension .log
    copytruncate
    missingok
    notifempty
}
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    ok "Serviço e logrotate configurados"
}

open_firewall() {
    is_true "$OPEN_FIREWALL" || return 0
    command -v ufw >/dev/null || return 0
    ufw status 2>/dev/null | grep -q "Status: active" || return 0
    step "Liberando a porta ${PROVIDER_PORT} no UFW"
    ufw allow "${PROVIDER_PORT}/tcp" >/dev/null
    ok "Porta liberada"
}

# -----------------------------------------------------------------------------
# 8. Registro no hub e início do serviço
# -----------------------------------------------------------------------------
HUB_AUTH_HEADER=()
HUB_CODE=""
HUB_BODY=""

# Chama a API do hub; define HUB_CODE/HUB_BODY e retorna sucesso para HTTP 2xx.
# Não usar dentro de $(...), senão as variáveis globais se perdem.
hub_call() {
    local method="$1" path="$2" out
    shift 2
    out="$(mktemp)"
    HUB_CODE="$(curl -s -o "$out" -w '%{http_code}' --max-time 300 -X "$method" \
        "${HUB_AUTH_HEADER[@]}" "$@" "${PROVIDER_HUB}${path}" || true)"
    HUB_BODY="$(cat "$out")"
    rm -f "$out"
    [[ "$HUB_CODE" =~ ^2 ]]
}

# Conteúdo útil da última resposta. Releases recentes embrulham as respostas em
# {"success":..,"message":..,"result":..}; as antigas retornam o objeto direto.
hub_result() {
    jq -c '(.result? // .)' <<<"$HUB_BODY" 2>/dev/null || true
}

hub_error() {
    jq -r '.message? // .error? // empty' <<<"$HUB_BODY" 2>/dev/null || printf '%s' "${HUB_BODY:0:200}"
}

check_connectivity() {
    step "Verificando conectividade com hub e MongoDB"
    local code mongo_host="${PROVIDER_MONGO_DB%:*}" mongo_port="${PROVIDER_MONGO_DB##*:}"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${PROVIDER_HUB}/" || true)"
    if [[ "$code" =~ ^[23] ]]; then
        ok "Hub acessível em ${PROVIDER_HUB}"
        HUB_REACHABLE="true"
    else
        HUB_REACHABLE="false"
        warn "Hub não respondeu em ${PROVIDER_HUB} (HTTP ${code:-000})."
    fi
    if tcp_open "$mongo_host" "$mongo_port"; then
        ok "MongoDB acessível em ${PROVIDER_MONGO_DB}"
    else
        warn "MongoDB não respondeu em ${PROVIDER_MONGO_DB}. O provider ficará reiniciando até que ele esteja disponível."
    fi
}

# Garante um WebDriverAgent no hub para o iOS (o provider não inicia com iOS
# habilitado sem ele). Define:
#   WDA_FILE_ID   - id do .ipa a usar (releases novas referenciam o arquivo por id)
#   WDA_AVAILABLE - true se existe um WDA utilizável no hub
ensure_wda() {
    local current_id="$1" files="" desc="" name select_desc
    WDA_FILE_ID=""
    WDA_AVAILABLE="false"
    select_desc='[.[] | select(.metadata.description? == $d)] | last | .id // empty'
    hub_call GET /admin/files && files="$(hub_result)"
    [[ "$files" == \[* ]] || files="[]"

    if [[ -n "$WDA_IPA_PATH" ]]; then
        # A descrição carrega o hash do arquivo para não reenviar o mesmo .ipa
        desc="gads-provider-install sha256:$(sha256sum "$WDA_IPA_PATH" | cut -c1-16)"
        WDA_FILE_ID="$(jq -r --arg d "$desc" "$select_desc" <<<"$files")"
        if [[ -n "$WDA_FILE_ID" ]]; then
            ok "WebDriverAgent ${WDA_IPA_PATH} já está no hub"
        else
            name="$(basename "$WDA_IPA_PATH")"
            [[ "${name,,}" == *.ipa ]] || name="WebDriverAgent.ipa"
            log "Enviando ${WDA_IPA_PATH} para o hub"
            if hub_call POST /admin/files/webdriveragent \
                    -F "file=@${WDA_IPA_PATH};filename=${name}" -F "description=${desc}"; then
                hub_call GET /admin/files && files="$(hub_result)"
                WDA_FILE_ID="$(jq -r --arg d "$desc" "$select_desc" <<<"$files")"
            elif [[ "$HUB_CODE" == "404" ]]; then
                # Releases antigas: upload genérico com nome fixo WebDriverAgent.ipa
                hub_call POST /admin/upload-file \
                    -F "file=@${WDA_IPA_PATH}" -F "fileName=WebDriverAgent.ipa" \
                    || die "Falha ao enviar o WebDriverAgent.ipa (HTTP ${HUB_CODE}): $(hub_error)"
                hub_call GET /admin/files && files="$(hub_result)"
            else
                die "Falha ao enviar o WebDriverAgent.ipa (HTTP ${HUB_CODE}): $(hub_error)"
            fi
            ok "WebDriverAgent enviado ao hub"
        fi
    fi

    # Sem .ipa novo: mantém o já selecionado no provider ou usa o mais recente
    if [[ -z "$WDA_FILE_ID" && -n "$current_id" ]]; then
        WDA_FILE_ID="$(jq -r --arg id "$current_id" '[.[] | select(.id? == $id)] | first | .id // empty' <<<"$files")"
    fi
    if [[ -z "$WDA_FILE_ID" ]]; then
        WDA_FILE_ID="$(jq -r '[.[] | select(.metadata.type? == "wda")] | sort_by(.upload_date) | last | .id // empty' <<<"$files")"
    fi
    if [[ -n "$WDA_FILE_ID" ]] || grep -q '"WebDriverAgent.ipa"' <<<"$files"; then
        WDA_AVAILABLE="true"
    fi
}

register_provider() {
    if [[ "$PROVIDER_REGISTER" != "true" ]]; then
        warn "PROVIDER_REGISTER=false: crie o provider '${PROVIDER_NICKNAME}' em Admin > Providers no hub."
        return 0
    fi
    step "Registrando o provider '${PROVIDER_NICKNAME}' no hub"
    [[ "$HUB_REACHABLE" == "true" ]] \
        || die "Hub inacessível em ${PROVIDER_HUB}; não é possível registrar o provider (ou use PROVIDER_REGISTER=false)."

    local token="" providers existing payload ios_enabled="$PROVIDE_IOS"
    if hub_call POST /authenticate -H 'Content-Type: application/json' \
            -d "$(jq -n --arg u "$HUB_ADMIN_USER" --arg p "$HUB_ADMIN_PASSWORD" '{username: $u, password: $p}')"; then
        token="$(hub_result | jq -r '.access_token? // empty')"
    fi
    [[ -n "$token" ]] && HUB_AUTH_HEADER=(-H "Authorization: Bearer ${token}")

    hub_call GET /admin/providers \
        || die "Sem acesso à API de administração do hub (HTTP ${HUB_CODE}). Verifique HUB_ADMIN_USER/HUB_ADMIN_PASSWORD."
    providers="$(hub_result)"
    [[ "$providers" == \[* ]] || providers="[]"
    existing="$(jq -c --arg n "$PROVIDER_NICKNAME" '[.[] | select(.nickname == $n)] | first // empty' <<<"$providers")"

    WDA_FILE_ID=""
    if [[ "$PROVIDE_IOS" == "true" ]]; then
        ensure_wda "$(jq -r '.web_driver_agent_ipa? // empty' <<<"${existing:-null}")"
        if [[ "$WDA_AVAILABLE" != "true" ]]; then
            ios_enabled="false"
            warn "Não há WebDriverAgent no hub: iOS DESABILITADO na configuração do provider (o host está preparado). Envie o .ipa assinado em Admin > Files (ou informe WDA_IPA_PATH) e reexecute o script."
        fi
    fi

    # Mescla com a configuração existente para preservar campos editados na UI
    # (ex.: supervision_password, use_gads_ios_stream). Campos que a release
    # instalada não conhece são ignorados pelo hub.
    payload="$(jq -cn \
        --argjson base "${existing:-null}" \
        --arg nickname "$PROVIDER_NICKNAME" \
        --arg host "$PROVIDER_HOST_ADDRESS" \
        --argjson port "$PROVIDER_PORT" \
        --argjson android "$PROVIDE_ANDROID" \
        --argjson androidtv "$PROVIDE_ANDROID_TV" \
        --argjson ios "$ios_enabled" \
        --argjson tizen "$PROVIDE_TIZEN" \
        --argjson webos "$PROVIDE_WEBOS" \
        --argjson grid "$USE_SELENIUM_GRID" \
        --arg grid_url "$SELENIUM_GRID" \
        --arg wda "$WDA_BUNDLE_ID" \
        --arg wda_id "$WDA_FILE_ID" \
        --argjson manage_wda "$PROVIDE_IOS" \
        '($base // {}) as $b
         | $b + {
            os: "linux",
            nickname: $nickname,
            host_address: $host,
            port: $port,
            provide_android: $android,
            provide_androidtv: $androidtv,
            provide_ios: $ios,
            provide_tizen: $tizen,
            provide_webos: $webos,
            provide_roku: ($b.provide_roku // false),
            use_selenium_grid: $grid,
            selenium_grid: $grid_url,
            wda_bundle_id: $wda,
            web_driver_agent_ipa: (if $manage_wda then $wda_id else ($b.web_driver_agent_ipa // "") end),
            setup_appium_servers: true
         }')"

    if [[ -n "$existing" ]]; then
        hub_call POST /admin/providers/update -H 'Content-Type: application/json' -d "$payload" \
            || die "Falha ao atualizar o provider no hub (HTTP ${HUB_CODE}): $(hub_error)"
        ok "Configuração do provider '${PROVIDER_NICKNAME}' atualizada no hub"
    else
        hub_call POST /admin/providers/add -H 'Content-Type: application/json' -d "$payload" \
            || die "Falha ao criar o provider no hub (HTTP ${HUB_CODE}): $(hub_error)"
        ok "Provider '${PROVIDER_NICKNAME}' criado no hub"
    fi
    PROVIDER_IOS_ENABLED="$ios_enabled"
}

start_and_verify() {
    step "Iniciando ${SERVICE_NAME}"
    touch "$SERVICE_LOG"
    local log_offset
    log_offset="$(stat -c %s "$SERVICE_LOG")"
    systemctl restart "$SERVICE_NAME"
    if [[ "$GADS_BINARY_CHANGED" == "true" ]] && systemctl is-active --quiet gads-hub; then
        log "Binário atualizado: reiniciando também gads-hub"
        systemctl restart gads-hub
    fi

    # Na primeira execução o provider instala o plugin appium-gads, o que pode
    # levar alguns minutos. Um reinício automático indica falha na inicialização.
    log "Aguardando o provider abrir a porta ${PROVIDER_PORT} (até 5 min)..."
    for _ in $(seq 1 150); do
        if [[ "$(systemctl show -p NRestarts --value "$SERVICE_NAME")" != "0" ]]; then
            break
        fi
        if ss -ltn "sport = :${PROVIDER_PORT}" | grep -q LISTEN; then
            ok "Provider escutando na porta ${PROVIDER_PORT}"
            return 0
        fi
        sleep 2
    done
    warn "O provider não iniciou corretamente. Últimas linhas de ${SERVICE_LOG}:"
    tail -c +"$((log_offset + 1))" "$SERVICE_LOG" | tail -n 30 >&2 || true
    die "Falha ao iniciar o provider (veja ${SERVICE_LOG} e ${PROVIDER_FOLDER}/provider.log)"
}

report_tools() {
    step "Resumo das ferramentas instaladas"
    printf '  %-14s %s\n' "Node.js" "$(node --version)"
    printf '  %-14s %s\n' "Appium" "$(appium --version | tail -n1)"
    appium driver list --installed --json 2>/dev/null \
        | jq -r 'to_entries[] | "  driver         \(.key)@\(.value.version)"'
    appium plugin list --installed --json 2>/dev/null \
        | jq -r 'to_entries[] | "  plugin         \(.key)@\(.value.version)"'
    printf '  %-14s %s\n' "Java" "$(java -version 2>&1 | head -n1)"
    [[ "$NEED_ANDROID" == "true" ]]    && printf '  %-14s %s\n' "adb" "$(adb version | head -n1)"
    [[ "$PROVIDE_TIZEN" == "true" ]]   && printf '  %-14s %s\n' "sdb" "$(sdb version 2>/dev/null | head -n1)"
    [[ "$PROVIDE_WEBOS" == "true" ]]   && printf '  %-14s %s\n' "ares" "$(ares -V 2>/dev/null | head -n1)"
    [[ "$PROVIDE_IOS" == "true" ]]     && printf '  %-14s %s\n' "usbmuxd" "$(dpkg-query -W -f='${Version}' usbmuxd 2>/dev/null)"
    printf '  %-14s %s\n' "GADS" "$(cat "${GADS_DIR}/.gads-release")"
}

summary() {
    cat <<EOF

${C_OK}==============================================================
 GADS PROVIDER '${PROVIDER_NICKNAME}' instalado
==============================================================${C_END}
  Provider:        http://${PROVIDER_HOST_ADDRESS}:${PROVIDER_PORT}
  Hub:             ${PROVIDER_HUB}
  MongoDB:         ${PROVIDER_MONGO_DB}
  iOS habilitado:  ${PROVIDER_IOS_ENABLED:-${PROVIDE_IOS}}

  Configuração:    ${SYSCONFIG_FILE}
  Serviço:         systemctl status|restart ${SERVICE_NAME}
  Log do serviço:  tail -f ${SERVICE_LOG}
  Logs do GADS:    ${PROVIDER_FOLDER}
  Log instalação:  ${INSTALL_LOG}

  Próximos passos:
   - Cadastre os dispositivos em Admin > Devices no hub, associados a
     '${PROVIDER_NICKNAME}', e reinicie o provider após alterações.
   - Android: habilite a depuração USB e aceite a chave RSA (adb devices).
   - Android TV: habilite a depuração de rede na TV e use adb connect <ip-da-tv>:5555
   - Tizen:   sdb connect <ip-da-tv>
   - webOS:   ares-setup-device --add <nome> -i "host=<ip>" -i "port=9922" -i "username=prisoner"
              (o nome deve ser IGUAL ao nome do dispositivo cadastrado no GADS)
   - iOS:     envie o WebDriverAgent.ipa assinado em Admin > Files.
EOF
    if (( ${#WARNINGS[@]} )); then
        printf '\n%sAvisos:%s\n' "$C_WARN" "$C_END"
        printf '  - %s\n' "${WARNINGS[@]}"
    fi
}

main() {
    parse_args "$@"
    check_prerequisites
    exec > >(tee -a "$INSTALL_LOG") 2>&1
    log "===== ${SCRIPT_NAME} iniciado em $(date -Is) ====="
    load_config
    install_system_packages
    install_node
    install_appium
    install_android_sdk
    install_tizen
    install_webos_cli
    install_gads_binary
    write_environment
    check_connectivity
    register_provider
    write_service
    open_firewall
    start_and_verify
    report_tools
    summary
}

main "$@"
