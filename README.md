# Infraestructura del VPS

Repositorio de infraestructura del VPS (Ubuntu 24.04, 4 GB RAM, Docker + Docker Compose v2).
Describe **qué corre en el servidor**: composes, configuración de Traefik y documentación.
No contiene código de aplicaciones ni Dockerfiles — las imágenes ya construidas viven en el
GitHub Container Registry (`ghcr.io`), publicadas por GitHub Actions desde cada repo de producto.

El repo se clona en `/srv/` del servidor.

## Estructura

```
/srv/infraestructure/
├── README.md
├── .gitignore
├── traefik/                 # Reverse proxy único (Traefik v3)
│   ├── docker-compose.yml
│   ├── traefik.yml          # Configuración estática (entrypoints, providers, resolvers ACME)
│   ├── .env.example         # IONOS_API_KEY (DNS-01)
│   └── letsencrypt/         # acme.json / acme-dns.json (NO versionado, se crea en el server)
├── dizaru/                  # Landing estática (Astro + nginx) — dizaru.com
│   ├── docker-compose.yml
│   └── .env.example
├── pinzon/                  # Plataforma DEMO para clientes — pinzontravel.com
│   ├── docker-compose.yml   # web (SPA React/nginx), api (NestJS+Prisma), db (Postgres 17)
│   └── .env.example
└── dromo/                   # Plataforma multi-tenant en PRE-LANZAMIENTO
    ├── docker-compose.yml   # web + admin (SPA/nginx), api (NestJS), db, pgbouncer, redis
    ├── .env.example
    ├── postgres/init.sh     # Bootstrap del cluster (route_control, usuarios, auth_query)
    └── pgbouncer/           # pgbouncer.ini + userlist.txt.example (el .txt real NO se versiona)
```

> **Nota sobre pinzon**: es la plataforma demo para mostrar a clientes y se mantiene
> deliberadamente simple (una sola DB, sin Redis, sin PgBouncer). Eventualmente migrará
> a una infraestructura similar a la de dromo.

Arquitectura de red:

```
Internet ──▶ Traefik v3 (:80 → :443)          red externa "proxy"
               │
               ├─ dizaru.com ───────────────▶ dizaru/web (nginx)
               ├─ pinzontravel.com, www ───▶ pinzon/landing (nginx, Astro)
               ├─ app.pinzontravel.com, *.tenants ─▶ pinzon/web (nginx SPA)
               ├─ api.pinzontravel.com ─────▶ pinzon/api
               ├─ ${DROMO_DOMAIN}, www, app, *.tenants ──▶ dromo/web    (+ basic auth + noindex)
               ├─ admin.${DROMO_DOMAIN} ────▶ dromo/admin               (+ basic auth + noindex)
               └─ api.${DROMO_DOMAIN} ──────▶ dromo/api                 (+ basic auth + noindex)

Solo en redes internas (sin puertos publicados):
  pinzon/db · dromo/db · dromo/pgbouncer · dromo/redis
```

Convenciones:

- Un solo Traefik en la red Docker externa `proxy` (`docker network create proxy`).
- `exposedByDefault: false`: cada servicio expuesto lleva `traefik.enable=true` explícito.
- Servicios con más de una red llevan `traefik.docker.network=proxy`.
- Todos los servicios: `restart: unless-stopped`.
- APIs Node: `mem_limit: 384m` con `NODE_OPTIONS=--max-old-space-size=256`. Los frontends
  son estáticos servidos por nginx (64m).
- Tags: `pinzon` y `dromo` usan tags inmutables (`v0.1.0`, `v0.2.0`, …); las landings
  (`dizaru`, `pinzon-landing`) usan `:latest`.
- Certificados: `letsencrypt` (HTTP-01) para dizaru; `letsencrypt-dns` (DNS-01 vía Cloudflare)
  para los wildcards de pinzon y dromo.

### DNS

Los dominios están registrados en Squarespace, que **no tiene API de DNS** — y el reto
DNS-01 de los certificados wildcard necesita una. Por eso:

- **dizaru.com**: se queda en Squarespace. Solo necesita registros A (apex y `www`)
  apuntando al VPS; su certificado sale por HTTP-01.
- **pinzontravel.com** (y el futuro dominio de dromo): delegar los nameservers a
  **Cloudflare** (plan free, el dominio sigue registrado en Squarespace). En Cloudflare:
  registros A para apex, `www`, `app`, `api` y `*` (wildcard) apuntando al VPS, en modo
  **DNS only** (nube gris — Traefik gestiona el TLS, no el proxy de Cloudflare), y un
  API token con `Zone:DNS:Edit` para el `CF_DNS_API_TOKEN` de `traefik/.env`.

### Imágenes

Todas las imágenes viven en `ghcr.io/josuecastillodev` y las construye el CI de cada
repo de producto (ver [Deploys](#deploys-gitops)):

| Imagen | Repo origen | Tag |
|---|---|---|
| `dizaru` | dizaru-landing (Astro estático → nginx) | `:latest` |
| `pinzon-landing` | pinzon-landing (Astro estático → nginx) | `:latest` |
| `pinzon-web`, `pinzon-api` | Pinzon (`apps/web`, `apps/api`) | `vX.Y.Z` |
| `dromo-web`, `dromo-admin`, `dromo-api` | route-platform (`apps/web`, `apps/admin`, `apps/api`) | `vX.Y.Z` |

### Dependencias externas de dromo

- **Infisical**: la API lee sus secretos de negocio (JWT, S3/R2, SMTP…) de Infisical en
  runtime; el `.env` solo lleva las credenciales machine identity y la infraestructura local.
- **S3/R2**: almacenamiento de objetos en producción (Cloudflare R2); el CORS del bucket
  se configura en R2, no aquí.
- **SMTP**: proveedor de correo transaccional.

## Bootstrap en un servidor nuevo

Requisitos previos: Docker + Docker Compose v2 instalados, DNS apuntando al servidor.

```bash
# 1. Clonar el repo en /srv
cd /srv
git clone <URL-del-repo> infraestructure
cd infraestructure

# 2. Login al GitHub Container Registry con un PAT (classic) de solo lectura
#    (scope read:packages), generado en https://github.com/settings/tokens
docker login ghcr.io -u josuecastillodev -p <PAT-read-packages>

# 3. Crear la red compartida del proxy
docker network create proxy

# 4. Crear los .env reales a partir de los .env.example y editar los valores
cp traefik/.env.example traefik/.env
cp dizaru/.env.example  dizaru/.env
cp pinzon/.env.example  pinzon/.env
cp dromo/.env.example   dromo/.env
# editar cada .env con credenciales reales

# 5. Directorio de certificados de Traefik y userlist provisional de PgBouncer
mkdir -p traefik/letsencrypt
cp dromo/pgbouncer/userlist.txt.example dromo/pgbouncer/userlist.txt

# 6. Arrancar en orden: traefik → dizaru → pinzon → dromo
docker compose -f traefik/docker-compose.yml up -d
docker compose -f dizaru/docker-compose.yml up -d
docker compose -f pinzon/docker-compose.yml up -d
docker compose -f dromo/docker-compose.yml up -d
```

### PgBouncer de dromo: generar userlist.txt (primera vez)

PgBouncer usa auth_query, pero necesita el hash SCRAM real de `pgbouncer_authenticator`
para autenticarse él mismo contra Postgres:

```bash
docker compose -f dromo/docker-compose.yml exec db \
  psql -U postgres -d postgres -t -A -c \
  "SELECT '\"' || rolname || '\" \"' || rolpassword || '\"' FROM pg_authid WHERE rolname = 'pgbouncer_authenticator'"
```

Copiar la línea resultante a `dromo/pgbouncer/userlist.txt` (reemplazando el contenido
de ejemplo) y reiniciar:

```bash
docker compose -f dromo/docker-compose.yml restart pgbouncer
```

`userlist.txt` está en `.gitignore`: contiene material de autenticación y vive solo en el servidor.

## Deploys (GitOps)

Los deploys están automatizados de punta a punta: **nunca hay que entrar al servidor**.
El gesto depende del tipo de repo:

| Repo | Gesto | Qué pasa solo |
|---|---|---|
| `dizaru-landing` | `git push` a `main` | CI construye `dizaru:latest` → SSH al VPS → `deploy dizaru` |
| `pinzon-landing` | `git push` a `main` | CI construye `pinzon-landing:latest` → SSH al VPS → `deploy pinzon` |
| `infraestructure` (este repo) | `git push` a `main` | workflow `deploy.yml` → SSH al VPS → `deploy all` |
| `Pinzon` / `route-platform` | tag `vX.Y.Z` | CI construye imágenes → job `bump-infra` committea la versión aquí → eso dispara `deploy all` |

### Publicar versión de pinzon / dromo (la forma cómoda)

```bash
npm version patch        # o minor / major — crea commit + tag vX.Y.Z
git push --follow-tags   # empuja el commit a main Y el tag en un solo comando
```

> **Ojo**: `git push --tags` a secas empuja el tag (y sí detona el deploy) pero NO el
> commit del bump a `main` — la rama queda desincronizada. Usar siempre `--follow-tags`,
> o dejarlo como default con `git config --global push.followTags true` y entonces basta
> `git push` normal.

No hay que editar este repo a mano: el job `bump-infra` del CI del producto actualiza el
tag de imagen en el `docker-compose.yml` correspondiente (necesita el secret
`INFRA_PUSH_TOKEN`, un PAT fine-grained con Contents RW solo sobre este repo).

### Cómo funciona por debajo

1. Cada workflow con deploy usa el secret `DEPLOY_SSH_KEY` y entra como `josue@VPS` con
   una llave **restringida por forced command**: solo puede ejecutar
   `scripts/deploy-entry.sh`, que únicamente acepta `deploy <traefik|dizaru|pinzon|dromo|all>`
   (sin pty, sin forwarding). La llave no sirve para nada más.
2. En el servidor, `scripts/deploy.sh` hace `git pull --ff-only` en `/srv/infraestructure`
   y luego `docker compose pull && up -d` del stack pedido. Para dromo además recicla
   pgbouncer y api si la db se recreó.
3. Ver el avance / relanzar a mano: pestaña **Actions** del repo, o
   `gh run list` / `gh workflow run deploy.yml` (el workflow de este repo admite
   `workflow_dispatch`).

> La API de pinzon ejecuta `prisma migrate deploy` en su entrypoint: cada deploy aplica
> las migraciones pendientes automáticamente. Con `SEED_ON_START=true` además puebla la
> demo (dejar en `false` tras el primer arranque).

### Deploy manual (fallback)

Si GitHub Actions está caído o hay que forzar algo:

```bash
ssh josue@VPS
cd /srv/infraestructure && git pull
docker compose -f dromo/docker-compose.yml pull
docker compose -f dromo/docker-compose.yml up -d   # o el stack que toque
```

`restart` NO relee labels de Traefik ni cambios de `.env`: para eso siempre `up -d`
(recrea solo lo que cambió) o `up -d --force-recreate` en el servicio afectado.

## Operaciones comunes

### Ver logs de emisión de certificados

```bash
docker compose -f traefik/docker-compose.yml logs -f traefik | grep -i acme
```

Los certificados emitidos quedan en `traefik/letsencrypt/acme.json` (HTTP-01) y
`traefik/letsencrypt/acme-dns.json` (DNS-01).

### Basic auth de dromo: generar el hash

```bash
htpasswd -nB usuario
# copiar la salida "usuario:$2y$..." a DROMO_BASIC_AUTH en dromo/.env,
# entre comillas simples para que los `$` del hash no se interpolen.
```

Verificar la interpolación con `docker compose -f dromo/docker-compose.yml config`.

## Lanzamiento de dromo

dromo está en pre-lanzamiento: sin dominio definitivo y protegido por dos middlewares
de Traefik (basic auth y `X-Robots-Tag: noindex, nofollow`). **Quitar esos dos
middlewares es el procedimiento de lanzamiento.** Pasos:

1. Comprar el dominio real, delegar sus nameservers a Cloudflare (ver sección [DNS](#dns))
   y apuntar apex, `www`, `app`, `admin`, `api` y wildcard `*` al servidor.
2. En `dromo/.env` del servidor: reemplazar `DROMO_DOMAIN` por el dominio real.
3. En `dromo/docker-compose.yml` (en el repo, commit + push + `git pull` en el server):
   - Eliminar los dos labels que definen los middlewares
     (`traefik.http.middlewares.dromo-auth.…` y `traefik.http.middlewares.dromo-noindex.…`).
   - Eliminar todos los labels `…routers.<router>.middlewares=dromo-auth,dromo-noindex`.
4. Aplicar:

```bash
docker compose -f dromo/docker-compose.yml up -d
```

Traefik emitirá el certificado wildcard del nuevo dominio por DNS-01 (revisar logs de acme).

## Agregar una nueva landing

Copiar el patrón de `dizaru/`:

1. Crear carpeta `nueva-landing/` con un `docker-compose.yml` igual al de dizaru, cambiando:
   - la imagen (`registry.gitlab.com/GRUPO/nueva-landing:latest`),
   - el nombre de router/servicio (`dizaru` → `nueva-landing`),
   - la regla `Host(...)` con el dominio nuevo.
2. Crear su `.env.example` (y el `.env` en el servidor, aunque esté vacío).
3. Apuntar el DNS del dominio al servidor y `docker compose -f nueva-landing/docker-compose.yml up -d`.

El certificado sale solo por HTTP-01 (resolver `letsencrypt`); no hay que tocar Traefik.

## Disaster recovery

Qué hay que respaldar (fuera del servidor, de forma periódica):

- **Pinzon** (una sola DB): dump lógico:

  ```bash
  docker compose -f pinzon/docker-compose.yml exec db pg_dump -U pinzon -d pinzon > pinzon-$(date +%F).sql
  ```

- **Dromo** (control plane + una DB por tenant): dump del cluster completo:

  ```bash
  docker compose -f dromo/docker-compose.yml exec db pg_dumpall -U postgres > dromo-$(date +%F).sql
  ```

- **Los `.env` reales** de cada carpeta y `dromo/pgbouncer/userlist.txt`
  (no están en git; guardarlos en un gestor de secretos).
- Los secretos de negocio de dromo viven en **Infisical** (respaldo propio, fuera de este server).
- `traefik/letsencrypt/` es prescindible: los certificados se re-emiten solos.
- Redis de dromo guarda colas BullMQ: tolerable perderlo (se reencolan trabajos), no se respalda.

Restauración en un servidor nuevo:

1. Seguir el [bootstrap](#bootstrap-en-un-servidor-nuevo) completo (los `.env` salen del
   gestor de secretos, no de los example).
2. Arrancar cada proyecto y restaurar los dumps:

   ```bash
   docker compose -f pinzon/docker-compose.yml exec -T db psql -U pinzon -d pinzon < pinzon-YYYY-MM-DD.sql
   docker compose -f dromo/docker-compose.yml  exec -T db psql -U postgres -d postgres < dromo-YYYY-MM-DD.sql
   ```

   (En dromo, `pg_dumpall` restaura roles y todas las DBs; regenerar después
   `pgbouncer/userlist.txt` como en el bootstrap.)
3. Verificar certificados en los logs de Traefik y probar cada dominio.

Las imágenes no se respaldan: viven en el registry de GitLab y se re-descargan con `pull`.
