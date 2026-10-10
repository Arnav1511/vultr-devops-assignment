#!/usr/bin/env bash
# Creates the non-admin "app" account the backend uses in PostgreSQL and
# MongoDB. Safe to re-run: it creates the account if missing and otherwise
# resets its password and privileges to what is written here.
#
# Why separate accounts: each database image creates one all-powerful account
# at first start (PostgreSQL "postgres", MongoDB "root"). If the backend used
# it, a bug or injection in the application could drop databases, create
# users or read anything. The backend only needs to read and write its own
# data, so it gets an account that can do exactly that.
#
#   account            used by                        can do
#   postgres / root    exporter, backup job, humans   everything
#   app                backend                        read/write the "app" database only
#
# Valkey has a single shared password and no per-user accounts here; it holds
# only a counter.
#
# Passwords are read from the db-credentials Secret and sent to the database
# clients on stdin, so they never appear in a process list.
set -euo pipefail

secret() { kubectl -n databases get secret db-credentials -o "jsonpath={.data.$1}" | base64 -d; }
PG_APP=$(secret postgres-app-password)
MONGO_APP=$(secret mongodb-app-password)

# Inside the pod, PostgreSQL trusts local socket connections, so the admin
# needs no password here. The passwords are hex strings, safe inside quotes.
kubectl -n databases exec -i postgres-0 -c db -- psql -U postgres -d app -q -v ON_ERROR_STOP=1 -f - <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app') THEN
    CREATE ROLE app LOGIN;
  END IF;
END \$\$;
-- Explicitly not a superuser, and unable to create databases or other roles.
ALTER ROLE app WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  PASSWORD '${PG_APP}';
-- Owning its own database lets the backend create and migrate its tables
-- there, and nowhere else.
ALTER DATABASE app OWNER TO app;
SQL
echo "postgres: role app ensured"

# readWrite on the "app" database only: no access to other databases, no user
# management, no server administration.
# The root password is expanded by the shell inside the pod, not here.
# shellcheck disable=SC2016
kubectl -n databases exec -i mongodb-0 -c db -- sh -c \
  'mongosh --quiet -u root -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' >/dev/null <<JS
const appDb = db.getSiblingDB("app");
const spec = { pwd: "${MONGO_APP}", roles: [{ role: "readWrite", db: "app" }] };
if (appDb.getUser("app")) { appDb.updateUser("app", spec); } else { appDb.createUser({ user: "app", ...spec }); }
JS
echo "mongodb: user app ensured"
