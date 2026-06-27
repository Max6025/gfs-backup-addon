#!/usr/bin/with-contenv bashio

bashio::log.info "GFS Backup Addon startet..."

# Token exportieren damit Kindprozesse ihn erben
export SUPERVISOR_TOKEN

# Konfiguration einlesen
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

# Validierung
if bashio::var.is_empty "${NAS_HOST}"; then
    bashio::log.fatal "NAS IP-Adresse ist nicht gesetzt!"
    exit 1
fi
if bashio::var.is_empty "${NAS_SHARE}"; then
    bashio::log.fatal "NAS Freigabe-Name ist nicht gesetzt!"
    exit 1
fi

bashio::log.info "NAS: //${NAS_HOST}/${NAS_SHARE}"
bashio::log.info "Täglich:     ${DAILY_ENABLED}   → ${DAILY_TIME}   | lokal: ${DAILY_KEEP_LOCAL}  | NAS: ${DAILY_KEEP_REMOTE}"
bashio::log.info "Wöchentlich: ${WEEKLY_ENABLED}   → ${WEEKLY_TIME}  ${WEEKLY_WEEKDAY} | lokal: ${WEEKLY_KEEP_LOCAL}  | NAS: ${WEEKLY_KEEP_REMOTE}"
bashio::log.info "Monatlich:   ${MONTHLY_ENABLED}  → ${MONTHLY_TIME} am ${MONTHLY_DAY}. | lokal: ${MONTHLY_KEEP_LOCAL} | NAS: ${MONTHLY_KEEP_REMOTE}"
bashio::log.info "Jährlich:    ${YEARLY_ENABLED}   → ${YEARLY_TIME}  am ${YEARLY_DAY}.${YEARLY_MONTH}. | lokal: ${YEARLY_KEEP_LOCAL} | NAS: ${YEARLY_KEEP_REMOTE}"

# Wochentag-Mapping (date +%w: 0=So, 1=Mo, ..., 6=Sa)
declare -A WEEKDAY_MAP
WEEKDAY_MAP[sun]=0
WEEKDAY_MAP[mon]=1
WEEKDAY_MAP[tue]=2
WEEKDAY_MAP[wed]=3
WEEKDAY_MAP[thu]=4
WEEKDAY_MAP[fri]=5
WEEKDAY_MAP[sat]=6

WEEKLY_DOW="${WEEKDAY_MAP[${WEEKLY_WEEKDAY}]}"

# Letzter ausgeführter Zeitstempel pro Ebene (verhindert Doppelausführung)
LAST_DAILY=""
LAST_WEEKLY=""
LAST_MONTHLY=""
LAST_YEARLY=""

bashio::log.info "GFS Backup läuft. Prüfe jede Minute..."

while true; do
    NOW_TIME=$(date +"%H:%M")
    NOW_DOW=$(date +"%w")
    NOW_DAY=$(date +%-d)
    NOW_MONTH=$(date +%-m)
    NOW_KEY=$(date +"%Y-%m-%d-%H-%M")

    # ── JÄHRLICH ──────────────────────────────────────────────
    if [ "${YEARLY_ENABLED}" = "true" ]; then
        if [ "${NOW_TIME}" = "${YEARLY_TIME}" ] && \
           [ "${NOW_DAY}" = "${YEARLY_DAY}" ] && \
           [ "${NOW_MONTH}" = "${YEARLY_MONTH}" ] && \
           [ "${LAST_YEARLY}" != "${NOW_KEY}" ]; then
            LAST_YEARLY="${NOW_KEY}"
            bashio::log.info "=== Starte JÄHRLICHES Backup ==="
            /gfs_backup.sh "yearly" \
                "${NAS_HOST}" "${NAS_SHARE}" "${NAS_USER}" "${NAS_PASS}" \
                "${YEARLY_DIR}" "${YEARLY_KEEP_LOCAL}" "${YEARLY_KEEP_REMOTE}" \
                "${BACKUP_PASS}"
        fi
    fi

    # ── MONATLICH ─────────────────────────────────────────────
    if [ "${MONTHLY_ENABLED}" = "true" ]; then
        if [ "${NOW_TIME}" = "${MONTHLY_TIME}" ] && \
           [ "${NOW_DAY}" = "${MONTHLY_DAY}" ] && \
           [ "${LAST_MONTHLY}" != "${NOW_KEY}" ]; then
            LAST_MONTHLY="${NOW_KEY}"
            bashio::log.info "=== Starte MONATLICHES Backup ==="
            /gfs_backup.sh "monthly" \
                "${NAS_HOST}" "${NAS_SHARE}" "${NAS_USER}" "${NAS_PASS}" \
                "${MONTHLY_DIR}" "${MONTHLY_KEEP_LOCAL}" "${MONTHLY_KEEP_REMOTE}" \
                "${BACKUP_PASS}"
        fi
    fi

    # ── WÖCHENTLICH ───────────────────────────────────────────
    if [ "${WEEKLY_ENABLED}" = "true" ]; then
        if [ "${NOW_TIME}" = "${WEEKLY_TIME}" ] && \
           [ "${NOW_DOW}" = "${WEEKLY_DOW}" ] && \
           [ "${LAST_WEEKLY}" != "${NOW_KEY}" ]; then
            LAST_WEEKLY="${NOW_KEY}"
            bashio::log.info "=== Starte WÖCHENTLICHES Backup ==="
            /gfs_backup.sh "weekly" \
                "${NAS_HOST}" "${NAS_SHARE}" "${NAS_USER}" "${NAS_PASS}" \
                "${WEEKLY_DIR}" "${WEEKLY_KEEP_LOCAL}" "${WEEKLY_KEEP_REMOTE}" \
                "${BACKUP_PASS}"
        fi
    fi

    # ── TÄGLICH ───────────────────────────────────────────────
    if [ "${DAILY_ENABLED}" = "true" ]; then
        if [ "${NOW_TIME}" = "${DAILY_TIME}" ] && \
           [ "${LAST_DAILY}" != "${NOW_KEY}" ]; then
            LAST_DAILY="${NOW_KEY}"
            bashio::log.info "=== Starte TÄGLICHES Backup ==="
            /gfs_backup.sh "daily" \
                "${NAS_HOST}" "${NAS_SHARE}" "${NAS_USER}" "${NAS_PASS}" \
                "${DAILY_DIR}" "${DAILY_KEEP_LOCAL}" "${DAILY_KEEP_REMOTE}" \
                "${BACKUP_PASS}"
        fi
    fi

    sleep 60
done
