#!/usr/bin/env bash
# shellcheck disable=SC1111  # deutsche Anführungszeichen „…“ in Meldungen sind gewollt
# Ein Deploy-Durchlauf für eine App: deploy.sh <index in options.apps>
#
#   holen (git) → neu? → prüfen → rsync nach /addons/<slug> → Store neu laden
#   → Update bzw. Rebuild → Gesundheitscheck → Status + Benachrichtigung
#
# Für lokale Tests per ENV überschreibbar: OPTIONS_FILE, DATA_DIR, ADDONS_DIR,
# SUPERVISOR_URL, GIT_BASE_URL, HEALTH_TIMEOUT, HEALTH_INTERVAL, BUILD_TIMEOUT.
# Kein set -x: das Token darf nie im Log landen.
set -euo pipefail

OPTIONS_FILE="${OPTIONS_FILE:-/data/options.json}"
DATA_DIR="${DATA_DIR:-/data}"
ADDONS_DIR="${ADDONS_DIR:-/addons}"
SUPERVISOR_URL="${SUPERVISOR_URL:-http://supervisor}"
GIT_BASE_URL="${GIT_BASE_URL:-https://github.com}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-10}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-1200}"

idx="${1:?Aufruf: deploy.sh <app-index>}"
[[ "$idx" =~ ^[0-9]+$ ]] || { echo "deploy.sh: Index muss eine Zahl sein" >&2; exit 2; }

opt() { jq -r "$1" "$OPTIONS_FILE"; }

slug=$(opt ".apps[$idx].slug // \"\"")
repo=$(opt ".apps[$idx].repo // \"\"")
branch=$(opt ".apps[$idx].branch // \"main\"")
path=$(opt ".apps[$idx].path // \"\"")
health_url=$(opt ".apps[$idx].health_url // \"\"")
dry_run=$(opt 'if .dry_run == null then true else .dry_run end')
notify_success=$(opt 'if .notify_success == null then true else .notify_success end')

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [${slug:-app$idx}] $*"; }

addon="local_${slug}"
repo_dir="${DATA_DIR}/repos/${slug}"
state_dir="${DATA_DIR}/state"
sha_file="${state_dir}/${slug}.sha"
json_file="${state_dir}/${slug}.json"
target="${ADDONS_DIR}/${slug}"

new_sha=""
short=""
commit_msg=""

# ---------------------------------------------------------------- Hilfsfunktionen

# Supervisor-API: sv METHOD PFAD [max-time] → setzt SV_CODE und SV_BODY.
# Rückgabe 0 nur bei 2xx und ohne "result": "error".
sv() {
  local method="$1" api_path="$2" max_time="${3:-30}" out
  out=$(mktemp)
  SV_CODE=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN:-}" \
    -H 'Content-Type: application/json' \
    --max-time "$max_time" "${SUPERVISOR_URL}${api_path}" 2>/dev/null) || SV_CODE="${SV_CODE:-000}"
  SV_BODY=$(cat "$out")
  rm -f "$out"
  [[ "$SV_CODE" =~ ^2 ]] || return 1
  [[ "$(jq -r '.result // "ok"' <<<"$SV_BODY" 2>/dev/null)" != "error" ]]
}

sv_message() { jq -r '.message // empty' <<<"$SV_BODY" 2>/dev/null | head -c 300; }

# Benachrichtigung in HA, notification_id deploy_<slug> → wird überschrieben statt gestapelt.
notify() {
  local title="$1" message="$2" payload code
  payload=$(jq -n --arg id "deploy_${slug}" --arg t "$title" --arg m "$message" \
    '{notification_id: $id, title: $t, message: $m}')
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN:-}" -H 'Content-Type: application/json' \
    --max-time 15 -d "$payload" \
    "${SUPERVISOR_URL}/core/api/services/persistent_notification/create" 2>/dev/null) || code="000"
  [[ "$code" =~ ^2 ]] || log "Benachrichtigung fehlgeschlagen (HTTP ${code})"
}

save_sha() { mkdir -p "$state_dir"; printf '%s\n' "$1" >"$sha_file"; }

write_state() {
  local status="$1" detail="${2:-}"
  mkdir -p "$state_dir"
  jq -n --arg sha "$new_sha" --arg time "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    --arg status "$status" --arg detail "$detail" --arg msg "$commit_msg" \
    '{sha: $sha, time: $time, status: $status, detail: $detail, commit_message: $msg}' >"$json_file"
}

last_status() { jq -r '.status // ""' "$json_file" 2>/dev/null || true; }

# Fehler: protokollieren, Status schreiben, benachrichtigen. Die neue SHA wird
# gespeichert (außer im Dry-Run), sonst baut der Deployer kaputten Code alle paar Minuten neu.
fail() {
  local step="$1" detail="$2"
  log "FEHLER bei „${step}“: ${detail}"
  [[ -n "$new_sha" && "$dry_run" != "true" ]] && save_sha "$new_sha"
  write_state "error" "${step}: ${detail}"
  notify "Deploy ${slug} fehlgeschlagen" \
    "Schritt: ${step}
${detail}
Commit: ${short:-?} – ${commit_msg:-?}
Log: Git-Deployer"
  exit 1
}

# Wert einer Top-Level-Zeile "key: wert" aus einer config.yaml (ohne Anführungszeichen/Kommentar).
yaml_val() {
  local key="$1"
  sed -n -E "s/^${key}:[[:space:]]*//p" | head -n1 | sed -E 's/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//; s/[[:space:]]+$//'
}

trap 'log "Unerwarteter Fehler in Zeile ${LINENO}"' ERR

# ---------------------------------------------------------------- Eingaben prüfen

[[ -n "$slug" ]] || { log "FEHLER: apps[$idx] hat keinen slug"; exit 1; }
if [[ ! "$slug" =~ ^[a-z0-9_]+$ ]]; then
  log "FEHLER: ungültiger slug"; exit 1
fi
if [[ "$slug" == "git_deployer" ]]; then
  log "FEHLER: Der Deployer verwaltet sich nie selbst – Eintrag wird ignoriert"
  notify "Deploy ${slug} abgelehnt" "Der Git-Deployer verwaltet sich nie selbst. Updates des Deployers laufen per Samba."
  exit 1
fi
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Prüfen" "Ungültiges repo „${repo}“ (erwartet: owner/name)"
[[ -n "$branch" && "$branch" != -* && "$branch" != *..* ]] || fail "Prüfen" "Ungültiger branch „${branch}“"
if [[ -z "$path" || "$path" == /* || "/$path/" == */../* ]]; then
  fail "Prüfen" "Ungültiger path „${path}“ (relativ, ohne ..)"
fi

# ---------------------------------------------------------------- 1. Holen

export GIT_TERMINAL_PROMPT=0
token=$(opt '.github_token // ""')
if [[ -n "$token" ]]; then
  # Header über die Umgebung statt URL, .git/config oder Kommandozeile.
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.extraHeader"
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
  export GIT_CONFIG_VALUE_0
fi
unset token

url="${GIT_BASE_URL}/${repo}.git"

fetch_failed() {
  local detail="$1"
  log "FEHLER beim Holen: ${detail}"
  # Nur beim ersten Fehlschlag benachrichtigen, nicht alle paar Minuten erneut.
  if [[ "$(last_status)" != "fetch_failed" ]]; then
    notify "Deploy ${slug} fehlgeschlagen" \
      "Schritt: Holen (git)
${detail}
Token abgelaufen oder Repo/Branch falsch? Log: Git-Deployer"
  fi
  local keep_sha
  keep_sha=$(cat "$sha_file" 2>/dev/null || true)
  new_sha="$keep_sha"
  write_state "fetch_failed" "$detail"
  exit 1
}

mkdir -p "${DATA_DIR}/repos"
if [[ ! -d "${repo_dir}/.git" ]]; then
  rm -rf "$repo_dir"
  git clone --quiet --branch "$branch" --single-branch -- "$url" "$repo_dir" 2>/dev/null \
    || fetch_failed "git clone ${repo} (${branch}) fehlgeschlagen"
else
  git -C "$repo_dir" remote set-url origin "$url"
  git -C "$repo_dir" fetch --quiet origin "+refs/heads/${branch}:refs/remotes/origin/${branch}" 2>/dev/null \
    || fetch_failed "git fetch ${repo} (${branch}) fehlgeschlagen"
  git -C "$repo_dir" reset --quiet --hard "origin/${branch}"
  git -C "$repo_dir" clean -qfdx
fi

new_sha=$(git -C "$repo_dir" rev-parse HEAD)
short="${new_sha:0:7}"
commit_msg=$(git -C "$repo_dir" log -1 --format=%s)

# ---------------------------------------------------------------- 2. Neu?

if [[ ! -s "$sha_file" ]]; then
  save_sha "$new_sha"
  write_state "baseline" "Ausgangsstand, kein Deploy"
  log "Ausgangsstand ${short} gespeichert (erster Lauf, kein Deploy) – ${commit_msg}"
  exit 0
fi

old_sha=$(tr -d '[:space:]' <"$sha_file")
[[ "$old_sha" == "$new_sha" ]] && exit 0

log "Neuer Stand ${old_sha:0:7} → ${short}: ${commit_msg}"

old_known=false
git -C "$repo_dir" cat-file -e "${old_sha}^{commit}" 2>/dev/null && old_known=true

if $old_known && git -C "$repo_dir" diff --quiet "$old_sha" "$new_sha" -- "$path"; then
  if [[ "$dry_run" == "true" ]]; then
    log "dry_run: keine Änderung in ${path}/, es würde nur die SHA gespeichert"
    exit 0
  fi
  save_sha "$new_sha"
  write_state "unchanged" "Keine Änderung in ${path}/"
  log "Keine Änderung in ${path}/ – kein Deploy, SHA gespeichert"
  exit 0
fi

# ---------------------------------------------------------------- 3. Prüfen

src="${repo_dir}/${path}"
[[ -d "$src" ]] || fail "Prüfen" "Ordner ${path}/ fehlt im Repo"
# pwd -P löst Symlinks auf (busybox-realpath kennt kein -m).
real_src=$(cd "$src" && pwd -P)
real_repo=$(cd "$repo_dir" && pwd -P)
[[ "$real_src" == "$real_repo" || "$real_src" == "$real_repo"/* ]] || fail "Prüfen" "path „${path}“ zeigt aus dem Repo heraus"
[[ -f "${src}/config.yaml" ]] || fail "Prüfen" "${path}/config.yaml fehlt"

cfg_slug=$(yaml_val slug <"${src}/config.yaml")
[[ "$cfg_slug" == "$slug" ]] || fail "Prüfen" "slug in ${path}/config.yaml ist „${cfg_slug}“, erwartet „${slug}“"

[[ "$target" == "${ADDONS_DIR}/${slug}" && "$slug" != "" ]] || fail "Prüfen" "Ungültiges Ziel"

new_version=$(yaml_val version <"${src}/config.yaml")
warning=""
if $old_known; then
  if ! git -C "$repo_dir" diff --quiet "$old_sha" "$new_sha" -- "${path}/config.yaml"; then
    old_version=$(git -C "$repo_dir" show "${old_sha}:${path}/config.yaml" 2>/dev/null | yaml_val version || true)
    if [[ -n "$old_version" && "$old_version" == "$new_version" ]]; then
      warning="config.yaml geändert ohne Versionssprung, Änderung wirkt evtl. nicht"
      log "WARNUNG: ${warning}"
    fi
  fi
else
  log "Alter Stand ${old_sha:0:7} nicht mehr in der Historie (Force-Push?) – deploye vollständig"
fi

# ---------------------------------------------------------------- 4. Kopieren

if [[ "$dry_run" == "true" ]]; then
  log "dry_run: rsync würde nach ${target}/ folgendes ändern:"
  rsync -a --checksum --delete --exclude .git --dry-run --itemize-changes "${src}/" "${target}/" 2>&1 \
    | sed "s/^/  /" | while IFS= read -r line; do log "$line"; done
  log "dry_run: nichts geändert, SHA nicht gespeichert"
  exit 0
fi

rsync -a --checksum --delete --exclude .git "${src}/" "${target}/" || fail "Kopieren" "rsync nach ${target}/ fehlgeschlagen"
log "Nach ${target}/ kopiert (Version ${new_version:-?})"

# ---------------------------------------------------------------- 5. Store neu laden

sv POST /store/reload 120 || fail "Store neu laden" "HTTP ${SV_CODE} $(sv_message)"

# ---------------------------------------------------------------- 6. Update oder Rebuild

if ! sv GET "/addons/${addon}/info" || [[ "$(jq -r '.data.version // empty' <<<"$SV_BODY")" == "" ]]; then
  save_sha "$new_sha"
  write_state "not_installed" "Add-on ${addon} nicht installiert"
  log "Add-on ${addon} ist nicht installiert – Dateien liegen bereit, keine automatische Installation"
  notify "Neues Add-on ${slug} liegt bereit" \
    "${slug} (${short} – ${commit_msg}) liegt unter /addons/${slug}. Bitte im Add-on-Store installieren und Optionen setzen."
  exit 0
fi

if [[ "$(jq -r '.data.update_available // false' <<<"$SV_BODY")" == "true" ]]; then
  action="Update"
  log "Update auf ${new_version} läuft (kann mehrere Minuten dauern)…"
  sv POST "/store/addons/${addon}/update" "$BUILD_TIMEOUT" || fail "Update" "HTTP ${SV_CODE} $(sv_message)"
else
  action="Rebuild"
  log "Rebuild läuft (kann mehrere Minuten dauern)…"
  sv POST "/addons/${addon}/rebuild" "$BUILD_TIMEOUT" || fail "Rebuild" "HTTP ${SV_CODE} $(sv_message)"
fi
log "${action} abgeschlossen"

# ---------------------------------------------------------------- 7. Gesundheitscheck

deadline=$((SECONDS + HEALTH_TIMEOUT))
health_ok=false
state=""
while ((SECONDS < deadline)); do
  if sv GET "/addons/${addon}/info"; then
    state=$(jq -r '.data.state // empty' <<<"$SV_BODY")
  fi
  if [[ "$state" == "started" ]]; then
    if [[ -z "$health_url" ]] || curl -fsS -o /dev/null --max-time 5 "$health_url" 2>/dev/null; then
      health_ok=true
      break
    fi
  fi
  sleep "$HEALTH_INTERVAL"
done

if ! $health_ok; then
  if [[ "$state" != "started" ]]; then
    fail "Gesundheitscheck" "Add-on-Status „${state:-unbekannt}“ statt „started“ nach ${HEALTH_TIMEOUT} s"
  fi
  fail "Gesundheitscheck" "${health_url} lieferte nach ${HEALTH_TIMEOUT} s kein 2xx"
fi

# ---------------------------------------------------------------- 8. Ergebnis

save_sha "$new_sha"
write_state "ok" "${action}${warning:+; WARNUNG: $warning}"
log "OK: ${slug} aktualisiert auf ${short} (${action})"
if [[ "$notify_success" == "true" || -n "$warning" ]]; then
  notify "${slug} aktualisiert" \
    "${slug} aktualisiert auf ${short} – ${commit_msg}${warning:+

⚠ ${warning}}"
fi
