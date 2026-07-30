#!/usr/bin/env bash
# Forced command de la llave SSH de deploys (ver authorized_keys en el VPS).
# Solo permite ejecutar el script de deploy con un stack válido; cualquier
# otro comando se rechaza. La llave además tiene no-pty/no-forwarding.
set -euo pipefail

# shellcheck disable=SC2086
set -- ${SSH_ORIGINAL_COMMAND:-}
case "${1:-}" in
  deploy) exec /srv/infraestructure/scripts/deploy.sh "${2:-all}" ;;
  *) echo "comando no permitido" >&2; exit 1 ;;
esac
