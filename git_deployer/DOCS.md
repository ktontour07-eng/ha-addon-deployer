# Git-Deployer

Spielt eigene lokale Add-ons automatisch aus GitHub ein. Der Deployer fragt die konfigurierten
Repos regelmäßig ab. Gibt es auf dem Branch einen neuen Commit, der den Add-on-Ordner ändert,
kopiert er den Ordner nach `/addons/<slug>` und stößt über die Supervisor-API ein **Update**
(bei Versionssprung) oder einen **Rebuild** an. Slug, `/data` und Backups der Add-ons bleiben
dabei unverändert (`local_<slug>`).

Kurz: **Merge nach `main` = live**, innerhalb von ca. `interval_minutes`.

## Optionen

| Option | Bedeutung |
|---|---|
| `github_token` | Fine-grained Token, nur die App-Repos, Berechtigung **Contents: Read-only**. |
| `interval_minutes` | Abstand zwischen zwei Prüfungen (1–60, Standard 5). |
| `dry_run` | `true`: nur protokollieren, was `rsync` ändern würde. Nichts wird kopiert oder gebaut. |
| `notify_success` | Auch bei Erfolg eine Benachrichtigung in HA anzeigen. |
| `apps` | Liste der verwalteten Add-ons (siehe unten). |

Pro Eintrag in `apps`:

| Feld | Beispiel | Bedeutung |
|---|---|---|
| `repo` | `ktontour07-eng/ha-Bon` | GitHub-Repo `owner/name` |
| `branch` | `main` | Branch, der live ist |
| `path` | `bon_tracker` | Add-on-Ordner im Repo (mit `config.yaml`) |
| `slug` | `bon_tracker` | Slug des lokalen Add-ons, Ziel ist `/addons/<slug>` |
| `health_url` | `http://192.168.178.28:5010/api/ping` | optional, muss nach dem Deploy 2xx liefern |

## Ablauf je App

1. **Holen:** Klon unter `/data/repos/<slug>`, danach `git fetch` + `reset --hard`.
2. **Neu?** Vergleich mit `/data/state/<slug>.sha`. **Erster Lauf** (keine State-Datei):
   Ausgangsstand speichern, **nicht** deployen.
   Commits, die den Add-on-Ordner nicht berühren (README, CLAUDE.md …), lösen keinen Deploy aus.
3. **Prüfen:** `config.yaml` vorhanden, `slug:` darin stimmt, Ordner liegt im Repo.
   Wurde `config.yaml` ohne Versionssprung geändert, kommt eine Warnung.
4. **Kopieren:** `rsync --delete` nach `/addons/<slug>/`. Dateien, die nur auf HA liegen,
   werden dabei **gelöscht**. Im Dry-Run stehen sie im Log als `*deleting …`.
5. **Store neu laden**, dann **Update** (wenn HA ein Update anbietet) oder **Rebuild**.
6. **Gesundheitscheck:** bis zu 3 min: Add-on-Status `started` und `health_url` liefert 2xx.
7. **Ergebnis:** Status in `/data/state/<slug>.json`, Benachrichtigung in HA
   (`notification_id: deploy_<slug>`, wird überschrieben statt gestapelt).

Die neue SHA wird auch bei einem Fehler gespeichert. Kaputter Code wird also nicht alle
5 min neu gebaut. Erst der nächste Commit löst wieder einen Deploy aus.

## Bedienung

- **Jetzt prüfen:** Add-on neu starten. Ein Neustart löst sofort einen Durchlauf aus.
- **Erneut deployen** (z. B. nach einem Fehler ohne neuen Commit): `/data/state/<slug>.sha`
  gibt es nur im Add-on-Container. Einfacher ist ein neuer (Mini-)Commit auf `main`.
- **Neue App aufnehmen:** Ordner einmal per Samba nach `/addons/<slug>` kopieren, installieren,
  Optionen setzen. Dann hier unter `apps` eintragen, Token in GitHub auf das Repo erweitern und
  den Deployer neu starten. Der erste Lauf speichert den Ausgangsstand.

## Grenzen (bewusst)

- Installiert **nie** ein Add-on neu. Ist `local_<slug>` nicht installiert, kommt nur ein Hinweis.
- Verwaltet **nie sich selbst** (`slug: git_deployer` wird abgelehnt). Updates des Deployers per Samba.
- Ruft nur `local_<slug>` der konfigurierten Apps auf.

## Rechte

`hassio_role: manager` sollte für `/store/reload`, `/store/addons/<addon>/update` und
`/addons/<addon>/rebuild` reichen. Kommt im Probelauf **HTTP 403**, die Rolle auf `admin` erhöhen
und das hier begründen.

## Sicherheit

- Das Token steht weder in der Clone-URL noch in `.git/config` noch auf der Kommandozeile.
  Es wird als `http.extraHeader` über Umgebungsvariablen (`GIT_CONFIG_*`) an git übergeben
  und nie geloggt.
- Kein offener Port.
