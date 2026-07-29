#!/bin/sh
# Bootstrap de primer arranque del cluster de dromo (docker-entrypoint-initdb.d).
# Solo corre cuando el volumen de datos está vacío. Crea:
#   - route_control: DB del control plane (Tenant, TenantConnection, …)
#   - route_provisioner: usuario de aplicación con CREATEDB + CREATEROLE
#     (el provisioning de tenants hace CREATE DATABASE / CREATE USER)
#   - pgbouncer_authenticator + función pgbouncer_auth_query: auth_query
#     mode de PgBouncer (ver pgbouncer/pgbouncer.ini)
# Las contraseñas vienen del .env (ROUTE_PROVISIONER_PASSWORD, PGBOUNCER_AUTH_PASSWORD).
set -eu

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres <<EOF
CREATE DATABASE route_control;
CREATE USER route_provisioner WITH ENCRYPTED PASSWORD '${ROUTE_PROVISIONER_PASSWORD}' CREATEDB CREATEROLE;
GRANT ALL PRIVILEGES ON DATABASE route_control TO route_provisioner;
CREATE USER pgbouncer_authenticator WITH ENCRYPTED PASSWORD '${PGBOUNCER_AUTH_PASSWORD}';
EOF

# Postgres 15+ revoca CREATE en schema public a PUBLIC; sin este GRANT,
# prisma migrate deploy falla con "permission denied for schema public".
# La función auth_query DEBE existir en route_control (auth_dbname de PgBouncer).
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d route_control <<'EOF'
GRANT CREATE, USAGE ON SCHEMA public TO route_provisioner;

CREATE OR REPLACE FUNCTION public.pgbouncer_auth_query(uname text)
  RETURNS TABLE (usename text, passwd text)
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path = pg_catalog
AS $$
  SELECT usename::text, passwd::text FROM pg_shadow WHERE usename = $1;
$$;
REVOKE ALL ON FUNCTION public.pgbouncer_auth_query(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pgbouncer_auth_query(text) TO pgbouncer_authenticator;
EOF
