-- Runs once, only on first init of the postgres_data volume.
-- Zitadel provisions its own "zitadel" database itself, from the
-- ZITADEL_DATABASE_POSTGRES_ADMIN_* credentials in compose.yml, so it does
-- not need to be created here. This script only creates the plain
-- application databases each project's own connection string points at.

CREATE DATABASE musify_db;
CREATE DATABASE ping_db;
CREATE DATABASE dockermanager_db;
