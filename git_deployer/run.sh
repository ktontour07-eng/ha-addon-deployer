#!/usr/bin/env bash
# Hauptschleife des Git-Deployers: für jede konfigurierte App deploy.sh aufrufen,
# danach interval_minutes schlafen. Ein Neustart des Add-ons löst sofort einen
# Durchlauf aus („Jetzt prüfen“).
# Kein set -x: das Token darf nie im Log landen.
set -uo pipefail

OPTIONS_FILE="${OPTIONS_FILE:-/data/options.json}"
DEPLOY_SH="${DEPLOY_SH:-/deploy.sh}"
export OPTIONS_FILE

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [deployer] $*"; }

if [[ ! -r "$OPTIONS_FILE" ]]; then
  log "FEHLER: $OPTIONS_FILE nicht lesbar"
  exit 1
fi

interval=$(jq -r '.interval_minutes // 5' "$OPTIONS_FILE")
dry_run=$(jq -r 'if .dry_run == null then true else .dry_run end' "$OPTIONS_FILE")
app_count=$(jq -r '.apps | length' "$OPTIONS_FILE")

if [[ -z "$(jq -r '.github_token // ""' "$OPTIONS_FILE")" ]]; then
  log "WARNUNG: github_token ist leer – private Repos lassen sich so nicht abrufen"
fi
log "Start: ${app_count} App(s), Intervall ${interval} min, dry_run=${dry_run}"

running=true
trap 'running=false; log "Beende…"; [[ -n "${sleep_pid:-}" ]] && kill "$sleep_pid" 2>/dev/null' TERM INT

while $running; do
  for ((i = 0; i < app_count; i++)); do
    $running || break
    # Jede App gekapselt: ein Fehler blockiert die anderen nicht.
    "$DEPLOY_SH" "$i" || true
  done
  $running || break
  # RUN_ONCE=1 nur für Tests: ein Durchlauf, dann Ende.
  [[ "${RUN_ONCE:-0}" == "1" ]] && break
  sleep "$((interval * 60))" &
  sleep_pid=$!
  wait "$sleep_pid" 2>/dev/null
  sleep_pid=""
done
