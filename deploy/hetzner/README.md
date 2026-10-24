# Yuvomi auf einem Mietserver (VPS) mit Caddy

Ein Server, zwei Container: Yuvomi und Caddy als Reverse Proxy mit automatischem
Let's-Encrypt-Zertifikat. Gedacht für einen Haushalt, der Yuvomi von überall und
mit Google-Calendar-Sync nutzen will. Kosten: ein kleiner VPS für 8 bis 10 € im
Monat plus eine Domain (2 bis 5 € im Jahr). Der Anbieter ist egal, solange es ein
Debian oder Ubuntu mit root-Zugang und eigener IPv4-Adresse ist.

Dieser Ordner ist eine Ergänzung zur allgemeinen [Installationsanleitung](../../docs/installation.md);
dort stehen alle Umgebungsvariablen im Detail.

## Was du vorher brauchst

1. **Eine Domain** und Zugriff auf ihre DNS-Einträge.
2. **Einen Server** mit Debian 12 oder Ubuntu 24.04, Zugang per SSH-Schlüssel.
   Yuvomi braucht 256 MB RAM; 1 GB reicht für den Betrieb, 2 GB oder mehr sind
   angenehmer, wenn das Fork-Image auf dem Server selbst gebaut werden soll
   (bei weniger als 2 GB legt `bootstrap.sh` 2 GB Swap an). x86 und ARM gehen
   beide, Yuvomi liefert Images für amd64 und arm64.

   Stand Oktober 2026 in Deutschland bestellbar:

   | Anbieter | Typ | Ausstattung | Preis brutto/Monat |
   |---|---|---|---|
   | Hetzner Cloud | CPX02 (Regular Performance) | 1 vCPU, 1 GB, 20 GB | 7,72 € |
   | netcup | VPS 500 G12.5 | 2 vCore, 4 GB, 64 GB | 8,26 € bei 12 Monaten, 9,50 € monatlich |
   | Hetzner Cloud | CX23 / CAX11 (Cost-Optimized) | 2 vCPU, 4 GB, 40 GB | 7,13 € / 7,72 €, derzeit **nicht bestellbar** |

   Die Cost-Optimized-Linie von Hetzner ist kontingentiert und seit Herbst
   2026 ausverkauft; was wirklich bestellbar ist, zeigt nur die Cloud Console
   beim Anlegen eines Servers je Standort. Bei netcup den Standort Nürnberg
   wählen. Die Firewall des Anbieters, falls vorhanden, auf 22, 80 und 443
   beschränken; `bootstrap.sh` setzt zusätzlich ufw auf dem Server.
3. **Einen A-Record** `essen.deine-domain.de -> <Server-IPv4>`. Optional einen
   AAAA-Record auf die IPv6-Adresse. Der Eintrag muss stehen, bevor Caddy ein
   Zertifikat holen kann.

## Einrichten

Auf dem Server als root:

```bash
apt-get install -y git
git clone -b ccr-7ad5c5ef-5q65wg https://github.com/cparaschiakos-wq/yuvomi.git /root/yuvomi-src
cd /root/yuvomi-src
DOMAIN=essen.deine-domain.de ACME_EMAIL=du@deine-domain.de bash deploy/hetzner/bootstrap.sh
```

Ohne die beiden Variablen fragt das Skript danach. Es macht der Reihe nach:

- System aktualisieren, automatische Sicherheitsupdates einschalten
- Docker installieren, Firewall (ufw) auf SSH, 80 und 443 beschränken
- `docker-compose.yml`, `Caddyfile` und `.env` nach `/opt/yuvomi` legen
- `SESSION_SECRET` und `DB_ENCRYPTION_KEY` erzeugen und in die `.env` schreiben
- Container holen und starten

Am Ende zeigt es den Datenbankschlüssel an. **Schreib ihn auf.** Ohne ihn ist die
Datenbank weg, auch aus einem Backup.

Dann `https://essen.deine-domain.de` öffnen und sofort das Admin-Konto anlegen.

## Google Calendar verbinden

Yuvomi hat den Zwei-Wege-Sync eingebaut, braucht aber einen eigenen OAuth-Client
bei Google. Das kostet nichts.

1. [console.cloud.google.com](https://console.cloud.google.com): neues Projekt,
   zum Beispiel „Yuvomi Haushalt".
2. **APIs & Dienste → Bibliothek**: „Google Calendar API" aktivieren.
3. **APIs & Dienste → OAuth-Zustimmungsbildschirm**: Nutzertyp „Extern", App-Name
   und Kontaktadresse eintragen. Unter Testnutzer das Google-Konto eintragen,
   dessen Kalender synchronisiert werden soll.
4. **Anmeldedaten → Anmeldedaten erstellen → OAuth-Client-ID**, Typ
   „Webanwendung". Als autorisierte Weiterleitungs-URI genau diese Adresse:
   `https://essen.deine-domain.de/api/v1/calendar/google/callback`
5. Client-ID und Client-Secret in `/opt/yuvomi/.env` bei `GOOGLE_CLIENT_ID` und
   `GOOGLE_CLIENT_SECRET` eintragen. `GOOGLE_REDIRECT_URI` steht dort schon mit
   deiner Domain. Dann:
   ```bash
   cd /opt/yuvomi && docker compose up -d
   ```
6. In Yuvomi als Admin unter der Domain anmelden, **Einstellungen → Module →
   Kalender → Kalender-Sync → Mit Google verbinden**, danach die Kalender
   anhaken, die synchronisiert werden sollen.

**Wichtig:** Solange das Google-Projekt im Status „Testing" steht, läuft die
Verbindung nach sieben Tagen ab. Für Dauerbetrieb den Zustimmungsbildschirm auf
„In Produktion" stellen. Google warnt dann beim Verbinden vor einer nicht
verifizierten App; das ist für eine private Installation in Ordnung.

## Backups

Yuvomi sichert täglich um 02:00 Uhr nach `/opt/yuvomi/backups` und behält 14
Stände. Das liegt auf derselben Platte wie die Datenbank. Ein zweiter Ort ist
Pflicht, zum Beispiel eine Hetzner Storage Box (ab etwa 4 € im Monat) oder eine
vorhandene Nextcloud: `WEBDAV_BACKUP_*` in der `.env` setzen, dann
`docker compose up -d`. Alternativ die Snapshot- oder Backup-Option des
Anbieters buchen (bei Hetzner 20 % des Serverpreises), die sichert die ganze
Platte.

Ein Backup lässt sich in Yuvomi unter Einstellungen → Haushalt → Backup
zurückspielen. Der Datenbankschlüssel muss dabei derselbe sein.

## Betrieb

```bash
cd /opt/yuvomi
docker compose pull && docker compose up -d   # Update
docker compose logs -f                        # Logs beider Container
docker compose logs -f caddy                  # nur Zertifikat / Proxy
docker compose ps                             # Zustand
```

Ein Update von Yuvomi ist ein neues Image; die Daten liegen in `./data`.
Vor größeren Versionssprüngen ein Backup auslösen, Yuvomi migriert die Datenbank
nur vorwärts.

## Eigenen Fork betreiben

Der Stack zieht standardmäßig das Upstream-Image. Sobald der eigene Fork
Änderungen hat, gibt es zwei Wege:

- **Auf dem Server bauen:** in `/root/yuvomi-src` den Branch aktualisieren,
  `docker build -t yuvomi-fork:latest .` ausführen und in der `.env`
  `YUVOMI_IMAGE=yuvomi-fork:latest` setzen. Dauert auf einem 1-GB-Server
  einige Minuten und braucht den Swap, den `bootstrap.sh` anlegt; geht aber
  ohne weitere Infrastruktur.
- **Image in der GitHub Container Registry:** der Upstream-Workflow unter
  `.github/workflows/docker-publish.yml` baut bei Tags ein Image. Im Fork
  aktiviert liegt es dann unter `ghcr.io/<github-user>/yuvomi`, und die `.env`
  zeigt dorthin.

## Wenn etwas nicht geht

- **Browser meldet Zertifikatsfehler:** A-Record prüfen (`dig +short essen.deine-domain.de`),
  dann `docker compose logs caddy`. Caddy versucht es selbst weiter.
- **Login schlägt still fehl:** `SESSION_SECURE=true` ist in der Compose-Datei
  fest gesetzt, die App muss also über HTTPS aufgerufen werden, nicht über die IP.
- **Google-Verbindung endet mit Fehler auf der Einstellungsseite:** Die Anmeldung
  in Yuvomi muss unter genau der Domain erfolgen, die in `GOOGLE_REDIRECT_URI`
  steht. Außerdem Weiterleitungs-URI bei Google Zeichen für Zeichen vergleichen.
- **Container startet nicht:** `docker compose logs yuvomi`. Steht dort etwas zu
  `SESSION_SECRET` oder `DB_ENCRYPTION_KEY`, enthält die `.env` noch einen
  Platzhalter.
