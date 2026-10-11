# pCloud-Backup für den Mac

Sichert den Benutzerordner eines Macs automatisch alle zwei Tage verschlüsselt in die pCloud. Ein einzelnes Shell-Skript richtet alles ein: [rclone](https://rclone.org) für Verschlüsselung und Upload, launchd für den Zeitplan.

*Encrypted, scheduled backup of a Mac home folder to pCloud, built on rclone and launchd. Documentation and script output are in German.*

## Was es macht

- Spiegelt den Benutzerordner nach pCloud, standardmäßig alle 48 Stunden.
- Verschlüsselt Inhalte und Dateinamen schon auf dem Mac. In der pCloud liegt nur Unlesbares.
- Bewahrt geänderte und gelöschte Dateien 90 Tage in einem datierten Archiv auf.
- Läuft im Hintergrund, startet nur am Netzteil und setzt nach Unterbrechungen von selbst fort.
- Meldet sich per Mitteilung, wenn Dateien nicht gesichert werden konnten oder seit Tagen kein Backup geklappt hat.

Es ist ein Daten-Backup, kein startfähiges Abbild des Systems. Nach einem Totalausfall installierst du macOS neu und holst deine Daten zurück. Eine Liste der installierten Programme wird dafür mitgesichert.

## Voraussetzungen

- macOS 12 oder neuer (Vorgabe der aktuellen rclone-Version)
- ein pCloud-Konto mit genug freiem Speicher für die Datenmenge plus Reserve fürs Archiv
- Internetverbindung; für das erste Backup je nach Datenmenge und Upload-Geschwindigkeit Stunden bis Tage

## Einrichten

Die Datei `pcloud-backup.sh` aus diesem Repository herunterladen und im Terminal starten:

```bash
bash ~/Downloads/pcloud-backup.sh einrichten
```

Die Einrichtung führt durch fünf Schritte:

1. **rclone laden.** Das Skript holt die aktuelle Version von rclone.org, prüft ihre SHA-256-Prüfsumme und legt sie unter `~/.pcloud-backup/bin/rclone` ab.
2. **pCloud verbinden.** Erst im Browser bei pCloud anmelden, danach auf der Freigabe-Seite nur noch auf „Allow" klicken.
3. **Verschlüsselungspasswort vergeben** (mindestens 12 Zeichen).
4. **Festplattenvollzugriff erteilen.** Die Datei `rclone` in die Liste unter Systemeinstellungen > Datenschutz & Sicherheit > Festplattenvollzugriff ziehen. Das Skript öffnet beide Fenster und prüft, ob der Zugriff wirkt.
5. **Zeitplan aktivieren** und auf Wunsch gleich das erste Backup starten.

> **Das Verschlüsselungspasswort ist der einzige Schlüssel zum Backup.** Bewahre es außerhalb des Macs auf, im Passwortmanager oder auf Papier. Ohne das Passwort lässt sich nichts wiederherstellen.

Nach der Einrichtung liegt das Skript unter `~/.pcloud-backup/pcloud-backup.sh`. Die Datei in den Downloads kann gelöscht werden.

## Befehle

Aufruf jeweils als `~/.pcloud-backup/pcloud-backup.sh <Befehl>`.

| Befehl | Wirkung |
| --- | --- |
| `status` | letzter Lauf, nächster Lauf, nicht gesicherte Einträge |
| `jetzt` | sofort ein Backup starten, auch im Akkubetrieb |
| `pause` / `weiter` | Backups anhalten (etwa am Handy-Hotspot) und fortsetzen |
| `vorschau` | zählen, wie viele Dateien und wie viel Speicher gesichert würden |
| `liste [Pfad]` | Inhalt des Backups anzeigen |
| `archiv [Stand] [Pfad]` | ältere Stände anzeigen |
| `wiederherstellen <Pfad> <Zielordner> [Stand]` | Dateien oder Ordner zurückholen |
| `test` | Selbsttest: pCloud, Verschlüsselung, Zeitplan, Festplattenvollzugriff |
| `aktualisieren` | rclone auf die neueste Version bringen |
| `einrichten` | Einrichtung starten oder wiederholen (vorhandene Schritte werden übersprungen) |
| `einrichten nur-verbinden` | nur verbinden, ohne Zeitplan, zum Wiederherstellen auf einem anderen Mac |
| `entfernen` | Zeitplan entfernen; Daten und Einstellungen bleiben |

## Wiederherstellen

Einzelne Datei oder ganzer Ordner aus dem aktuellen Stand:

```bash
~/.pcloud-backup/pcloud-backup.sh liste Documents
~/.pcloud-backup/pcloud-backup.sh wiederherstellen Documents/Steuer ~/Desktop/zurueck
```

Eine ältere Fassung einer geänderten oder gelöschten Datei:

```bash
~/.pcloud-backup/pcloud-backup.sh archiv                          # vorhandene Stände
~/.pcloud-backup/pcloud-backup.sh archiv 2026-10-11_1317 Documents  # Inhalt eines Stands
~/.pcloud-backup/pcloud-backup.sh wiederherstellen Documents/brief.txt ~/Desktop/zurueck 2026-10-11_1317
```

Ein Stand enthält die vorherige Fassung der Dateien, die in diesem Lauf als geändert oder gelöscht erkannt wurden.

### Auf einem neuen Mac

```bash
bash ~/Downloads/pcloud-backup.sh einrichten nur-verbinden
~/.pcloud-backup/pcloud-backup.sh wiederherstellen Documents ~/Documents
```

Bei der Einrichtung dasselbe Verschlüsselungspasswort eingeben wie auf dem alten Mac. `nur-verbinden` legt keinen Zeitplan an. Das ist wichtig: Würde ein leerer neuer Mac sofort weitersichern, wanderte der bisherige Stand ins Archiv. Die normale Einrichtung erkennt ein vorhandenes Backup und fragt deshalb nach.

### Ohne dieses Skript

Das Backup ist ein gewöhnliches rclone-crypt-Ziel und lässt sich mit rclone allein öffnen:

```bash
rclone config create pcloud pcloud
rclone config create pcloud-backup crypt remote=pcloud:MacBook-Backup \
  password='DEIN-PASSWORT' filename_encryption=standard directory_name_encryption=true --obscure
rclone copy pcloud-backup:aktuell/Documents ~/Desktop/zurueck --links
```

## Was gesichert wird

Gesichert wird der gesamte Benutzerordner einschließlich `~/Library` (Mail, Fotos, Einstellungen). Ausgenommen sind:

- Papierkorb, Caches, Protokolle und andere Wegwerfdaten
- der Ordner „pCloud Drive" und `~/Library/CloudStorage` (Cloud-Ordner würden sich sonst selbst sichern)
- das Abbild der virtuellen Maschine von Docker Desktop
- Programme, Protokolle und Zustandsdateien des Backup-Werkzeugs selbst

Die Regeln stehen in `~/.pcloud-backup/ausschluss.txt` und lassen sich anpassen. Dort sind auch Zeilen für iCloud Drive, iPhone-Backups, virtuelle Maschinen und `node_modules` vorbereitet, die man bei Bedarf aktiviert.

In der pCloud entsteht diese Struktur:

```
MacBook-Backup/           verschlüsselt, Namen und Inhalte unlesbar
  aktuell/                Spiegel des Benutzerordners
  archiv/2026-10-11_1317/ geänderte und gelöschte Dateien dieses Laufs
```

## Einstellungen

Datei `~/.pcloud-backup/einstellungen.conf`. Änderungen gelten ab dem nächsten Lauf.

| Einstellung | Vorgabe | Bedeutung |
| --- | --- | --- |
| `QUELLE` | Benutzerordner | was gesichert wird |
| `INTERVALL_STUNDEN` | 48 | Abstand zwischen zwei Backups |
| `WIEDERHOLUNG_STUNDEN` | 6 | Wartezeit nach einem fehlgeschlagenen Lauf |
| `ARCHIV_TAGE` | 90 | Aufbewahrung geänderter und gelöschter Dateien; 0 = für immer |
| `NUR_AM_STROM` | 1 | nur am Netzteil starten |
| `SCHONEND` | 1 | mit niedriger Priorität arbeiten |
| `BANDBREITE` | leer | Upload begrenzen, z. B. `2M` oder `08:00,1M 23:00,off` |
| `UEBERTRAGUNGEN` | 4 | gleichzeitige Uploads |
| `FEHLER_TOLERANZ` | 20 | bis zu so vielen unlesbaren Einträgen gilt ein Lauf als abgeschlossen (mit Hinweis) |
| `WARNUNG_NACH_TAGEN` | 4 | Mitteilung, wenn so lange kein Backup geklappt hat |
| `MELDUNG_BEI_ERFOLG` | 0 | 1 = Mitteilung auch nach jedem erfolgreichen Lauf |
| `ZUSATZ_OPTIONEN` | leer | weitere rclone-Optionen, z. B. `--fast-list` |

## Wie es funktioniert

Alles liegt in `~/.pcloud-backup`. Zwei launchd-Jobs teilen sich die Arbeit:

- **Der Planer** ist dieses Skript. launchd startet es stündlich und nach der Anmeldung. Es prüft nur, ob ein Backup fällig ist: letzter erfolgreicher Lauf älter als das Intervall, Netzteil angeschlossen, pCloud erreichbar.
- **Der Sync-Job** ist rclone selbst. Der Planer lädt ihn bei Bedarf als eigenen launchd-Job, wartet auf das Ende und wertet Ergebnis und Protokoll aus.

Der Grund für diese Trennung ist der Festplattenvollzugriff. macOS vergibt ihn an das Programm, das launchd startet. Liefe rclone als Kindprozess eines Shell-Skripts, müsste man `/bin/bash` den Vollzugriff geben, und damit jedem Skript, das launchd je startet. So braucht ihn nur die eine Datei `~/.pcloud-backup/bin/rclone`.

Der Mac bleibt während eines Laufs wach, solange er aufgeklappt ist. Bei zugeklapptem Deckel ruht das Backup und wird danach fortgesetzt.

## Fehlerbehebung

**Browser zeigt „Failure! … No code returned by remote server".** pCloud hat den Browser ohne Freigabe zurückgeschickt. Zuerst unter my.pcloud.com anmelden, dann die Einrichtung wiederholen und auf der Freigabe-Seite nur „Allow" klicken. Hilft das nicht, die vom Skript angezeigte Adresse in einem anderen Browser öffnen.

**`status` zeigt „operation not permitted".** rclone fehlt der Festplattenvollzugriff. Mit `test` prüfen und `~/.pcloud-backup/bin/rclone` in den Systemeinstellungen eintragen.

**Nach `aktualisieren` fehlt der Zugriff wieder.** macOS bindet den Vollzugriff an die konkrete Programmdatei. Den Eintrag „rclone" entfernen, neu hinzufügen und mit `test` prüfen.

**Zeitplan „NICHT geladen".** `einrichten` erneut ausführen. Unter Systemeinstellungen > Allgemein > Anmeldeobjekte darf der Hintergrundeintrag nicht abgeschaltet sein.

**Es startet kein Backup.** `status` nennt den Grund: pausiert, Akkubetrieb oder noch nicht fällig. `jetzt` erzwingt einen Lauf.

**Einträge unter „Nicht gesichert".** Solange Dateien unlesbar sind, räumt rclone gelöschte Dateien nicht aus dem Spiegel. Entweder den Zugriff herstellen oder den Pfad in `ausschluss.txt` eintragen.

Protokolle liegen in `~/.pcloud-backup/logs`.

## Grenzen

- Gesichert wird nur der Benutzerordner des angemeldeten Benutzers, nicht das System und keine anderen Benutzer.
- Erweiterte Attribute wie Finder-Tags gehen verloren. Symbolische Links werden als `.rclonelink`-Dateien gespeichert und beim Wiederherstellen wieder zu Links.
- Mit „Mac-Speicher optimieren" liegen iCloud-Dateien und Fotos nur teilweise auf dem Mac. Gesichert wird, was lokal vorhanden ist; ausgelagerte iCloud-Dateien muss macOS zum Sichern erst herunterladen.
- Sehr lange Dateinamen können durch die Namensverschlüsselung die Längengrenze des Speichers überschreiten. Sie erscheinen dann unter „Nicht gesichert".
- Dateien, die sich während des Uploads ändern (Datenbanken geöffneter Programme), landen möglicherweise in einem Zwischenzustand im Backup.

## Sicherheit

- `~/.pcloud-backup/rclone.conf` enthält den pCloud-Zugang und das Verschlüsselungspasswort in einer Form, die sich zurückrechnen lässt. Die Datei nicht weitergeben und niemals in ein Repository legen.
- Das Skript selbst enthält keine Zugangsdaten.
- pCloud sieht nur verschlüsselte Namen und Inhalte, wohl aber Anzahl, Größe und Änderungszeit der Dateien.

## Entfernen

```bash
~/.pcloud-backup/pcloud-backup.sh entfernen
```

Das entfernt nur den Zeitplan. Wer alles loswerden will, löscht danach den Ordner `~/.pcloud-backup`, nimmt rclone aus dem Festplattenvollzugriff und löscht in der pCloud den Ordner „MacBook-Backup".

## Stand

Version 1.1, Oktober 2026. Das Skript ist bisher auf einem einzelnen Mac im Einsatz; der Ablauf wurde zusätzlich in einer Testumgebung mit nachgebautem launchd durchgespielt. Verlass dich erst darauf, wenn du selbst einmal testweise eine Datei zurückgeholt hast.

Dieses Projekt steht in keiner Verbindung zu pCloud oder zum rclone-Projekt.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Nutzung auf eigene Verantwortung.
