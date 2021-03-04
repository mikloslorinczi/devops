### Dump the schema of an RDS PostgreSQL Database

```SHELL
pg_dump -U user_name -h host_name -d database_name  -n public -s > database_schema.sql
```
-s stands for Schema only

### Log in to the RDS PostgreSQL Database with the admin user

```SHELL
psql -U user_name  -h host_name -d database_name 
```

### Create the new database

```SQL
CREATE DATABASE database_name;
```

### Copy the schema to the new database

```SHELL
psql -U user_name -h host_name -d database_name < database_schema.sql
```
