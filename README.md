Kill Bill Docker stack
======================

Docker Compose stack for [Kill Bill](https://killbill.io) (open source
subscription billing and payments platform) and Kaui (its admin UI), usable
for local development and for simple production deployments (a single
server). Maintained by [BillMySales](https://www.billmysales.com).

| Component   | Image                             | Default version |
|-------------|-----------------------------------|-----------------|
| Web server  | `caddy:<ver>-alpine`              | 2.11            |
| Kill Bill   | `killbill/killbill` (vendor)      | 0.24.21         |
| Kaui        | `killbill/kaui` (vendor)          | 4.0.26          |
| Email plugin | `killbill-email-notifications` (in the image) | 0.8.6 |
| Database    | `mariadb` (official)              | 11.8 (LTS)      |
| Mailpit     | `axllent/mailpit` (optional, dev) | v1.31           |

Kill Bill and Kaui are the vendor's images (Ubuntu, Java 11, Tomcat; amd64
and arm64); MariaDB 11.8 is the version Kill Bill's own database image uses.
The Kill Bill image is built locally from the vendor's (`image/Dockerfile`,
a few seconds) to add the email notifications plugin (Apache-2.0), so the
running image doesn't download anything.

Requirements
------------

- Docker Engine 24+ with the Compose v2 plugin (`docker compose`, 2.20+).
- About 3.5 GB of disk for the images and 2.5 GB of RAM for the stack (two
  JVMs).
- Development: ports 8110, 8410 and 8025 free on the host.
- Production: a server with ports 80 and 443 reachable, and a DNS record for
  the site's domain pointing to it.

Quick start (development)
-------------------------

```shell
cp .env.dev.example .env
docker compose up -d
docker compose logs -f setup   # wait for "==> Done" (about 1 minute)
```

- Kaui: http://localhost:8110 (user `admin`, password `admin12345`), opens
  the tenant directly.
- API: http://localhost:8110/1.0/kb (HTTP basic auth `admin`/`admin12345`,
  headers `X-Killbill-ApiKey: dev` and `X-Killbill-ApiSecret: dev-secret`);
  API docs at http://localhost:8110/api.html.
- Mailpit (every email Kill Bill sends): http://localhost:8025

```shell
curl -u admin:admin12345 -H 'X-Killbill-ApiKey: dev' -H 'X-Killbill-ApiSecret: dev-secret' \
  http://localhost:8110/1.0/kb/accounts/pagination
```

Production
----------

```shell
cp .env.prod.example .env
# Fill in KILLBILL_URL, SITE_ADDRESS, DB_ROOT_PASSWORD, DB_PASSWORD,
# KILLBILL_ADMIN_PASSWORD, KILLBILL_API_KEY, KILLBILL_API_SECRET,
# KAUI_SECRET_KEY_BASE and the SMTP_* values.
docker compose up -d
```

- With `SITE_ADDRESS` set to the domain, Caddy gets a Let's Encrypt certificate
  and renews it automatically (certificates live in the `caddy_data` volume).
- Behind another TLS-terminating proxy, use `SITE_ADDRESS=:80`.
- Compose refuses to start while a required value is missing.
- The `backup` profile is enabled by default in the production template.
- Behind an existing Traefik (no host ports), use `overrides/traefik.yaml`
  (see [Overrides](#overrides)).

Services
--------

| Service    | Profile  | Role                                                                 |
|------------|----------|----------------------------------------------------------------------|
| `db`       |          | MariaDB: databases `killbill` and `kaui`, in the `db_data` volume.   |
| `migrate`  |          | One-shot job before Kill Bill (`scripts/migrate.sh`): schema.        |
| `killbill` |          | Kill Bill API (Tomcat), internal.                                    |
| `setup`    |          | One-shot job after Kill Bill (`scripts/setup.sh`): tenant and Kaui.  |
| `kaui`     |          | Kaui admin UI (Rails on JRuby, Tomcat), internal.                    |
| `caddy`    |          | TLS and public address, the only published ports (80, 443).          |
| `backup`   | `backup` | Dumps of both databases plus Kaui's key, on a schedule.              |
| `mailpit`  | `mailpit`| Development SMTP server that catches all mail.                       |

One address serves both: Caddy sends `/1.0/...`, `/plugins/...` and the API
docs (`/api.html`) to Kill Bill, and everything else to Kaui.

### What `migrate` and `setup` do

`migrate` (Kill Bill image, before Kill Bill starts):

- Creates the `killbill` and `kaui` databases and the stack's user.
- Empty database: loads the DDL of every Kill Bill module, taken from the
  jars of the running image (so the schema matches that exact version), and
  records its migrations as applied in `docker_stack_migrations`.
- Existing database: applies the migrations of the new version that aren't
  applied yet (the `migration/V<version>__*.sql` files in the jars, in
  version order). No internet access needed; the upstream tooling downloads
  them from GitHub and asks for confirmation.
- The tables of the plugins in the image (their `ddl.sql`), if missing.

`setup` (Kaui image, once Kill Bill is healthy):

- Kaui's schema on an empty `kaui` database, and `admin` as an allowed user.
- Kaui's encryption key, generated once in the `kaui_config` volume (the key
  in the Kaui image is public).
- The tenant (`KILLBILL_API_KEY`, `KILLBILL_API_SECRET`,
  `KILLBILL_TENANT_NAME`) through the API, if missing; it checks that the
  secret still matches (it can't be changed later).
- On every run, only when they change: the tenant's push notification
  callback (`KILLBILL_NOTIFICATION_URL`), Spanish invoice texts for
  `KILLBILL_INVOICE_LOCALE` (`es_CL`), and the email plugin's configuration
  (`SMTP_*`, `KILLBILL_EMAIL_EVENTS`) and Spanish email texts.
- The tenant registered in Kaui for `admin` (otherwise Kaui asks for the key
  and secret after the first login).

Common commands
---------------

```shell
docker compose ps                        # status: every service "healthy", migrate/setup "Exited (0)"
docker compose logs -f killbill kaui     # logs
docker compose exec db mariadb -u root -p killbill   # SQL shell
docker compose down                      # stop, keep data
docker compose down -v                   # stop and DELETE all data
```

Using Kill Bill
---------------

Kill Bill starts empty: add plans, then accounts and subscriptions, in Kaui
or through the API. For Chile, use `CLP` (amounts without decimals), the
account time zone `America/Santiago` and the locale `es_CL`, for example:

```shell
KB=(-u admin:admin12345 -H 'X-Killbill-ApiKey: dev' -H 'X-Killbill-ApiSecret: dev-secret'
    -H 'X-Killbill-CreatedBy: me' -H 'Content-Type: application/json')
# A monthly plan of $9.990 (added to the tenant's catalog)
curl "${KB[@]}" -X POST http://localhost:8110/1.0/kb/catalog/simplePlan -d \
  '{"planId":"pro-monthly","productName":"Pro","productCategory":"BASE","currency":"CLP","amount":9990,"billingPeriod":"MONTHLY","trialLength":0,"trialTimeUnit":"UNLIMITED"}'
# An account (the response's Location header has its id)
curl -i "${KB[@]}" -X POST http://localhost:8110/1.0/kb/accounts -d \
  '{"name":"Cliente SpA","email":"cliente@example.com","currency":"CLP","timeZone":"America/Santiago","locale":"es_CL","country":"CL"}'
# A subscription: Kill Bill invoices it right away
curl "${KB[@]}" -X POST http://localhost:8110/1.0/kb/subscriptions -d '{"accountId":"<id>","planName":"pro-monthly"}'
```

Full catalogs (XML, several plans and phases) can be uploaded in Kaui's
tenant configuration or with `POST /1.0/kb/catalog/xml`.

Kill Bill POSTs every event of the tenant (`ACCOUNT_CREATION`,
`SUBSCRIPTION_CREATION`, `INVOICE_CREATION`, `INVOICE_PAYMENT_SUCCESS`,
`INVOICE_PAYMENT_FAILED`, ...) as JSON to `KILLBILL_NOTIFICATION_URL`: that's
how an integration such as BillMySales learns about new invoices.

Emails
------

The killbill-email-notifications plugin emails the account's address (the
account's `email`) on the events in `KILLBILL_EMAIL_EVENTS`:

| Event                     | Email                                            |
|---------------------------|--------------------------------------------------|
| `INVOICE_CREATION`        | The new invoice.                                 |
| `INVOICE_NOTIFICATION`    | Upcoming invoice, `KILLBILL_UPCOMING_INVOICE_NOTICE` before it (off by default). |
| `INVOICE_PAYMENT_SUCCESS` | Payment receipt (refunds too).                   |
| `INVOICE_PAYMENT_FAILED`  | Failed payment.                                  |
| `SUBSCRIPTION_CANCEL`     | Cancellation requested / effective.              |

- SMTP comes from `SMTP_*` (the plugin's tenant configuration, rewritten by
  `setup` when it changes); without `SMTP_HOST` no email is sent. The plugin
  supports SMTPS (`SMTP_SECURE=ssl`, port 465) and plain SMTP, not STARTTLS
  on port 587.
- Accounts with the locale `es_CL` get Spanish texts
  (`config/killbill/EmailTranslation.properties`, a translation of the
  plugin's English texts plus the `KILLBILL_COMPANY_*` values); the others
  get the plugin's English. The HTML layout is the plugin's; custom
  templates can be uploaded per tenant and locale (tenant key
  `killbill-email-notifications:<TEMPLATE>_<locale>`, e.g.
  `INVOICE_CREATION_es_CL`, through `/1.0/kb/tenants/userKeyValue/<key>`).
- Per account, the events can be changed through the plugin's API
  (`/plugins/killbill-email-notifications/v1/accounts/<id>`).
- Some actions emit an event twice (an immediate cancellation sends the
  cancellation email twice and an invoice with the credit): that's how Kill
  Bill reports them.
- In production, BillMySales (with the biller) can send the tax documents
  instead: leave `KILLBILL_EMAIL_EVENTS` empty to keep only the push
  notifications.

Kill Bill's invoice HTML (`GET /1.0/kb/invoices/<id>/html`) uses the texts in
`config/killbill/InvoiceTranslation.properties` and the `KILLBILL_COMPANY_*`
values for accounts with the locale `es_CL`. It's not a Chilean tax document:
that comes from the biller (e.g. through BillMySales).

Backups
-------

With the `backup` profile, the `backup` service writes
`<timestamp>-killbill.sql.gz`, `<timestamp>-kaui.sql.gz` and
`<timestamp>-kaui-config.tar.gz` (Kaui's encryption key) to the `backups`
volume (or `./data/backups` with `overrides/local-dirs.yaml`) at start and
then every `BACKUP_INTERVAL_HOURS`, and deletes files older than
`BACKUP_KEEP_DAYS`. Files are readable by their owner only.

```shell
docker compose run --rm --no-deps backup now                  # back up now
docker compose run --rm --no-deps backup list                 # list timestamps
docker compose stop killbill kaui                   # Kill Bill keeps caches: stop it first
docker compose run --rm --no-deps backup restore <timestamp>  # both databases and the key
docker compose up -d
```

`--no-deps` keeps the command from starting `setup` first (with damaged
data `setup` fails and the restore would never run); the database must
be running (`docker compose up -d db` if the stack is down).

A restore empties each database first, so nothing created after the backup
remains.

Upgrades
--------

Back up first, then change `KILLBILL_VERSION` (and `KAUI_VERSION`,
`EMAIL_NOTIFICATIONS_VERSION`) in `.env` and run `docker compose up -d
--build`: the Kill Bill image is rebuilt on the new version and `migrate`
applies its schema migrations before Kill Bill starts. Downgrades are not
supported. Rebuild regularly for the vendor image's updates
(`docker compose build --pull`).

A database created elsewhere (e.g. by Kill Bill's own tooling) has no
`docker_stack_migrations` records: `migrate` stops and asks to mark the
current version's migrations as applied once, if that's its schema:
`MIGRATE_BASELINE=1 docker compose run --rm migrate`.

Overrides
---------

Optional compose files in `overrides/`, enabled with `COMPOSE_FILE` in `.env`
(several are combined with `:`). Each file documents its variables.

```shell
COMPOSE_FILE=compose.yaml:overrides/traefik.yaml:overrides/local-dirs.yaml
```

| File                        | Purpose                                                            |
|-----------------------------|--------------------------------------------------------------------|
| `overrides/traefik.yaml`    | Publish through an existing Traefik on a shared external network:  |
|                             | no host ports, Traefik terminates TLS (`TRAEFIK_HOST`, ...).       |
| `overrides/local-dirs.yaml` | Database, Kaui's key, Caddy and backups in local directories       |
|                             | (`DATA_DIR`, default `./data`) instead of named volumes.           |

A local `compose.override.yaml` (gitignored) is also loaded automatically by
Docker Compose, for changes specific to one machine.

Configuration
-------------

Every variable is documented in `.env.prod.example`. Main groups:

- **Site and network**: `KILLBILL_URL`, `SITE_ADDRESS`, `HTTP_BIND`,
  `HTTP_PORT`, `HTTPS_PORT`.
- **Credentials**: `DB_ROOT_PASSWORD`, `DB_PASSWORD`,
  `KILLBILL_ADMIN_PASSWORD`, `KILLBILL_API_KEY`, `KILLBILL_API_SECRET`,
  `KAUI_SECRET_KEY_BASE` (required).
- **Tenant**: `KILLBILL_TENANT_NAME`, `KILLBILL_NOTIFICATION_URL`,
  `KILLBILL_INVOICE_LOCALE`, `KILLBILL_COMPANY_*`,
  `KILLBILL_UPCOMING_INVOICE_NOTICE`.
- **Mail**: `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`,
  `SMTP_PASSWORD`, `SMTP_FROM`, `KILLBILL_EMAIL_EVENTS`.
- **Versions**: `KILLBILL_VERSION`, `EMAIL_NOTIFICATIONS_VERSION`,
  `KAUI_VERSION`, `MARIADB_VERSION`, `CADDY_VERSION`, `MAILPIT_VERSION`.
- **Resources and logs**: `KILLBILL_JAVA_XMX`, `KAUI_JAVA_XMX`,
  `*_MEMORY_LIMIT` per service, `LOG_MAX_SIZE`, `LOG_MAX_FILE`.

Configuration files, mounted read-only:

| File                                      | Purpose                                              |
|-------------------------------------------|------------------------------------------------------|
| `config/caddy/Caddyfile`                  | TLS, routing between Kill Bill and Kaui, headers.    |
| `config/tomcat/setenv2.sh`                | JVM options for both images (see Security).          |
| `config/killbill/InvoiceTranslation.properties` | Spanish invoice texts uploaded to the tenant.  |
| `config/killbill/EmailTranslation.properties`   | Spanish email texts (email plugin).            |

Notes:

- More plugins (payment gateways such as Stripe or Adyen, analytics) go in
  `image/Dockerfile` (`kpm install_java_plugin ...`) and, if they have
  tables, `migrate` creates them from their `ddl.sql`.
- Kaui 4.0.26 fails to boot with the default jruby-rack response "dechunk"
  patch (Rack 3.1+ has no `rack/chunked`): compose sets
  `-Djruby.rack.response.dechunk=true` for Kaui (`STACK_JAVA_OPTS`).
- The `admin` user is defined in Kill Bill's `shiro.ini` (password from
  `KILLBILL_ADMIN_PASSWORD`); more users and roles can be created through
  the API or Kaui.
- From inside the containers, the host machine is reachable as
  `host.docker.internal` (e.g. for `KILLBILL_NOTIFICATION_URL` in
  development).

Security
--------

- No default secrets: compose fails if the required passwords and keys are
  missing. The development template uses public values; never use it on a
  server.
- Both vendor images enable a remote Java debugger (JDWP, port 12345) and
  unauthenticated JMX (port 8000) by default: `config/tomcat/setenv2.sh`
  removes them.
- Kaui stores tenant API secrets encrypted with a key generated per install
  (not the image's public one); keep it with the backups.
- Only Caddy publishes ports; Kill Bill, Kaui and the database are internal
  (`HTTP_BIND` defaults to `127.0.0.1`). Kill Bill's JNDI registry for its
  plugins (RMI, port 1099) is only reachable on the stack's internal network.
- Kaui's session cookie isn't marked `Secure` behind TLS (Kaui's own
  setting).
- Not included: a web application firewall or off-site backup copies.

Validation
----------

What was checked for this stack (2026-09-24):

- Clean start (`down -v` + `up -d`) in about 60 s: every service `healthy`,
  `migrate` and `setup` `Exited (0)`; a second run makes no changes.
- Kaui login with the tenant opened directly, pages and all their CSS/JS
  (`200`); the API with the tenant's credentials (`401` without them).
- CLP plan (`$9.990`), a Chilean account (`America/Santiago`, `es_CL`), a
  subscription invoiced right away (9990 CLP), the Spanish invoice HTML.
- Push notifications received by a callback on the host
  (`ACCOUNT_CREATION`, `SUBSCRIPTION_CREATION`, `INVOICE_CREATION`, ...).
- Email plugin: its table created on a fresh install and on an existing
  database; invoice and cancellation emails in Spanish to Mailpit, with CLP
  amounts (`$9.990`).
- Upgrade 0.24.13 → 0.24.21 with data: 6 migrations applied (one of them is
  packaged at a jar's root; comparing the schemas found it), and the
  resulting schema (columns and indexes) is identical to a fresh 0.24.21
  schema.
- Backup and restore (data created after the backup is gone; Kaui still
  decrypts the tenant secret).
- HTTPS with `SITE_ADDRESS=localhost` (Caddy internal CA, HTTP/2, Kaui
  redirects and API `Location` headers with the right scheme and port).
- Overrides: Traefik v3.6 routing with no host ports, local directories
  (including the database and backups).
- Not tested: issuing a real Let's Encrypt certificate (needs a public
  domain), payment plugins, the upcoming invoice email, SMTPS with a real
  provider.

Resource usage
--------------

Idle, after a few requests: Kill Bill ~1 GiB (1 GiB heap), Kaui ~900 MiB
(512 MiB heap plus JRuby), MariaDB ~120 MiB, Caddy ~12 MiB.

License
-------

[MIT](LICENSE).
