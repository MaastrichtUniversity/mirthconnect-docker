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

## configuration.properties
sed -i "s/RIT_ENV/$RIT_ENV/" /opt/mirth-connect/appdata/configuration.properties

## server.id
# Keep server id constant in order to load corresponding message history from existing database
echo "server.id = $MIRTH_SERVER_ID" > /opt/mirth-connect/appdata/server.id

# Start MirthConnect service
./mcservice start

# Check if MirthConnect is running
until nc -z localhost 80; do
  echo "MirthConnect not started, sleeping"
  sleep 2
done

# Determine if this is the first run on this database and then:
# - Import initial configuration into database
# - Import initial channels
# - Change the initial password to the one defined in env var
# Note: to update channels on an existing database, you MUST use the Administrator GUI. Using the ./mccommand import statement will result in message history data loss!
SHORT_HASH=$(psql -qAt -h ${MIRTH_POSTGRES_DB_HOST} -U ${MIRTH_POSTGRES_USER} -d mirthdb -c 'SELECT password FROM person_password WHERE person_id = 1;' | cut -c1-6)
if [[ $SHORT_HASH = 'YzKZIA' ]]; then
    # Import config and channels into MirthConnect using CLI
    ./mccommand -s /opt/mirth-script_config.txt

    # Change the initial admin password
    sed -i "s|ADMIN_PASS_PLACEHOLDER|$MIRTH_ADMIN_PASSWORD|" /opt/mirth-changepw.txt
    ./mccommand -s /opt/mirth-changepw.txt
fi

# Template the user specified credentials into mirth-cli-config.properties
sed -i "s|password=.*|password=$MIRTH_ADMIN_PASSWORD|" /opt/mirth-connect/conf/mirth-cli-config.properties

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
