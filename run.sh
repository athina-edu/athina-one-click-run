#!/usr/bin/env bash
#
# Athina One-Click Installer
# ───────────────────────────
# Usage:
#   ./run.sh              First-time install or start
#   ./run.sh --reset      Tear down everything and reinstall from scratch
#   ./run.sh --status     Show running service status
#   ./run.sh --stop       Stop all services
#   ./run.sh --logs       Tail all service logs
#
set -euo pipefail

# ── Colours / helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()  { echo -e "\n${BLUE}── $* ──${NC}"; }

# ── Argument parsing ─────────────────────────────────────────────────────────
ACTION="install"
for arg in "$@"; do
  case "$arg" in
    --reset)   ACTION="reset"   ;;
    --status)  ACTION="status"  ;;
    --stop)    ACTION="stop"    ;;
    --logs)    ACTION="logs"    ;;
    --help|-h)
      echo "Usage: $0 [--reset|--status|--stop|--logs]"
      exit 0 ;;
    *) err "Unknown option: $arg (use --help for usage)" ;;
  esac
done

# ── Quick actions (no dependency check needed) ──────────────────────────────
case "$ACTION" in
  status)
    step "Service status"
    docker compose ps
    exit 0 ;;
  stop)
    step "Stopping all services"
    docker compose down
    info "All services stopped"
    exit 0 ;;
  logs)
    docker compose logs -f --tail=100
    exit 0 ;;
esac

# ── Dependency check ────────────────────────────────────────────────────────
step "Checking dependencies"
missing=()
command -v docker  >/dev/null 2>&1 || missing+=("docker")
command -v docker  >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1 && missing+=("docker compose plugin")
command -v pwgen   >/dev/null 2>&1 || missing+=("pwgen")
command -v mysql   >/dev/null 2>&1 || missing+=("mysql-client / mariadb-client")
command -v openssl >/dev/null 2>&1 || missing+=("openssl")

if [ ${#missing[@]} -gt 0 ]; then
  err "Missing dependencies: ${missing[*]}\n  Install them and try again."
fi
info "All dependencies found"

# ── Reset mode ──────────────────────────────────────────────────────────────
if [ "$ACTION" = "reset" ]; then
  step "Resetting Athina installation"
  warn "This will stop containers, remove volumes, certs, settings, and MySQL data."
  read -rp "Type 'YES' to confirm: " confirm
  if [ "$confirm" != "YES" ]; then
    info "Aborted."
    exit 0
  fi

  docker compose down -v --remove-orphans 2>/dev/null || true
  rm -rf athina_web/settings_secret.py certs/athinaweb.key certs/athinaweb.crt static_files/* nginx.conf.bak docker-compose.yml.bak 2>/dev/null || true
  # MySQL data is owned by root (created by Docker) — need sudo to remove
  sudo rm -rf mysql/ 2>/dev/null || { warn "Could not remove mysql/ (run: sudo rm -rf mysql/)"; }

  # Restore docker-compose.yml from template
  if [ -f "docker-compose.yml.template" ]; then
    cp docker-compose.yml.template docker-compose.yml
    info "Restored docker-compose.yml from template"
  fi

  info "Reset complete — running fresh install"
fi

# ── Pull images ─────────────────────────────────────────────────────────────
step "Pulling Docker images"
docker compose pull
info "Images pulled"

# ── Create directories ──────────────────────────────────────────────────────
step "Ensuring directories exist"
mkdir -p athina_web certs mysql logs nginx/cache nginx static_files
info "Directories ready"

# ── First-time setup ────────────────────────────────────────────────────────
if [ ! -f "athina_web/settings_secret.py" ]; then
  step "First-time installation"

  # Detect local IPs for default value
  detected_ips=$(hostname -I 2>/dev/null | xargs | tr ' ' ', ' || echo "")
  if [ -n "$detected_ips" ]; then
    default_hosts="127.0.0.1, $detected_ips"
  else
    default_hosts="127.0.0.1"
  fi

  echo -e "Enter the domain(s) or IP(s) for the web interface (cannot be *)."
  echo -e "You can enter a ${YELLOW}comma-separated list${NC} (e.g., 192.168.1.10, myserver.edu)."
  echo -e "You can change this later in athina_web/settings_secret.py. [${YELLOW}$default_hosts${NC}]"
  read -rp "> " ip_input
  ip_input="${ip_input:-$default_hosts}"

  # Format for Django ALLOWED_HOSTS (Python list).
  # '172.29.1.1' is the nginx container and '172.29.1.2' the athina-web container
  # on the internal network. Both must be allowed: nginx proxies with
  # Host $host (which is the client's host, often the IP on the docker network),
  # and the grading daemon calls athina-web directly at 172.29.1.2:8001.
  django_hosts="'172.29.1.1', '172.29.1.2'"
  IFS=',' read -ra HOSTS_ARRAY <<< "$ip_input"
  for host in "${HOSTS_ARRAY[@]}"; do
    host=$(echo "$host" | xargs) # trim whitespace
    if [ -n "$host" ]; then
      django_hosts="$django_hosts, '$host'"
    fi
  done

  # Format for Nginx server_name (space-separated)
  nginx_hosts=$(echo "$ip_input" | tr ',' ' ')

  # Generate random MySQL password
  mysql_pass=$(pwgen 16 1)
  info "Generated MySQL password"

  # Update docker-compose.yml with real password and web URL
  tmpfile=$(mktemp)
  sed -r "s/_PASSWORD:.*/_PASSWORD: \"$mysql_pass\"/g" docker-compose.yml > "$tmpfile" && mv "$tmpfile" docker-compose.yml
  tmpfile=$(mktemp)
  sed -r "s|ATHINA_WEB_URL:.*|ATHINA_WEB_URL: \"https://$ip_input\"|g" docker-compose.yml > "$tmpfile" && mv "$tmpfile" docker-compose.yml

  # Generate Django secret key
  secret_key=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9!@#$%^&*' | head -c 64)

  cat > athina_web/settings_secret.py <<PYEOF
# SECURITY WARNING: keep the secret key used in production secret!
SECRET_KEY='$secret_key'

# SECURITY WARNING: don't run with debug turned on in production!
DEBUG = False

ALLOWED_HOSTS = [$django_hosts]

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': 'athina_web',
        'USER': 'athina',
        'PASSWORD': '$mysql_pass',
        'HOST': 'db',
        'PORT': 3306,
    }
}

# Production security settings (running behind nginx HTTPS proxy)
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = 'Lax'
CSRF_COOKIE_HTTPONLY = True
SECURE_BROWSER_XSS_FILTER = True
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = 'DENY'
SECURE_SSL_REDIRECT = True
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
SECURE_HSTS_SECONDS = 31536000
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = True
PYEOF
  info "Wrote athina_web/settings_secret.py"

  # Start only MySQL and wait until it's accepting connections
  step "Initialising MySQL"
  docker compose up -d db

  MAX_WAIT=180
  ELAPSED=0
  CONTAINER_NAME=$(docker compose ps -q db)
  echo -n "  Waiting for MySQL to be ready "
  until docker exec "$CONTAINER_NAME" mysqladmin ping -h127.0.0.1 -uroot -p"$mysql_pass" --silent 2>/dev/null; do
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    echo -n "."
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
      echo
      err "MySQL did not become ready within ${MAX_WAIT}s"
    fi
  done
  echo
  info "MySQL is ready (${ELAPSED}s)"

  # Create the athina grading database and grant permissions
  step "Creating athina grading database"
  echo "CREATE DATABASE IF NOT EXISTS athina; GRANT ALL ON athina.* TO 'athina'@'%'; FLUSH PRIVILEGES;" \
    | docker compose exec -T db mysql -uroot -p"$mysql_pass"
  info "Database 'athina' created and privileges granted"

  # Stop the temporary DB — compose will bring everything up later
  docker compose down

  # Run Django migrations (start DB first and wait for it)
  step "Running Django migrations"
  docker compose up -d db

  MAX_WAIT=180
  ELAPSED=0
  MIGRATION_CONTAINER=$(docker compose ps -q db)
  echo -n "  Waiting for MySQL to be ready for migrations "
  until docker exec "$MIGRATION_CONTAINER" mysqladmin ping -h127.0.0.1 -uroot -p"$mysql_pass" --silent 2>/dev/null; do
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    echo -n "."
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
      echo
      err "MySQL did not become ready within ${MAX_WAIT}s"
    fi
  done
  echo
  info "MySQL is ready for migrations (${ELAPSED}s)"

  docker compose run --rm athina-web python manage.py migrate --noinput
  info "Migrations applied"

  # Create superuser (interactive)
  step "Creating Django superuser"
  if [ -t 0 ]; then
    echo -e "  You will be prompted to create an admin account for the web dashboard."
    docker compose run --rm athina-web python manage.py createsuperuser
    info "Superuser created"
  else
    warn "Non-interactive mode — skipping superuser creation."
    warn "After install, run: docker compose run --rm athina-web python manage.py createsuperuser"
  fi

else
  info "Existing installation detected — skipping first-time setup"
fi

# ── SSL certificates ────────────────────────────────────────────────────────
if [ ! -f "certs/athinaweb.key" ]; then
  step "Generating self-signed SSL certificate"

  # Read the IP from the settings we already wrote
  # We use the comma-separated string for nginx if multiple hosts were provided
  ip_for_nginx=$(python3 -c "import sys; sys.path.insert(0,'athina_web'); import settings_secret; print(' '.join(settings_secret.ALLOWED_HOSTS[1:]))")

  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout certs/athinaweb.key \
    -out   certs/athinaweb.crt \
    -days 365 \
    -subj  "/C=US/ST=Washington/L=Bellingham/O=AthinaWeb/OU=AthinaWeb/CN=$(echo $ip_for_nginx | awk '{print $1}')" 2>/dev/null

  # Update nginx.conf with the correct server_name
  tmpfile=$(mktemp)
  sed -r "s/server_name.+;/server_name $ip_for_nginx;/g" nginx.conf > "$tmpfile" && mv "$tmpfile" nginx.conf
  info "SSL certificate generated and nginx configured"
else
  info "SSL certificate already exists"
fi

# ── Ensure migrations are up to date ────────────────────────────────────────
# Start DB and wait for it (needed for both fresh and existing installs)
# Read MySQL root password from settings_secret.py
mysql_pass=$(python3 -c "import sys; sys.path.insert(0,'athina_web'); import settings_secret; print(settings_secret.DATABASES['default']['PASSWORD'])")

step "Starting database"
docker compose up -d db
DB_CONTAINER=$(docker compose ps -q db)
MAX_WAIT=180
ELAPSED=0
echo -n "  Waiting for MySQL "
until docker exec "$DB_CONTAINER" mysqladmin ping -h127.0.0.1 -uroot -p"$mysql_pass" --silent 2>/dev/null; do
  sleep 3
  ELAPSED=$((ELAPSED + 3))
  echo -n "."
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo
    err "MySQL did not become ready within ${MAX_WAIT}s"
  fi
done
echo
info "MySQL ready (${ELAPSED}s)"

step "Verifying Django migrations"
docker compose run --rm athina-web python manage.py migrate --noinput 2>/dev/null
info "Migrations up to date"

# ── Collect static files ────────────────────────────────────────────────────
step "Collecting static files"
docker compose run --rm athina-web python manage.py collectstatic --noinput 2>/dev/null
info "Static files collected"

# ── Start all services ──────────────────────────────────────────────────────
step "Starting all services"
docker compose up -d
info "Services starting"

# ── Health check ────────────────────────────────────────────────────────────
step "Waiting for web interface to respond"
MAX_WAIT=60
ELAPSED=0
until curl -sk https://127.0.0.1/ >/dev/null 2>&1; do
  sleep 3
  ELAPSED=$((ELAPSED + 3))
  echo -n "."
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo
    warn "Web interface not responding after ${MAX_WAIT}s — check logs with: $0 --logs"
    break
  fi
done
echo

if curl -sk https://127.0.0.1/ >/dev/null 2>&1; then
  info "Web interface is up!"
fi

# ── Final summary ───────────────────────────────────────────────────────────
step "Athina is running"
ip=$(python3 -c "import sys; sys.path.insert(0,'athina_web'); import settings_secret; print(settings_secret.ALLOWED_HOSTS[1])" 2>/dev/null || echo "127.0.0.1")
echo ""
echo -e "  ${GREEN}Dashboard:${NC}  https://$ip/"
echo -e "  ${GREEN}API:${NC}        https://$ip/assignments/api/"
echo -e "  ${GREEN}Webhook:${NC}    https://$ip/assignments/webhook/"
echo ""
echo -e "  ${YELLOW}Useful commands:${NC}"
echo -e "    $0 --status   Show service status"
echo -e "    $0 --logs     Tail all logs"
echo -e "    $0 --stop     Stop all services"
echo -e "    $0 --reset    Full teardown and reinstall"
echo ""


