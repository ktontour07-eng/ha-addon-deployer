#!/usr/bin/env bash
# Lokaler Test von deploy.sh/run.sh gegen einen Mock-Supervisor und ein lokales Git-Repo.
# Aufruf: tests/run_tests.sh   (braucht bash, git, rsync, curl, jq, python3)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ADDON="$HERE/../git_deployer"
T=$(mktemp -d)
PORT=$((20000 + RANDOM % 20000))
TOKEN="ghp_GEHEIM_TESTTOKEN_123"

export DATA_DIR="$T/data" ADDONS_DIR="$T/addons" OPTIONS_FILE="$T/options.json"
export SUPERVISOR_URL="http://127.0.0.1:$PORT" SUPERVISOR_TOKEN="sv-token"
export GIT_BASE_URL="file://$T/remote" HEALTH_TIMEOUT=3 HEALTH_INTERVAL=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$DATA_DIR" "$ADDONS_DIR"

REQ="$T/requests.log"; STATE="$T/mock.json"; OUT="$T/out.log"
echo '{}' >"$STATE"; : >"$REQ"
python3 "$HERE/mock_supervisor.py" "$PORT" "$STATE" "$REQ" &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null; [[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT
for _ in $(seq 50); do curl -s "$SUPERVISOR_URL/x" >/dev/null 2>&1 && break; sleep 0.1; done

pass=0; failed=0
ok()   { echo "  ✔ $*"; pass=$((pass + 1)); }
bad()  { echo "  ✘ $*"; failed=$((failed + 1)); }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }
has()  { grep -q -- "$1" "$2"; }
hasnt() { ! grep -q -- "$1" "$2"; }

# --- Test-Repo: owner/app mit Add-on-Ordner myapp/ (slug myapp)
git init -q --bare -b main "$T/remote/owner/app.git"
W="$T/work"
git clone -q "$T/remote/owner/app.git" "$W" 2>/dev/null
git -C "$W" checkout -q -b main
mkdir -p "$W/myapp"
printf 'name: My App\nversion: "1.0.0"\nslug: myapp\noptions: {}\n' >"$W/myapp/config.yaml"
echo v1 >"$W/myapp/app.txt"; echo weg >"$W/myapp/alt.txt"; echo readme >"$W/README.md"
commit() { git -C "$W" add -A; git -C "$W" commit -qm "$1"; git -C "$W" push -q origin main 2>/dev/null; }
commit "Erster Stand"

options() { # options <dry_run> [apps-json]
  local apps="${2:-}"
  [[ -n "$apps" ]] || apps=$(jq -nc --arg h "$SUPERVISOR_URL/health" \
    '[{repo: "owner/app", branch: "main", path: "myapp", slug: "myapp", health_url: $h}]')
  jq -n --arg tok "$TOKEN" --argjson dry "$1" --argjson apps "$apps" \
    '{github_token: $tok, interval_minutes: 5, dry_run: $dry, notify_success: true, apps: $apps}' >"$OPTIONS_FILE"
}
mock() { echo "$1" >"$STATE"; }
run() { : >"$REQ"; "$ADDON/deploy.sh" 0 >"$OUT" 2>&1 || true; cat "$OUT" >>"$T/all.log"; }
sha() { cat "$DATA_DIR/state/myapp.sha"; }
head_sha() { git -C "$W" rev-parse HEAD; }

echo "1) Erster Lauf = nur Ausgangsstand"
options true; mock '{}'; run
check "SHA gespeichert" [ "$(sha)" = "$(head_sha)" ]
check "Log meldet Ausgangsstand" has "Ausgangsstand" "$OUT"
check "nichts kopiert" [ ! -e "$ADDONS_DIR/myapp" ]
check "keine API-Aufrufe" [ ! -s "$REQ" ]
check "Token nicht in .git/config" hasnt "$TOKEN" "$DATA_DIR/repos/myapp/.git/config"

echo "2) Dry-Run ändert nichts"
mkdir -p "$ADDONS_DIR/myapp"; cp "$W/myapp/"* "$ADDONS_DIR/myapp/"; echo "nur-auf-ha" >"$ADDONS_DIR/myapp/lokal.txt"
echo v2 >"$W/myapp/app.txt"; commit "Code v2"
old=$(sha); run
check "SHA nicht gespeichert" [ "$(sha)" = "$old" ]
check "Datei unverändert" [ "$(cat "$ADDONS_DIR/myapp/app.txt")" = v1 ]
check "rsync-Liste im Log (app.txt)" has "app.txt" "$OUT"
check "rsync-Liste zeigt deleting lokal.txt" has "deleting.*lokal.txt" "$OUT"
check "keine API-Aufrufe" [ ! -s "$REQ" ]

echo "3) Neuer Commit → rsync + reload + rebuild"
options false; rm -f "$ADDONS_DIR/myapp/lokal.txt"; run
check "Datei aktualisiert" [ "$(cat "$ADDONS_DIR/myapp/app.txt")" = v2 ]
check "store/reload" has "POST /store/reload" "$REQ"
check "rebuild" has "POST /addons/local_myapp/rebuild" "$REQ"
check "kein update" hasnt "/update" "$REQ"
check "Health abgefragt" has "GET /health" "$REQ"
check "Erfolgsmeldung" has "aktualisiert auf $(head_sha | cut -c1-7)" "$REQ"
check "notification_id deploy_myapp" has '"notification_id": "deploy_myapp"' "$REQ"
check "Supervisor-Token gesendet" has "AUTH=Bearer sv-token" "$REQ"
check "SHA gespeichert" [ "$(sha)" = "$(head_sha)" ]
check "Status ok" [ "$(jq -r .status "$DATA_DIR/state/myapp.json")" = ok ]
check ".git nicht kopiert" [ ! -e "$ADDONS_DIR/myapp/.git" ]

echo "4) Gelöschte Datei wird auf HA entfernt"
git -C "$W" rm -q myapp/alt.txt; commit "alt.txt entfernt"; run
check "alt.txt entfernt" [ ! -e "$ADDONS_DIR/myapp/alt.txt" ]

echo "5) Commit außerhalb des Add-on-Ordners → kein Deploy"
echo neu >>"$W/README.md"; commit "nur README"; run
check "keine API-Aufrufe" [ ! -s "$REQ" ]
check "SHA trotzdem gespeichert" [ "$(sha)" = "$(head_sha)" ]

echo "6) Versionssprung → update"
sed -i 's/1.0.0/1.0.1/' "$W/myapp/config.yaml"; commit "Version 1.0.1"
mock '{"update_available": true}'; run
check "update aufgerufen" has "POST /store/addons/local_myapp/update" "$REQ"
check "kein rebuild" hasnt "/rebuild" "$REQ"
check "keine Versionswarnung" hasnt "ohne Versionssprung" "$REQ"

echo "7) config.yaml geändert ohne Versionssprung → Warnung"
echo "ports: {}" >>"$W/myapp/config.yaml"; commit "Port ohne Version"
mock '{}'; run
check "rebuild" has "POST /addons/local_myapp/rebuild" "$REQ"
check "Warnung in Benachrichtigung" has "ohne Versionssprung" "$REQ"

echo "8) Falscher Slug in config.yaml → Abbruch"
sed -i 's/^slug: myapp/slug: anders/' "$W/myapp/config.yaml"; commit "falscher Slug"
before=$(cat "$ADDONS_DIR/myapp/config.yaml"); run
check "nichts kopiert" [ "$(cat "$ADDONS_DIR/myapp/config.yaml")" = "$before" ]
check "kein reload/rebuild" hasnt "/store/reload" "$REQ"
check "Fehler-Benachrichtigung" has "Deploy myapp fehlgeschlagen" "$REQ"
check "SHA trotzdem gespeichert (kein Endlos-Rebuild)" [ "$(sha)" = "$(head_sha)" ]
run
check "nächster Lauf: kein erneuter Versuch" [ ! -s "$REQ" ]
sed -i 's/^slug: anders/slug: myapp/' "$W/myapp/config.yaml"; commit "Slug repariert"; run

echo "9) Health-Fehler → Fehler-Benachrichtigung"
echo v3 >"$W/myapp/app.txt"; commit "Code v3"
mock '{"health": 500}'; run
check "Fehler-Benachrichtigung" has "Deploy myapp fehlgeschlagen" "$REQ"
check "Schritt Gesundheitscheck" has "Gesundheitscheck" "$REQ"
check "SHA gespeichert" [ "$(sha)" = "$(head_sha)" ]
check "Status error" [ "$(jq -r .status "$DATA_DIR/state/myapp.json")" = error ]

echo "10) Add-on gestoppt → Fehler"
echo v4 >"$W/myapp/app.txt"; commit "Code v4"
mock '{"state": "stopped"}'; run
check "Fehler nennt Status" has "stopped" "$REQ"

echo "11) Rebuild HTTP 403 → Fehler mit Status"
echo v5 >"$W/myapp/app.txt"; commit "Code v5"
mock '{"fail": {"/addons/local_myapp/rebuild": 403}}'; run
check "Fehler mit HTTP 403" has "HTTP 403" "$REQ"

echo "12) Nicht installiert → nur Hinweis"
echo v6 >"$W/myapp/app.txt"; commit "Code v6"
mock '{"installed": false}'; run
check "Hinweis 'liegt bereit'" has "liegt bereit" "$REQ"
check "kein install/rebuild/update" bash -c "! grep -qE '/install|/rebuild|/update' '$REQ'"

echo "13) Token taucht nie im Log auf"
check "Token nicht in Ausgaben" hasnt "$TOKEN" "$T/all.log"

echo "14) slug git_deployer wird abgelehnt"
options false '[{"repo":"owner/app","branch":"main","path":"myapp","slug":"git_deployer"}]'; mock '{}'; run
check "abgelehnt" has "verwaltet sich nie selbst" "$OUT"
check "nicht geklont" [ ! -e "$DATA_DIR/repos/git_deployer" ]

echo "15) Path-Traversal wird abgelehnt"
options false '[{"repo":"owner/app","branch":"main","path":"../../etc","slug":"evil"}]'; run
check "abgelehnt" has "Ungültiger path" "$OUT"
check "nichts unter /addons/evil" [ ! -e "$ADDONS_DIR/evil" ]

echo "16) Repo nicht erreichbar → nur einmal benachrichtigen"
options false '[{"repo":"owner/gibtsnicht","branch":"main","path":"x","slug":"weg"}]'; run
check "Fehler-Benachrichtigung" has "Holen" "$REQ"
run
check "zweiter Lauf: keine erneute Benachrichtigung" hasnt "persistent_notification" "$REQ"

echo "17) run.sh: Fehler bei einer App blockiert die andere nicht"
options false "[{\"repo\":\"owner/gibtsnicht\",\"branch\":\"main\",\"path\":\"x\",\"slug\":\"weg\"},{\"repo\":\"owner/app\",\"branch\":\"main\",\"path\":\"myapp\",\"slug\":\"myapp\",\"health_url\":\"$SUPERVISOR_URL/health\"}]"
echo v7 >"$W/myapp/app.txt"; commit "Code v7"; mock '{}'; : >"$REQ"
RUN_ONCE=1 DEPLOY_SH="$ADDON/deploy.sh" "$ADDON/run.sh" >"$OUT" 2>&1
check "zweite App deployt" [ "$(cat "$ADDONS_DIR/myapp/app.txt")" = v7 ]
check "Token nicht im run.sh-Log" hasnt "$TOKEN" "$OUT"

echo "18) Symlink aus dem Repo heraus wird abgelehnt"
ln -s ../../.. "$W/esc"; commit "Symlink"
options false '[{"repo":"owner/app","branch":"main","path":"esc","slug":"esc"}]'
run                                   # erster Lauf: Ausgangsstand
rm "$W/esc"; ln -s / "$W/esc"; commit "Symlink auf /"; run
check "abgelehnt" has "aus dem Repo heraus" "$OUT"
check "nichts unter /addons/esc" [ ! -e "$ADDONS_DIR/esc" ]

echo
echo "Ergebnis: $pass bestanden, $failed fehlgeschlagen"
[ "$failed" -eq 0 ]
