#!/usr/bin/env bash
# Backup diario: dumps de Postgres (pinzon + dromo) y configuración no versionada.
# Local en ~/backups (7 días) y offsite en Cloudflare R2 vía rclone (30 días).
# Corre por cron como josue (grupo docker, sin sudo):
#   0 9 * * * /srv/infraestructure/scripts/backup.sh >> $HOME/backups/backup.log 2>&1
set -euo pipefail

INFRA=/srv/infraestructure
DEST=${BACKUP_DIR:-$HOME/backups}
REMOTE=${BACKUP_REMOTE:-r2:dpd-backups}
RCLONE_CONF=${RCLONE_CONF:-$HOME/.config/rclone}
STAMP=$(date +%F)
DIR="$DEST/$STAMP"

echo "== backup $STAMP: inicio $(date -u +%T) UTC =="
mkdir -p "$DIR"

# Dumps lógicos (-T: sin tty, necesario bajo cron)
docker compose -f "$INFRA/pinzon/docker-compose.yml" exec -T db \
  pg_dump -U pinzon -d pinzon | gzip > "$DIR/pinzon.sql.gz"
# dromo es multi-DB (control plane + una DB por tenant): pg_dumpall trae todo, roles incluidos
docker compose -f "$INFRA/dromo/docker-compose.yml" exec -T db \
  pg_dumpall -U postgres | gzip > "$DIR/dromo.sql.gz"

# Configuración que no está en git: .env, userlist de pgbouncer y certificados ACME.
# Los acme*.json son de root: se leen vía contenedor (josue está en el grupo docker).
docker run --rm -v "$INFRA":/infra:ro alpine tar czf - -C /infra \
  traefik/.env traefik/letsencrypt \
  pinzon/.env dromo/.env dromo/pgbouncer/userlist.txt \
  > "$DIR/config.tgz"

# Sanidad: gzip íntegro y dumps con contenido real
gzip -t "$DIR"/*.gz
for f in "$DIR/pinzon.sql.gz" "$DIR/dromo.sql.gz"; do
  [ "$(stat -c%s "$f")" -gt 1024 ] || { echo "ERROR: $f sospechosamente pequeño"; exit 1; }
done
tar tzf "$DIR/config.tgz" >/dev/null

# Retención local: 7 días
find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime +6 -exec rm -rf {} +

# Offsite a R2. Sin rclone.conf el backup queda solo local (aviso, no error).
if [ ! -f "$RCLONE_CONF/rclone.conf" ]; then
  echo "AVISO: no existe $RCLONE_CONF/rclone.conf; backup solo local"
  exit 0
fi
docker run --rm -v "$RCLONE_CONF":/config/rclone -v "$DIR":/data:ro \
  rclone/rclone copy /data "$REMOTE/$STAMP"
# Retención remota: 30 días (borra archivos viejos y directorios que queden vacíos)
docker run --rm -v "$RCLONE_CONF":/config/rclone rclone/rclone delete --min-age 30d "$REMOTE"
docker run --rm -v "$RCLONE_CONF":/config/rclone rclone/rclone rmdirs --leave-root "$REMOTE"

echo "== backup OK: $DIR y $REMOTE/$STAMP =="
