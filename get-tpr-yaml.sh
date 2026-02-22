#!/usr/bin/env bash
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"

TS="$(date +%Y%m%d-%H%M%S)"
OUTFILE="${1:-$HOME/Downloads/tpr-result-$TS.txt}"

# Optional: provide expected list source file (the TPR 1.18.0 metadata/readme dump)
#   export TPR_EXPECTED_FILE="/path/to/Tetragon Policy Ruleset-1.18.0-helm metadata-values-readme.txt"
TPR_EXPECTED_FILE="${TPR_EXPECTED_FILE:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

ensure_cluster_access() {
  command -v "$KUBECTL" >/dev/null 2>&1 || die "kubectl not found (or set KUBECTL env var)"
  $KUBECTL version --client >/dev/null 2>&1 || die "kubectl not usable"
  $KUBECTL get ns >/dev/null 2>&1 || die "cannot access cluster (check kubeconfig/context)"
}

ensure_outdir() {
  local d
  d="$(dirname "$OUTFILE")"
  mkdir -p "$d" || die "cannot create output dir: $d"
}

# Detect whether a resource is namespaced via api-resources output.
# Prints "true" or "false". Defaults to "false" if unknown.
is_namespaced() {
  local res="$1"
  local v
  v="$($KUBECTL api-resources --api-group=cilium.io -o wide --no-headers 2>/dev/null \
      | awk -v r="$res" '$1==r {print $4; exit}')"
  if [[ "$v" == "true" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# List objects as: "ns<TAB>name"
# For cluster-scoped resources, ns is "-".
list_objects() {
  local res="$1"
  local namespaced="$2"

  if [[ "$namespaced" == "true" ]]; then
    $KUBECTL get "$res" -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers 2>/dev/null \
      | awk 'NF>=2 {print $1 "\t" $2}' \
      | sort
  else
    $KUBECTL get "$res" -o custom-columns='NAME:.metadata.name' --no-headers 2>/dev/null \
      | awk 'NF>=1 {print "-\t" $1}' \
      | sort
  fi
}

dump_one_yaml() {
  local res="$1"
  local namespaced="$2"
  local ns="$3"
  local name="$4"

  {
    echo "----- BEGIN res=$res ns=$ns name=$name -----"
    if [[ "$namespaced" == "true" ]]; then
      $KUBECTL get "$res" -n "$ns" "$name" -o yaml
    else
      $KUBECTL get "$res" "$name" -o yaml
    fi
    echo "----- END res=$res ns=$ns name=$name -----"
    echo
  } >>"$OUTFILE"
}

# Extract expected AlertRule names from the metadata/readme file.
extract_expected_alertrules() {
  local f="$1"
  awk '
    /BEGIN ALERTRULES TABLE/ {in=1; next}
    /END ALERTRULES TABLE/ {in=0}
    in {
      if (match($0, /^\|\s*[0-9]+\s*\|\s*([a-z0-9][a-z0-9-]*)\s*\|/, m)) print m[1]
    }
  ' "$f" | sort -u
}

# Extract expected TracingPolicy names from the mermaid graph block.
extract_expected_tracingpolicies() {
  local f="$1"
  awk '
    /BEGIN ALERTRULES GRAPH/ {in=1; next}
    in && /```mermaid/ {mermaid=1; next}
    mermaid && /^```/ {exit}
    mermaid {
      if (match($0, /TracingPolicy:\s*([^"]+)\"]/, m)) print m[1]
    }
  ' "$f" | sort -u
}

write_header() {
  {
    echo "===== TPR EXPORT ====="
    echo "time: $(date -Iseconds)"
    echo "context: $($KUBECTL config current-context 2>/dev/null || echo "<unknown>")"
    echo "output: $OUTFILE"
    echo
    echo "===== LIST (cluster snapshot) ====="
    $KUBECTL get alertrules 2>/dev/null || true
    $KUBECTL get tracingpolicies 2>/dev/null || $KUBECTL get tracingpolicy 2>/dev/null || true
    echo
    echo "===== YAML DUMPS ====="
    echo
  } >"$OUTFILE"
}

main() {
  ensure_cluster_access
  ensure_outdir

  # Use plural resources by default; they work even if you usually type singular.
  local AR_RES="alertrules"
  local TP_RES="tracingpolicies"

  # Verify resources exist
  $KUBECTL get "$AR_RES" >/dev/null 2>&1 || die "resource not found: $AR_RES"
  $KUBECTL get "$TP_RES" >/dev/null 2>&1 || die "resource not found: $TP_RES"

  local AR_NS TP_NS
  AR_NS="$(is_namespaced "$AR_RES")"
  TP_NS="$(is_namespaced "$TP_RES")"

  write_header

  local tmp_actual_ar tmp_actual_tp
  tmp_actual_ar="$(mktemp)"
  tmp_actual_tp="$(mktemp)"
  trap 'rm -f "$tmp_actual_ar" "$tmp_actual_tp"' EXIT

  # Dump AlertRules
  {
    echo "##### AlertRule ($AR_RES) namespaced=$AR_NS #####"
    echo
  } >>"$OUTFILE"

  local line ns name ar_count=0
  while IFS=$'\t' read -r ns name; do
    [[ -z "${name:-}" ]] && continue
    ar_count=$((ar_count + 1))
    echo "$name" >>"$tmp_actual_ar"
    if [[ "$AR_NS" == "true" ]]; then
      dump_one_yaml "$AR_RES" "$AR_NS" "$ns" "$name"
    else
      dump_one_yaml "$AR_RES" "$AR_NS" "-" "$name"
    fi
  done < <(list_objects "$AR_RES" "$AR_NS")

  {
    echo "##### END AlertRule count=$ar_count #####"
    echo
  } >>"$OUTFILE"

  # Dump TracingPolicies
  {
    echo "##### TracingPolicy ($TP_RES) namespaced=$TP_NS #####"
    echo
  } >>"$OUTFILE"

  local tp_count=0
  while IFS=$'\t' read -r ns name; do
    [[ -z "${name:-}" ]] && continue
    tp_count=$((tp_count + 1))
    echo "$name" >>"$tmp_actual_tp"
    if [[ "$TP_NS" == "true" ]]; then
      dump_one_yaml "$TP_RES" "$TP_NS" "$ns" "$name"
    else
      dump_one_yaml "$TP_RES" "$TP_NS" "-" "$name"
    fi
  done < <(list_objects "$TP_RES" "$TP_NS")

  {
    echo "##### END TracingPolicy count=$tp_count #####"
    echo
  } >>"$OUTFILE"

  # Summary + optional "missing names" check
  {
    echo "===== SUMMARY ====="
    echo "AlertRule count: $ar_count"
    echo "TracingPolicy count: $tp_count"
    echo
  } >>"$OUTFILE"

  # Auto-detect expected file if not provided
  if [[ -z "$TPR_EXPECTED_FILE" ]]; then
    if [[ -f "./Tetragon Policy Ruleset-1.18.0-helm metadata-values-readme.txt" ]]; then
      TPR_EXPECTED_FILE="./Tetragon Policy Ruleset-1.18.0-helm metadata-values-readme.txt"
    fi
  fi

  if [[ -n "$TPR_EXPECTED_FILE" && -f "$TPR_EXPECTED_FILE" ]]; then
    local tmp_expected_ar tmp_expected_tp
    tmp_expected_ar="$(mktemp)"
    tmp_expected_tp="$(mktemp)"
    trap 'rm -f "$tmp_actual_ar" "$tmp_actual_tp" "$tmp_expected_ar" "$tmp_expected_tp"' EXIT

    extract_expected_alertrules "$TPR_EXPECTED_FILE" >"$tmp_expected_ar" || true
    extract_expected_tracingpolicies "$TPR_EXPECTED_FILE" >"$tmp_expected_tp" || true

    sort -u "$tmp_actual_ar" -o "$tmp_actual_ar" || true
    sort -u "$tmp_actual_tp" -o "$tmp_actual_tp" || true

    {
      echo "===== EXPECTED CHECK (TPR 1.18.0) ====="
      echo "expected source: $TPR_EXPECTED_FILE"
      echo
      echo "Missing AlertRules (expected - actual):"
      comm -23 "$tmp_expected_ar" "$tmp_actual_ar" || true
      echo
      echo "Missing TracingPolicies (expected - actual):"
      comm -23 "$tmp_expected_tp" "$tmp_actual_tp" || true
      echo
    } >>"$OUTFILE"
  fi

  echo "Wrote: $OUTFILE"
  echo "AlertRule count: $ar_count"
  echo "TracingPolicy count: $tp_count"
}

main "$@"

