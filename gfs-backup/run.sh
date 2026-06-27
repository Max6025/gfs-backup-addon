#!/usr/bin/with-contenv bashio

bashio::log.info "GFS Backup Addon startet..."

export SUPERVISOR_TOKEN

NAS_HOST=$(bashio::config 'nas_host')
NAS_SHARE=$(bashio::config 'nas_share')
NAS_USER=$(bashio::config 'nas_username')
NAS_PASS=$(bashio::config 'nas_password')
BACKUP_PASS=$(bashio::config 'backup_password')

DAILY_ENABLED=$(bashio::config 'daily_enabled')
DAILY_TIME=$(bashio::config 'daily_time')
DAILY_DIR=$(bashio::config 'daily_target_dir')
DAILY_KEEP_LOCAL=$(bashio::config 'daily_keep_local')
DAILY_KEEP_REMOTE=$(bashio::config 'daily_keep_remote')

WEEKLY_ENABLED=$(bashio::config 'weekly_enabled')
WEEKLY_TIME=$(bashio::config 'weekly_time')
WEEKLY_WEEKDAY=$(bashio::config 'weekly_weekday')
WEEKLY_DIR=$(bashio::config 'weekly_target_dir')
WEEKLY_KEEP_LOCAL=$(bashio::config 'weekly_keep_local')
WEEKLY_KEEP_REMOTE=$(bashio::config 'weekly_keep_remote')

MONTHLY_ENABLED=$(bashio::config 'monthly_enabled')
MONTHLY_TIME=$(bashio::config 'monthly_time')
MONTHLY_DAY=$(bashio::config 'monthly_day')
MONTHLY_DIR=$(bashio::config 'monthly_target_dir')
MONTHLY_KEEP_LOCAL=$(bashio::config 'monthly_keep_local')
MONTHLY_KEEP_REMOTE=$(bashio::config 'monthly_keep_remote')

YEARLY_ENABLED=$(bashio::config 'yearly_enabled')
YEARLY_TIME=$(bashio::config 'yearly_time')
YEARLY_DAY=$(bashio::config 'yearly_day')
YEARLY_MONTH=$(bashio::config 'yearly_month')
YEARLY_DIR=$(bashio::config 'yearly_target_dir')
YEARLY_KEEP_LOCAL=$(bashio::config 'yearly_keep_local')
YEARLY_KEEP_REMOTE=$(bashio::config 'yearly_keep_remote')

if bashio::var.is_empty "${NAS_HOST}"; then
    bashio::log.fatal "NAS IP-Adresse ist nicht gesetzt!"
    exit 1
fi
if bashio::var.is_empty "${NAS_SHARE}"; then
    bashio::log.fatal "NAS Freigabe-Name ist nicht gesetzt!"
    exit 1
fi

bashio::log.info "NAS: //${NAS_HOST}/${NAS_SHARE}"
bashio::log.info "Täglich:     ${DAILY_ENABLED}  → ${DAILY_TIME}  | lokal: ${DAILY_KEEP_LOCAL} | NAS: ${DAILY_KEEP_REMOTE}"
bashio::log.info "Wöchentlich: ${WEEKLY_ENABLED}  → ${WEEKLY_TIME} ${WEEKLY_WEEKDAY} | lokal: ${WEEKLY_KEEP_LOCAL} | NAS: ${WEEKLY_KEEP_REMOTE}"
bashio::log.info "Monatlich:   ${MONTHLY_ENABLED} → ${MONTHLY_TIME} am ${MONTHLY_DAY}. | lokal: ${MONTHLY_KEEP_LOCAL} | NAS: ${MONTHLY_KEEP_REMOTE}"
bashio::log.info "Jährlich:    ${YEARLY_ENABLED}  → ${YEARLY_TIME} am ${YEARLY_DAY}.${YEARLY_MONTH}. | lokal: ${YEARLY_KEEP_LOCAL} | NAS: ${YEARLY_KEEP_REMOTE}"

declare -A WEEKDAY_MAP
WEEKDAY_MAP[sun]=0
WEEKDAY_MAP[mon]=1
WEEKDAY_MAP[tue]=2
WEEKDAY_MAP[wed]=3
WEEKDAY_MAP[thu]=4
WEEKDAY_MAP[fri]=5
WEEKDAY_MAP[sat]=6
WEEKLY_DOW="${WEEKDAY_MAP[${WEEKLY_WEEKDAY}]}"

LAST_DAILY=""
LAST_WEEKLY=""
LAST_MONTHLY=""
LAST_YEARLY=""

# ── Backup ausführen – Fehler stoppen NICHT das Addon ─────────────────────
_run_backup() {
    local type="$1"
    bashio::log.info "=== Starte ${type} Backup ==="
    /gfs_backup.sh "${type}" \
        "${NAS_HOST}" "${NAS_SHARE}" "${NAS_USER}" "${NAS_PASS}" \
        "$2" "$3" "$4" "${BACKUP_PASS}" || \
        bashio::log.error "${type} Backup fehlgeschlagen – Addon läuft weiter"
}

# ── NAS löschen Hilfsfunktion ──────────────────────────────────────────────
_delete_last_nas() {
    local DIR="$1"
    if [ -n "${NAS_USER}" ] && [ -n "${NAS_PASS}" ]; then
        SMB_AUTH="-U ${NAS_USER}%${NAS_PASS}"
    else
        SMB_AUTH="-N"
    fi
    LAST_FILE=$(smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
        -c "ls ${DIR}/HA-*.tar" 2>/dev/null | \
        grep "\.tar" | awk '{print $1}' | sort -r | head -1)
    if [ -n "${LAST_FILE}" ]; then
        smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
            -c "del ${DIR}/${LAST_FILE}" 2>/dev/null
        bashio::log.info "NAS gelöscht: ${DIR}/${LAST_FILE}"
    else
        bashio::log.warning "Kein Backup in ${DIR}/ gefunden"
    fi
}

# ── stdin-Handler ──────────────────────────────────────────────────────────
_handle_stdin() {
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        CMD=$(echo "${line}" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('command',''))
except:
    print('')
" 2>/dev/null)
        bashio::log.info "stdin: ${CMD}"

        case "${CMD}" in
            trigger_daily)
                _run_backup "daily" "${DAILY_DIR}" "${DAILY_KEEP_LOCAL}" "${DAILY_KEEP_REMOTE}" ;;
            trigger_weekly)
                _run_backup "weekly" "${WEEKLY_DIR}" "${WEEKLY_KEEP_LOCAL}" "${WEEKLY_KEEP_REMOTE}" ;;
            trigger_monthly)
                _run_backup "monthly" "${MONTHLY_DIR}" "${MONTHLY_KEEP_LOCAL}" "${MONTHLY_KEEP_REMOTE}" ;;
            trigger_yearly)
                _run_backup "yearly" "${YEARLY_DIR}" "${YEARLY_KEEP_LOCAL}" "${YEARLY_KEEP_REMOTE}" ;;
            delete_last_local)
                bashio::log.info "=== Lösche letztes lokales GFS-Backup ==="
                LAST_SLUG=$(curl -s \
                    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                    "http://supervisor/backups" | \
                    python3 -c "
import sys, json
data = json.load(sys.stdin)
prefixes = ('HA-Daily-', 'HA-Weekly-', 'HA-Monthly-', 'HA-Yearly-')
backups = [b for b in data.get('data', {}).get('backups', []) if b.get('name','').startswith(prefixes)]
backups.sort(key=lambda x: x.get('date',''), reverse=True)
if backups: print(backups[0]['slug'])
" 2>/dev/null)
                if [ -n "${LAST_SLUG}" ]; then
                    curl -s -X DELETE \
                        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                        "http://supervisor/backups/${LAST_SLUG}" > /dev/null
                    bashio::log.info "Lokal gelöscht: ${LAST_SLUG}"
                else
                    bashio::log.warning "Kein GFS-Backup zum Löschen gefunden"
                fi ;;
            delete_last_nas_daily)   _delete_last_nas "${DAILY_DIR}"   ;;
            delete_last_nas_weekly)  _delete_last_nas "${WEEKLY_DIR}"  ;;
            delete_last_nas_monthly) _delete_last_nas "${MONTHLY_DIR}" ;;
            delete_last_nas_yearly)  _delete_last_nas "${YEARLY_DIR}"  ;;
            *) bashio::log.warning "Unbekannter Befehl: ${CMD}" ;;
        esac
    done
}

_handle_stdin &

bashio::log.info "GFS Backup läuft. Prüfe jede Minute..."

while true; do
    NOW_TIME=$(date +"%H:%M")
    NOW_DOW=$(date +"%w")
    NOW_DAY=$(date +%-d)
    NOW_MONTH=$(date +%-m)
    NOW_KEY=$(date +"%Y-%m-%d-%H-%M")

    if [ "${YEARLY_ENABLED}" = "true" ] && \
       [ "${NOW_TIME}" = "${YEARLY_TIME}" ] && \
       [ "${NOW_DAY}" = "${YEARLY_DAY}" ] && \
       [ "${NOW_MONTH}" = "${YEARLY_MONTH}" ] && \
       [ "${LAST_YEARLY}" != "${NOW_KEY}" ]; then
        LAST_YEARLY="${NOW_KEY}"
        _run_backup "yearly" "${YEARLY_DIR}" "${YEARLY_KEEP_LOCAL}" "${YEARLY_KEEP_REMOTE}"
    fi

    if [ "${MONTHLY_ENABLED}" = "true" ] && \
       [ "${NOW_TIME}" = "${MONTHLY_TIME}" ] && \
       [ "${NOW_DAY}" = "${MONTHLY_DAY}" ] && \
       [ "${LAST_MONTHLY}" != "${NOW_KEY}" ]; then
        LAST_MONTHLY="${NOW_KEY}"
        _run_backup "monthly" "${MONTHLY_DIR}" "${MONTHLY_KEEP_LOCAL}" "${MONTHLY_KEEP_REMOTE}"
    fi

    if [ "${WEEKLY_ENABLED}" = "true" ] && \
       [ "${NOW_TIME}" = "${WEEKLY_TIME}" ] && \
       [ "${NOW_DOW}" = "${WEEKLY_DOW}" ] && \
       [ "${LAST_WEEKLY}" != "${NOW_KEY}" ]; then
        LAST_WEEKLY="${NOW_KEY}"
        _run_backup "weekly" "${WEEKLY_DIR}" "${WEEKLY_KEEP_LOCAL}" "${WEEKLY_KEEP_REMOTE}"
    fi

    if [ "${DAILY_ENABLED}" = "true" ] && \
       [ "${NOW_TIME}" = "${DAILY_TIME}" ] && \
       [ "${LAST_DAILY}" != "${NOW_KEY}" ]; then
        LAST_DAILY="${NOW_KEY}"
        _run_backup "daily" "${DAILY_DIR}" "${DAILY_KEEP_LOCAL}" "${DAILY_KEEP_REMOTE}"
    fi

    sleep 60
done
