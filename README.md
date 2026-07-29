# Infraestructura del VPS

Repositorio de infraestructura del VPS (Ubuntu 24.04, 4 GB RAM, Docker + Docker Compose v2).
Describe **qué corre en el servidor**: composes, configuración de Traefik y documentación.
No contiene código de aplicaciones ni Dockerfiles — las imágenes ya construidas viven en el
GitLab Container Registry (`registry.gitlab.com`).

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
├── pinzon/                  # Plataforma multi-tenant PRODUCTIVA — pinzontravel.com
│   ├── docker-compose.yml   # front (Next.js), api (NestJS), db (Postgres 17), redis (Redis 7)
│   └── .env.example
└── dromo/                   # Plataforma multi-tenant en PRE-LANZAMIENTO (idéntica a pinzon)
    ├── docker-compose.yml
    └── .env.example
```

Arquitectura de red:

```
Internet ──▶ Traefik v3 (:80 → :443)          red externa "proxy"
               │
               ├─ dizaru.com ───────────────▶ dizaru/web (nginx)
               ├─ pinzontravel.com, www, app, *.tenants ─▶ pinzon/front
               ├─ api.pinzontravel.com ─────▶ pinzon/api
               ├─ ${DROMO_DOMAIN}, www, app, *.tenants ──▶ dromo/front   (+ basic auth + noindex)
               └─ api.${DROMO_DOMAIN} ──────▶ dromo/api                  (+ basic auth + noindex)

pinzon/db, pinzon/redis, dromo/db, dromo/redis: SOLO en la red interna de su
proyecto, sin puertos publicados.
```

Convenciones:

- Un solo Traefik en la red Docker externa `proxy` (`docker network create proxy`).
- `exposedByDefault: false`: cada servicio expuesto lleva `traefik.enable=true` explícito.
- Servicios con más de una red llevan `traefik.docker.network=proxy`.
- Todos los servicios: `restart: unless-stopped`.
- Servicios Node: `mem_limit` (384m APIs, 512m Next.js) con `NODE_OPTIONS=--max-old-space-size` coherente.
- Tags: `pinzon` y `dromo` usan tags inmutables (`v0.1.0`, `v0.2.0`, …); `dizaru` usa `:latest`.
- Certificados: `letsencrypt` (HTTP-01) para dizaru; `letsencrypt-dns` (DNS-01 vía IONOS) para
  los wildcards de pinzon y dromo.

## Bootstrap en un servidor nuevo

Requisitos previos: Docker + Docker Compose v2 instalados, DNS apuntando al servidor.

```bash
# 1. Clonar el repo en /srv
cd /srv
git clone <URL-del-repo> infraestructure
cd infraestructure

# 2. Login al GitLab Container Registry con un deploy token (scope read_registry)
docker login registry.gitlab.com -u <deploy-token-username> -p <deploy-token>

# 3. Crear la red compartida del proxy
docker network create proxy

# 4. Crear los .env reales a partir de los .env.example y editar los valores
cp traefik/.env.example traefik/.env
cp dizaru/.env.example  dizaru/.env
cp pinzon/.env.example  pinzon/.env
cp dromo/.env.example   dromo/.env
# editar cada .env con credenciales reales

# 5. Directorio de certificados de Traefik
mkdir -p traefik/letsencrypt

# 6. Arrancar en orden: traefik → dizaru → pinzon → dromo
docker compose -f traefik/docker-compose.yml up -d
docker compose -f dizaru/docker-compose.yml up -d
docker compose -f pinzon/docker-compose.yml up -d
docker compose -f dromo/docker-compose.yml up -d
```

## Operaciones comunes

### Desplegar una nueva versión (pinzon / dromo)

1. En el repo: editar el tag de la imagen en el `docker-compose.yml` del proyecto
   (p. ej. `pinzon-front:v0.1.0` → `pinzon-front:v0.2.0`) y hacer commit + push.
2. En el servidor:

```bash
cd /srv/infraestructure
git pull
docker compose -f pinzon/docker-compose.yml pull
docker compose -f pinzon/docker-compose.yml up -d
```

Para dizaru (`:latest`) no hay que editar nada: basta `pull && up -d`.

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

1. Comprar el dominio real y apuntar su DNS (apex, `www`, `app`, `api` y wildcard `*`) al servidor.
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

- **Bases de datos**: dump lógico de cada Postgres:

  ```bash
  docker compose -f pinzon/docker-compose.yml exec db pg_dump -U pinzon -d pinzon > pinzon-$(date +%F).sql
  docker compose -f dromo/docker-compose.yml  exec db pg_dump -U dromo  -d dromo  > dromo-$(date +%F).sql
  ```

- **Los `.env` reales** de cada carpeta (no están en git; guardarlos en un gestor de secretos).
- `traefik/letsencrypt/` es prescindible: los certificados se re-emiten solos.
- Redis se usa como caché/colas efímeras: no requiere backup.

Restauración en un servidor nuevo:

1. Seguir el [bootstrap](#bootstrap-en-un-servidor-nuevo) completo (los `.env` salen del
   gestor de secretos, no de los example).
2. Arrancar pinzon/dromo y restaurar cada dump:

   ```bash
   docker compose -f pinzon/docker-compose.yml exec -T db psql -U pinzon -d pinzon < pinzon-YYYY-MM-DD.sql
   ```

3. Verificar certificados en los logs de Traefik y probar cada dominio.

Las imágenes no se respaldan: viven en el registry de GitLab y se re-descargan con `pull`.
