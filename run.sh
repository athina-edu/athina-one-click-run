#!/bin/bash

# Check dependencies
dockercommand=$(command -v docker | wc -l)
dockercompcommand=$(command -v docker-compose | wc -l)

if [[ $dockercommand -eq 0 || $dockercompcommand -eq 0 ]]; then
  echo "docker or docker-compose missing on system"
  echo "Install them first in your system then run again this script."
fi

# Downloading and building images
docker-compose pull

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

  secret_key=$(date +%s | sha256sum | base64 | head -c 64 ; echo)
  echo "
# SECURITY WARNING: keep the secret key used in production secret!
SECRET_KEY='$secret_key'
  
# SECURITY WARNING: don't run with debug turned on in production!
DEBUG=False

ALLOWED_HOSTS=['127.0.0.1', '$ip']" > athinaweb/settings_secret.py

# Creating db.sqlite3 in case it doesn't exist
touch db.sqlite3
docker-compose run athina-web python manage.py migrate

# Creating superuser
docker-compose run athina-web python manage.py createsuperuser
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

    # MySQL pass
    rm -f docker-compose.yml.bak
    mv docker-compose.yml docker-compose.yml.bak
    mysql_pass=$(pwgen 32 1)
    cat docker-compose.yml.bak | sed -r "s/MYSQL_PASSWORD:.+/MYSQL_PASSWORD: '$mysql_pass'/gi" > docker-compose.yml
fi

# Creating db.sqlite3 in case it doesn't exist
docker-compose run athina-web python manage.py migrate

docker-compose up


