# GFS Backup – Dokumentation

## Voraussetzungen

- Home Assistant OS oder Supervised
- Ein NAS mit Samba/CIFS-Freigabe (Synology, QNAP, FritzNAS, Windows Share usw.)
- Ordner auf dem NAS vorab **nicht** nötig – das Addon legt sie automatisch an

## Installation

1. Repository in HA hinzufügen:
   **Einstellungen → Add-ons → Add-on Store → ⋮ → Repositories**
   URL: `https://github.com/DEIN-GITHUB/gfs-backup-addon`

2. "GFS Backup" suchen und installieren

3. Konfiguration ausfüllen (siehe unten)

4. Addon starten

## Konfiguration

| Option | Beschreibung | Beispiel |
|--------|-------------|---------|
| `nas_host` | IP-Adresse des NAS | `192.168.1.50` |
| `nas_share` | Name der Samba-Freigabe | `Backups` |
| `nas_username` | Benutzername (optional) | `ha_user` |
| `nas_password` | Passwort (optional) | `geheim` |
| `backup_password` | Backup-Verschlüsselung (optional) | `sicher123` |

### Täglich (Sohn)
| Option | Beschreibung | Standard |
|--------|-------------|---------|
| `daily_enabled` | Aktiviert | `true` |
| `daily_time` | Uhrzeit | `03:00` |
| `daily_target_dir` | NAS-Unterordner | `ha_daily` |
| `daily_keep_local` | Lokal behalten (0 = sofort löschen) | `1` |
| `daily_keep_remote` | Auf NAS behalten | `7` |

### Wöchentlich (Vater)
| Option | Beschreibung | Standard |
|--------|-------------|---------|
| `weekly_enabled` | Aktiviert | `true` |
| `weekly_time` | Uhrzeit | `04:00` |
| `weekly_weekday` | Wochentag (mon/tue/wed/thu/fri/sat/sun) | `sun` |
| `weekly_target_dir` | NAS-Unterordner | `ha_weekly` |
| `weekly_keep_local` | Lokal behalten | `1` |
| `weekly_keep_remote` | Auf NAS behalten | `4` |

### Monatlich (Großvater)
| Option | Beschreibung | Standard |
|--------|-------------|---------|
| `monthly_enabled` | Aktiviert | `true` |
| `monthly_time` | Uhrzeit | `05:00` |
| `monthly_day` | Tag des Monats (1–28) | `1` |
| `monthly_target_dir` | NAS-Unterordner | `ha_monthly` |
| `monthly_keep_local` | Lokal behalten | `1` |
| `monthly_keep_remote` | Auf NAS behalten | `12` |

### Jährlich (Urgroßvater)
| Option | Beschreibung | Standard |
|--------|-------------|---------|
| `yearly_enabled` | Aktiviert | `true` |
| `yearly_time` | Uhrzeit | `06:00` |
| `yearly_day` | Tag des Monats (1–28) | `1` |
| `yearly_month` | Monat (1–12) | `1` |
| `yearly_target_dir` | NAS-Unterordner | `ha_yearly` |
| `yearly_keep_local` | Lokal behalten | `1` |
| `yearly_keep_remote` | Auf NAS behalten | `2` |

## Dateinamen auf dem NAS

```
ha_daily/   HA-Daily-2026-06-27.tar
ha_weekly/  HA-Weekly-2026-06-22.tar
ha_monthly/ HA-Monthly-2026-06.tar
ha_yearly/  HA-Yearly-2026.tar
```

## Logs

Die Addon-Logs sind unter **Einstellungen → Add-ons → GFS Backup → Log** einsehbar.
