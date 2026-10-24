#!/usr/bin/env bash
# Richtet einen frischen Debian-12- oder Ubuntu-24.04-Server für Yuvomi ein:
# Docker, Firewall, automatische Sicherheitsupdates, dann Yuvomi + Caddy unter
# /opt/yuvomi. Danach zeigt https://<DOMAIN> die Ersteinrichtung von Yuvomi.
#
# Aufruf als root auf dem Server, aus einem Klon des Repos:
#   sudo bash deploy/hetzner/bootstrap.sh
# oder ohne Klon (Dateien kommen dann aus RAW_BASE):
#   curl -fsSL <RAW_BASE>/bootstrap.sh | sudo DOMAIN=essen.example.de ACME_EMAIL=ich@example.de bash
#
# Fragt nach DOMAIN und ACME_EMAIL, wenn sie nicht als Umgebungsvariable gesetzt
# sind. Ein zweiter Lauf erzeugt keine neuen Schlüssel und überschreibt keine .env.

set -euo pipefail

TARGET_DIR="${TARGET_DIR:-/opt/yuvomi}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/cparaschiakos-wq/yuvomi/ccr-7ad5c5ef-5q65wg/deploy/hetzner}"
FILES=(docker-compose.yml Caddyfile .env.example)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFehler: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Bitte als root ausführen (sudo bash bootstrap.sh)."
command -v apt-get >/dev/null || fail "Dieses Skript erwartet Debian oder Ubuntu (apt-get)."

# --- Eingaben ---------------------------------------------------------------
if [[ -z "${DOMAIN:-}" ]]; then
  read -r -p "Domain für Yuvomi (z. B. essen.example.de): " DOMAIN
fi
if [[ -z "${ACME_EMAIL:-}" ]]; then
  read -r -p "E-Mail für Let's Encrypt: " ACME_EMAIL
fi
[[ "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || fail "'$DOMAIN' sieht nicht wie ein Hostname aus (nur Kleinbuchstaben, Ziffern, Punkte, Bindestriche)."
[[ "$ACME_EMAIL" == *@*.* ]] || fail "'$ACME_EMAIL' sieht nicht wie eine E-Mail-Adresse aus."

# --- DNS prüfen (Warnung, kein Abbruch) ------------------------------------
log "DNS prüfen"
SERVER_IP="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
DNS_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
if [[ -n "$SERVER_IP" && "$DNS_IP" == "$SERVER_IP" ]]; then
  echo "    $DOMAIN -> $DNS_IP (passt zu diesem Server)"
else
  echo "    WARNUNG: $DOMAIN zeigt auf '${DNS_IP:-nichts}', dieser Server hat '${SERVER_IP:-unbekannt}'."
  echo "    Caddy bekommt erst ein Zertifikat, wenn der A-Record stimmt. Weiter geht es trotzdem."
fi

# --- Pakete -----------------------------------------------------------------
log "System aktualisieren und Grundpakete installieren"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -y -q
apt-get install -y -q ca-certificates curl gnupg ufw unattended-upgrades openssl

log "Automatische Sicherheitsupdates einschalten"
dpkg-reconfigure -f noninteractive unattended-upgrades

# --- Docker -----------------------------------------------------------------
if ! command -v docker >/dev/null; then
  log "Docker installieren (offizielles Convenience-Skript von get.docker.com)"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
else
  log "Docker ist bereits installiert: $(docker --version)"
fi
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 fehlt (docker compose version)."
systemctl enable --now docker

# --- Firewall ---------------------------------------------------------------
log "Firewall: nur SSH, HTTP und HTTPS"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw --force enable >/dev/null
ufw status | sed 's/^/    /'

# --- Dateien ----------------------------------------------------------------
log "Dateien nach $TARGET_DIR"
mkdir -p "$TARGET_DIR"/{data,backups,modules,documents}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
for f in "${FILES[@]}"; do
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$f" ]]; then
    cp "$SCRIPT_DIR/$f" "$TARGET_DIR/$f"
  else
    curl -fsSL "$RAW_BASE/$f" -o "$TARGET_DIR/$f"
  fi
done

# --- .env -------------------------------------------------------------------
ENV_FILE="$TARGET_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  log ".env existiert bereits, bleibt unverändert"
else
  log ".env erzeugen"
  SESSION_SECRET="$(openssl rand -hex 32)"
  DB_KEY="$(openssl rand -hex 32)"
  sed \
    -e "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" \
    -e "s|^ACME_EMAIL=.*|ACME_EMAIL=${ACME_EMAIL}|" \
    -e "s|REPLACE_WITH_DOMAIN|${DOMAIN}|g" \
    -e "s|^SESSION_SECRET=.*|SESSION_SECRET=${SESSION_SECRET}|" \
    -e "s|^DB_ENCRYPTION_KEY=.*|DB_ENCRYPTION_KEY=${DB_KEY}|" \
    "$TARGET_DIR/.env.example" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  grep -q REPLACE_WITH "$ENV_FILE" && fail "In $ENV_FILE steht noch ein Platzhalter."
fi

# --- Start ------------------------------------------------------------------
log "Container holen und starten"
cd "$TARGET_DIR"
docker compose pull -q
docker compose up -d
sleep 5
docker compose ps

# --- Abschluss --------------------------------------------------------------
DB_KEY_NOW="$(sed -n 's/^DB_ENCRYPTION_KEY=//p' "$ENV_FILE")"
cat <<MSG

==========================================================================
 Fertig. Nächste Schritte:

 1. https://${DOMAIN} im Browser öffnen und SOFORT das Admin-Konto anlegen.
    Bis dahin ist die Einrichtungsseite ohne Anmeldung erreichbar.
    Kommt ein Zertifikatsfehler, stimmt der A-Record noch nicht;
    Caddy versucht es automatisch weiter (docker compose logs -f caddy).

 2. Diesen Datenbankschlüssel JETZT an einem sicheren Ort notieren.
    Ohne ihn ist die Datenbank nicht wiederherstellbar, auch nicht aus Backups:

      DB_ENCRYPTION_KEY=${DB_KEY_NOW}

 3. Backups prüfen: ${TARGET_DIR}/backups, täglich 02:00 Uhr.
    WebDAV-Ziel in ${ENV_FILE} eintragen (WEBDAV_BACKUP_*), dann
    docker compose up -d.

 4. Google Calendar: Client-ID und Secret in ${ENV_FILE} eintragen
    (GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET), docker compose up -d,
    dann in Yuvomi unter Einstellungen -> Module -> Kalender verbinden.
    Anleitung: deploy/hetzner/README.md

 Updates:  cd ${TARGET_DIR} && docker compose pull && docker compose up -d
 Logs:     cd ${TARGET_DIR} && docker compose logs -f
==========================================================================
MSG
