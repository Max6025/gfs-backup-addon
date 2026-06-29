#!/usr/bin/with-contenv bashio

bashio::log.info "GFS Backup Addon startet..."

export SUPERVISOR_TOKEN

NAS_HOST=$(bashio::config 'nas_host')
NAS_SHARE=$(bashio::config 'nas_share')
NAS_USER=$(bashio::config 'nas_username')
NAS_PASS=$(bashio::config 'nas_password')
BACKUP_PASS=$(bashio::config 'backup_password')
TEST_MODE=$(bashio::config 'test_mode')

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
STATUS_FILE="/tmp/gfs_status.json"
LAST_SUCCESS_TIME=""
LAST_SUCCESS_NAME=""
LAST_ERROR=""

if [ "${TEST_MODE}" = "true" ]; then
    bashio::log.warning "⚠️ TESTMODUS AKTIV – kein echtes Backup wird erstellt!"
fi

# ── Status schreiben + WebSocket Push ─────────────────────────────────────
_set_phase() {
    local PHASE="$1"
    local DETAIL="${2:-}"
    python3 -c "
import json, sys
from datetime import datetime

try:
    with open('${STATUS_FILE}', 'r') as f:
        data = json.load(f)
except:
    data = {}

data['phase'] = '${PHASE}'
data['phase_detail'] = '${DETAIL}'
data['phase_updated'] = datetime.now().isoformat()
data['last_success_time'] = '${LAST_SUCCESS_TIME}'
data['last_success_name'] = '${LAST_SUCCESS_NAME}'
data['last_error'] = '${LAST_ERROR}'
data['addon_running'] = True
data['test_mode'] = '${TEST_MODE}' == 'true'

with open('${STATUS_FILE}', 'w') as f:
    json.dump(data, f)
" 2>/dev/null

    # WebSocket Push – notify_clients via Python
    python3 -c "
import sys
sys.path.insert(0, '/')
try:
    import server
    server.notify_clients()
except Exception as e:
    pass
" 2>/dev/null || true
}

# ── Vollständigen Status schreiben ─────────────────────────────────────────
_write_full_status() {
    TOKEN="${SUPERVISOR_TOKEN}"
    ALL=$(curl -s -H "Authorization: Bearer ${TOKEN}" "http://supervisor/backups" 2>/dev/null)

    python3 << PYEOF
import json
from datetime import datetime

try:
    all_data = json.loads(r"""${ALL}""")
    backups = all_data.get('data', {}).get('backups', [])
except:
    backups = []

try:
    with open('${STATUS_FILE}', 'r') as f:
        existing = json.load(f)
except:
    existing = {}

prefixes = {
    'daily':   'HA-Daily-',
    'weekly':  'HA-Weekly-',
    'monthly': 'HA-Monthly-',
    'yearly':  'HA-Yearly-',
}

for btype, prefix in prefixes.items():
    typed = [b for b in backups if b.get('name','').startswith(prefix)]
    typed.sort(key=lambda x: x.get('date',''), reverse=True)
    last = typed[0] if typed else None
    existing[btype] = {
        'count': len(typed),
        'last_date': last.get('date') if last else None,
        'last_name': last.get('name') if last else None,
        'last_size': last.get('size', 0) if last else 0,
        'last_slug': last.get('slug') if last else None,
    }

existing['config'] = {
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
existing['addon_running'] = True
existing['test_mode'] = '${TEST_MODE}' == 'true'
existing['last_update'] = datetime.now().isoformat()

with open('${STATUS_FILE}', 'w') as f:
    json.dump(existing, f)
print('[GFS] Status aktualisiert')
PYEOF

    # WebSocket Push nach vollständigem Update
    python3 -c "
import sys, importlib.util
spec = importlib.util.spec_from_file_location('server', '/server.py')
try:
    import server
    server.notify_clients()
except: pass
" 2>/dev/null || true
}

# ── NAS löschen ────────────────────────────────────────────────────────────
_delete_last_nas() {
    local DIR="$1"
    if [ "${TEST_MODE}" = "true" ]; then
        bashio::log.warning "[TESTMODUS] NAS-Löschung übersprungen: ${DIR}"
        return 0
    fi
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
    fi
}

# ── Backup mit Phasen + Testmodus ─────────────────────────────────────────
_run_backup() {
    local type="$1" dir="$2" keep_local="$3" keep_remote="$4"
    local DATE=$(date +"%Y-%m-%d")
    local YEAR=$(date +"%Y")
    local MONTH=$(date +"%Y-%m")
    local NAME=""

    case "${type}" in
        daily)   NAME="HA-Daily-${DATE}"    ;;
        weekly)  NAME="HA-Weekly-${DATE}"   ;;
        monthly) NAME="HA-Monthly-${MONTH}" ;;
        yearly)  NAME="HA-Yearly-${YEAR}"   ;;
    esac

    bashio::log.info "=== Starte ${type} Backup: ${NAME} ==="

    if [ "${TEST_MODE}" = "true" ]; then
        bashio::log.warning "[TESTMODUS] Simuliere Backup: ${NAME}"

        # Phase 1: Erstellen simulieren (45s)
        _set_phase "creating" "${NAME}"
        bashio::log.info "[TESTMODUS] Simuliere Backup-Erstellung (45s)..."
        sleep 45

        # Phase 2: Upload simulieren (60s)
        _set_phase "uploading" "${NAME} → ${dir}/"
        bashio::log.info "[TESTMODUS] Simuliere Upload (60s)..."
        sleep 60

        # Phase 3: Rotation simulieren (5s)
        _set_phase "rotating" "${dir}/"
        bashio::log.info "[TESTMODUS] Simuliere Rotation (5s)..."
        sleep 5

        # Erfolg
        LAST_SUCCESS_TIME=$(date +"%Y-%m-%dT%H:%M:%S")
        LAST_SUCCESS_NAME="${NAME} [TEST]"
        LAST_ERROR=""
        _set_phase "success" "${NAME} [TEST]"
        _write_full_status
        bashio::log.info "[TESTMODUS] ✓ Simulation abgeschlossen: ${NAME}"
        sleep 300
        _set_phase "idle" ""
        return 0
    fi

    # ── ECHTER Backup-Ablauf ───────────────────────────────────────────────

    # Phase 1: Erstellen
    _set_phase "creating" "${NAME}"

    PAYLOAD=$(printf '{"name": "%s"}' "${NAME}")
    [ -n "${BACKUP_PASS}" ] && PAYLOAD=$(printf '{"name": "%s", "password": "%s"}' "${NAME}" "${BACKUP_PASS}")

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${PAYLOAD}" \
        "http://supervisor/backups/new/full")

    HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
    BODY=$(echo "${RESPONSE}" | head -n -1)

    if [ "${HTTP_CODE}" != "200" ] && [ "${HTTP_CODE}" != "201" ]; then
        LAST_ERROR="HTTP ${HTTP_CODE}"
        bashio::log.error "Backup fehlgeschlagen: ${LAST_ERROR}"
        _set_phase "error" "${LAST_ERROR}"
        sleep 300
        LAST_ERROR=""
        _set_phase "idle" ""
        _write_full_status
        return 1
    fi

    BACKUP_SLUG=$(echo "${BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['slug'])" 2>/dev/null)
    bashio::log.info "Backup erstellt: ${BACKUP_SLUG}"

    # Warten auf Datei
    WAIT=0
    BACKUP_FILE=""
    while [ "${WAIT}" -lt 600 ]; do
        FOUND=$(find /backup -maxdepth 1 -name "*${BACKUP_SLUG}*" 2>/dev/null | head -1)
        if [ -n "${FOUND}" ]; then
            BACKUP_FILE="${FOUND}"
            break
        fi
        sleep 10
        WAIT=$((WAIT + 10))
    done

    if [ -z "${BACKUP_FILE}" ]; then
        LAST_ERROR="Backup-Datei nicht gefunden"
        _set_phase "error" "${LAST_ERROR}"
        sleep 300
        LAST_ERROR=""
        _set_phase "idle" ""
        return 1
    fi

    # Phase 2: Upload
    _set_phase "uploading" "${NAME} → ${dir}/"
    bashio::log.info "Upload: ${BACKUP_FILE} → ${dir}/${NAME}.tar"

    if [ -n "${NAS_USER}" ] && [ -n "${NAS_PASS}" ]; then
        SMB_AUTH="-U ${NAS_USER}%${NAS_PASS}"
    else
        SMB_AUTH="-N"
    fi

    # Fix: Ordner muss auf NAS bereits existieren – kein automatisches Anlegen
    DIR_CHECK=$(smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
        -c "ls ${dir}" 2>&1)
    if echo "${DIR_CHECK}" | grep -qiE "NT_STATUS_NO_SUCH_FILE|NT_STATUS_OBJECT_NAME_NOT_FOUND|does not exist|No such"; then
        LAST_ERROR="NAS-Ordner '${dir}' existiert nicht – bitte manuell auf dem NAS anlegen!"
        bashio::log.error "${LAST_ERROR}"
        _set_phase "error" "${LAST_ERROR}"
        sleep 300
        LAST_ERROR=""
        _set_phase "idle" ""
        return 1
    fi
    bashio::log.info "NAS-Ordner '${dir}' gefunden"

    smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
        -c "put ${BACKUP_FILE} ${dir}/${NAME}.tar"

    if [ $? -ne 0 ]; then
        LAST_ERROR="Upload fehlgeschlagen: ${dir}/${NAME}.tar"
        bashio::log.error "${LAST_ERROR}"
        _set_phase "error" "${LAST_ERROR}"
        sleep 300
        LAST_ERROR=""
        _set_phase "idle" ""
        return 1
    fi

    # Phase 3: Rotation
    _set_phase "rotating" "${dir}/"

    NAS_FILES=$(smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
        -c "ls ${dir}/HA-*.tar" 2>/dev/null | \
        grep "\.tar" | awk '{print $1}' | sort)
    # sort ohne -r = älteste zuerst (Dateiname enthält Datum)
    NAS_COUNT=$(echo "${NAS_FILES}" | grep -c "\.tar" 2>/dev/null || echo "0")
    if [ "${NAS_COUNT}" -gt "${keep_remote}" ]; then
        DELETE_COUNT=$((NAS_COUNT - keep_remote))
        echo "${NAS_FILES}" | head -n "${DELETE_COUNT}" | while IFS= read -r filename; do
            [ -z "${filename}" ] && continue
            smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
                -c "del ${dir}/${filename}" 2>/dev/null || true
        done
    fi

    case "${type}" in
        daily)   PREFIX="HA-Daily-"   ;;
        weekly)  PREFIX="HA-Weekly-"  ;;
        monthly) PREFIX="HA-Monthly-" ;;
        yearly)  PREFIX="HA-Yearly-"  ;;
    esac

    if [ "${keep_local}" -eq 0 ]; then
        curl -s -X DELETE \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "http://supervisor/backups/${BACKUP_SLUG}" > /dev/null
    else
        ALL_BACKUPS=$(curl -s \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "http://supervisor/backups" | \
            python3 -c "
import sys,json
data=json.load(sys.stdin)
pfx='${PREFIX}'
bs=[b for b in data.get('data',{}).get('backups',[]) if b.get('name','').startswith(pfx)]
bs.sort(key=lambda x:x.get('date',''))
for b in bs: print(b['date']+'\t'+b['slug'])
" 2>/dev/null)
        LOCAL_COUNT=$(echo "${ALL_BACKUPS}" | grep -c $'\t' 2>/dev/null || echo "0")
        if [ "${LOCAL_COUNT}" -gt "${keep_local}" ]; then
            DELETE_LOCAL=$((LOCAL_COUNT - keep_local))
            echo "${ALL_BACKUPS}" | head -n "${DELETE_LOCAL}" | awk -F'\t' '{print $2}' | \
            while IFS= read -r slug; do
                [ -z "${slug}" ] && continue
                curl -s -X DELETE \
                    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
                    "http://supervisor/backups/${slug}" > /dev/null
            done
        fi
    fi

    # Erfolg
    LAST_SUCCESS_TIME=$(date +"%Y-%m-%dT%H:%M:%S")
    LAST_SUCCESS_NAME="${NAME}"
    LAST_ERROR=""
    _set_phase "success" "${NAME}"
    _write_full_status
    bashio::log.info "✓ ${type} Backup fertig: ${NAME}"
    sleep 300
    _set_phase "idle" ""
}

# ── Befehl ausführen ───────────────────────────────────────────────────────
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
                _write_full_status
            fi ;;
        delete_last_nas_daily)   _delete_last_nas "${DAILY_DIR}"   ;;
        delete_last_nas_weekly)  _delete_last_nas "${WEEKLY_DIR}"  ;;
        delete_last_nas_monthly) _delete_last_nas "${MONTHLY_DIR}" ;;
        delete_last_nas_yearly)  _delete_last_nas "${YEARLY_DIR}"  ;;
        *) bashio::log.warning "Unbekannter Befehl: ${CMD}" ;;
    esac
}

# ── HTTP + WebSocket Server starten ───────────────────────────────────────
python3 /server.py &
bashio::log.info "Server gestartet (HTTP:8099, WebSocket:8098)"

_set_phase "idle" ""
_write_full_status

bashio::log.info "GFS Backup läuft. Testmodus: ${TEST_MODE}"

STATUS_COUNTER=0

while true; do
    NOW_TIME=$(date +"%H:%M")
    NOW_DOW=$(date +"%w")
    NOW_DAY=$(date +%-d)
    NOW_MONTH=$(date +%-m)
    NOW_KEY=$(date +"%Y-%m-%d-%H-%M")

    for FLAG in /tmp/gfs_cmd_*; do
        [ -f "${FLAG}" ] || continue
        CMD=$(cat "${FLAG}" 2>/dev/null)
        rm -f "${FLAG}"
        [ -n "${CMD}" ] && _handle_command "${CMD}"
    done

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

    STATUS_COUNTER=$((STATUS_COUNTER + 1))
    if [ "${STATUS_COUNTER}" -ge 5 ]; then
        STATUS_COUNTER=0
        _write_full_status
    fi

    sleep 60
done
