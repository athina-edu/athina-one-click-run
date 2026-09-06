# One-click run/install for Athina

This bundle deploys the complete **Athina** platform (grading engine + web dashboard + database) with a single command.

> **Note:** The web dashboard (`athina-web`) has been **merged into the main `athina` repository**. Both Docker images (`athinaedu/athina` and `athinaedu/athina-web`) are now built from the same repo — the CLI uses `Dockerfile` and the web app uses `Dockerfile.web`.

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│  nginx      │────▶│  athina-web  │────▶│  MySQL DB    │
│  :80/:443   │     │  (Django)    │     │  (grades,    │
│  :8000      │     │  :8001       │     │   users)     │
└─────────────┘     └──────┬───────┘     └──────┬───────┘
                           │                     │
                           │  reads/writes       │  reads/writes
                           ▼                     ▼
                    ┌──────────────┐
                    │  athina-cli  │
                    │  (daemon)    │
                    └──────┬───────┘
                           │
                           │  spawns containers
                           ▼
                    ┌──────────────┐
                    │  Docker      │
                    │  (sandbox)   │
                    └──────────────┘
```

| Service | Image | IP | Role |
|---------|-------|----|------|
| **nginx** | `nginx:latest` | `172.29.1.1` | Reverse proxy, SSL termination, static files |
| **athina-web** | `athinaedu/athina-web:latest` | `172.29.1.2` | Django web app (gunicorn on :8001) |
| **athina** | `athinaedu/athina:latest` | `172.29.1.3` | Grading daemon (polls API every 60s) |
| **db** | `mysql:5.7` | `172.29.1.4` | MySQL (databases: `athina_web` + `athina`) |

## Prerequisites
* docker
* docker compose
* pwgen
* mysql-client (or mariadb-client)

## Run and auto-install
```bash
sudo su   # run as root
./run.sh
```

The first time execution will install and configure Athina. Subsequent runs will just start the services.

## What `run.sh` does on first run
1. Pulls the Docker images (`athinaedu/athina` + `athinaedu/athina-web`)
2. Prompts for the authorized domain/IP
3. Generates a random MySQL password and a Django `SECRET_KEY`
4. Writes `athina_web/settings_secret.py` with production security settings
5. Initializes the MySQL database and runs Django migrations
6. Creates a superuser
7. Generates self-signed SSL certificates
8. Starts all services

## Development overrides
`docker-compose.override.yml` is gitignored and used for local development — it mounts local source directories instead of pulling images. It is **not** part of the production deployment.

## Deprecated
The standalone `athina-web` repository is **deprecated**. All source now lives in the [athina](https://github.com/athina-edu/athina) repo under `athina_web/`.
