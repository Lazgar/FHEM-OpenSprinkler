# FHEM OpenSprinkler Integration (`73_OpenSprinkler.pm`)

Dieses FHEM-Modul ermöglicht eine hocheffiziente, nicht-blockierende und native Integration der intelligenten **OpenSprinkler-Gartenbewässerung** in das Open-Source-Hausautomationssystem **FHEM**.

Das Modul kommuniziert direkt über die lokale HTTP-JSON-API des OpenSprinkler-Controllers.

---

## ✨ Hauptmerkmale

* ⚡ **Nicht-blockierendes Polling:** Verhindert das Einfrieren von FHEM während der Netzwerkabfragen durch die konsequente Nutzung von `HttpUtils_NonblockingGet`.
* 🔒 **Sichere Passwort-Speicherung:** Nutzt die offizielle, moderne FHEM-Kern-Schnittstelle `setKeyValue`, um Passwörter verschlüsselt außerhalb der Standard-Konfigurationsdatei abzuspeichern.
* 📦 **Dynamische Board-Erkennung:** Erkennt angeschlossene Erweiterungsboards (Extension Boards) vollautomatisch während der Laufzeit. Das Modul skaliert bei Bedarf selbstständig von 8 auf bis zu 72 Stationen (Zonen).
* 🗂️ **Natives Multi-Strict-Attribut:** Perfekte FHEMWEB-Integration über das Attribut `active_stations`. Benutzer können Stationen komfortabel via Checkboxen aktivieren oder deaktivieren.
* 🧹 **Automatisches Aufräumen:** Beim Abwählen einer Station im Attribut werden alle zugehörigen verwaisten Readings sofort rückstandslos aus FHEM gelöscht.
* 🔄 **Zustandsgesteuerter Neustart-Schutz:** Der Zeitstempel (`ReadingsTimestamp`) von Ventilen wird nur bei echten physischen Zustandsänderungen aktualisiert. Das macht alle Berechnungen absolut immun gegen FHEM-Systemneustarts.
* 📊 **Erweiterte Laufzeithistorie:** Berechnet pro Station individuell die aktuelle Live-Laufzeit (`_runSince`) sowie die vergangenen Kalendertage seit der letzten Aktivität (`_lastRun`) mittels `SYSMON`-Bordmitteln.

---

## 🚀 Installation & Einrichtung

### 1. Repository als Updatequelle in FHEM hinzufügen
Kopiere folgenden Befehl und füge ihn oben in die FHEM-Befehlszeile ein. Dadurch wird das Modul direkt in den offiziellen FHEM-Updateprozess integriert:

```fhem
update add https://raw.githubusercontent.com/Lazgar/FHEM-OpenSprinkler/master/controls_opensprinkler.txt
```

### 2. Update ausführen
Triggere nun das Update in FHEM, damit die Moduldatei automatisch vom GitHub-Repository heruntergeladen und am richtigen Ort (`/opt/fhem/FHEM/73_OpenSprinkler.pm`) abgelegt wird:

```fhem
update
```
Nach erfolgreichem Update startet das Modul automatisch mit dem FHEM-System (bzw. kann sofort per `reload 73_OpenSprinkler.pm` ohne Neustart geladen werden).

### 3. Gerät definieren
Lege die Instanz deiner Bewässerungssteuerung mit der IP-Adresse deines OpenSprinklers an:
```fhem
define OU_Garten_Bewaesserung OpenSprinkler <Deine-OpenSprinkler-IP>
```
*Beispiel: `define OU_Garten_Bewaesserung OpenSprinkler 192.168.178.50`*

### 4. Passwort verschlüsselt hinterlegen
Aus Sicherheitsgründen blockiert das Modul das Polling so lange, bis das Geräte-Passwort gesetzt wurde. Führe dazu einmalig folgenden Befehl aus:
```fhem
set OU_Garten_Bewaesserung password <DeinOpenSprinklerPasswort>
```
Das Passwort wird sofort per MD5 gehasht und im sicheren FHEMWEB-Speicher abgelegt.

---

## ⚙️ Unterstützte Attribute

| Attribut | Typ | Beschreibung |
| :--- | :--- | :--- |
| `interval` | Zahl (Sekunden) | Polling-Intervall für den Datenabruf. Standard: `60`. |
| `active_stations` | `multiple-strict` | Checkbox-Liste aller erkannten Stationen. Nur angehakte Stationen erzeugen Readings und tauchen im `set`-Dropdown auf. |

---

## 🛠️ Befehlsstruktur (Set / Get)

### Set-Befehle
* `set <name> station_<ID>_start <Sekunden>`: Startet die angegebene Zone für eine feste Dauer.
* `set <name> station_<ID>_stop`: Stoppt die angegebene Zone sofort.
* `set <name> rainDelay <Stunden>`: Aktiviert eine temporäre Regenverzögerung.
* `set <name> system_enabled <on\|off>`: Schaltet die gesamte Bewässerungsanlage aktiv oder inaktiv.

### Get-Befehle
* `get <name> status`: Triggert einen sofortigen asynchronen Datenabruf außerhalb des regulären Intervalls.

---

## 📊 Generierte Readings

Das Modul erzeugt globale Hardwaredaten sowie spezifische Readings pro **aktiver** Station:

* `state`: Allgemeiner Verbindungsstatus (`connected`, `error`, `missing_password`).
* `current_mA`: Aktuell gemessene Stromstärke des Controllers.
* `hardware_type`: Erkennt den Hardware-Typ (z. B. *OSPi Raspberry*, *AC Power Version*, *DC Power Version*).
* `water_level_percent`: Aktueller prozentualer Bewässerungs-Level (z. B. durch Wetterdienste modifiziert).
* `station_X_name`: Der im OpenSprinkler hinterlegte Klarname der Zone.
* `station_X_state`: Aktueller Ventilzustand (`on` / `off`).
* `station_X_runSince`: Live-Laufzeitanzeige im Format `MM:SS` (nur sichtbar, wenn das Ventil offen ist).
* `station_X_lastRun`: Kalendertage, die seit dem letzten Guss vergangen sind (`0` = heute bewässert, `1` = gestern bewässert, etc.).

---

## 🎨 UI-Optimierung (Schnellstart im Raum)

Für eine besonders komfortable und optisch cleane Steuerung direkt in der FHEM-Raumansicht, empfiehlt sich die Nutzung des folgenden `stateFormat`-Attributs. Es bettet ein rahmenloses Schnellstart-Menü mit **Minuten-Eingabe** ein, welches im Hintergrund automatisch in die von der Hardware benötigten Sekunden umrechnet:

```fhem
attr OU_Garten_Bewaesserung stateFormat {\
  my \(active_attr = AttrVal(\)name, "active_stations", "");;\
  my \$max_stations = \(defs{\)name}{helper}{MAX_STATIONS} // 8;;\
  my \$options = "";;\
  for (my \(i = 0;;\)i < \(max_stations;;\)i++) {\
    if (\$active_attr eq "" || \(active_attr =~ /station_\)i/) {\
      my \(alias = ReadingsVal(\)name, "station_" . \(i . "_name", "Station \)i");;\
      \$options .= "<option value='\(i'>\)alias</option>";;\
    }\
  }\
  my \$html = "<div style='display: inline-flex;; align-items: center;; gap: 8px;; padding: 2px 0;; background: transparent;; font-family: sans-serif;'>".\
             "  <span style='font-weight: 600;; color: var(--text-color, #333);; font-size: 13px;'>Schnellstart:</span>".\
             "  <select id='sf_zone_\$name' style='padding: 4px 24px 4px 8px;; border: 1px solid var(--border-color, #ccc);; border-radius: 4px;; background: var(--bg-color, #fff);; color: var(--text-color, #000);; font-size: 12px;; cursor: pointer;; height: 26px;; -webkit-appearance: none;; -moz-appearance: none;; appearance: none;; background-image: url(\"data:image/svg+xml;utf8,<svg xmlns=\'http://w3.org\' width=\'10\' height=\'6\' viewBox=\'0 0 10 6\'><path fill=\'%23666\' d=\'M0 0l5 5 5-5z\'/></svg>\");; background-repeat: no-repeat;; background-position: right 8px center;'>\$options</select>".\
             "  <input id='sf_time_\$name' type='text' value='5' style='width: 30px;; height: 16px;; padding: 4px;; text-align: center;; border: 1px solid var(--border-color, #ccc);; border-radius: 4px;; background: var(--bg-color, #fff);; color: var(--text-color, #000);; font-size: 12px;'>".\
             "  <span style='color: var(--text-color, #666);; font-size: 12px;'>Min.</span>".\
             "  <button onclick=\"var m=parseFloat(document.getElementById('sf_time_\$name').value)||0;; var s=Math.round(m*60);; FW_cmd('/fhem?cmd=set \(name station_'+document.getElementById('sf_zone_\)name').value+'_start '+s)\" onmouseover=\"this.style.background='#4cae4c'\" onmouseout=\"this.style.background='#5cb85c'\" style='background: #5cb85c;; color: white;; border: 0;; padding: 5px 12px;; border-radius: 4px;; cursor: pointer;; font-weight: bold;; font-size: 12px;; height: 26px;; transition: background 0.2s;'>▶ Start</button>".\
             "  <button onclick=\"FW_cmd('/fhem?cmd=set \(name station_'+document.getElementById('sf_zone_\)name').value+'_stop')\" onmouseover=\"this.style.background='#d43f3a'\" onmouseout=\"this.style.background='#d9534f'\" style='background: #d9534f;; color: white;; border: 0;; padding: 5px 12px;; border-radius: 4px;; cursor: pointer;; font-weight: bold;; font-size: 12px;; height: 26px;; transition: background 0.2s;'>■ Stop</button>".\
             "</div>";;\
  return "Status: " . ReadingsVal(\(name, "state", "connected") . " <br style='margin-bottom:6px;'> " . \)html;;\
}
```
*(Hinweis: Bei der direkten Eingabe im FHEM-Befehlsfeld müssen die Semikolons und Zeilenumbrüche wie oben dargestellt maskiert sein).*

---

## 📋 Voraussetzungen

* Das FHEM-Modul `SYSMON` sollte auf dem System vorhanden sein, um die relativen Tage für `_lastRun` fehlerfrei zu decodieren.
* Eine aktive OpenSprinkler-Hardware (ab v3.x) oder eine entsprechende OpenSprinkler-Firmware im selben lokalen Netzwerk.
