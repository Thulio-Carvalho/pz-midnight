#!/usr/bin/env bash
set -Eeuo pipefail

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()       { local level=$1; shift; echo "$(timestamp) [${level}] $*"; }
log_info()  { log INFO  "$@"; }
log_warn()  { log WARN  "$@"; }
log_error() { log ERROR "$@" >&2; }
fatal()     { log_error "$@"; exit 1; }

: "${BUCKET:?Environment variable BUCKET must be set}"
: "${SERVER_NAME:?Environment variable SERVER_NAME must be set}"
: "${ADMIN_USERNAME:?Environment variable ADMIN_USERNAME must be set}"
: "${ADMIN_PASSWORD:?Environment variable ADMIN_PASSWORD must be set}"
: "${PORT:=16261}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-0}"

readonly PZ_HOME="/home/pz/Zomboid"
readonly LOG_DIR="${PZ_HOME}/logs"
readonly MARKER="${PZ_HOME}/.bootstrapped"
readonly LOCK_FILE="/var/lock/${SERVER_NAME}_backup.lock"
readonly SCREEN_LOG="${LOG_DIR}/pz-screen.log"

backup_all() {
  exec 200>"${LOCK_FILE}"
  flock 200 || { log_warn "Could not acquire backup lock; skipping"; return; }

  log_info "Starting full backup of Server, Saves & logs"
  local start_ts archive elapsed
  start_ts=$(date +%s)
  archive=$(mktemp -u "/tmp/${SERVER_NAME}_backup.XXXXXX.tar.gz")

  tar --warning=no-timestamp -czf "${archive}" \
      -C "${PZ_HOME}" logs Server Saves \
    || fatal "Failed to create archive ${archive}"

  log_info "Uploading archive → s3://$BUCKET/backups/${SERVER_NAME}_backup.tar.gz"
  aws s3 cp "${archive}" \
    "s3://$BUCKET/backups/${SERVER_NAME}_backup.tar.gz" \
    --no-progress \
    || fatal "Failed to upload backup to S3"

  rm -f "${archive}"
  elapsed=$(( $(date +%s) - start_ts ))
  log_info "Backup complete in ${elapsed}s"
}

graceful_shutdown() {
  log_info "SIGTERM received; initiating graceful shutdown"
  screen -S pz-server -p 0 -X stuff "/servermsg [INFO] Server restarting…$(printf \\r)"
  sleep 1
  screen -S pz-server -p 0 -X stuff "/save$(printf \\r)"
  sleep 30
  screen -S pz-server -p 0 -X stuff "/quit$(printf \\r)"
  backup_all
  log_info "Graceful shutdown complete"
  exit 0
}
trap graceful_shutdown SIGINT SIGTERM

main() {
  log_info "Ensuring directories exist: $PZ_HOME and $LOG_DIR"
  mkdir -p "${PZ_HOME}" "${LOG_DIR}"

  if [[ ! -f "$MARKER" ]]; then
   log_info "Bootstrapping from s3://$BUCKET/backups/${SERVER_NAME}_backup.tar.gz…"
   aws s3 cp "s3://$BUCKET/backups/${SERVER_NAME}_backup.tar.gz" - \
     | tar --warning=no-timestamp -xz -C "$PZ_HOME" \
         --no-same-owner --no-same-permissions \
     || log_info "Bootstrap extraction failed"
   touch "$MARKER"
   log_info "Bootstrap complete."
  else
   log_info "Already bootstrapped—skipping extraction."
  fi

  if (( BACKUP_INTERVAL > 0 )); then
    log_info "Scheduling recurring backups every ${BACKUP_INTERVAL}m"
    (
      while true; do
        sleep $(( BACKUP_INTERVAL * 60 ))
        backup_all
      done
    ) &
  fi

  log_info "Launching Project Zomboid in screen session 'pz-server' (logs → ${SCREEN_LOG})"
  screen -L -Logfile "${SCREEN_LOG}" -dmS pz-server \
    /home/pz/pz/start-server.sh \
      -servername     "${SERVER_NAME}"    \
      -port           "${PORT}"           \
      -adminusername  "${ADMIN_USERNAME}" \
      -adminpassword  "${ADMIN_PASSWORD}"

  log_info "Tailing server log (press Ctrl-C to stop locally)…"
  tail -F "$SCREEN_LOG" &
  tail_pid=$!

  wait "${tail_pid}"
}

main "$@"

