#!/bin/bash

# Check dependencies
dockercommand=$(command -v docker | wc -l)
pwgencommand=$(command -v pwgen | wc -l)
mysqlcommand=$(command -v mysql | wc -l)

if [[ $dockercommand -eq 0 || $pwgencommand -eq 0 || $mysqlcommand -eq 0 ]]; then
  echo "docker, docker compose, mysql-client (mariadb-client) or pwgen is missing on system"
  echo "Install them first in your system then run again this script."
fi


# Downloading and building images
docker compose pull

# Creating necessary secrets for the new installation (if they do not exist)
if [ ! -d "athinaweb" ]; then
  mkdir athinaweb
fi

if [ ! -f "athinaweb/settings_secret.py" ]; then
  echo -e "First time installation! Welcome!"
  echo -e "Enter the authorized domain through which the web interface can be accessed."
  echo -e "For security purposes this cannot be a * but you can change it by editing"
  echo -e "athinaweb/settings_secret.py at any time. [127.0.0.1]"
  read ip

  if [ -z "$ip" ]; then
    ip="127.0.0.1"
  fi

  # MySQL pass
  rm -f docker-compose.yml.bak
  mv docker-compose.yml docker-compose.yml.bak
  mysql_pass=$(pwgen 10 1)
  cat docker-compose.yml.bak | sed -r "s/_PASSWORD:.+/_PASSWORD: \"$mysql_pass\"/gi" > docker-compose.yml

  rm -f docker-compose.yml.bak
  mv docker-compose.yml docker-compose.yml.bak
  cat docker-compose.yml.bak | sed -r "s/ATHINA_WEB_URL:.+/ATHINA_WEB_URL: \"https:\/\/$ip\"/gi" > docker-compose.yml

  secret_key=$(date +%s | sha256sum | base64 | head -c 64 ; echo)
  echo "
# SECURITY WARNING: keep the secret key used in production secret!
SECRET_KEY='$secret_key'
  
# SECURITY WARNING: don't run with debug turned on in production!
DEBUG=False

ALLOWED_HOSTS=['172.29.1.1', '$ip']

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': 'athina_web',
        'USER': 'athina',
        'PASSWORD': '$mysql_pass',
        'HOST': 'db',
        'PORT': 3306,
    }
}" > athinaweb/settings_secret.py

  # Initialize db (necessary to get the database and passwords setup (10secs are enough to initialize)
  docker compose up db &

  echo "Waiting"
  sleep 60 # In some slow systems, the first mysql init may take a long time

  echo "Running"
  # Grant athina db access
  echo "CREATE DATABASE athina; GRANT ALL ON athina.* TO 'athina'@'%';"| mysql -h172.29.1.4 -uroot -p$mysql_pass

  # Shut down
  docker compose down

  # Creating db.sqlite3 in case it doesn't exist
  docker compose run athina-web python manage.py migrate

  # Creating superuser
  docker compose run athina-web python manage.py createsuperuser
fi

if [ ! -f "certs/athinaweb.key" ]; then
    # Nginx config
    cd athinaweb
    ip=$(python -c 'import settings_secret; print settings_secret.ALLOWED_HOSTS[1]')
    cd ../certs/
    openssl req -x509 -nodes -newkey rsa:2048 -keyout athinaweb.key -out athinaweb.crt -subj "/C=US/ST=Washington/L=Bellingham/O=AthinaWeb/OU=AthinaWeb/CN=$ip"
    cd ..
    rm -f nginx.conf.bak
    mv nginx.conf nginx.conf.bak
    cat nginx.conf.bak | sed -r "s/server_name.+;/server_name $ip;/gi" > nginx.conf
fi

# Creating db.sqlite3 in case it doesn't exist
docker compose run athina-web python manage.py migrate

docker compose up


