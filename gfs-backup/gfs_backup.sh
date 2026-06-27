#!/bin/bash
# gfs_backup.sh - Backup erstellen, auf NAS hochladen, Rotation lokal + NAS

TYPE="$1"
NAS_HOST="$2"
NAS_SHARE="$3"
NAS_USER="$4"
NAS_PASS="$5"
TARGET_DIR="$6"
KEEP_LOCAL="$7"
KEEP_REMOTE="$8"
BACKUP_PASS="$9"

DATE=$(date +"%Y-%m-%d")
YEAR=$(date +"%Y")
MONTH=$(date +"%Y-%m")

case "${TYPE}" in
    daily)   BACKUP_NAME="HA-Daily-${DATE}"   ; PREFIX="HA-Daily-"   ;;
    weekly)  BACKUP_NAME="HA-Weekly-${DATE}"  ; PREFIX="HA-Weekly-"  ;;
    monthly) BACKUP_NAME="HA-Monthly-${MONTH}"; PREFIX="HA-Monthly-" ;;
    yearly)  BACKUP_NAME="HA-Yearly-${YEAR}"  ; PREFIX="HA-Yearly-"  ;;
    *)       echo "[GFS] Unbekannter Typ: ${TYPE}"; exit 1 ;;
esac

TOKEN="${SUPERVISOR_TOKEN}"

if [ -z "${TOKEN}" ]; then
    echo "[GFS] FEHLER: SUPERVISOR_TOKEN ist leer!"
    exit 1
fi

echo "[GFS] Erstelle Backup: ${BACKUP_NAME}"

# ── 1. Backup über Supervisor API erstellen ────────────────────────────────
# Korrekter Endpunkt: POST /backups/new/full
if [ -n "${BACKUP_PASS}" ]; then
    PAYLOAD=$(printf '{"name": "%s", "password": "%s"}' "${BACKUP_NAME}" "${BACKUP_PASS}")
else
    PAYLOAD=$(printf '{"name": "%s"}' "${BACKUP_NAME}")
fi

echo "[GFS] POST http://supervisor/backups/new/full"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" \
    "http://supervisor/backups/new/full")

HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
BODY=$(echo "${RESPONSE}" | head -n -1)

echo "[GFS] HTTP Status: ${HTTP_CODE}"

if [ "${HTTP_CODE}" != "200" ] && [ "${HTTP_CODE}" != "201" ]; then
    echo "[GFS] FEHLER: HTTP ${HTTP_CODE} – ${BODY}"
    exit 1
fi

RESULT=$(echo "${BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result','error'))" 2>/dev/null || echo "error")
if [ "${RESULT}" != "ok" ]; then
    echo "[GFS] FEHLER beim Backup: ${BODY}"
    exit 1
fi

BACKUP_SLUG=$(echo "${BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['slug'])" 2>/dev/null)
echo "[GFS] Backup erstellt: Slug=${BACKUP_SLUG}"

# Warten bis Datei auf Disk ist (max 10 Min)
echo "[GFS] Warte auf Backup-Datei..."
WAIT=0
while [ ! -f "/backup/${BACKUP_SLUG}/${BACKUP_SLUG}.tar" ] && [ ! -f "/backup/${BACKUP_SLUG}.tar" ] && [ "${WAIT}" -lt 600 ]; do
    sleep 10
    WAIT=$((WAIT + 10))
done

# Neues Format (2025+): /backup/SLUG/SLUG.tar, Fallback auf altes Format
BACKUP_FILE="/backup/${BACKUP_SLUG}/${BACKUP_SLUG}.tar"
if [ ! -f "${BACKUP_FILE}" ]; then
    BACKUP_FILE="/backup/${BACKUP_SLUG}.tar"
fi
if [ ! -f "${BACKUP_FILE}" ]; then
    echo "[GFS] FEHLER: Backup-Datei nach ${WAIT}s nicht gefunden!"
    exit 1
fi

FILESIZE=$(du -sh "${BACKUP_FILE}" | cut -f1)
echo "[GFS] Backup-Datei: ${BACKUP_FILE} (${FILESIZE})"

# ── 2. Auf NAS hochladen via smbclient ────────────────────────────────────
echo "[GFS] Upload → //${NAS_HOST}/${NAS_SHARE}/${TARGET_DIR}/${BACKUP_NAME}.tar"

if [ -n "${NAS_USER}" ] && [ -n "${NAS_PASS}" ]; then
    SMB_AUTH="-U ${NAS_USER}%${NAS_PASS}"
else
    SMB_AUTH="-N"
fi

# Unterordner anlegen (Fehler ignorieren)
smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
    -c "mkdir ${TARGET_DIR}" 2>/dev/null || true

# Upload
smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
    -c "put ${BACKUP_FILE} ${TARGET_DIR}/${BACKUP_NAME}.tar"

if [ $? -ne 0 ]; then
    echo "[GFS] FEHLER: Upload fehlgeschlagen!"
    exit 1
fi
echo "[GFS] Upload OK"

# ── 3. Rotation auf NAS ───────────────────────────────────────────────────
echo "[GFS] NAS-Rotation: max ${KEEP_REMOTE} behalten"

NAS_FILES=$(smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
    -c "ls ${TARGET_DIR}/HA-*.tar" 2>/dev/null | \
    grep "\.tar" | awk '{print $1}' | sort)

NAS_COUNT=$(echo "${NAS_FILES}" | grep -c "\.tar" 2>/dev/null || echo "0")
echo "[GFS] NAS: ${NAS_COUNT} Backups"

if [ "${NAS_COUNT}" -gt "${KEEP_REMOTE}" ]; then
    DELETE_COUNT=$((NAS_COUNT - KEEP_REMOTE))
    echo "[GFS] Lösche ${DELETE_COUNT} älteste vom NAS"
    echo "${NAS_FILES}" | head -n "${DELETE_COUNT}" | while IFS= read -r filename; do
        [ -z "${filename}" ] && continue
        echo "[GFS] Lösche NAS: ${TARGET_DIR}/${filename}"
        smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
            -c "del ${TARGET_DIR}/${filename}" 2>/dev/null || true
    done
fi

# ── 4. Lokale Rotation ────────────────────────────────────────────────────
echo "[GFS] Lokale Rotation: max ${KEEP_LOCAL} behalten"

if [ "${KEEP_LOCAL}" -eq 0 ]; then
    echo "[GFS] keep_local=0 – lösche sofort lokal: ${BACKUP_SLUG}"
    curl -s -X DELETE \
        -H "Authorization: Bearer ${TOKEN}" \
        "http://supervisor/backups/${BACKUP_SLUG}" > /dev/null
else
    # Alle lokalen Backups mit passendem Präfix holen
    ALL_BACKUPS=$(curl -s \
        -H "Authorization: Bearer ${TOKEN}" \
        "http://supervisor/backups" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
prefix = sys.argv[1]
backups = [b for b in data.get('data', {}).get('backups', []) if b.get('name','').startswith(prefix)]
backups.sort(key=lambda x: x.get('date',''))
for b in backups:
    print(b['date'] + '\t' + b['slug'])
" "${PREFIX}" 2>/dev/null)

    LOCAL_COUNT=$(echo "${ALL_BACKUPS}" | grep -c $'\t' 2>/dev/null || echo "0")
    echo "[GFS] Lokal: ${LOCAL_COUNT} Backups mit Präfix '${PREFIX}'"

    if [ "${LOCAL_COUNT}" -gt "${KEEP_LOCAL}" ]; then
        DELETE_LOCAL=$((LOCAL_COUNT - KEEP_LOCAL))
        echo "[GFS] Lösche ${DELETE_LOCAL} älteste lokal"
        echo "${ALL_BACKUPS}" | head -n "${DELETE_LOCAL}" | awk -F'\t' '{print $2}' | \
        while IFS= read -r slug; do
            [ -z "${slug}" ] && continue
            echo "[GFS] Lösche lokal: ${slug}"
            curl -s -X DELETE \
                -H "Authorization: Bearer ${TOKEN}" \
                "http://supervisor/backups/${slug}" > /dev/null
        done
    fi
fi

echo "[GFS] ✓ ${TYPE} Backup fertig: ${BACKUP_NAME}"
