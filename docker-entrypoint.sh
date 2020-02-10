#! /bin/bash

set -e

# Wait for postgres container to become available
until psql -h ${MIRTH_POSTGRES_DB_HOST} -U ${MIRTH_POSTGRES_USER} -d postgres -c '\l'; do
  >&2 echo "Postgres is unavailable - sleeping"
  sleep 1
done

# Ensure that database is empty and fresh when working in development env
if [ "${DROP_DB_ON_START}" = "true" ] && [ $RIT_ENV != acc ] && [ $RIT_ENV != prod ]; then
    echo "Dropping existing MirthConnect database"
    psql -h ${MIRTH_POSTGRES_DB_HOST} -U ${MIRTH_POSTGRES_USER} -d postgres <<- EOSQL
        DROP DATABASE IF EXISTS ${MIRTH_POSTGRES_DB};
        CREATE DATABASE ${MIRTH_POSTGRES_DB};
        GRANT ALL PRIVILEGES ON DATABASE ${MIRTH_POSTGRES_DB} TO ${MIRTH_POSTGRES_USER};
EOSQL
fi

# Templating various config files
## mirth.properties
sed -i "s|http.port.*|http.port = 80|" /opt/mirth-connect/conf/mirth.properties
sed -i "s|keystore.storepass.*|keystore.storepass = $MIRTH_KEYSTORE_STOREPASS|" /opt/mirth-connect/conf/mirth.properties
sed -i "s|keystore.keypass.*|keystore.keypass = $MIRTH_KEYSTORE_KEYPASS|" /opt/mirth-connect/conf/mirth.properties
sed -i "s|database =.*|database = postgres|" /opt/mirth-connect/conf/mirth.properties
sed -i "s|database.url.*|database.url = jdbc:postgresql://$MIRTH_POSTGRES_DB_HOST:5432/$MIRTH_POSTGRES_DB|" /opt/mirth-connect/conf/mirth.properties
sed -i "s|database.username.*|database.username = $MIRTH_POSTGRES_USER|" /opt/mirth-connect/conf/mirth.properties
sed -i "s|database.password.*|database.password = $PGPASSWORD|" /opt/mirth-connect/conf/mirth.properties

## mirth-cli-config.properties
sed -i "s|user=.*|user=$MIRTH_ADMIN_USER|" /opt/mirth-connect/conf/mirth-cli-config.properties
sed -i "s|password=.*|password=$MIRTH_ADMIN_PASSWORD|" /opt/mirth-connect/conf/mirth-cli-config.properties

## configuration.properties
sed -i "s/RIT_ENV/$RIT_ENV/" /opt/mirth-connect/appdata/configuration.properties

# Start MirthConnect service
./mcservice start

# Check if MirthConnect is running
until nc -z localhost 80; do
  echo "MirthConnect not started, sleeping"
  sleep 2
done

# Create users and import channels into MirthConnect using CLI
./mccommand -s /opt/mirth-script_config.txt

# Only run channel backup job in development env
if [ $RIT_ENV != acc ] && [ $RIT_ENV != prod ]; then
  # force start of cron
  service cron start

  # Modify crontab to export channels every 15 minutes and remove old backups once a day
  crontab /opt/crontab.txt
fi

#logstash
/etc/init.d/filebeat start


# End with a persistent foreground process
tail -f /opt/mirth-connect/logs/mirth.log
