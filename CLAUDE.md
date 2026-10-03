# ha-addon-deployer – Hinweise für Claude

Lokales HA-Add-on **Git-Deployer** (Slug `git_deployer`). Es holt die App-Repos per git,
kopiert den Add-on-Ordner nach `/addons/<slug>` und stößt über die Supervisor-API Update bzw.
Rebuild an. Plan und Status: [PLAN.md](PLAN.md), Nutzerdoku: [git_deployer/DOCS.md](git_deployer/DOCS.md).

## Regeln

- **Token nie loggen**, kein `set -x`, Token nie in URL, `.git/config` oder Kommandozeile
  (Übergabe als `http.extraHeader` über `GIT_CONFIG_*`).
- Der Deployer **verwaltet nie sich selbst** und **installiert nie** ein Add-on neu.
  Aufrufe nur an `local_<slug>` der konfigurierten Apps.
- Die neue SHA wird auch bei einem Fehler gespeichert (sonst Endlos-Rebuild). Ausnahme: Dry-Run.
- Laufzeit ist **Alpine/Busybox**: keine GNU-Optionen in Hilfsbefehlen (z. B. kein `realpath -m`).
  bash, git, rsync, curl, jq sind echte Pakete.
- jq: `false // true` ergibt `true`. Für Booleans `if .x == null then … else .x end` verwenden.
- Schema-Typen `email?`/`url?` nie verwenden, immer `str?`.
- Änderungen an `config.yaml` brauchen einen Versionssprung.
- Updates des Deployers selbst: Ordner per Samba kopieren, dann im Store aktualisieren.

## Vor dem Commit

```bash
shellcheck git_deployer/run.sh git_deployer/deploy.sh tests/run_tests.sh
tests/run_tests.sh
```

Neue Verhaltensweisen in `deploy.sh` bekommen einen Fall in `tests/run_tests.sh`.

## Konventionen

Code-Kommentare, Logzeilen und Benachrichtigungen auf **Deutsch**. Logzeilen mit Präfix `[<slug>]`.
