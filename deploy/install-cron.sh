#!/usr/bin/env bash
# Install the nightly backup cron (03:45, a different time than the other apps on this VM), its
# log file and the logrotate entry. Idempotent; run on the server as the normal sudo user
# (deploy/push.sh does it).
#   45 3 * * * /opt/receipts/deploy/backup.sh >> /var/log/receipts-backup.log 2>&1
set -euo pipefail

TARGET_USER="${TARGET_USER:-$(id -un)}"
TARGET_GROUP="${TARGET_GROUP:-$(id -gn)}"
APP_DIR="${APP_DIR:-/opt/receipts}"
LOG="${LOG:-/var/log/receipts-backup.log}"
LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/receipts-backup}"
CRON_TIME="${CRON_TIME:-45 3}"   # minute hour

[[ "$(id -u)" -ne 0 ]] || { echo "error: run as the normal user, not root" >&2; exit 1; }
[[ -x "$APP_DIR/deploy/backup.sh" ]] || chmod +x "$APP_DIR/deploy/backup.sh"

sudo -n touch "$LOG"
sudo -n chown "$TARGET_USER:$TARGET_GROUP" "$LOG"
sudo -n chmod 640 "$LOG"
sudo -n tee "$LOGROTATE_FILE" >/dev/null <<CONF
$LOG {
    monthly
    rotate 6
    compress
    missingok
    notifempty
    create 640 $TARGET_USER $TARGET_GROUP
}
CONF

cron_line="$CRON_TIME * * * $APP_DIR/deploy/backup.sh >> $LOG 2>&1"
current="$(crontab -l 2>/dev/null || true)"
if grep -qF "$APP_DIR/deploy/backup.sh" <<<"$current"; then
  echo "backup cron already installed"
else
  { [[ -n "$current" ]] && printf '%s\n' "$current"; printf '%s\n' "$cron_line"; } | crontab -
  echo "backup cron installed: $cron_line"
fi
