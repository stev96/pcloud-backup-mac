#!/bin/bash
# =============================================================================
#  pcloud-backup.sh – verschlüsseltes Backup des Benutzerordners nach pCloud
#
#  Einmalig einrichten:   bash ~/Downloads/pcloud-backup.sh einrichten
#  Danach:                ~/.pcloud-backup/pcloud-backup.sh status   (oder: hilfe)
#
#  Technik: rclone verschlüsselt und überträgt, launchd sorgt für den Zeitplan.
#
#  Alles liegt in ~/.pcloud-backup:
#    einstellungen.conf   Intervall, Bandbreite, Aufbewahrung …
#    ausschluss.txt       was nicht gesichert wird
#    rclone.conf          pCloud-Zugang und Schlüssel – nicht weitergeben
#    inventar/            Liste der installierten Programme (wird mitgesichert)
#    logs/                Protokolle
#
#  In der pCloud:
#    MacBook-Backup/      verschlüsselt (Namen und Inhalte sind dort unlesbar)
#      aktuell/           Spiegel des Benutzerordners
#      archiv/<Datum>/    geänderte und gelöschte Dateien des jeweiligen Laufs
#
#  Warum zwei launchd-Jobs?  macOS vergibt den „Festplattenvollzugriff" an das
#  Programm, das launchd startet. Ein Shell-Skript bekäme ihn nur über /bin/bash,
#  was viel zu breit wäre. Deshalb prüft der Planer (dieses Skript, stündlich)
#  nur, ob ein Backup fällig ist, und lässt rclone dann als eigenen launchd-Job
#  laufen. Den Vollzugriff braucht so nur ~/.pcloud-backup/bin/rclone.
# =============================================================================

set -u
umask 077

VERSION="1.1"

BASIS="$HOME/.pcloud-backup"
RCLONE="$BASIS/bin/rclone"
RCONF="$BASIS/rclone.conf"
EINST="$BASIS/einstellungen.conf"
AUSSCHLUSS="$BASIS/ausschluss.txt"
LOGS="$BASIS/logs"
JOBS="$BASIS/jobs"
ZUSTAND="$BASIS/zustand"
SKRIPT="$BASIS/pcloud-backup.sh"
# shellcheck disable=SC2088
KURZ="~/.pcloud-backup/pcloud-backup.sh"     # nur für die Anzeige

PLANER="de.pcloud-backup.planer"
SYNCJOB="de.pcloud-backup.sync"
TESTJOB="de.pcloud-backup.test"
PLANER_PLIST="$HOME/Library/LaunchAgents/$PLANER.plist"
DOMAIN="gui/$(id -u)"
RCLONE_QUELLE="${PCLOUD_BACKUP_RCLONE_URL:-https://downloads.rclone.org}"
NETZTEST="${PCLOUD_BACKUP_NETZTEST_URL:-https://api.pcloud.com/getapiserver}"

# --- Standardwerte (werden von einstellungen.conf überschrieben) -------------
QUELLE="$HOME"
INTERVALL_STUNDEN=48
WIEDERHOLUNG_STUNDEN=6
ARCHIV_TAGE=90
NUR_AM_STROM=1
SCHONEND=1
BANDBREITE=""
UEBERTRAGUNGEN=4
FEHLER_TOLERANZ=20
WARNUNG_NACH_TAGEN=4
MELDUNG_BEI_ERFOLG=0
ZUSATZ_OPTIONEN=""
REMOTE_BASIS="pcloud"
REMOTE_KRYPT="pcloud-backup"
ZIEL_ORDNER="MacBook-Backup"
ABFRAGE_SEKUNDEN=20

# shellcheck disable=SC1090
[ -f "$EINST" ] && . "$EINST"

JOB_RC=-1
JOB_INFO=""

# =============================================================================
#  Hilfsfunktionen
# =============================================================================

sag()     { printf '%s\n' "$*"; }
gut()     { printf '  ✓ %s\n' "$*"; }
schlecht(){ printf '  ✗ %s\n' "$*"; }
titel()   { printf '\n== %s ==\n' "$*"; }
abbruch() { printf '\nAbbruch: %s\n' "$*" >&2; exit 1; }

prot() {
  mkdir -p "$LOGS"
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGS/planer.log"
}

rc() { "$RCLONE" --config "$RCONF" "$@"; }

lies_zahl() {
  local v=""
  [ -f "$1" ] && read -r v < "$1" 2>/dev/null
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

zeit_text() {
  date -r "$1" '+%d.%m.%Y %H:%M' 2>/dev/null || date -d "@$1" '+%d.%m.%Y %H:%M'
}

dauer_text() {
  local s="$1"
  if   [ "$s" -ge 172800 ]; then echo "$((s / 86400)) Tagen"
  elif [ "$s" -ge 7200 ];   then echo "$((s / 3600)) Std."
  elif [ "$s" -ge 120 ];    then echo "$((s / 60)) Min."
  else echo "$s Sek."
  fi
}

tage_zurueck() {
  date -v-"$1"d '+%Y%m%d' 2>/dev/null || date -d "$1 days ago" '+%Y%m%d'
}

xml() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'
  fi
}

am_strom() {
  command -v pmset >/dev/null 2>&1 || return 0
  pmset -g batt 2>/dev/null | grep -q "AC Power"
}

melden() {
  command -v osascript >/dev/null 2>&1 || return 0
  LC_ALL=en_US.UTF-8 osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "pCloud-Backup"' \
    -e 'end run' "$1" >/dev/null 2>&1 || true
}

frage_jn() {   # $1 = Frage, $2 = Vorgabe (j/n)
  local a=""
  read -r -p "$1 " a || a=""
  [ -n "$a" ] || a="$2"
  case "$a" in j|J|y|Y|ja|Ja) return 0 ;; *) return 1 ;; esac
}

eingerichtet() {
  [ -x "$RCLONE" ] && [ -f "$RCONF" ] && [ -f "$AUSSCHLUSS" ] &&
    rc listremotes 2>/dev/null | grep -qx "$REMOTE_KRYPT:"
}

muss_eingerichtet_sein() {
  eingerichtet || abbruch "Noch nicht eingerichtet. Bitte zuerst:  bash $0 einrichten"
}

# =============================================================================
#  launchd: rclone als eigenen Job ausführen
# =============================================================================

plist_kopf() {
  cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
EOF
}

job_plist() {   # $1 Datei, $2 Label, $3 Ausgabedatei, $4 schonend (1/0), Rest: Programm + Argumente
  local datei="$1" label="$2" aus="$3" schonend="$4" a
  shift 4
  {
    plist_kopf
    printf '  <key>Label</key>\n  <string>%s</string>\n' "$label"
    printf '  <key>ProgramArguments</key>\n  <array>\n'
    for a in "$@"; do printf '    <string>%s</string>\n' "$(xml "$a")"; done
    printf '  </array>\n'
    if [ "$schonend" = 1 ]; then
      printf '  <key>ProcessType</key>\n  <string>Background</string>\n'
    fi
    printf '  <key>StandardOutPath</key>\n  <string>%s</string>\n' "$(xml "$aus")"
    printf '  <key>StandardErrorPath</key>\n  <string>%s</string>\n' "$(xml "$aus")"
    printf '</dict>\n</plist>\n'
  } > "$datei"
  chmod 600 "$datei"
}

job_aktiv() {   # $1 Label
  local info
  info=$(launchctl print "$DOMAIN/$1" 2>/dev/null) || return 1
  case "$info" in
    *"state = running"*|*"state = spawn scheduled"*) return 0 ;;
  esac
  printf '%s\n' "$info" | grep -q '^[[:space:]]*pid = [0-9]' && return 0
  return 1
}

job_rc_lesen() {   # liest die Ausgabe von "launchctl print" von stdin
  awk '
    /last terminating signal/ { signal = 1 }
    /last exit code = [0-9]/  { s = $0; sub(/.*last exit code = /, "", s); sub(/[^0-9].*/, "", s); code = s }
    END {
      if (signal)          print 143
      else if (code != "") print code
      else                 print -1
    }'
}

job_stoppen() {   # $1 Label
  launchctl bootout "$DOMAIN/$1" >/dev/null 2>&1
}

# Führt rclone mit den übergebenen Argumenten als launchd-Job aus und wartet.
# Ergebnis: JOB_RC (Exit-Code, -1 = unbekannt/abgebrochen)
job_ausfuehren() {   # $1 Label, $2 Ausgabedatei, $3 schonend, Rest: rclone-Argumente
  local label="$1" aus="$2" schonend="$3" plist ausgabe pid i
  shift 3
  JOB_RC=-1
  JOB_INFO=""
  mkdir -p "$JOBS" "$LOGS"
  plist="$JOBS/$label.plist"
  job_plist "$plist" "$label" "$aus" "$schonend" "$RCLONE" "$@"

  job_stoppen "$label"
  i=0
  until ausgabe=$(launchctl bootstrap "$DOMAIN" "$plist" 2>&1); do
    i=$((i + 1))
    if [ "$i" -ge 10 ]; then
      JOB_INFO="launchctl bootstrap: $ausgabe"
      return 1
    fi
    sleep 1
  done

  if ! ausgabe=$(launchctl kickstart -p "$DOMAIN/$label" 2>&1); then
    JOB_INFO="launchctl kickstart: $ausgabe"
    job_stoppen "$label"
    return 1
  fi
  pid=$(printf '%s\n' "$ausgabe" | sed -n 's/.*pid:* *\([0-9][0-9]*\).*/\1/p' | head -1)
  if [ -n "$pid" ] && command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i -w "$pid" >/dev/null 2>&1 &
  fi

  while job_aktiv "$label"; do sleep "$ABFRAGE_SEKUNDEN"; done

  JOB_INFO=$(launchctl print "$DOMAIN/$label" 2>/dev/null)
  JOB_RC=$(printf '%s\n' "$JOB_INFO" | job_rc_lesen)
  job_stoppen "$label"
  return 0
}

# Prüft, ob der von launchd gestartete rclone geschützte Ordner lesen darf.
# 0 = ja, 1 = nein, 2 = nicht prüfbar
zugriffstest() {
  local probe="" p alt="$ABFRAGE_SEKUNDEN"
  for p in "$HOME/Library/Application Support/com.apple.TCC" "$HOME/Library/Safari" "$HOME/Library/Mail"; do
    if [ -d "$p" ]; then probe="$p"; break; fi
  done
  [ -n "$probe" ] || return 2
  ABFRAGE_SEKUNDEN=1
  job_ausfuehren "$TESTJOB" /dev/null 0 lsf --config "$RCONF" --max-depth 1 "$probe"
  ABFRAGE_SEKUNDEN="$alt"
  [ "$JOB_RC" = 0 ]
}

# Prüft, ob launchd Exit-Codes so zurückmeldet, wie dieses Skript sie erwartet.
mechaniktest() {
  local alt="$ABFRAGE_SEKUNDEN" a b
  ABFRAGE_SEKUNDEN=1
  job_ausfuehren "$TESTJOB" /dev/null 0 version
  a="$JOB_RC"
  job_ausfuehren "$TESTJOB" /dev/null 0 lsf --config "$RCONF" "/pcloud-backup-gibt-es-nicht"
  b="$JOB_RC"
  ABFRAGE_SEKUNDEN="$alt"
  [ "$a" = 0 ] && [ "$b" -gt 0 ]
}

# =============================================================================
#  Der eigentliche Backup-Lauf
# =============================================================================

sperre_holen() {
  local d="$ZUSTAND/sperre" alt
  mkdir -p "$ZUSTAND"
  if mkdir "$d" 2>/dev/null; then echo $$ > "$d/pid"; return 0; fi
  alt=$(lies_zahl "$d/pid")
  if [ "$alt" -gt 0 ] && kill -0 "$alt" 2>/dev/null &&
     ps -p "$alt" -o command= 2>/dev/null | grep -q "pcloud-backup"; then
    return 1
  fi
  rm -rf "$d"
  mkdir "$d" 2>/dev/null || return 1
  echo $$ > "$d/pid"
}

sperre_freigeben() { rm -rf "$ZUSTAND/sperre"; }

warnen_wenn_ueberfaellig() {   # $1 = Grund
  local jetzt bezug letzte tage
  jetzt=$(date +%s)
  bezug=$(lies_zahl "$ZUSTAND/letzter_erfolg")
  [ "$bezug" -gt 0 ] || bezug=$(lies_zahl "$ZUSTAND/eingerichtet")
  [ "$bezug" -gt 0 ] || return 0
  tage=$(( (jetzt - bezug) / 86400 ))
  [ "$tage" -ge "$WARNUNG_NACH_TAGEN" ] || return 0
  letzte=$(lies_zahl "$ZUSTAND/letzte_warnung")
  [ $((jetzt - letzte)) -ge 86400 ] || return 0
  echo "$jetzt" > "$ZUSTAND/letzte_warnung"
  melden "Seit $tage Tagen kein vollständiges Backup. $1"
}

schreibe_wenn_anders() {   # $1 = Zieldatei, Inhalt von stdin
  local neu="$1.neu"
  cat > "$neu"
  if [ -f "$1" ] && cmp -s "$neu" "$1"; then rm -f "$neu"; else mv -f "$neu" "$1"; fi
}

inventar_schreiben() {
  local d="$BASIS/inventar" brew
  mkdir -p "$d"
  {
    command -v sw_vers >/dev/null 2>&1 && sw_vers
    uname -m
  } 2>/dev/null | schreibe_wenn_anders "$d/system.txt"
  {
    ls -1 /Applications 2>/dev/null
    [ -d "$HOME/Applications" ] && ls -1 "$HOME/Applications" 2>/dev/null
  } | schreibe_wenn_anders "$d/programme.txt"
  for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$brew" ]; then
      HOMEBREW_NO_AUTO_UPDATE=1 "$brew" leaves      2>/dev/null | schreibe_wenn_anders "$d/homebrew-pakete.txt"
      HOMEBREW_NO_AUTO_UPDATE=1 "$brew" list --cask 2>/dev/null | schreibe_wenn_anders "$d/homebrew-casks.txt"
      break
    fi
  done
  return 0
}

probleme_im_log() {   # $1 = Logdatei → eine Zeile pro betroffener Datei/Ordner
  [ -f "$1" ] || return 0
  grep ' ERROR : ' "$1" |
    grep -v -e 'not deleting' -e 'Attempt [0-9]*/[0-9]* ' |
    sed -e 's/^.* ERROR : //'
}

probleme_kurz() {   # $1 = Logdatei → "Pfad (Grund)"
  probleme_im_log "$1" | awk '{
    i = index($0, ": ")
    if (i == 0) { print; next }
    pfad = substr($0, 1, i - 1); rest = $0
    while ((j = index(rest, ": ")) > 0) rest = substr(rest, j + 2)
    print pfad " (" rest ")"
  }'
}

archiv_aufraeumen() {
  local grenze name tag
  case "$ARCHIV_TAGE" in ''|*[!0-9]*|0) return 0 ;; esac
  grenze=$(tage_zurueck "$ARCHIV_TAGE") || return 0
  case "$grenze" in ''|*[!0-9]*) return 0 ;; esac
  rc lsf --dirs-only "$REMOTE_KRYPT:archiv" 2>/dev/null | while IFS= read -r name; do
    name="${name%/}"
    case "$name" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9]) ;;
      *) continue ;;
    esac
    tag="${name:0:4}${name:5:2}${name:8:2}"
    if [ "$tag" -lt "$grenze" ]; then
      if rc purge "$REMOTE_KRYPT:archiv/$name" >/dev/null 2>&1; then
        prot "Archiv $name entfernt (älter als $ARCHIV_TAGE Tage)"
      fi
    fi
  done
}

logs_aufraeumen() {
  find "$LOGS" -name 'lauf-*.log' -mtime +60 -exec rm -f {} + 2>/dev/null
  local f
  for f in "$LOGS/planer.log" "$LOGS/planer-ausgabe.log" "$LOGS/job-ausgabe.log"; do
    if [ -f "$f" ] && [ "$(wc -c < "$f" | tr -d ' ')" -gt 1000000 ]; then
      tail -n 2000 "$f" > "$f.neu" && mv -f "$f.neu" "$f"
    fi
  done
  return 0
}

backup_lauf() {
  local start ende laufid log args w rc_code probleme kritisch ergebnis menge text dauer
  start=$(date +%s)
  laufid=$(date '+%Y-%m-%d_%H%M')
  log="$LOGS/lauf-$laufid.log"
  echo "$start" > "$ZUSTAND/letzter_versuch"

  if [ ! -d "$QUELLE" ]; then
    prot "FEHLER: Quelle $QUELLE nicht gefunden"
    warnen_wenn_ueberfaellig "Der Quellordner wurde nicht gefunden."
    return 1
  fi

  inventar_schreiben
  logs_aufraeumen

  args=(sync "$QUELLE" "$REMOTE_KRYPT:aktuell"
        --config "$RCONF"
        --exclude-from "$AUSSCHLUSS"
        --backup-dir "$REMOTE_KRYPT:archiv/$laufid"
        --links --one-file-system --local-no-check-updated
        --transfers "$UEBERTRAGUNGEN" --retries 1 --low-level-retries 10
        --log-file "$log" --log-level NOTICE
        --stats 5m --stats-one-line --stats-log-level NOTICE)
  [ -n "$BANDBREITE" ] && args+=(--bwlimit "$BANDBREITE")
  if [ -n "$ZUSATZ_OPTIONEN" ]; then
    set -f
    for w in $ZUSATZ_OPTIONEN; do args+=("$w"); done
    set +f
  fi

  prot "Backup $laufid gestartet"
  echo "$laufid" > "$ZUSTAND/laeuft"
  job_ausfuehren "$SYNCJOB" "$LOGS/job-ausgabe.log" "$SCHONEND" "${args[@]}"
  rc_code="$JOB_RC"
  rm -f "$ZUSTAND/laeuft"
  ende=$(date +%s)

  probleme=$(probleme_im_log "$log" | wc -l | tr -d ' ')
  kritisch=0
  [ -f "$log" ] && grep -q ' CRITICAL: ' "$log" && kritisch=1
  menge=""
  [ -f "$log" ] && menge=$(grep ', ETA ' "$log" | tail -1 | sed -e 's/^.*NOTICE: *//' -e 's/,.*$//')

  if [ "$rc_code" = 0 ]; then
    ergebnis="OK"
  elif [ "$rc_code" -lt 0 ]; then
    ergebnis="ABGEBROCHEN"
  elif [ "$rc_code" -gt 0 ] && [ "$kritisch" = 0 ] &&
       [ "$probleme" -gt 0 ] && [ "$probleme" -le "$FEHLER_TOLERANZ" ] &&
       grep -q 'Failed to sync with [0-9]* errors' "$log" 2>/dev/null; then
    ergebnis="TEILWEISE"
  else
    ergebnis="FEHLER"
  fi

  dauer=$(dauer_text "$((ende - start))")
  text=$(printf '%s  %-11s  Dauer %-9s  Probleme: %-3s  übertragen: %s' \
           "$laufid" "$ergebnis" "$dauer" "$probleme" "${menge:-–}")
  [ "$ergebnis" = FEHLER ] && text="$text  (Code $rc_code)"
  echo "$text" >> "$ZUSTAND/verlauf.log"
  prot "Backup $laufid beendet: $ergebnis (Code $rc_code, Probleme: $probleme)"

  case "$ergebnis" in
    OK)
      echo "$start" > "$ZUSTAND/letzter_erfolg"
      rm -f "$ZUSTAND/letzte_warnung"
      archiv_aufraeumen
      [ "$MELDUNG_BEI_ERFOLG" = 1 ] && melden "Backup abgeschlossen (${menge:-keine Änderungen})."
      ;;
    TEILWEISE)
      echo "$start" > "$ZUSTAND/letzter_erfolg"
      rm -f "$ZUSTAND/letzte_warnung"
      archiv_aufraeumen
      melden "Backup fertig, aber nicht alles ließ sich sichern (Probleme: $probleme). Details: pcloud-backup.sh status"
      ;;
    ABGEBROCHEN)
      if [ -f "$ZUSTAND/pausiert" ]; then
        # Nach einer bewussten Pause soll "weiter" sofort wieder anlaufen.
        rm -f "$ZUSTAND/letzter_versuch"
      else
        prot "launchd: $(printf '%s\n' "$JOB_INFO" | grep -i -e 'launchctl' -e 'state' -e 'exit' -e 'signal' | tr -s '\t\n' '  ')"
      fi
      ;;
    *)
      warnen_wenn_ueberfaellig "Der letzte Lauf ist fehlgeschlagen. Details: pcloud-backup.sh status"
      ;;
  esac
  return 0
}

cmd_auto() {
  eingerichtet || exit 0
  mkdir -p "$ZUSTAND" "$LOGS"
  sperre_holen || exit 0
  trap sperre_freigeben EXIT

  local erzwungen=0 jetzt erfolg versuch
  if [ -f "$ZUSTAND/erzwingen" ]; then
    erzwungen=1
    rm -f "$ZUSTAND/erzwingen"
  fi
  [ -f "$ZUSTAND/pausiert" ] && exit 0

  jetzt=$(date +%s)
  erfolg=$(lies_zahl "$ZUSTAND/letzter_erfolg")
  versuch=$(lies_zahl "$ZUSTAND/letzter_versuch")

  # Wurde der letzte Lauf mittendrin unterbrochen (Neustart, Abmeldung), geht es
  # ohne Wartezeit weiter – rclone überspringt, was schon oben ist.
  if [ -f "$ZUSTAND/laeuft" ] && ! job_aktiv "$SYNCJOB"; then
    rm -f "$ZUSTAND/laeuft"
    versuch=0
  fi

  if [ "$erzwungen" = 0 ]; then
    # 30 Minuten Spielraum, damit sich der Rhythmus nicht jede Runde verschiebt
    [ $((jetzt - erfolg))  -lt $((INTERVALL_STUNDEN * 3600 - 1800)) ]   && exit 0
    [ $((jetzt - versuch)) -lt $((WIEDERHOLUNG_STUNDEN * 3600 - 1800)) ] && exit 0
    if [ "$NUR_AM_STROM" = 1 ] && ! am_strom; then
      warnen_wenn_ueberfaellig "Das MacBook war bei jeder Prüfung im Akkubetrieb."
      exit 0
    fi
  fi

  job_aktiv "$SYNCJOB" && exit 0

  if ! rc lsd "$REMOTE_BASIS:" --max-depth 1 --contimeout 15s --timeout 30s \
         --retries 1 --low-level-retries 1 >/dev/null 2>&1; then
    warnen_wenn_ueberfaellig "pCloud ist nicht erreichbar (Internet oder Anmeldung prüfen)."
    exit 0
  fi

  backup_lauf
}

# =============================================================================
#  Einrichtung
# =============================================================================

rclone_laden() {
  local sys arch ver datei tmp soll ist
  case "$(uname -s)" in Darwin) sys=osx ;; Linux) sys=linux ;; *) return 1 ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) return 1 ;; esac
  ver=$(curl -fsSL "$RCLONE_QUELLE/version.txt" 2>/dev/null |
        sed -n 's/^rclone \(v[0-9][0-9.]*\).*/\1/p' | head -1)
  [ -n "$ver" ] || return 1
  datei="rclone-$ver-$sys-$arch.zip"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/pcloud-backup.XXXXXX") || return 1
  if curl -fsSL -o "$tmp/$datei" "$RCLONE_QUELLE/$ver/$datei" &&
     curl -fsSL -o "$tmp/SHA256SUMS" "$RCLONE_QUELLE/$ver/SHA256SUMS"; then
    soll=$(awk -v f="$datei" '$2 == f { print $1; exit }' "$tmp/SHA256SUMS")
    ist=$(sha256 "$tmp/$datei")
    if [ -n "$soll" ] && [ "$soll" = "$ist" ]; then
      if unzip -q -o "$tmp/$datei" -d "$tmp/aus" 2>/dev/null &&
         [ -f "$tmp/aus/rclone-$ver-$sys-$arch/rclone" ]; then
        mkdir -p "$BASIS/bin"
        cp "$tmp/aus/rclone-$ver-$sys-$arch/rclone" "$RCLONE.neu" &&
          chmod 755 "$RCLONE.neu" && mv -f "$RCLONE.neu" "$RCLONE" &&
          { rm -rf "$tmp"; return 0; }
      fi
    else
      schlecht "Prüfsumme von $datei stimmt nicht – Download verworfen."
    fi
  fi
  rm -rf "$tmp"
  return 1
}

rclone_bereitstellen() {
  local vorhanden
  if [ -x "$RCLONE" ]; then
    gut "rclone ist vorhanden ($("$RCLONE" version 2>/dev/null | head -1))"
    return 0
  fi
  sag "  Lade rclone von rclone.org …"
  if rclone_laden; then
    gut "rclone installiert ($("$RCLONE" version 2>/dev/null | head -1))"
    return 0
  fi
  vorhanden=$(command -v rclone 2>/dev/null || true)
  if [ -n "$vorhanden" ]; then
    mkdir -p "$BASIS/bin"
    cp -L "$vorhanden" "$RCLONE" && chmod 755 "$RCLONE"
    gut "Download nicht möglich – vorhandenes rclone übernommen ($vorhanden)"
    return 0
  fi
  abbruch "rclone konnte nicht geladen werden. Internetverbindung prüfen und erneut versuchen."
}

einstellungen_schreiben() {
  [ -f "$EINST" ] && return 0
  cat > "$EINST" <<EOF
# Einstellungen für das pCloud-Backup. Änderungen gelten ab dem nächsten Lauf.

QUELLE="$HOME"            # was gesichert wird
INTERVALL_STUNDEN=48      # Abstand zwischen zwei Backups (48 = alle 2 Tage)
WIEDERHOLUNG_STUNDEN=6    # nach einem Fehlschlag frühestens nach … Stunden erneut
ARCHIV_TAGE=90            # geänderte/gelöschte Dateien so lange aufbewahren (0 = für immer)
NUR_AM_STROM=1            # 1 = nur am Netzteil starten
SCHONEND=1                # 1 = mit niedriger Priorität im Hintergrund arbeiten
BANDBREITE=""             # Upload begrenzen, z. B. "2M" oder "08:00,1M 23:00,off"
UEBERTRAGUNGEN=4          # gleichzeitige Uploads
FEHLER_TOLERANZ=20        # so viele unlesbare Einträge gelten noch als "fertig mit Hinweis"
WARNUNG_NACH_TAGEN=4      # Mitteilung, wenn so lange kein Backup geklappt hat
MELDUNG_BEI_ERFOLG=0      # 1 = auch nach jedem erfolgreichen Lauf eine Mitteilung
ZUSATZ_OPTIONEN=""        # weitere rclone-Optionen, z. B. "--fast-list"
EOF
}

ausschluss_schreiben() {
  [ -f "$AUSSCHLUSS" ] && return 0
  cat > "$AUSSCHLUSS" <<'EOF'
# Ausschlussliste für das pCloud-Backup
# Eine Regel pro Zeile, Pfade relativ zum Benutzerordner.
#   /Ordner/**   schließt genau diesen Ordner samt Inhalt aus
#   Name/**      schließt jeden Ordner mit diesem Namen aus, egal wo
# Zeilen mit # sind Kommentare. Änderungen gelten ab dem nächsten Lauf.

# --- Cloud-Ordner -----------------------------------------------------------
# pCloud Drive würde sich sonst selbst in die pCloud sichern.
/pCloud Drive/**
/pCloudDrive/**
/.pcloud/**
/Library/CloudStorage/**
# iCloud Drive wird mitgesichert. Ist dort "Mac-Speicher optimieren" aktiv,
# lädt das Backup ausgelagerte Dateien erst herunter. Dann nächste Zeile aktivieren:
#/Library/Mobile Documents/**

# --- Papierkorb, Caches, Protokolle, Wegwerfdaten ---------------------------
/.Trash/**
/.cache/**
/.npm/**
/Library/Caches/**
/Library/Logs/**
/Library/Saved Application State/**
/Library/Containers/*/Data/Library/Caches/**
/Library/Containers/*/Data/Library/Logs/**
/Library/Containers/*/Data/tmp/**
/Library/Group Containers/*/Library/Caches/**
/Library/Application Support/CrashReporter/**
/Library/Application Support/FileProvider/**
/Library/Metadata/CoreSpotlight/**
/Library/Biome/**
/Library/DuetExpertCenter/**
/Library/Trial/**
/Library/HTTPStorages/**
/Library/Developer/Xcode/DerivedData/**
/Library/Developer/CoreSimulator/**
Cache/**
Caches/**
GPUCache/**
Code Cache/**
CacheStorage/**
.DS_Store

# --- Das Backup-Werkzeug selbst (Einstellungen und Inventar bleiben drin) ----
/.pcloud-backup/bin/**
/.pcloud-backup/logs/**
/.pcloud-backup/jobs/**
/.pcloud-backup/zustand/**

# --- Große Dateien, die sich ständig ändern ---------------------------------
/Library/Containers/com.docker.docker/Data/vms/**
# Bei Bedarf aktivieren:
#/Parallels/**
#/Virtual Machines.localized/**
#/Library/Application Support/MobileSync/Backup/**
#node_modules/**
EOF
}

internet_da() {
  curl -fsS -m 10 -o /dev/null "$NETZTEST" 2>/dev/null
}

pcloud_anmelden() {
  local a
  while :; do
    cat <<EOF
  Die Anmeldung läuft in zwei Schritten, so klappt sie am zuverlässigsten:
    1. Gleich öffnet sich pCloud im Browser. Melde dich dort wie gewohnt an.
    2. Danach fragt eine zweite Seite, ob "rclone" auf deine pCloud zugreifen darf.
       Dort nur noch auf "Allow" bzw. "Erlauben" klicken.

EOF
    open "https://my.pcloud.com/" >/dev/null 2>&1
    read -r -p "  Bist du im Browser bei pCloud angemeldet? Dann hier Enter drücken: " a ||
      abbruch "Keine Eingabe."
    # rclone meldet sich auf stderr; davon ist nur die Adresse der Anmeldeseite interessant
    rc config create "$REMOTE_BASIS" pcloud 2>&1 >/dev/null |
      sed -n 's/^.*go to the following link: /  Öffnet sich keine Seite? Dann diese Adresse im Browser aufrufen: /p'
    if rc listremotes 2>/dev/null | grep -qx "$REMOTE_BASIS:" &&
       rc lsd "$REMOTE_BASIS:" --max-depth 1 >/dev/null 2>&1; then
      return 0
    fi
    rc config delete "$REMOTE_BASIS" >/dev/null 2>&1
    schlecht "Die Anmeldung ist nicht angekommen: pCloud hat den Browser ohne Freigabe zurückgeschickt."
    sag "    Das passiert, wenn auf der Freigabe-Seite abgelehnt oder die Seite geschlossen wurde,"
    sag "    und manchmal auch, wenn man sich erst dort anmeldet statt vorher in Schritt 1."
    sag "    Die Adresse oben lässt sich auch in einem anderen Browser öffnen."
    frage_jn "  Noch einmal versuchen? [J/n]" j ||
      abbruch "Die Anmeldung bei pCloud wurde nicht abgeschlossen."
  done
}

pcloud_verbinden() {
  if rc listremotes 2>/dev/null | grep -qx "$REMOTE_BASIS:"; then
    if rc lsd "$REMOTE_BASIS:" --max-depth 1 >/dev/null 2>&1; then
      gut "pCloud ist bereits verbunden"
      return 0
    fi
    internet_da ||
      abbruch "pCloud ist nicht erreichbar. Internetverbindung prüfen und 'einrichten' erneut starten."
    sag "  Die gespeicherte pCloud-Anmeldung funktioniert nicht mehr. Bitte neu anmelden."
    rc config delete "$REMOTE_BASIS" >/dev/null 2>&1
  fi
  pcloud_anmelden
  gut "Verbindung zu pCloud funktioniert"
}

passwort_passt() {
  # Liegen im Zielordner schon Daten, müssen sie sich mit dem Passwort entschlüsseln lassen.
  local roh klar
  roh=$(rc lsf "$REMOTE_BASIS:$ZIEL_ORDNER" --max-depth 1 2>/dev/null | head -1)
  [ -n "$roh" ] || return 0
  klar=$(rc lsf "$REMOTE_KRYPT:" --max-depth 1 2>/dev/null | head -1)
  [ -n "$klar" ]
}

verschluesselung_einrichten() {
  local p1 p2 obs
  if rc listremotes 2>/dev/null | grep -qx "$REMOTE_KRYPT:"; then
    gut "Verschlüsselung ist bereits eingerichtet"
    return 0
  fi
  cat <<EOF
  Das Backup wird auf dem Mac verschlüsselt, bevor es hochgeladen wird.
  Dafür brauchst du ein eigenes Passwort (mindestens 12 Zeichen).

  WICHTIG: Dieses Passwort ist der einzige Schlüssel zum Backup. Schreib es in
  deinen Passwortmanager oder auf Papier, also an einen Ort außerhalb dieses
  MacBooks. Ohne das Passwort ist das Backup nicht wiederherstellbar.

EOF
  while :; do
    read -r -s -p "  Verschlüsselungspasswort: " p1 || abbruch "Keine Eingabe."
    echo
    read -r -s -p "  Passwort wiederholen:     " p2 || abbruch "Keine Eingabe."
    echo
    if [ "$p1" != "$p2" ]; then schlecht "Die Eingaben stimmen nicht überein."; continue; fi
    if [ "${#p1}" -lt 12 ];  then schlecht "Bitte mindestens 12 Zeichen.";       continue; fi
    obs=$(printf '%s' "$p1" | "$RCLONE" obscure -) || abbruch "rclone obscure fehlgeschlagen."
    rc config create "$REMOTE_KRYPT" crypt \
       remote="$REMOTE_BASIS:$ZIEL_ORDNER" password="$obs" \
       filename_encryption=standard directory_name_encryption=true \
       --no-obscure >/dev/null || abbruch "Verschlüsselung konnte nicht eingerichtet werden."
    if passwort_passt; then break; fi
    rc config delete "$REMOTE_KRYPT" >/dev/null 2>&1
    schlecht "In der pCloud liegt schon ein Backup, das sich mit diesem Passwort nicht öffnen lässt."
  done
  p1=""; p2=""; obs=""
  chmod 600 "$RCONF" 2>/dev/null
  gut "Verschlüsselung eingerichtet (Ordner \"$ZIEL_ORDNER\" in der pCloud)"
}

zugriff_einrichten() {
  local a st
  zugriffstest; st=$?
  if [ "$st" = 0 ]; then gut "Festplattenvollzugriff für rclone ist aktiv"; return 0; fi
  if [ "$st" = 2 ]; then sag "  (Kein geschützter Ordner zum Prüfen gefunden – Schritt übersprungen.)"; return 0; fi
  cat <<EOF
  rclone braucht "Festplattenvollzugriff". Ohne ihn fehlen im Backup Mail,
  Fotos, Safari, Nachrichten und weitere Teile der Library.

  Es öffnen sich jetzt zwei Fenster:
    - Systemeinstellungen > Datenschutz & Sicherheit > Festplattenvollzugriff
    - ein Finder-Fenster, in dem die Datei "rclone" markiert ist
  Zieh die Datei "rclone" aus dem Finder in die Liste und schalte sie ein.
  (Alternativ: "+" klicken, Cmd+Shift+G drücken, eingeben: ~/.pcloud-backup/bin/rclone)

EOF
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" >/dev/null 2>&1
  open -R "$RCLONE" >/dev/null 2>&1
  while :; do
    read -r -p "  Erledigt? Enter drücken (oder s = überspringen): " a || a="s"
    case "$a" in s|S)
      schlecht "Übersprungen. Geschützte Ordner fehlen im Backup, bis der Zugriff erteilt ist."
      sag "    Später nachholen und prüfen mit:  $KURZ test"
      return 0 ;;
    esac
    if zugriffstest; then gut "Festplattenvollzugriff für rclone ist aktiv"; return 0; fi
    schlecht "rclone hat noch keinen Zugriff. Steht \"rclone\" in der Liste und ist eingeschaltet?"
  done
}

planer_plist_schreiben() {
  local minute
  minute=$((10#$(date +%M)))
  mkdir -p "$HOME/Library/LaunchAgents"
  {
    plist_kopf
    cat <<EOF
  <key>Label</key>
  <string>$PLANER</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml "$SKRIPT")</string>
    <string>auto</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Minute</key>
    <integer>$minute</integer>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$(xml "$LOGS/planer-ausgabe.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml "$LOGS/planer-ausgabe.log")</string>
</dict>
</plist>
EOF
  } > "$PLANER_PLIST"
  chmod 644 "$PLANER_PLIST"
}

planer_laden() {
  local i=0
  launchctl bootout "$DOMAIN/$PLANER" >/dev/null 2>&1
  until launchctl bootstrap "$DOMAIN" "$PLANER_PLIST" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -ge 10 ] && return 1
    sleep 1
  done
  return 0
}

cmd_einrichten() {
  local nur_verbinden=0
  [ "${1:-}" = "nur-verbinden" ] && nur_verbinden=1

  sag "pCloud-Backup $VERSION – Einrichtung"
  if [ "$(id -u)" = 0 ] && [ "${PCLOUD_BACKUP_ERLAUBE_ROOT:-0}" != 1 ]; then
    abbruch "Bitte ohne sudo ausführen."
  fi
  [ "$(uname -s)" = Darwin ] || sag "Hinweis: Dieses Skript ist für macOS gedacht."
  launchctl print "$DOMAIN" >/dev/null 2>&1 ||
    abbruch "Bitte im Terminal direkt am Mac ausführen, während du angemeldet bist."

  mkdir -p "$BASIS/bin" "$LOGS" "$JOBS" "$ZUSTAND"
  chmod 700 "$BASIS"
  if [ -f "$0" ] && ! [ "$0" -ef "$SKRIPT" ]; then
    cp "$0" "$SKRIPT" || abbruch "Konnte das Skript nicht nach $SKRIPT kopieren."
  fi
  [ -f "$SKRIPT" ] || abbruch "Bitte die Datei speichern und mit 'bash <Datei> einrichten' starten."
  chmod 700 "$SKRIPT"

  titel "1/5  rclone"
  rclone_bereitstellen

  titel "2/5  pCloud verbinden"
  pcloud_verbinden

  titel "3/5  Verschlüsselung"
  verschluesselung_einrichten
  einstellungen_schreiben
  ausschluss_schreiben

  if [ "$nur_verbinden" = 0 ] && [ ! -f "$ZUSTAND/eingerichtet" ] &&
     [ -n "$(rc lsf "$REMOTE_KRYPT:aktuell" --max-depth 1 2>/dev/null | head -1)" ]; then
    cat <<EOF

  In der pCloud liegt bereits ein Backup.
    s = Dieses MacBook sichert dorthin weiter (nur sinnvoll, wenn es derselbe Mac ist;
        sonst wandert der bisherige Stand ins Archiv)
    w = Nur verbinden, um Dateien wiederherzustellen (kein Zeitplan)
EOF
    local wahl=""
    read -r -p "  Auswahl [w]: " wahl || wahl="w"
    case "$wahl" in s|S) ;; *) nur_verbinden=1 ;; esac
  fi

  if [ "$nur_verbinden" = 1 ]; then
    titel "Fertig – nur verbunden"
    sag "  Inhalt ansehen:      $KURZ liste [Pfad]"
    sag "  Wiederherstellen:    $KURZ wiederherstellen <Pfad im Backup> <Zielordner>"
    sag "  Zeitplan einrichten: $KURZ einrichten"
    return 0
  fi

  titel "4/5  Festplattenvollzugriff"
  if mechaniktest; then
    zugriff_einrichten
  else
    schlecht "launchd meldet auf diesem macOS unerwartete Werte – das Backup würde so nicht zuverlässig laufen."
    sag "    Bitte diese Ausgabe weitergeben:"
    printf '%s\n' "$JOB_INFO" | grep -i -e 'launchctl' -e 'state' -e 'exit' -e 'signal' -e 'pid' | sed 's/^/      /'
    abbruch "Einrichtung angehalten."
  fi

  titel "5/5  Zeitplan"
  [ -f "$ZUSTAND/eingerichtet" ] || date +%s > "$ZUSTAND/eingerichtet"
  planer_plist_schreiben
  if frage_jn "  Erstes Backup gleich starten? [J/n]" j; then
    rm -f "$ZUSTAND/pausiert"
  else
    : > "$ZUSTAND/pausiert"
  fi
  planer_laden || abbruch "Der Zeitplan ließ sich nicht laden (launchctl bootstrap)."
  gut "Zeitplan aktiv: stündliche Prüfung, Backup alle $INTERVALL_STUNDEN Stunden"
  sag "    macOS zeigt dazu evtl. die Mitteilung \"Hintergrundobjekt hinzugefügt\" – das ist dieser Zeitplan."

  titel "Fertig"
  if [ -f "$ZUSTAND/pausiert" ]; then
    sag "  Das Backup ist pausiert. Starten mit:  $KURZ weiter"
  elif [ "$NUR_AM_STROM" = 1 ] && ! am_strom; then
    sag "  Das erste Backup startet, sobald das Netzteil angeschlossen ist."
  else
    sag "  Das erste Backup startet jetzt im Hintergrund. Je nach Datenmenge dauert es Tage;"
    sag "  es setzt nach Unterbrechungen von selbst fort."
  fi
  sag "  Stand ansehen:   $KURZ status"
  sag "  Alle Befehle:    $KURZ hilfe"
}

# =============================================================================
#  Befehle für den Alltag
# =============================================================================

cmd_status() {
  muss_eingerichtet_sein
  local jetzt erfolg versuch naechster letztes_log n alter netz=""
  jetzt=$(date +%s)
  erfolg=$(lies_zahl "$ZUSTAND/letzter_erfolg")
  versuch=$(lies_zahl "$ZUSTAND/letzter_versuch")
  alter=$((jetzt - erfolg))
  [ "$NUR_AM_STROM" = 1 ] && netz=", am Netzteil"

  sag "pCloud-Backup $VERSION"
  if launchctl print "$DOMAIN/$PLANER" >/dev/null 2>&1; then
    if [ -f "$ZUSTAND/pausiert" ]; then sag "  Zeitplan:        pausiert (fortsetzen mit: weiter)"
    else sag "  Zeitplan:        aktiv (alle $INTERVALL_STUNDEN Std.)"; fi
  else
    sag "  Zeitplan:        NICHT geladen (beheben mit: einrichten)"
  fi

  if [ "$erfolg" -gt 0 ]; then
    sag "  Letztes Backup:  $(zeit_text "$erfolg"), vor $(dauer_text "$alter")"
  else
    sag "  Letztes Backup:  noch keines abgeschlossen"
  fi

  if job_aktiv "$SYNCJOB"; then
    letztes_log="$LOGS/lauf-$(cat "$ZUSTAND/laeuft" 2>/dev/null).log"
    sag "  Gerade aktiv:    ja"
    if [ -f "$letztes_log" ] && grep -q ', ETA ' "$letztes_log"; then
      sag "                   $(grep ', ETA ' "$letztes_log" | tail -1 | sed -e 's/^.*NOTICE: *//')"
    else
      sag "                   (erste Zwischenmeldung nach etwa 5 Minuten)"
    fi
  elif [ -f "$ZUSTAND/laeuft" ]; then
    sag "  Gerade aktiv:    Lauf beendet, wird gerade ausgewertet"
  else
    sag "  Gerade aktiv:    nein"
    if [ ! -f "$ZUSTAND/pausiert" ]; then
      naechster=$((erfolg + INTERVALL_STUNDEN * 3600))
      if [ "$versuch" -gt "$erfolg" ] && [ $((versuch + WIEDERHOLUNG_STUNDEN * 3600)) -gt "$naechster" ]; then
        naechster=$((versuch + WIEDERHOLUNG_STUNDEN * 3600))
      fi
      if [ "$naechster" -le "$jetzt" ]; then
        sag "  Nächster Lauf:   bei der nächsten stündlichen Prüfung$netz"
      else
        sag "  Nächster Lauf:   ab $(zeit_text "$naechster")$netz"
      fi
    fi
  fi

  if [ -f "$ZUSTAND/verlauf.log" ]; then
    sag ""
    sag "  Letzte Läufe:"
    tail -n 5 "$ZUSTAND/verlauf.log" | sed 's/^/    /'
  fi

  letztes_log=$(ls -t "$LOGS"/lauf-*.log 2>/dev/null | head -1)
  if [ -n "$letztes_log" ]; then
    n=$(probleme_im_log "$letztes_log" | wc -l | tr -d ' ')
    if [ "$n" -gt 0 ]; then
      sag ""
      sag "  Nicht gesichert im letzten Lauf ($n):"
      probleme_kurz "$letztes_log" | head -15 | sed 's/^/    /'
      [ "$n" -gt 15 ] && sag "    … vollständig in $letztes_log"
      if probleme_im_log "$letztes_log" | grep -q -i 'operation not permitted'; then
        sag "  \"operation not permitted\" heißt: rclone fehlt der Festplattenvollzugriff (prüfen mit: test)."
      fi
      sag "  Solange Einträge unlesbar sind, räumt rclone gelöschte Dateien nicht aus dem Spiegel."
      sag "  Abhilfe: Festplattenvollzugriff erteilen oder den Pfad in ausschluss.txt eintragen."
    fi
    if grep -q ' CRITICAL: ' "$letztes_log"; then
      sag ""
      sag "  Fehlermeldung:"
      grep ' CRITICAL: ' "$letztes_log" | tail -3 | sed -e 's/^.* CRITICAL: //' -e 's/^/    /'
    fi
  fi
}

cmd_jetzt() {
  muss_eingerichtet_sein
  if job_aktiv "$SYNCJOB"; then sag "Es läuft bereits ein Backup. Stand: $KURZ status"; return 0; fi
  launchctl print "$DOMAIN/$PLANER" >/dev/null 2>&1 ||
    abbruch "Der Zeitplan ist nicht geladen. Bitte zuerst: $KURZ einrichten"
  mkdir -p "$ZUSTAND"
  rm -f "$ZUSTAND/pausiert"
  : > "$ZUSTAND/erzwingen"
  launchctl kickstart "$DOMAIN/$PLANER" >/dev/null 2>&1
  sag "Backup wird im Hintergrund gestartet. Stand: $KURZ status"
}

cmd_pause() {
  muss_eingerichtet_sein
  mkdir -p "$ZUSTAND"
  : > "$ZUSTAND/pausiert"
  job_stoppen "$SYNCJOB"
  sag "Pausiert. Ein laufendes Backup wurde angehalten und setzt später dort fort."
  sag "Fortsetzen mit: $KURZ weiter"
}

cmd_weiter() {
  muss_eingerichtet_sein
  rm -f "$ZUSTAND/pausiert"
  launchctl kickstart "$DOMAIN/$PLANER" >/dev/null 2>&1
  sag "Zeitplan läuft wieder. Fällige Backups starten bei der nächsten Prüfung."
}

cmd_vorschau() {
  muss_eingerichtet_sein
  local aus="$LOGS/vorschau.txt" log="$LOGS/vorschau.log"
  : > "$aus"; : > "$log"
  sag "Zähle, was gesichert würde (kann einige Minuten dauern) …"
  job_ausfuehren "$TESTJOB" "$aus" 0 size "$QUELLE" --config "$RCONF" \
    --exclude-from "$AUSSCHLUSS" --links --one-file-system --log-file "$log"
  sed -e 's/^Total objects:/Dateien:/' -e 's/^Total size:/Größe:  /' -e 's/^/  /' "$aus"
  if [ -s "$log" ] && [ -n "$(probleme_im_log "$log" | head -1)" ]; then
    sag "  Nicht lesbar:"
    probleme_kurz "$log" | head -15 | sed 's/^/    /'
  fi
}

cmd_liste() {
  muss_eingerichtet_sein
  rc lsf "$REMOTE_KRYPT:aktuell/${1:-}"
}

cmd_archiv() {
  muss_eingerichtet_sein
  local staende
  if [ -n "${1:-}" ]; then
    rc lsf "$REMOTE_KRYPT:archiv/$1/${2:-}"
  else
    staende=$(rc lsf --dirs-only "$REMOTE_KRYPT:archiv" 2>/dev/null | sed 's:/$::')
    if [ -n "$staende" ]; then printf '%s\n' "$staende"
    else sag "Noch keine älteren Stände vorhanden."; fi
  fi
}

cmd_wiederherstellen() {
  muss_eingerichtet_sein
  local pfad="${1:-}" ziel="${2:-}" stand="${3:-}" quelle
  if [ -z "$pfad" ] || [ -z "$ziel" ]; then
    abbruch "Aufruf: wiederherstellen <Pfad im Backup> <Zielordner> [Archivstand]
  Beispiel: wiederherstellen Documents/Steuer ~/Desktop/zurueck
  Älterer Stand: wiederherstellen Documents/brief.txt ~/Desktop/zurueck 2026-10-11_1317"
  fi
  pfad="${pfad#/}"
  if [ -n "$stand" ]; then quelle="$REMOTE_KRYPT:archiv/$stand/$pfad"
  else quelle="$REMOTE_KRYPT:aktuell/$pfad"; fi
  mkdir -p "$ziel" || abbruch "Zielordner $ziel lässt sich nicht anlegen."
  sag "Hole \"$pfad\" nach $ziel …"
  rc copy "$quelle" "$ziel" --links --transfers "$UEBERTRAGUNGEN" --progress
}

cmd_test() {
  muss_eingerichtet_sein
  local st t probe frei
  sag "pCloud-Backup – Selbsttest"
  gut "rclone: $("$RCLONE" version 2>/dev/null | head -1)"

  if rc lsd "$REMOTE_BASIS:" --max-depth 1 >/dev/null 2>&1; then
    frei=$(rc about "$REMOTE_BASIS:" 2>/dev/null | sed -n 's/^Free: *//p')
    gut "pCloud erreichbar${frei:+ (frei: $frei)}"
  else
    schlecht "pCloud nicht erreichbar (Internet oder Anmeldung)"
  fi

  t="pcloud-backup-selbsttest-$$"
  probe="Selbsttest $(date +%s)"
  if printf '%s' "$probe" | rc rcat "$REMOTE_KRYPT:$t/probe.txt" 2>/dev/null &&
     [ "$(rc cat "$REMOTE_KRYPT:$t/probe.txt" 2>/dev/null)" = "$probe" ]; then
    gut "Verschlüsselt hochladen und wieder lesen funktioniert"
  else
    schlecht "Hochladen/Lesen über die Verschlüsselung klappt nicht"
  fi
  rc purge "$REMOTE_KRYPT:$t" >/dev/null 2>&1

  if launchctl print "$DOMAIN/$PLANER" >/dev/null 2>&1; then gut "Zeitplan ist geladen"
  else schlecht "Zeitplan ist nicht geladen (beheben mit: einrichten)"; fi

  if job_aktiv "$SYNCJOB"; then
    sag "  – launchd- und Zugriffstest übersprungen, weil gerade ein Backup läuft"
    return 0
  fi
  if mechaniktest; then gut "launchd startet rclone und meldet das Ergebnis korrekt"
  else schlecht "launchd meldet unerwartete Werte"; fi

  zugriffstest; st=$?
  case "$st" in
    0) gut "Festplattenvollzugriff für rclone ist aktiv" ;;
    2) sag "  – Festplattenvollzugriff nicht prüfbar (kein geschützter Ordner gefunden)" ;;
    *) schlecht "Kein Festplattenvollzugriff: Systemeinstellungen > Datenschutz & Sicherheit >"
       sag "    Festplattenvollzugriff > \"+\" > Cmd+Shift+G > ~/.pcloud-backup/bin/rclone" ;;
  esac
}

cmd_aktualisieren() {
  muss_eingerichtet_sein
  local alt
  if job_aktiv "$SYNCJOB"; then abbruch "Es läuft gerade ein Backup. Bitte danach erneut versuchen."; fi
  alt=$("$RCLONE" version 2>/dev/null | head -1)
  if rclone_laden; then
    gut "rclone: $alt  →  $("$RCLONE" version 2>/dev/null | head -1)"
    zugriffstest
    case $? in
      0) gut "Festplattenvollzugriff ist weiterhin aktiv" ;;
      1) schlecht "macOS verlangt den Festplattenvollzugriff für die neue Version erneut:"
         sag "    Systemeinstellungen > Datenschutz & Sicherheit > Festplattenvollzugriff:"
         sag "    \"rclone\" entfernen und ~/.pcloud-backup/bin/rclone neu hinzufügen, dann: $KURZ test" ;;
    esac
  else
    schlecht "Aktualisierung nicht möglich (Download fehlgeschlagen). Es bleibt bei $alt."
  fi
}

cmd_entfernen() {
  job_stoppen "$SYNCJOB"
  launchctl bootout "$DOMAIN/$PLANER" >/dev/null 2>&1
  rm -f "$PLANER_PLIST"
  sag "Zeitplan entfernt. Es laufen keine automatischen Backups mehr."
  sag "Die Daten in der pCloud und der Ordner ~/.pcloud-backup bleiben unverändert."
  sag "Wer alles loswerden will: den Ordner ~/.pcloud-backup löschen und rclone aus dem"
  sag "Festplattenvollzugriff entfernen."
}

cmd_hilfe() {
  cat <<EOF
pCloud-Backup $VERSION

  einrichten              Einrichtung (rclone, pCloud, Verschlüsselung, Zeitplan)
  einrichten nur-verbinden  nur verbinden, z. B. auf einem neuen Mac zum Wiederherstellen
  status                  letzter Lauf, nächster Lauf, Probleme
  jetzt                   sofort ein Backup starten (auch im Akkubetrieb)
  pause / weiter          Backups anhalten (z. B. am Handy-Hotspot) und fortsetzen
  vorschau                zählen, wie viel gesichert würde
  liste [Pfad]            Inhalt des Backups anzeigen
  archiv [Stand] [Pfad]   ältere Stände anzeigen
  wiederherstellen <Pfad> <Zielordner> [Stand]
  test                    Selbsttest (pCloud, Verschlüsselung, Festplattenvollzugriff)
  aktualisieren           rclone auf die neueste Version bringen
  entfernen               Zeitplan entfernen (Daten bleiben)

Einstellungen:  $EINST
Ausschlüsse:    $AUSSCHLUSS
Protokolle:     $LOGS
EOF
}

case "${1:-hilfe}" in
  einrichten)        shift; cmd_einrichten "$@" ;;
  auto)              cmd_auto ;;
  status)            cmd_status ;;
  jetzt)             cmd_jetzt ;;
  pause)             cmd_pause ;;
  weiter)            cmd_weiter ;;
  vorschau)          cmd_vorschau ;;
  liste)             shift; cmd_liste "$@" ;;
  archiv)            shift; cmd_archiv "$@" ;;
  wiederherstellen)  shift; cmd_wiederherstellen "$@" ;;
  test)              cmd_test ;;
  aktualisieren)     cmd_aktualisieren ;;
  entfernen)         cmd_entfernen ;;
  hilfe|-h|--help)   cmd_hilfe ;;
  *)                 cmd_hilfe; exit 1 ;;
esac
