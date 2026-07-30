#!/usr/bin/env bash
# Deploy de los stacks del VPS. Lo invoca el workflow de GitHub Actions vía SSH
# (llave dedicada con forced command en deploy-entry.sh), o un humano a mano.
# Uso: deploy.sh [traefik|dizaru|pinzon|dromo|all]
set -euo pipefail

cd /srv/infraestructure
git pull --ff-only

deploy_stack() {
  local dir="$1"
  echo "==> ${dir}"
  (cd "$dir" && docker compose pull -q && docker compose up -d)
}

deploy_dromo() {
  # Si el contenedor db se recrea, PgBouncer se queda con la conexión vieja:
  # hay que reciclar pgbouncer y api después del up.
  local db_before db_after
  db_before=$(docker ps -q -f name=dromo-db-1 || true)
  deploy_stack dromo
  db_after=$(docker ps -q -f name=dromo-db-1 || true)
  if [ "$db_before" != "$db_after" ]; then
    echo "==> dromo: db recreada, reciclando pgbouncer y api"
    (cd dromo && docker compose restart pgbouncer && docker compose restart api)
  fi
}

target="${1:-all}"
case "$target" in
  traefik|dizaru|pinzon) deploy_stack "$target" ;;
  dromo) deploy_dromo ;;
  all)
    deploy_stack traefik
    deploy_stack dizaru
    deploy_stack pinzon
    deploy_dromo
    ;;
  *) echo "stack desconocido: $target" >&2; exit 1 ;;
esac
echo "deploy OK ($target)"
