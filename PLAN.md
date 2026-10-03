# Plan: Git-Deployer – automatisches Deployment eigener Add-ons aus GitHub

Stand 04.10.2026 · Betrifft: `ha-bon-tracker`, `ha-trainings-coach` und künftige eigene Add-ons

Ziel: Ein Push bzw. Merge auf `main` eines App-Repos landet automatisch auf HA, ohne Samba-Kopie, ohne `ha store reload`
und ohne manuelles Update. Dafür gibt es ein kleines lokales Add-on **Git-Deployer**. Es fragt die Repos regelmäßig ab,
kopiert den Add-on-Ordner nach `/addons/<slug>` und stößt über die Supervisor-API Update bzw. Rebuild an.

Warum so und nicht als Add-on-Repository im Store oder als fertiges Image aus GHCR: Bei beiden bekämen die Add-ons einen
neuen Slug (`xxxx_bon_tracker` statt `local_bon_tracker`). Das wäre ein neues Add-on mit leerem `/data`, die Daten müssten
umziehen. Der Deployer behält Slug, Daten und Backup, braucht keinen offenen Port und kein Token in der Store-URL.

Arbeitsteilung:
- **Claude Code**: Phase 1–3 (Vorarbeit in den App-Repos, neues Repo, Add-on, lokaler Test)
- **Jannik**: Ordner einmal per Samba kopieren, GitHub-Token anlegen und eintragen
- **Cowork (Chrome + `hass`)**: Phase 4–5 (Installation, Probelauf, Brain)

---

## Phase 1 – Vorarbeit in den App-Repos (Claude Code)

Der Deployer überschreibt `/addons/<slug>` mit dem Stand von `main`. Was nur auf HA gepatcht wurde, geht dabei verloren.
Deshalb vorher abgleichen:

**`ha-trainings-coach`**
- Auf HA läuft 1.0.1 mit dem Fix `str?` statt `email?`/`url?` im `schema` (siehe Brain, „Home Assistant.md“ → Trainings-Coach).
  Prüfen, ob dieser Fix in `main` steht. Wenn nicht: einbauen und `version` auf `1.0.2` setzen.
  Sonst startet der Coach nach dem ersten automatischen Deploy nicht mehr.
- Phase 1–3 wurden damals auf dem Branch `claude/new-session-tq4lqd` gebaut. Prüfen, ob `main` diesen Stand enthält.
  Wenn nicht: nach `main` mergen.
- Ordner im Repo: `trainings_coach/` (Slug `trainings_coach`).

**`ha-bon-tracker`**
- `main` muss dem Stand entsprechen, der auf HA läuft (1.0.0). Ordner: `bon_tracker/`.

**Beide Repos, `CLAUDE.md` ergänzen:**
- „`main` = live. Jeder Merge nach `main` wird innerhalb von ~5 min automatisch auf HA eingespielt (Git-Deployer).
  Entwickeln auf Feature-Branch, vor dem Merge muss der Build lokal durchlaufen.“
- „Änderungen an `config.yaml` (Optionen, Schema, Ports) brauchen einen Versionssprung. Reine Code-Änderungen gehen auch
  ohne, dann wird nur neu gebaut. Ein Versionssprung ist trotzdem empfohlen, damit man im HA-Log sieht, was läuft.“
- Schema-Typen `email?`/`url?` nie verwenden, immer `str?`.

---

## Phase 2 – Neues Repo `ha-addon-deployer` (Claude Code)

- **Privat**, frischer erster Commit.
- Struktur: Der Ordner `git_deployer/` wird einmalig nach `\\192.168.178.28\addons\git_deployer\` kopiert.

```
ha-addon-deployer/
├── README.md
├── CLAUDE.md
├── PLAN.md              ← diese Datei
└── git_deployer/
    ├── config.yaml
    ├── Dockerfile
    ├── run.sh           ← Hauptschleife
    ├── deploy.sh        ← ein Deploy-Durchlauf für eine App (testbar einzeln)
    └── DOCS.md
```

### `git_deployer/config.yaml`

```yaml
name: Git-Deployer
version: "1.0.0"
slug: git_deployer
description: Spielt eigene Add-ons automatisch aus GitHub ein (git fetch → Update/Rebuild)
arch:
  - amd64
startup: services
boot: auto
init: true
hassio_api: true
hassio_role: manager       # darf andere Add-ons aktualisieren/neu bauen und den Store neu laden
homeassistant_api: true    # für Benachrichtigungen (persistent_notification)
map:
  - type: addons
    read_only: false
options:
  github_token: ""
  interval_minutes: 5
  dry_run: true            # beim ersten Start nur protokollieren, nichts ändern
  notify_success: true
  apps:
    - repo: ktontour07-eng/ha-Bon            # tatsächlicher Repo-Name (siehe Status)
      branch: main
      path: bon_tracker
      slug: bon_tracker
      health_url: "http://192.168.178.28:5010/api/ping"
    - repo: ktontour07-eng/Trainer-Gemini-HA # tatsächlicher Repo-Name (siehe Status)
      branch: main
      path: trainings_coach
      slug: trainings_coach
      health_url: "http://192.168.178.28:5000/health"
schema:
  github_token: password
  interval_minutes: "int(1,60)"
  dry_run: bool
  notify_success: bool
  apps:
    - repo: str
      branch: str
      path: str
      slug: "match(^[a-z0-9_]+$)"
      health_url: "str?"   # NIE url? – Supervisor lehnt sonst Speichern und Start ab
```

Ob `hassio_role: manager` für `/addons/<slug>/rebuild` und `/store/addons/<slug>/update` reicht, beim Probelauf
(Phase 4) prüfen. Bei HTTP 403 auf `admin` erhöhen und das in `DOCS.md` begründen.

### `git_deployer/Dockerfile`

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache bash git rsync curl jq ca-certificates tzdata
ENV TZ=Europe/Berlin
COPY run.sh deploy.sh /
RUN chmod a+x /run.sh /deploy.sh
CMD ["/run.sh"]
```

### Ablauf `run.sh` (Schleife)

1. Optionen aus `/data/options.json` mit `jq` lesen. Das **Token nie loggen**, auch nicht in `set -x`.
2. Endlosschleife: für jede App `deploy.sh` aufrufen, danach `interval_minutes` schlafen.
   Ein Fehler bei einer App darf die anderen nicht blockieren.
3. Ein Neustart des Deployers löst sofort einen Durchlauf aus und dient so als manueller „Jetzt prüfen“-Knopf.

### Ablauf `deploy.sh <app>` (ein Durchlauf)

1. **Holen:** Klon unter `/data/repos/<slug>`, beim ersten Mal `git clone --branch <branch> --single-branch`, danach
   `git fetch` + `git reset --hard origin/<branch>`. Authentifizierung ohne Token in URL oder `.git/config`:
   `git -c http.extraHeader="Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)" …`
   Dazu `GIT_TERMINAL_PROMPT=0`.
2. **Neu?** `HEAD`-SHA mit `/data/state/<slug>.sha` vergleichen. Gleich → fertig.
   **Erster Lauf** (keine State-Datei): nur die SHA als Ausgangsstand speichern, **nicht deployen**, im Log vermerken.
3. **Prüfen vor dem Kopieren:**
   - `<path>/config.yaml` existiert, und `slug:` darin entspricht dem konfigurierten `slug`. Sonst abbrechen und benachrichtigen.
   - Ziel ist exakt `/addons/<slug>` (Path-Traversal ausschließen, `slug` per Schema schon auf `[a-z0-9_]` begrenzt).
   - Hat sich `config.yaml` zwischen alter und neuer SHA geändert (`git diff --quiet <alt> <neu> -- <path>/config.yaml`),
     die `version` aber nicht → Warnung in der Benachrichtigung („config.yaml geändert ohne Versionssprung, Änderung wirkt evtl. nicht“).
4. **Kopieren:** `rsync -a --delete --exclude .git <repo>/<path>/ /addons/<slug>/`.
   Bei `dry_run: true` nur `rsync --dry-run --itemize-changes` loggen und hier aufhören, die SHA **nicht** speichern.
5. **Store neu laden:** `POST http://supervisor/store/reload` (Header `Authorization: Bearer $SUPERVISOR_TOKEN`).
6. **Update oder Rebuild:** `GET /addons/local_<slug>/info`
   - nicht installiert → nur benachrichtigen („neues Add-on <slug> liegt bereit, bitte installieren und Optionen setzen“), **nicht** automatisch installieren
   - `update_available: true` → `POST /store/addons/local_<slug>/update`
   - sonst → `POST /addons/local_<slug>/rebuild`
   - Beide Aufrufe blockieren bis zum Ende des Builds (mehrere Minuten): `curl --max-time 1200`.
7. **Gesundheitscheck:** Ist `health_url` gesetzt, bis zu 3 min alle 10 s abfragen und 2xx erwarten.
   Zusätzlich muss `GET /addons/local_<slug>/info` den Status `started` liefern.
8. **Ergebnis:** Die neue SHA wird **immer** gespeichert, auch bei einem Fehler. Sonst baut der Deployer kaputten Code alle 5 min neu.
   Den Status in `/data/state/<slug>.json` ablegen (SHA, Zeit, ok/fehler, Commit-Message der ersten Zeile).
   Benachrichtigung über `POST http://supervisor/core/api/services/persistent_notification/create`
   mit `notification_id: deploy_<slug>`, damit sie überschrieben wird und sich nicht stapelt:
   - Fehler: Titel „Deploy <slug> fehlgeschlagen“, Schritt, HTTP-Status, Kurz-SHA, Commit-Message, Hinweis „Log: Git-Deployer“
   - Erfolg (bei `notify_success`): „<slug> aktualisiert auf <kurz-sha> – <commit-message>“

Grundsätze:
- `set -euo pipefail` in `deploy.sh`, aber jede App in `run.sh` gekapselt (`deploy.sh … || true`).
- Der Deployer verwaltet **nie sich selbst** (`slug == git_deployer` → ablehnen). Updates des Deployers laufen weiter per Samba.
- Keine Aufrufe an andere Add-ons als die konfigurierten `local_<slug>`.
- Logzeilen mit Präfix `[<slug>]`, ohne Secrets.

### Lokaler Test (Claude Code)

- `shellcheck run.sh deploy.sh`.
- `deploy.sh` mit `SUPERVISOR_URL` (Default `http://supervisor`) und `ADDONS_DIR` (Default `/addons`) per ENV überschreibbar machen.
  Dann gegen einen kleinen Mock-Server (z. B. Python `http.server`) und ein lokales Test-Repo durchspielen:
  erster Lauf = nur Ausgangsstand, neuer Commit → rsync + reload + rebuild, Versionssprung → update,
  falscher Slug in `config.yaml` → Abbruch, Health-Fehler → Fehler-Benachrichtigung, Dry-Run ändert nichts.
- `docker build`, falls Docker verfügbar ist. Sonst im Status vermerken.

---

## Phase 3 – Übergabe (Claude Code)

Tag `v1.0.0`. In `PLAN.md` unter „Status“ eintragen, was gemacht und was nicht testbar war.
Ergebnis von Phase 1 (Coach-Fix in `main`? Branch gemergt?) ausdrücklich nennen.

---

## Phase 4 – Installation und Probelauf (Jannik + Cowork)

1. **Token (Jannik):** GitHub → Settings → Developer settings → Fine-grained token. Nur die Repos `ha-Bon` (Bon-Tracker) und
   `Trainer-Gemini-HA` (Trainings-Coach), Berechtigung nur **Contents: Read-only**, Ablauf z. B. 1 Jahr. Ablaufdatum ins Brain.
2. **Kopieren (Jannik):** Ordner `git_deployer/` nach `\\192.168.178.28\addons\git_deployer\`.
3. **Installieren (Cowork):** `/store/reload` → `/store/addons/local_git_deployer/install`.
4. **Optionen (Jannik):** Token eintragen, `dry_run: true` lassen.
5. **Start und Probelauf (Cowork):** Das Log muss für beide Apps „Ausgangsstand <sha> gespeichert“ zeigen. Dann einen
   Mini-Commit auf `main` im Bon-Tracker (z. B. Kommentar in `DOCS.md`) → im Log die `rsync --dry-run`-Liste prüfen.
   Es dürfen nur erwartete Dateien auftauchen. Ein `deleting …` bei Dateien, die nur auf HA liegen, ist ein Warnsignal.
6. **Scharf schalten:** `dry_run: false`, neu starten. Noch einen Mini-Commit → Rebuild läuft, Health ok, Benachrichtigung kommt.
   Danach dasselbe mit Versionssprung → Update statt Rebuild.
7. **Coach:** Ein Mini-Commit auf `ha-trainings-coach`, danach prüfen, dass der Coach startet und Login/Daten da sind.

## Phase 5 – Abschluss (Cowork)

Brain:
- `Home Assistant.md`: Add-on-Tabelle (Git-Deployer), eigener Abschnitt mit Optionen, Token-Ablauf, Stolperfallen.
  Update-Wege bei Bon-Tracker und Coach auf „Merge nach `main` → automatisch“ umstellen, den alten Weg als (veraltet) markieren.
- `Eigene Web-Apps als Add-on.md`, Abschnitt 5: Deployment für neue Apps = einmal Samba + Install, danach Eintrag in `apps` des Deployers.
- `Chats/Chats.md`: eine Zeile.

## Neue Add-ons später

1. Repo nach Playbook anlegen (Brain: „Eigene Web-Apps als Add-on“).
2. Ordner **einmal** per Samba kopieren, installieren, Optionen/Secrets setzen. Das muss weiter von Hand passieren,
   weil der Deployer bewusst nichts neu installiert.
3. Token in GitHub auf das neue Repo erweitern.
4. In den Deployer-Optionen unter `apps` einen Eintrag ergänzen, Deployer neu starten → erster Lauf speichert den Ausgangsstand.

Ab dann gilt: Merge nach `main` = live.

---

## Status

- 04.10.2026: Plan erstellt (Cowork).
- 03.10.2026: Phase 1–3 umgesetzt (Claude Code). Details unten.

### Ergebnis Phase 1 (App-Repos)

**Repo-Namen:** `ha-bon-tracker` und `ha-trainings-coach` gibt es auf GitHub nicht. Die tatsächlichen
Repos sind **`ktontour07-eng/ha-Bon`** (Bon-Tracker, Ordner `bon_tracker/`) und
**`ktontour07-eng/Trainer-Gemini-HA`** (Trainings-Coach, Ordner `trainings_coach/`).
In `git_deployer/config.yaml` und oben im Plan sind die echten Namen eingetragen.

**Trainings-Coach (`Trainer-Gemini-HA`):**
- Coach-Fix in `main`: **ja.** `main` steht auf Version **1.0.1**, im Schema sind `public_url`,
  `vapid_claim_email` und `supabase_url` bereits `str?` (Commit `09b7aaf`). Kein Versionssprung auf 1.0.2 nötig.
- Branch `claude/new-session-tq4lqd` gemergt: **ja.** PR #1 (Merge-Commit `a7c9212`), `main` und der Branch
  zeigen auf denselben Commit.
- **Achtung:** Der **Default-Branch** des Repos auf GitHub ist noch `claude/new-session-tq4lqd`, nicht `main`.
  Für den Deployer egal (er nutzt `branch: main`), aber PRs zielen sonst auf den falschen Branch.
  Bitte unter Settings → General → Default branch auf `main` umstellen (Jannik).
- `CLAUDE.md` neu angelegt („`main` = live“, Versionssprung-Regel, nie `email?`/`url?`), README und
  PLAN.md-Update-Weg angepasst (alter Samba-Weg als veraltet markiert).

**Bon-Tracker (`ha-Bon`):**
- `main` = Commit `c9b013c` „Bon-Tracker als lokales Home-Assistant-Add-on (v1.0.0)“, Version **1.0.0**,
  einziger Commit, keine weiteren Branches. Das passt zum Stand 1.0.0 auf HA. Dass auf HA nichts
  zusätzlich gepatcht wurde, lässt sich von hier nicht prüfen. Das zeigt der Dry-Run in Phase 4
  (`*deleting …` bzw. geänderte Dateien in der rsync-Liste).
- Schema nutzt bereits nur `str?`/`password?`.
- `CLAUDE.md` Abschnitt „Update-Weg“ ersetzt durch „`main` = live“ + Regeln, README und PLAN.md angepasst.

**Wo die Phase-1-Änderungen liegen:** Nur Doku-Dateien (CLAUDE.md, README.md, PLAN.md), nichts im
Add-on-Ordner. Gepusht auf Branch `claude/git-deployer-addon-phases-3cudkz` in beiden Repos
(`ha-Bon` `90a5c19`, `Trainer-Gemini-HA` `3d22803`), **noch nicht nach `main` gemergt**. Mergen
vor Phase 4, damit „`main` = live“ in `main` dokumentiert ist. Da sich `bon_tracker/` bzw.
`trainings_coach/` nicht ändern, löst der Merge später keinen Rebuild aus.

### Ergebnis Phase 2 (Add-on)

- Repo `ha-addon-deployer` mit `git_deployer/` (config.yaml, Dockerfile, run.sh, deploy.sh, DOCS.md),
  README.md, CLAUDE.md, PLAN.md und `tests/` (Mock-Supervisor + Testskript, wird nicht nach HA kopiert).
- **Sichtbarkeit:** Das Repo ist auf GitHub derzeit **öffentlich**, laut Plan soll es **privat** sein.
  Ließ sich von hier nicht umstellen → Settings → General → Danger Zone → Change visibility (Jannik).
  Es enthält keine Secrets.
- Abweichungen bzw. Ergänzungen zum Plan:
  - Token als `http.extraHeader` über `GIT_CONFIG_COUNT/KEY/VALUE`-Umgebungsvariablen statt `git -c …`.
    So steht es auch nicht in der Prozessliste.
  - Commits, die den Add-on-Ordner nicht ändern (README, CLAUDE.md …), lösen keinen Deploy aus.
    Nur die SHA wird gespeichert.
  - `rsync --checksum`, damit auch gleich große Änderungen mit gleicher mtime erkannt werden.
  - Fetch-Fehler (z. B. Token abgelaufen) benachrichtigen nur beim ersten Mal, nicht alle 5 min.
    Die SHA bleibt dabei unverändert.
  - Symlinks, die aus dem Repo herauszeigen, werden abgelehnt (zusätzlich zur `..`-Prüfung).
  - Ist der alte Stand nicht mehr in der Historie (Force-Push), wird vollständig deployt.
  - Schema `repo` per `match(owner/name)` eingeschränkt.
  - Im Dry-Run wird die SHA auch bei Prüf-Fehlern nicht gespeichert.

### Lokaler Test

- `shellcheck run.sh deploy.sh`: sauber (SC1111 für die deutschen Anführungszeichen „…“ bewusst abgeschaltet).
- `tests/run_tests.sh`: **53/53 bestanden**, gegen Mock-Supervisor (Python `http.server`) und lokales Git-Repo
  (`GIT_BASE_URL=file://…`). Abgedeckt: erster Lauf = nur Ausgangsstand, Dry-Run ändert nichts (inkl.
  `*deleting` in der Liste), neuer Commit → rsync + reload + rebuild + Health + Erfolgsmeldung, gelöschte
  Dateien, Commit außerhalb des Ordners, Versionssprung → update, config.yaml ohne Versionssprung → Warnung,
  falscher Slug → Abbruch (SHA gespeichert, kein erneuter Versuch), Health-Fehler, Add-on gestoppt,
  HTTP 403 beim Rebuild, nicht installiert → nur Hinweis, Token nie im Log/.git/config,
  `git_deployer` abgelehnt, Path-Traversal und Symlink abgelehnt, Fetch-Fehler nur einmal gemeldet,
  run.sh: Fehler einer App blockiert die andere nicht.
- Dieselbe Suite mit **Busybox-Applets** aus `alpine:3.20` vor `PATH` (realpath, sed, date, base64 …): 53/53.
  Dabei gefunden und behoben: Busybox-`realpath` kennt kein `-m`.
- Dabei außerdem gefunden und behoben: `jq '.dry_run // true'` liefert bei `false` trotzdem `true`.
- **`docker build`: nicht möglich.** Docker läuft, aber die Netzwerk-Policy der Testumgebung sperrt
  `dl-cdn.alpinelinux.org` (HTTP 403), `apk add` schlägt fehl. Das Dockerfile entspricht 1:1 dem Plan.
  Der Build passiert ohnehin auf HA.

### Nicht testbar (→ Phase 4)

- Echter Supervisor: ob `hassio_role: manager` reicht (sonst HTTP 403 → `admin`), Antwortformat von
  `/addons/local_<slug>/info` bei nicht installiertem Add-on (erkannt an `data.version == null`),
  Dauer von Update/Rebuild (`--max-time 1200`).
- HA-Core-API für `persistent_notification` über `http://supervisor/core/api`.
- Erreichbarkeit der `health_url` (Host-IP) aus dem Add-on-Container.
- Echter GitHub-Zugriff mit Fine-grained Token (der Header-Weg ist der von GitHub dokumentierte).

### Phase 3

- Tag `v1.0.0` auf den Übergabe-Commit gesetzt.
