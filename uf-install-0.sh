#!/usr/bin/env bash
set -euo pipefail

SPLUNK_HOME="/opt/splunkforwarder"

UF_VERSION="${UF_VERSION}"
UF_BUILD="${UF_BUILD}"
UF_PASS="${UF_ADMIN_PASS}"

INDEXER_HOST="${SPLUNK_INDEXER_HOST}"
INDEXER_PORT="${SPLUNK_INDEXER_PORT}"

TETRAGON_LOG="${UF_TETRAGON_LOG}"
ALERT_GLOB="${UF_ALERT_GLOB}"

ST_MAIN="${UF_SOURCETYPE_MAIN}"
ST_ALERT="${UF_SOURCETYPE_ALERT}"
ALERT_INDEX="${UF_ALERT_INDEX}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1; }

arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "unsupported" ;;
  esac
}

pm() {
  if need dnf; then echo "dnf"
  elif need yum; then echo "yum"
  elif need apt-get; then echo "apt"
  else echo "none"
  fi
}

ensure_curl() {
  if need curl; then return 0; fi
  case "$(pm)" in
    dnf) dnf install -y curl-minimal ;;
    yum) yum install -y curl ;;
    apt) apt-get update -y && apt-get install -y curl ;;
    *) echo "no curl and no package manager" >&2; exit 1 ;;
  esac
}

download_rpm() {
  local a="$1"
  local base="https://download.splunk.com/products/universalforwarder/releases/${UF_VERSION}/linux"
  local file
  if [[ "$a" == "x86_64" ]]; then
    file="splunkforwarder-${UF_VERSION}-${UF_BUILD}.x86_64.rpm"
  else
    file="splunkforwarder-${UF_VERSION}-${UF_BUILD}.aarch64.rpm"
  fi
  echo "${base}/${file} ${file}"
}

install_pkg() {
  local a="$1"
  local p
  p="$(pm)"
  if [[ "$p" == "apt" ]]; then
    echo "rpm-based install expected on EKS nodes" >&2
    exit 1
  fi

  ensure_curl

  local url file tmpdir
  read -r url file < <(download_rpm "$a")
  tmpdir="/tmp/splunk-uf"
  mkdir -p "$tmpdir"

  log "download ${url}"
  curl -fL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 900 -o "${tmpdir}/${file}" "$url"

  if [[ -x "${SPLUNK_HOME}/bin/splunk" ]]; then
    "${SPLUNK_HOME}/bin/splunk" stop || true
  fi

  if [[ "$p" == "dnf" ]]; then
    dnf install -y "${tmpdir}/${file}"
  else
    yum install -y "${tmpdir}/${file}"
  fi
}

seed_start_stop() {
  "${SPLUNK_HOME}/bin/splunk" start --accept-license --answer-yes --no-prompt --seed-passwd "${UF_PASS}" || true
  "${SPLUNK_HOME}/bin/splunk" stop || true
}

write_confs() {
  mkdir -p "${SPLUNK_HOME}/etc/system/local"

  cat > "${SPLUNK_HOME}/etc/system/local/outputs.conf" <<EOC
[tcpout]
defaultGroup = default-indexer

[tcpout:default-indexer]
server = ${INDEXER_HOST}:${INDEXER_PORT}

[tcpout-server://${INDEXER_HOST}:${INDEXER_PORT}]
EOC

  cat > "${SPLUNK_HOME}/etc/system/local/inputs.conf" <<EOC
[monitor://${TETRAGON_LOG}]
sourcetype = ${ST_MAIN}

[monitor://${ALERT_GLOB}]
sourcetype = ${ST_ALERT}
index = ${ALERT_INDEX}
EOC

  cat > "${SPLUNK_HOME}/etc/system/local/props.conf" <<EOC
[_json]
TRUNCATE = 0

[${ST_ALERT}]
INDEXED_EXTRACTIONS = json
KV_MODE = none
SHOULD_LINEMERGE = false
category = Structured
TRUNCATE = 0
EOC

  cat > "${SPLUNK_HOME}/etc/system/local/limits.conf" <<'EOC'
[thruput]
maxKBps = 0
EOC
}

enable_boot_start() {
  "${SPLUNK_HOME}/bin/splunk" enable boot-start -user root || true
}

start_uf() {
  "${SPLUNK_HOME}/bin/splunk" start || true
  "${SPLUNK_HOME}/bin/splunk" status || true
}

main() {
  local a
  a="$(arch)"
  [[ "$a" != "unsupported" ]] || { echo "unsupported arch" >&2; exit 1; }

  install_pkg "$a"
  [[ -x "${SPLUNK_HOME}/bin/splunk" ]] || { echo "splunk binary not found" >&2; exit 1; }

  seed_start_stop
  write_confs
  enable_boot_start
  start_uf
}

main "$@"
