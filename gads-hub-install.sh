#!/usr/bin/env bash
# =============================================================================
# gads-hub-install.sh - instala e configura um GADS HUB como serviço systemd.
#
# Alvo: Ubuntu (amd64), executado como root.
# Uso:  sudo ./gads-hub-install.sh [-c gads-hub.conf] [--force-download]
#
# Etapas:
#   1. Dependências de sistema (curl, unzip, jq, logrotate)
#   2. MongoDB local via Docker (opcional, ver MONGO_INSTALL)
#   3. Binário do GADS (release do GitHub) em GADS_DIR
#   4. /etc/sysconfig/gads, unit systemd gads-hub e logrotate
#   5. Início do serviço e verificação de saúde
#
# O script é idempotente: pode ser reexecutado para aplicar alterações do
# arquivo de configuração ou atualizar a release do GADS.
# =============================================================================
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/gads-hub.conf"
FORCE_DOWNLOAD="false"

SYSCONFIG_FILE="/etc/sysconfig/gads"
SERVICE_NAME="gads-hub"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOGROTATE_FILE="/etc/logrotate.d/${SERVICE_NAME}"
SERVICE_LOG="/var/log/${SERVICE_NAME}.log"
INSTALL_LOG="/var/log/gads-hub-install.log"
MONGO_CONTAINER="gads-mongodb"
MONGO_VOLUME="gads-mongo-data"
BASE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# -----------------------------------------------------------------------------
# Utilitários
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_INFO=$'\e[1;34m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'; C_END=$'\e[0m'
else
    C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_END=""
fi

log()     { printf '%s[%s] %s%s\n' "$C_INFO" "$(date +%H:%M:%S)" "$*" "$C_END"; }
ok()      { printf '%s[ OK ] %s%s\n' "$C_OK" "$*" "$C_END"; }
warn()    { printf '%s[WARN] %s%s\n' "$C_WARN" "$*" "$C_END" >&2; }
die()     { printf '%s[ERRO] %s%s\n' "$C_ERR" "$*" "$C_END" >&2; exit 1; }
step()    { printf '\n%s==> %s%s\n' "$C_INFO" "$*" "$C_END"; }
is_true() { [[ "${1,,}" =~ ^(true|yes|y|1|sim|s)$ ]]; }

trap 'die "Falha inesperada na linha ${LINENO}: ${BASH_COMMAND}"' ERR

usage() {
    cat <<EOF
Uso: sudo ./${SCRIPT_NAME} [opções]

Opções:
  -c, --config ARQUIVO   Arquivo de configuração (padrão: ${SCRIPT_DIR}/gads-hub.conf)
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

# Remove uma chave de um arquivo de ambiente (se existir).
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

is_local_host() {
    local host="$1" addr
    case "$host" in
        localhost|127.*|::1|0.0.0.0|"$(hostname)"|"$(hostname -f 2>/dev/null)") return 0 ;;
    esac
    for addr in $(hostname -I 2>/dev/null); do
        [[ "$host" == "$addr" ]] && return 0
    done
    return 1
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

    HUB_HOST_ADDRESS="${HUB_HOST_ADDRESS:-auto}"
    HUB_PORT="${HUB_PORT:-10000}"
    HUB_MONGO_DB="${HUB_MONGO_DB:-localhost:27017}"
    HUB_AUTH="${HUB_AUTH:-true}"
    MONGO_INSTALL="${MONGO_INSTALL:-auto}"
    MONGO_IMAGE="${MONGO_IMAGE:-mongo:6.0}"
    MONGO_IMAGE_NO_AVX="${MONGO_IMAGE_NO_AVX:-mongo:4.4}"
    GADS_VERSION="${GADS_VERSION:-latest}"
    GADS_REPO="${GADS_REPO:-gifflet/GADS}"
    GADS_DIR="${GADS_DIR:-/root/GADS}"
    HUB_FILES_DIR="${HUB_FILES_DIR-/root/GADS/hub-files}"
    GADS_CLIENT_ID_PREFIX="${GADS_CLIENT_ID_PREFIX:-}"
    HUB_EXTRA_ARGS="${HUB_EXTRA_ARGS:-}"
    OPEN_FIREWALL="${OPEN_FIREWALL:-true}"
    GITHUB_TOKEN="${GITHUB_TOKEN:-}"

    # Normalizações e validações
    HUB_HOST_ADDRESS="$(strip_scheme "$HUB_HOST_ADDRESS")"
    HUB_HOST_ADDRESS="${HUB_HOST_ADDRESS%%:*}"
    if [[ "$HUB_HOST_ADDRESS" == "auto" ]]; then
        HUB_HOST_ADDRESS="$(primary_ip)"
        [[ -n "$HUB_HOST_ADDRESS" ]] || die "Não foi possível detectar o IP principal; defina HUB_HOST_ADDRESS."
        log "HUB_HOST_ADDRESS=auto -> ${HUB_HOST_ADDRESS}"
    fi
    [[ "$HUB_PORT" =~ ^[0-9]+$ ]] && (( HUB_PORT > 0 && HUB_PORT < 65536 )) \
        || die "HUB_PORT inválida: ${HUB_PORT}"

    HUB_MONGO_DB="$(strip_scheme "${HUB_MONGO_DB#mongodb://}")"
    [[ "$HUB_MONGO_DB" == *:* ]] || HUB_MONGO_DB="${HUB_MONGO_DB}:27017"
    MONGO_HOST="${HUB_MONGO_DB%:*}"
    MONGO_PORT="${HUB_MONGO_DB##*:}"
    [[ "$MONGO_PORT" =~ ^[0-9]+$ ]] || die "Porta do MongoDB inválida em HUB_MONGO_DB: ${HUB_MONGO_DB}"

    if is_true "$HUB_AUTH"; then HUB_AUTH="true"; else HUB_AUTH="false"; fi

    case "${MONGO_INSTALL,,}" in
        auto)  if is_local_host "$MONGO_HOST"; then MONGO_INSTALL="true"; else MONGO_INSTALL="false"; fi ;;
        true|false) MONGO_INSTALL="${MONGO_INSTALL,,}" ;;
        *) die "MONGO_INSTALL deve ser auto, true ou false (atual: ${MONGO_INSTALL})" ;;
    esac

    cat <<EOF

  Hub:            http://${HUB_HOST_ADDRESS}:${HUB_PORT}
  MongoDB:        ${HUB_MONGO_DB} (instalação local: ${MONGO_INSTALL})
  Autenticação:   ${HUB_AUTH}
  Release GADS:   ${GADS_VERSION} (${GADS_REPO})
  Diretório:      ${GADS_DIR}

EOF
}

# -----------------------------------------------------------------------------
# Etapas de instalação
# -----------------------------------------------------------------------------
install_system_packages() {
    step "Instalando dependências de sistema"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        ca-certificates curl unzip jq logrotate iproute2
    ok "Dependências instaladas"
}

install_mongodb() {
    [[ "$MONGO_INSTALL" == "true" ]] || {
        step "Verificando MongoDB externo em ${HUB_MONGO_DB}"
        if tcp_open "$MONGO_HOST" "$MONGO_PORT"; then
            ok "MongoDB acessível em ${HUB_MONGO_DB}"
        else
            warn "MongoDB não respondeu em ${HUB_MONGO_DB}. O hub ficará reiniciando até que ele esteja disponível."
        fi
        return 0
    }

    step "Instalando MongoDB local via Docker"
    if ! command -v docker >/dev/null; then
        apt-get install -y docker.io
    fi
    systemctl enable --now docker >/dev/null

    local image="$MONGO_IMAGE"
    if ! grep -qw avx /proc/cpuinfo; then
        warn "CPU sem suporte a AVX: MongoDB 5.0+ não executa. Usando ${MONGO_IMAGE_NO_AVX}."
        image="$MONGO_IMAGE_NO_AVX"
    fi

    if docker container inspect "$MONGO_CONTAINER" >/dev/null 2>&1; then
        local current_image current_port
        current_image="$(docker container inspect -f '{{.Config.Image}}' "$MONGO_CONTAINER")"
        current_port="$(docker container inspect -f '{{(index (index .HostConfig.PortBindings "27017/tcp") 0).HostPort}}' "$MONGO_CONTAINER" 2>/dev/null || true)"
        if [[ "$current_image" != "$image" || "$current_port" != "$MONGO_PORT" ]]; then
            log "Recriando contêiner ${MONGO_CONTAINER} (${current_image}:${current_port} -> ${image}:${MONGO_PORT}); os dados ficam no volume ${MONGO_VOLUME}"
            docker rm -f "$MONGO_CONTAINER" >/dev/null
        fi
    fi

    if ! docker container inspect "$MONGO_CONTAINER" >/dev/null 2>&1; then
        docker run -d --name "$MONGO_CONTAINER" --restart=always \
            -p "${MONGO_PORT}:27017" -v "${MONGO_VOLUME}:/data/db" "$image" >/dev/null
    else
        docker start "$MONGO_CONTAINER" >/dev/null
    fi

    for _ in $(seq 1 30); do
        if tcp_open 127.0.0.1 "$MONGO_PORT"; then
            ok "MongoDB (${image}) em execução na porta ${MONGO_PORT}"
            return 0
        fi
        sleep 2
    done
    docker logs --tail 30 "$MONGO_CONTAINER" >&2 || true
    die "MongoDB não ficou disponível na porta ${MONGO_PORT}"
}

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
    mkdir -p "$GADS_DIR"

    GADS_BINARY_CHANGED="false"
    if [[ -x "${GADS_DIR}/GADS" && "$(cat "$marker" 2>/dev/null)" == "$tag" && "$FORCE_DOWNLOAD" != "true" ]]; then
        ok "Release ${tag} já instalada em ${GADS_DIR}/GADS"
        return 0
    fi

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
}

write_sysconfig() {
    step "Gravando ${SYSCONFIG_FILE}"
    mkdir -p "$(dirname "$SYSCONFIG_FILE")"
    if [[ ! -s "$SYSCONFIG_FILE" ]]; then
        cat >"$SYSCONFIG_FILE" <<'EOF'
# /etc/sysconfig/gads - variáveis de ambiente dos serviços GADS (hub/provider).
# Gerado pelos scripts gads-*-install.sh. Após alterar, reinicie o serviço:
#   systemctl restart gads-hub     (e/ou gads-provider)
# Atenção: o systemd NÃO expande variáveis neste arquivo (ex.: $PATH);
# os valores devem estar completos.
EOF
    fi
    # O PATH é compartilhado com o provider (que precisa de um PATH maior);
    # o hub só o define se ainda não existir.
    grep -q '^PATH=' "$SYSCONFIG_FILE" || set_kv "$SYSCONFIG_FILE" PATH "$BASE_PATH"
    set_kv "$SYSCONFIG_FILE" HUB_HOST_ADDRESS "$HUB_HOST_ADDRESS"
    set_kv "$SYSCONFIG_FILE" HUB_PORT "$HUB_PORT"
    set_kv "$SYSCONFIG_FILE" HUB_MONGO_DB "$HUB_MONGO_DB"
    set_kv "$SYSCONFIG_FILE" HUB_AUTH "$HUB_AUTH"
    set_kv "$SYSCONFIG_FILE" HUB_FILES_DIR "$HUB_FILES_DIR"
    set_kv "$SYSCONFIG_FILE" HUB_EXTRA_ARGS "$HUB_EXTRA_ARGS"
    if [[ -n "$GADS_CLIENT_ID_PREFIX" ]]; then
        set_kv "$SYSCONFIG_FILE" GADS_CLIENT_ID_PREFIX "$GADS_CLIENT_ID_PREFIX"
    else
        unset_kv "$SYSCONFIG_FILE" GADS_CLIENT_ID_PREFIX
    fi
    [[ -n "$HUB_FILES_DIR" ]] && mkdir -p "$HUB_FILES_DIR"
    ok "Variáveis do hub gravadas"
}

write_service() {
    step "Configurando serviço systemd ${SERVICE_NAME}"
    local after="network-online.target"
    [[ "$MONGO_INSTALL" == "true" ]] && after="${after} docker.service"

    cat >"$SERVICE_FILE" <<EOF
# ${SERVICE_FILE} - gerado por ${SCRIPT_NAME}
[Unit]
Description=GADS Hub Service
After=${after}
Wants=network-online.target

[Service]
User=root
Group=root
EnvironmentFile=${SYSCONFIG_FILE}
Type=simple
WorkingDirectory=${GADS_DIR}
ExecStart=/bin/bash -c 'trap "" SIGHUP; exec ./GADS hub --host-address=\${HUB_HOST_ADDRESS} --port=\${HUB_PORT} --mongo-db=\${HUB_MONGO_DB} --auth=\${HUB_AUTH} --files-dir=\${HUB_FILES_DIR} \${HUB_EXTRA_ARGS} >> ${SERVICE_LOG} 2>&1'
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
    step "Liberando portas no UFW"
    ufw allow "${HUB_PORT}/tcp" >/dev/null
    [[ "$MONGO_INSTALL" == "true" ]] && ufw allow "${MONGO_PORT}/tcp" >/dev/null
    ok "Portas liberadas"
}

start_and_verify() {
    step "Iniciando ${SERVICE_NAME}"
    touch "$SERVICE_LOG"
    local log_offset
    log_offset="$(stat -c %s "$SERVICE_LOG")"
    systemctl restart "$SERVICE_NAME"
    # Hub e provider compartilham o binário: se ele mudou, reinicia o provider local.
    if [[ "$GADS_BINARY_CHANGED" == "true" ]] && systemctl is-active --quiet gads-provider; then
        log "Binário atualizado: reiniciando também gads-provider"
        systemctl restart gads-provider
    fi

    local check_host="$HUB_HOST_ADDRESS" url code
    [[ "$check_host" == "0.0.0.0" ]] && check_host="127.0.0.1"
    url="http://${check_host}:${HUB_PORT}"
    for _ in $(seq 1 30); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${url}/" || true)"
        if [[ "$code" =~ ^[23] ]]; then
            ok "Hub respondendo em ${url} (HTTP ${code})"
            verify_login "$url"
            return 0
        fi
        sleep 2
    done
    warn "O hub não respondeu em ${url}. Últimas linhas de ${SERVICE_LOG}:"
    tail -c +"$((log_offset + 1))" "$SERVICE_LOG" | tail -n 30 >&2 || true
    systemctl --no-pager status "$SERVICE_NAME" >&2 || true
    die "Falha ao iniciar o hub"
}

verify_login() {
    local url="$1" resp
    [[ "$HUB_AUTH" == "true" ]] || return 0
    resp="$(curl -s --max-time 5 -X POST "${url}/authenticate" \
        -H 'Content-Type: application/json' \
        -d '{"username":"admin","password":"password"}' || true)"
    # Releases novas embrulham a resposta em {"success":..,"result":{..}}
    if jq -e '(.result? // .) | .access_token? // empty' >/dev/null 2>&1 <<<"$resp"; then
        warn "O usuário 'admin' ainda usa a senha padrão 'password'. Altere-a em Admin > Users."
    fi
}

summary() {
    cat <<EOF

${C_OK}==============================================================
 GADS HUB instalado com sucesso
==============================================================${C_END}
  UI / API:        http://${HUB_HOST_ADDRESS}:${HUB_PORT}
  Swagger:         http://${HUB_HOST_ADDRESS}:${HUB_PORT}/swagger/index.html
  Grid Appium:     http://${HUB_HOST_ADDRESS}:${HUB_PORT}/grid
  Login padrão:    admin / password   (autenticação: ${HUB_AUTH})
  MongoDB:         ${HUB_MONGO_DB}

  Configuração:    ${SYSCONFIG_FILE}
  Serviço:         systemctl status|restart ${SERVICE_NAME}
  Log do serviço:  tail -f ${SERVICE_LOG}
  Log instalação:  ${INSTALL_LOG}

  Próximo passo: instalar os providers com gads-provider-install.sh
  apontando PROVIDER_HUB=http://${HUB_HOST_ADDRESS}:${HUB_PORT} e
  PROVIDER_MONGO_DB=<endereço acessível do MongoDB>.
EOF
}

main() {
    parse_args "$@"
    check_prerequisites
    exec > >(tee -a "$INSTALL_LOG") 2>&1
    log "===== ${SCRIPT_NAME} iniciado em $(date -Is) ====="
    load_config
    install_system_packages
    install_mongodb
    install_gads_binary
    write_sysconfig
    write_service
    open_firewall
    start_and_verify
    summary
}

main "$@"
