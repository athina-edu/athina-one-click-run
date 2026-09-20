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
| **athina-web** | `athinaedu/athina-web:latest` | `172.29.1.2` | Django 5.2 web app (Python 3.14, gunicorn on :8001) |
| **athina** | `athinaedu/athina:latest` | `172.29.1.3` | Grading daemon (polls API every 60s) |
| **db** | `mysql:8.0` | `172.29.1.4` | MySQL (databases: `athina_web` + `athina`) |

## Stack

- **Python 3.14** (latest)
- **Django 5.2 LTS**
- **MySQL 8.0**
- **Docker** for test sandboxing

## Prerequisites
* docker
* docker compose
* pwgen
* mysql-client (or mariadb-client)

## Run and auto-install
```bash
cd athina-one-click-run
./run.sh
```

The first time execution will install and configure Athina. Subsequent runs will just start the services.

### Flags

| Flag | Description |
|------|-------------|
| `--reset` | Full teardown (containers, volumes, data, certs) and reinstall |
| `--status` | Show running service status |
| `--stop` | Stop all services |
| `--logs` | Tail all service logs |

## What `run.sh` does on first run

1. Checks dependencies (docker, pwgen, mysql-client, openssl)
2. Pulls the latest Docker images from Docker Hub
3. Prompts for the authorized domain(s)/IP(s) — supports comma-separated lists (e.g., `192.168.1.10, myserver.edu`)
4. Auto-detects local IPs as default suggestion
5. Generates a random MySQL password and a Django `SECRET_KEY`
6. Writes `athina_web/settings_secret.py` with production security settings
7. Initializes MySQL 8.0 with health checks (no hardcoded sleep timers)
8. Creates the `athina` grading database
9. Runs all Django migrations
10. Prompts to create a superuser (for the web dashboard)
11. Generates self-signed SSL certificates
12. Collects static files
13. Starts all services
14. Verifies the web interface is responding

## Configuration

The generated `athina_web/settings_secret.py` contains:
- Django `SECRET_KEY` (auto-generated)
- `ALLOWED_HOSTS` (your domain/IP + Docker internal IP `172.29.1.1`)
- MySQL credentials
- Production security settings (HTTPS, HSTS, secure cookies)

Edit this file directly to change settings. The file is mounted as a volume into the container.

## Deprecated
The standalone `athina-web` repository is **deprecated**. All source now lives in the [athina](https://github.com/athina-edu/athina) repo under `athina_web/`.
