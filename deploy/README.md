# Deploy runbook (Receipts server on the shared VM)

The Receipts server runs as its own Docker Compose stack in `/opt/receipts` on the same VM and
under the same domain as the FitnessBuddy project (`/opt/fitnessbuddy`). Nothing is shared with it except the VM, the domain and
FitnessBuddy's Caddy (which terminates TLS and routes `/api/v1/receipts/*` here). Code, deploy
scripts, data folder, backups and cron are all separate.

```
/opt/receipts/
  backend/                 the code (rsynced by push.sh), backend/.env.production (mode 600)
  deploy/                  docker-compose.yml and the scripts, deploy/.env (APP_UID, APP_GID)
    data/                  receipts.db, receipts_photos/   (never touched by push.sh)
    backups/               receipts_<ts>.db.gz (30 days), receipts_photos_pending/ (one mirror)
```

How requests arrive: Caddy (other stack) -> Docker network `deploy_default` -> container alias
`receipts-backend:8000`. The container publishes no host port. Compose project `receipts`, service
`receipts-backend` (the service name becomes a network alias; `backend` is already taken on that
network, and the project name is pinned because both stacks live in a directory called `deploy`).

## Requirements on the VM (already there)

docker + compose plugin, `sqlite3`, `rsync`, passwordless `sudo` for the login user (only to
create `/opt/receipts` once), and the Caddy stack running, so that the network `deploy_default`
exists. If the Caddy stack's compose project is not called `deploy`, put
`PROXY_NETWORK=<network>` into `/opt/receipts/deploy/.env` (push.sh keeps other keys).
Read-only checks on the VM:

```sh
docker compose ls                                   # the Caddy stack's project should be `deploy`
docker network ls | grep deploy_default
docker volume ls | grep caddy_data                  # deploy_caddy_data: the TLS certificates
```

## 1. Production env (Mac, once)

```sh
deploy/make-prod-env.sh --import-from <env file of the old shared server>
```

builds `backend/.env.production` (mode 600). `RECEIPTS_API_TOKEN` is kept if already there, else
imported (the installed apps keep working with the same token), else generated.
`CLAUDE_CODE_OAUTH_TOKEN` and `RECEIPTS_*` settings are imported if not already known; **nothing
else** in the import file is read. A re-run never drops a key that exists only in
`.env.production`; keys in `backend/.env` win over `.env.production`. Prints key names only.
`DOCS_ENABLED=false` and `SCHEDULER_ENABLED=true` are always written.

Without `CLAUDE_CODE_OAUTH_TOKEN` (subscription, from `claude setup-token`) or `ANTHROPIC_API_KEY`
uploads are stored but extraction waits (jobs stay queued). `deploy/copy-token.sh` copies
`RECEIPTS_API_TOKEN` to the clipboard without printing it.

## 2. Deploy / update

```sh
deploy/push.sh user@your-server --with-env     # first time (uploads .env.production)
deploy/push.sh user@your-server                # later: code only
```

Creates `/opt/receipts` (sudo, owned by the login user) if absent, rsyncs `backend/` and `deploy/`
(`data/` and `backups/` are excluded and never touched), installs the nightly backup cron if
absent, `docker compose up -d --build`, waits for `/health` inside the container and checks the
network alias. The entrypoint runs `alembic upgrade head` before serving (single uvicorn worker).
Logs and state: `deploy/status.sh user@your-server`,
`ssh HOST 'cd /opt/receipts/deploy && docker compose logs -f receipts-backend'`.

## 3. Take over the data of the old shared server (one-off, non-destructive)

`deploy/import-from-fitnessbuddy.sh user@your-server [--dry-run] [--freeze-fitness]` copies
`/opt/fitnessbuddy/deploy/data/receipts.db` (consistent `sqlite3 .backup`, integrity checked) and
`receipts_photos/` (rsync without `--delete`, verified by checksum) into `/opt/receipts/deploy/data`
and prints the counts of receipts, line items, dictionary entries and photo files for both sides.
It refuses when the new database already holds receipts, unless they are identical. It stops only
the new `receipts-backend` container while its database is replaced (and starts it again). It
deletes nothing: an existing empty `receipts.db` is moved aside as `receipts.db.before-import-<ts>`.
`--freeze-fitness` additionally stops the old backend container so nothing is written to the old
receipts data between copy and cut-over; the old project's API then stays down until its own
`push.sh` has run (it restarts only if the import fails). Without it a receipt uploaded to the
old server after the copy is not carried over.

## 4. Cut-over, in order

Run the steps in this order; each has a rollback.

| # | Where | Command | Effect | Rollback |
|---|---|---|---|---|
| 1 | Receipts repo | `deploy/make-prod-env.sh --import-from <old .env.production>` | writes `backend/.env.production` | `rm backend/.env.production` |
| 2 | Receipts repo | `deploy/push.sh user@your-server --with-env` | new stack up with an empty DB, nobody routes to it yet | `ssh HOST 'cd /opt/receipts/deploy && docker compose down'` (remove the 03:45 cron line with `crontab -e`) |
| 3 | Receipts repo | `deploy/import-from-fitnessbuddy.sh user@your-server --dry-run`, then without `--dry-run` | data copied, counts printed | move `data/receipts.db` aside and re-import; the old files are untouched |
| 4 | FitnessBuddy repo | `deploy/push.sh user@your-server` | its backend rebuilt without receipts code, Caddy gets the new Caddyfile: `/api/v1/receipts/*` -> `receipts-backend:8000` | check out the previous commit of that repo and run its `push.sh` again (routes back to the old backend, which still has the old files; anything written to the new server since is not there) |
| 5 | Mac | `curl -s -o /dev/null -w '%{http_code}\n' https://<domain>/api/v1/receipts/status` expects `401` (no token); then *Test connection* and a sync in the Receipts app | 502 means Caddy cannot reach `receipts-backend` (container down / not on `deploy_default`) | as step 4 |
| 6 | Mac | install the offsite backup (below) | | `launchctl bootout` |

Caddy keeps starting while `receipts-backend` is down: that path answers 502, everything else is
unaffected. If step 4 runs before step 2, receipts uploads get 502 until step 2 is done.

## 5. Removing the old copy (manual, later)

Only after the new server has been used for a while and `deploy/backup.sh` has run there at least
once. Nothing automatic deletes these. On the VM, in the old project's directory
(`/opt/fitnessbuddy/deploy`): move first, delete much later.

```sh
mkdir -p ~/old-receipts && cd /opt/fitnessbuddy/deploy
mv data/receipts.db data/receipts.db-wal data/receipts.db-shm data/receipts_photos ~/old-receipts/ 2>/dev/null
mv backups/receipts_*.db.gz backups/receipts_photos_pending ~/old-receipts/ 2>/dev/null
```

and delete the stale `RECEIPTS_*` lines from that project's `backend/.env.production` (they are
ignored there). The old tokens are not secrets you need to keep once the apps use the new server.

## 6. Backups

`deploy/backup.sh` (cron 03:45, log `/var/log/receipts-backup.log`; the other project's cron runs
at 03:15) writes `backups/receipts_<ts>.db.gz` (`sqlite3 .backup`, integrity checked, 30 days) and
refreshes **one** mirror, `backups/receipts_photos_pending/`, with `rsync -a --delete` of
`data/receipts_photos`. Why a mirror and not dated copies: the photos folder contains exactly the
photos that are not archived yet, so a mirror that follows deletions is as large as the photos
themselves and can never bring back a photo the laptop already archived, whereas dated copies would
grow without bound and keep archived photos for 30 days. The script refuses (exit 1, a line in the
log) when the disk could not hold the mirror.

Offsite copy to the Mac: `deploy/pull-backup.sh` takes a fresh snapshot, downloads it to
`~/Backups/Receipts/db/`, verifies it and mirrors the pending photos (the Mac mirror loses a photo at
the next pull after it was archived). A launchd agent runs it at login and daily; it only copies when
the newest local copy is older than 7 days.

```sh
mkdir -p ~/Library/Logs/Receipts
cp deploy/com.robinrossner.receipts.backup.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.robinrossner.receipts.backup.plist
bash deploy/pull-backup.sh --force      # copy now
```

Gap, stated plainly: between two nightly backups a freshly uploaded photo exists once on the server
(and on the phone that took it). Archived photos are in no server backup by design: the laptop
archive is their only copy, so keep the Mac archive folder in Time Machine / your own backup.

Restore after a lost or damaged server database:

```sh
ssh user@your-server && cd /opt/receipts/deploy
docker compose stop receipts-backend
gunzip -c backups/receipts_YYYYMMDD_HHMMSS.db.gz > data/receipts.db && rm -f data/receipts.db-wal data/receipts.db-shm
rsync -a --ignore-existing backups/receipts_photos_pending/ data/receipts_photos/
docker compose up -d receipts-backend   # the daily job removes files of receipts that are archived in this DB
```

A receipt whose photo was archived after the snapshot was taken may point at a file that is gone:
the laptop holds it, and `archive-confirm` for it is then a no-op.

## 7. Configuration

All keys are optional except the token (`backend/.env` for development, `backend/.env.production`
on the server, see `backend/.env.example`): `RECEIPTS_API_TOKEN`, `RECEIPTS_LLM_PROVIDER`
(`auto|claude_code|api`; `auto` prefers `CLAUDE_CODE_OAUTH_TOKEN`, then `ANTHROPIC_API_KEY`),
`RECEIPTS_LLM_MODEL` (default `claude-haiku-5-5`) and `RECEIPTS_LLM_EFFORT` (default `high`; leave both unset in production), `RECEIPTS_MAX_PHOTO_BYTES` (15 MB; Caddy has no
body limit of its own), `RECEIPTS_ARCHIVE_REMINDER_DAYS` (30), `RECEIPTS_DISK_WARNING_FREE_MB`
(2048), `RECEIPTS_NOTIFY_URL`, `AUTH_MAX_FAILURES` / `AUTH_FAILURE_WINDOW_S` (429 after 20 wrong
tokens per client IP in 10 minutes), `TRUSTED_PROXY_IPS` (default: private ranges, i.e. the Caddy
container). The `claude -p` call never receives `ANTHROPIC_API_KEY`.

Rotate the token: delete the `RECEIPTS_API_TOKEN` line in `backend/.env.production`, run
`deploy/make-prod-env.sh`, `deploy/push.sh user@your-server --with-env`, then `deploy/copy-token.sh` and
paste it into the apps.

Photo retention: a receipt photo stays on the server only until the Mac archive client has stored a
verified copy and confirmed its sha256 (`POST /receipts/{id}/archive-confirm`); nothing deletes a
photo because of its age. `GET /api/v1/receipts/status` shows `archive_overdue` and `disk_warning`;
a daily job (09:00) sends a reminder at most every 3 days, but **delivery needs
`RECEIPTS_NOTIFY_URL`** (ntfy style); otherwise it is only a log line.

## 8. Migrating the Mac app's data (only for a Mac database that was never synced)

`uv run python -m receipts.migrate_mac_data --db <Mac receipts.db> --archive <receipts_archive/>` (in
`backend/`) is a dry run; add `--apply` to write the local `backend/var/receipts.db`. It is idempotent,
gives every Mac row a stable UUID and uploads no photo. Work on a copy of the Mac data, not on
`~/Library/Application Support/ReceiptsApp/` while the app runs. To put such a database on the server
while the server holds no receipts yet (it REPLACES `data/receipts.db`):

```sh
ssh user@your-server 'cd /opt/receipts/deploy && docker compose stop receipts-backend'
sqlite3 backend/var/receipts.db ".backup /tmp/receipts-seed.db"
scp /tmp/receipts-seed.db user@your-server:/opt/receipts/deploy/data/receipts.db
ssh user@your-server 'cd /opt/receipts/deploy && docker compose up -d receipts-backend'
```

Once phones have uploaded receipts, copy the Mac database (and the archive folder) to
`deploy/data/mac-import/` and run the same command inside the container instead:
`docker compose exec receipts-backend python -m receipts.migrate_mac_data --db /app/var/mac-import/receipts.db --archive /app/var/mac-import/receipts_archive --apply`.

## Local checks of the scripts

`make-prod-env.sh`, `backup.sh`, `install-cron.sh` and `import-from-fitnessbuddy.sh` can be tried on
temp copies without a server (`IMPORT_LOCAL=1 FB_DEPLOY=... RC_DEPLOY=...` runs the import on this
machine against two temp directories, with a fake `docker` on `PATH`).
