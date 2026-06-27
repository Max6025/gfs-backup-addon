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
    daily)   BACKUP_NAME="HA-Daily-${DATE}" ;;
    weekly)  BACKUP_NAME="HA-Weekly-${DATE}" ;;
    monthly) BACKUP_NAME="HA-Monthly-${MONTH}" ;;
    yearly)  BACKUP_NAME="HA-Yearly-${YEAR}" ;;
    *)       echo "[GFS] Unbekannter Typ: ${TYPE}"; exit 1 ;;
esac

# Token kommt als Umgebungsvariable vom Supervisor (via with-contenv in run.sh)
TOKEN="${SUPERVISOR_TOKEN}"
HA_API="http://supervisor/backups"

if [ -z "${TOKEN}" ]; then
    echo "[GFS] FEHLER: SUPERVISOR_TOKEN ist leer!"
    exit 1
fi

echo "[GFS] Erstelle Backup: ${BACKUP_NAME}"

# ── 1. Backup über Supervisor API erstellen ────────────────────────────────
# Korrekte API: POST /backups mit JSON body (HA 2024+)
if [ -n "${BACKUP_PASS}" ]; then
    PAYLOAD=$(printf '{"name": "%s", "password": "%s"}' "${BACKUP_NAME}" "${BACKUP_PASS}")
else
    PAYLOAD=$(printf '{"name": "%s"}' "${BACKUP_NAME}")
fi

echo "[GFS] API-Aufruf: POST ${HA_API}"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" \
    "${HA_API}")

HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
BODY=$(echo "${RESPONSE}" | head -n -1)

echo "[GFS] HTTP Status: ${HTTP_CODE}"

if [ "${HTTP_CODE}" != "200" ] && [ "${HTTP_CODE}" != "201" ]; then
    echo "[GFS] FEHLER: HTTP ${HTTP_CODE}"
    echo "[GFS] Response: ${BODY}"
    exit 1
fi

RESULT=$(echo "${BODY}" | jq -r '.result // "error"')
if [ "${RESULT}" != "ok" ]; then
    echo "[GFS] FEHLER beim Backup: ${BODY}"
    exit 1
fi

BACKUP_SLUG=$(echo "${BODY}" | jq -r '.data.slug')
echo "[GFS] Backup erstellt: Slug=${BACKUP_SLUG}"

# Warten bis Backup fertig auf Disk ist
echo "[GFS] Warte auf Backup-Datei..."
WAIT=0
while [ ! -f "/backup/${BACKUP_SLUG}.tar" ] && [ "${WAIT}" -lt 300 ]; do
    sleep 5
    WAIT=$((WAIT + 5))
done

BACKUP_FILE="/backup/${BACKUP_SLUG}.tar"
if [ ! -f "${BACKUP_FILE}" ]; then
    echo "[GFS] FEHLER: Backup-Datei nach ${WAIT}s nicht gefunden: ${BACKUP_FILE}"
    exit 1
fi

FILESIZE=$(du -sh "${BACKUP_FILE}" | cut -f1)
echo "[GFS] Backup-Datei gefunden: ${BACKUP_FILE} (${FILESIZE})"

# ── 2. Auf NAS hochladen via smbclient ────────────────────────────────────
echo "[GFS] Upload nach //${NAS_HOST}/${NAS_SHARE}/${TARGET_DIR}/${BACKUP_NAME}.tar"

if [ -n "${NAS_USER}" ] && [ -n "${NAS_PASS}" ]; then
    SMB_AUTH="-U ${NAS_USER}%${NAS_PASS}"
else
    SMB_AUTH="-N"
fi

# Unterordner anlegen (Fehler ignorieren falls schon vorhanden)
smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
    -c "mkdir ${TARGET_DIR}" 2>/dev/null || true

# Upload
smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
    -c "put ${BACKUP_FILE} ${TARGET_DIR}/${BACKUP_NAME}.tar"

if [ $? -ne 0 ]; then
    echo "[GFS] FEHLER: Upload auf NAS fehlgeschlagen!"
    exit 1
fi
echo "[GFS] Upload OK: ${TARGET_DIR}/${BACKUP_NAME}.tar"

# ── 3. Rotation auf NAS ───────────────────────────────────────────────────
echo "[GFS] NAS-Rotation: behalte ${KEEP_REMOTE} in ${TARGET_DIR}/"

NAS_FILES=$(smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
    -c "ls ${TARGET_DIR}/HA-*.tar" 2>/dev/null | \
    grep "\.tar" | \
    awk '{print $1}' | \
    sort)

NAS_COUNT=$(echo "${NAS_FILES}" | grep -c "\.tar" 2>/dev/null || echo "0")
echo "[GFS] NAS: ${NAS_COUNT} Backups gefunden"

if [ "${NAS_COUNT}" -gt "${KEEP_REMOTE}" ]; then
    DELETE_COUNT=$((NAS_COUNT - KEEP_REMOTE))
    echo "[GFS] Lösche ${DELETE_COUNT} älteste vom NAS"
    echo "${NAS_FILES}" | head -n "${DELETE_COUNT}" | while IFS= read -r filename; do
        [ -z "${filename}" ] && continue
        echo "[GFS] Lösche NAS: ${TARGET_DIR}/${filename}"
        smbclient "//${NAS_HOST}/${NAS_SHARE}" ${SMB_AUTH} \
            -c "del ${TARGET_DIR}/${filename}" 2>/dev/null || \
            echo "[GFS] Warnung: Konnte ${filename} nicht löschen"
    done
fi

# ── 4. Lokale Rotation ────────────────────────────────────────────────────
echo "[GFS] Lokale Rotation: behalte ${KEEP_LOCAL}"

# Präfix je nach Typ (capitalize first letter)
case "${TYPE}" in
    daily)   PREFIX="HA-Daily-" ;;
    weekly)  PREFIX="HA-Weekly-" ;;
    monthly) PREFIX="HA-Monthly-" ;;
    yearly)  PREFIX="HA-Yearly-" ;;
esac

LOCAL_BACKUPS=$(curl -s \
    -H "Authorization: Bearer ${TOKEN}" \
    "${HA_API}" | \
    jq -r --arg pfx "${PREFIX}" \
    '.data.backups[] | select(.name | startswith($pfx)) | [.date, .slug] | @tsv' | \
    sort)

LOCAL_COUNT=$(echo "${LOCAL_BACKUPS}" | grep -c $'\t' 2>/dev/null || echo "0")
echo "[GFS] Lokal: ${LOCAL_COUNT} Backups mit Präfix '${PREFIX}'"

if [ "${KEEP_LOCAL}" -eq 0 ]; then
    echo "[GFS] keep_local=0 – lösche sofort lokal: ${BACKUP_SLUG}"
    curl -s -X DELETE \
        -H "Authorization: Bearer ${TOKEN}" \
        "${HA_API}/${BACKUP_SLUG}" > /dev/null
elif [ "${LOCAL_COUNT}" -gt "${KEEP_LOCAL}" ]; then
    DELETE_LOCAL=$((LOCAL_COUNT - KEEP_LOCAL))
    echo "[GFS] Lösche ${DELETE_LOCAL} älteste lokal"
    echo "${LOCAL_BACKUPS}" | head -n "${DELETE_LOCAL}" | awk '{print $2}' | \
    while IFS= read -r slug; do
        [ -z "${slug}" ] && continue
        echo "[GFS] Lösche lokal: ${slug}"
        curl -s -X DELETE \
            -H "Authorization: Bearer ${TOKEN}" \
            "${HA_API}/${slug}" > /dev/null
    done
fi

echo "[GFS] ✓ ${TYPE} Backup fertig: ${BACKUP_NAME}"
