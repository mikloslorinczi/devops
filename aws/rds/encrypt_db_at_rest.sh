#!/usr/bin/env bash

set -Eeou pipefail

# KMS Key ID ARN (master key)
kms_key_id="arn:aws:kms:YOUR-REGION-HERE:YOUR-ACCOUNT-NUMBER-HERE:key/YOUR-KMS-KEY-ID-HERE"

# The database to be encrypted (first argument of this script)
database_id="${1}"
placeholder_database_id="${database_id}-placeholder"
encrypted_database_id="${database_id}-encrypted"
unencrypted_snapshot_id="${database_id}-unencrypted"
encrypted_snapshot_id="${database_id}-encrypted"

# Depending on the database's name choose appropriate environment tag (test, stage or prod)
env_tag="test"
lower_database_id=$(echo "${database_id}" | tr '[:upper:]' '[:lower:]')
case "${lower_database_id}" in
  *"stag"*)
    env_tag="staging"
    ;;
  *"prod"*)
    env_tag="production"
    ;;
esac

# Logging function with date
function log() {
    echo "$(date) - ${1}"
}

# Check JQ version
log "JQ Version: $(jq --version)"

# Check if the database is available and its not already encrypted
log "Checking if ${database_id} is available"
res=$(aws rds describe-db-instances --db-instance-identifier ${database_id})
status=$(echo $res | jq -r .DBInstances[].DBInstanceStatus)
encrypted=$(echo $res | jq -r .DBInstances[].StorageEncrypted)

if [[ $status != "available" ]]; then
    log "Database instance ${database_id} is not available!"
    exit 1
fi

if [[ $encrypted == "true" ]]; then
    log "Database instance ${database_id} is already encrypted!"
    exit 1
fi

log "Encrypting database ${database_id} with KMS Key ${kms_key_id} Owner: Platform, Environment: ${env_tag}"

log "Creating snapshot of database: ${database_id}"
aws rds create-db-snapshot \
    --db-instance-identifier "${database_id}" \
    --db-snapshot-identifier "${unencrypted_snapshot_id}" \
    --tags "Key"="owner","Value"="Platform" "Key"="env","Value"="${env_tag}" \
    >> aws_responses.json

log "Waiting for the snapshot to be completed"
aws rds wait db-snapshot-completed \
    --db-instance-identifier "${database_id}" \
    --db-snapshot-identifier "${unencrypted_snapshot_id}"
log "The snapshot is ready: ${unencrypted_snapshot_id}"

log "Copy the snapshot and encrypt the copy"
aws rds copy-db-snapshot \
    --source-db-snapshot-identifier "${unencrypted_snapshot_id}" \
    --target-db-snapshot-identifier "${encrypted_snapshot_id}" \
    --copy-tags \
    --kms-key-id "${kms_key_id}" \
    >> aws_responses.json

log "Waiting for the encrypted snapshot to be completed"
aws rds wait db-snapshot-completed \
    --db-instance-identifier "${database_id}" \
    --db-snapshot-identifier "${encrypted_snapshot_id}"
log "The encrypted snapshot is ready: ${encrypted_snapshot_id}"

log "Creating new database from the encrypted snapshot"
aws rds restore-db-instance-from-db-snapshot \
    --db-instance-identifier "${encrypted_database_id}" \
    --db-snapshot-identifier "${encrypted_snapshot_id}" \
    --db-instance-class db.t2.small \
    --publicly-accessible \
    --auto-minor-version-upgrade \
    --copy-tags-to-snapshot \
    --tags "Key"="owner","Value"="Platform" "Key"="env","Value"="${env_tag}" \
    >> aws_responses.json

log "Waiting for the encrypted database to be available"
aws rds wait db-instance-available --db-instance-identifier "${encrypted_database_id}"
log "Encrypted database created: ${encrypted_database_id}"

log "Renaming unencrypted database: ${database_id} to ${placeholder_database_id}"
resource_id=$(aws rds modify-db-instance \
    --db-instance-identifier "${database_id}" \
    --new-db-instance-identifier "${placeholder_database_id}" \
    --apply-immediately | \
    jq -r .DBInstance.DbiResourceId)

log "Waiting for the unencrypted database to be available"
aws rds wait db-instance-available \
    --filters "Name"="dbi-resource-id","Values"="${resource_id}"
log "Unencrypted database is available by the Resource ID ${resource_id} now waiting for all pending changes to be finished"
res=""
until [[  $res == "{}" ]]; do
    sleep 10
    res=$(aws rds describe-db-instances \
        --filters "Name"="dbi-resource-id","Values"="${resource_id}" | \
        jq -r .DBInstances[].PendingModifiedValues)
done
log "Unencrypted database renamed from: ${database_id} to ${placeholder_database_id}"

log "Renaming encrypted database: ${encrypted_database_id} to ${database_id}"
resource_id=$(aws rds modify-db-instance \
    --db-instance-identifier "${encrypted_database_id}" \
    --new-db-instance-identifier "${database_id}" \
    --apply-immediately | \
    jq -r .DBInstance.DbiResourceId)
log "Waiting for the encrypted database to be available"
aws rds wait db-instance-available \
    --filters "Name"="dbi-resource-id","Values"="${resource_id}"
log "Encrypted database is available by the Resource ID ${resource_id} now waiting for all pending changes to be finished"
res=""
until [[  $res == "{}" ]]; do
    sleep 10
    res=$(aws rds describe-db-instances \
        --filters "Name"="dbi-resource-id","Values"="${resource_id}" | \
        jq -r .DBInstances[].PendingModifiedValues)
done
log "Encrypted database renamed from: ${encrypted_database_id} to ${database_id}"

log "Database ${database_id} is now encrypted with KMS Key ${kms_key_id}"
