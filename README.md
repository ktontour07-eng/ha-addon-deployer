# ha-addon-deployer

Lokales Home-Assistant-Add-on **Git-Deployer**: Ein Merge auf `main` eines App-Repos landet
automatisch auf HA, ohne Samba-Kopie, ohne `ha store reload` und ohne manuelles Update.
Slug, Daten und Backup der Add-ons bleiben erhalten (`local_<slug>`).

Planung und Status: [PLAN.md](PLAN.md) · Add-on-Doku: [git_deployer/DOCS.md](git_deployer/DOCS.md)

## Aufbau

```
git_deployer/           ← wird einmalig nach \\192.168.178.28\addons\git_deployer\ kopiert
  config.yaml           ← Add-on-Definition, Optionen, Liste der Apps
  Dockerfile
  run.sh                ← Hauptschleife (alle interval_minutes)
  deploy.sh             ← ein Deploy-Durchlauf für eine App: deploy.sh <index>
  DOCS.md
tests/                  ← lokaler Test (wird nicht nach HA kopiert)
  run_tests.sh, mock_supervisor.py
```

## Installation

1. Ordner `git_deployer/` per Samba nach `\\192.168.178.28\addons\git_deployer\` kopieren.
2. Einstellungen → Add-ons → Add-on-Store → ⋮ → „Nach Updates suchen“, „Git-Deployer“ installieren.
3. Optionen: `github_token` eintragen, `dry_run: true` zunächst lassen. Starten.
4. Log prüfen (für jede App „Ausgangsstand … gespeichert“), danach `dry_run: false`.

Updates des Deployers selbst laufen weiter per Samba (er verwaltet sich nie selbst).

## Lokal testen

```bash
shellcheck git_deployer/run.sh git_deployer/deploy.sh
tests/run_tests.sh      # braucht bash, git, rsync, curl, jq, python3
```

Der Test spielt gegen einen Mock-Supervisor und ein lokales Git-Repo durch: erster Lauf,
Dry-Run, Rebuild, Update bei Versionssprung, falscher Slug, Health-Fehler, nicht installiert,
Path-Traversal/Symlink, Fetch-Fehler, Token nie im Log.
