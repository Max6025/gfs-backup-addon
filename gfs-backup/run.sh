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
    bashio::log.fatal "NAS IP-Adresse nicht gesetzt!"
    exit 1
fi

declare -A WEEKDAY_MAP
WEEKDAY_MAP[sun]=0; WEEKDAY_MAP[mon]=1; WEEKDAY_MAP[tue]=2
WEEKDAY_MAP[wed]=3; WEEKDAY_MAP[thu]=4; WEEKDAY_MAP[fri]=5; WEEKDAY_MAP[sat]=6
WEEKLY_DOW="${WEEKDAY_MAP[${WEEKLY_WEEKDAY}]}"

LAST_DAILY=""; LAST_WEEKLY=""; LAST_MONTHLY=""; LAST_YEARLY=""
BACKUP_RUNNING="false"

STATUS_FILE="/tmp/gfs_status.json"

# ── Status in Datei schreiben (HTTP-Server liest sie) ─────────────────────
_write_status() {
    TOKEN="${SUPERVISOR_TOKEN}"
    ALL=$(curl -s \
        -H "Authorization: Bearer ${TOKEN}" \
        "http://supervisor/backups" 2>/dev/null)

    python3 << PYEOF
import json, os, sys
from datetime import datetime

try:
    all_data = json.loads('''${ALL}''')
    backups = all_data.get('data', {}).get('backups', [])
except:
    backups = []

prefixes = {
    'daily':   'HA-Daily-',
    'weekly':  'HA-Weekly-',
    'monthly': 'HA-Monthly-',
    'yearly':  'HA-Yearly-',
}

result = {
    'addon_running': True,
    'backup_running': '${BACKUP_RUNNING}' == 'true',
    'last_update': datetime.now().isoformat(),
    'config': {
        'nas_host': '${NAS_HOST}',
        'nas_share': '${NAS_SHARE}',
        'daily_time': '${DAILY_TIME}',
        'weekly_time': '${WEEKLY_TIME}',
        'weekly_weekday': '${WEEKLY_WEEKDAY}',
        'monthly_time': '${MONTHLY_TIME}',
        'monthly_day': int('${MONTHLY_DAY}'),
        'yearly_time': '${YEARLY_TIME}',
        'yearly_day': int('${YEARLY_DAY}'),
        'yearly_month': int('${YEARLY_MONTH}'),
    }
}

for btype, prefix in prefixes.items():
    typed = [b for b in backups if b.get('name','').startswith(prefix)]
    typed.sort(key=lambda x: x.get('date',''), reverse=True)
    last = typed[0] if typed else None
    result[btype] = {
        'count': len(typed),
        'last_date': last.get('date') if last else None,
        'last_name': last.get('name') if last else None,
        'last_size': last.get('size', 0) if last else 0,
        'last_slug': last.get('slug') if last else None,
    }

with open('${STATUS_FILE}', 'w') as f:
    json.dump(result, f)
print('[GFS] Status aktualisiert')
PYEOF
}

# ── Backup starten ─────────────────────────────────────────────────────────
_run_backup() {
    local type="$1" dir="$2" keep_local="$3" keep_remote="$4"
    BACKUP_RUNNING="true"
    _write_status
    bashio::log.info "=== Starte ${type} Backup ==="
    /gfs_backup.sh "${type}" \
        "${NAS_HOST}" "${NAS_SHARE}" "${NAS_USER}" "${NAS_PASS}" \
        "${dir}" "${keep_local}" "${keep_remote}" "${BACKUP_PASS}" || \
        bashio::log.error "${type} Backup fehlgeschlagen"
    BACKUP_RUNNING="false"
    _write_status
}

# ── NAS löschen ────────────────────────────────────────────────────────────
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

# ── Befehl ausführen (von HTTP-Server via Flag-Datei) ─────────────────────
_handle_command() {
    local CMD="$1"
    bashio::log.info "Befehl: ${CMD}"
    case "${CMD}" in
        trigger_daily)   _run_backup "daily"   "${DAILY_DIR}"   "${DAILY_KEEP_LOCAL}"   "${DAILY_KEEP_REMOTE}"   ;;
        trigger_weekly)  _run_backup "weekly"  "${WEEKLY_DIR}"  "${WEEKLY_KEEP_LOCAL}"  "${WEEKLY_KEEP_REMOTE}"  ;;
        trigger_monthly) _run_backup "monthly" "${MONTHLY_DIR}" "${MONTHLY_KEEP_LOCAL}" "${MONTHLY_KEEP_REMOTE}" ;;
        trigger_yearly)  _run_backup "yearly"  "${YEARLY_DIR}"  "${YEARLY_KEEP_LOCAL}"  "${YEARLY_KEEP_REMOTE}"  ;;
        delete_last_local)
            LAST_SLUG=$(curl -s \
                -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                "http://supervisor/backups" | \
                python3 -c "
import sys,json
data=json.load(sys.stdin)
p=('HA-Daily-','HA-Weekly-','HA-Monthly-','HA-Yearly-')
bs=[b for b in data.get('data',{}).get('backups',[]) if b.get('name','').startswith(p)]
bs.sort(key=lambda x:x.get('date',''),reverse=True)
if bs: print(bs[0]['slug'])
" 2>/dev/null)
            if [ -n "${LAST_SLUG}" ]; then
                curl -s -X DELETE \
                    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                    "http://supervisor/backups/${LAST_SLUG}" > /dev/null
                bashio::log.info "Lokal gelöscht: ${LAST_SLUG}"
                _write_status
            fi ;;
        delete_last_nas_daily)   _delete_last_nas "${DAILY_DIR}"   ;;
        delete_last_nas_weekly)  _delete_last_nas "${WEEKLY_DIR}"  ;;
        delete_last_nas_monthly) _delete_last_nas "${MONTHLY_DIR}" ;;
        delete_last_nas_yearly)  _delete_last_nas "${YEARLY_DIR}"  ;;
        *) bashio::log.warning "Unbekannter Befehl: ${CMD}" ;;
    esac
}

# ── HTTP-Server starten ────────────────────────────────────────────────────
python3 /server.py &
bashio::log.info "HTTP-Server gestartet auf Port 8099"

# Initialen Status schreiben
_write_status

bashio::log.info "GFS Backup läuft. Prüfe jede Minute..."

STATUS_COUNTER=0

while true; do
    NOW_TIME=$(date +"%H:%M")
    NOW_DOW=$(date +"%w")
    NOW_DAY=$(date +%-d)
    NOW_MONTH=$(date +%-m)
    NOW_KEY=$(date +"%Y-%m-%d-%H-%M")

    # Flag-Dateien prüfen (Befehle vom HTTP-Server)
    for FLAG in /tmp/gfs_cmd_*; do
        [ -f "${FLAG}" ] || continue
        CMD=$(cat "${FLAG}" 2>/dev/null)
        rm -f "${FLAG}"
        [ -n "${CMD}" ] && _handle_command "${CMD}"
    done

    # Zeitgesteuerte Backups
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

    # Status alle 5 Minuten aktualisieren
    STATUS_COUNTER=$((STATUS_COUNTER + 1))
    if [ "${STATUS_COUNTER}" -ge 5 ]; then
        STATUS_COUNTER=0
        _write_status
    fi

    sleep 60
done
