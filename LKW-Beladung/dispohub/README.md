# LKW-Ladeplaner in DispoHub

Hier liegt alles, was den Ladeplaner als eingebautes Modul **„LKW“** in DispoHub bringt. Ab DispoHub Beta 9.7 ist es schon dabei; diese Dateien braucht man nur, um den Planer nach einer Änderung neu einzubauen oder ihn in eine neuere DispoHub-Fassung zu übernehmen.

| Datei | Zweck |
|---|---|
| `lkw.php` | Seite mit Menü; zeigt den Planer in einem Rahmen, der das Fenster unter der Kopfzeile füllt |
| `lkw-app.php` | liefert den Planer aus; prüft Anmeldung und Modulrecht selbst |
| `einbau.py` | baut alles in einen DispoHub-Ordner ein (wiederholbar) |

## Einbauen oder aktualisieren

```sh
python3 einbau.py /pfad/zu/dispohub            # nur Planer und Modul
python3 einbau.py /pfad/zu/dispohub --version 9.7   # zusätzlich APP_VERSION setzen
```

Danach den DispoHub-Ordner wie gewohnt als ZIP packen und unter **Admin → System-Update** hochladen, oder die Dateien per FTP kopieren.

`einbau.py` erledigt Folgendes:

1. **`includes/lkw-planer.html`** wird aus `../index.html` erzeugt.
   - Offline-Cache und App-Symbol fallen weg.
   - three.js und die Schriften kommen aus `assets/lkw/`.
   - Der Speicherplatz im Browser wird je Benutzer getrennt (`lkw_u<ID>_…`).
2. **`assets/lkw/`** bekommt three.js, OrbitControls, die Schriften und die Lizenzen.
3. **`lkw.php`** und **`lkw-app.php`** werden kopiert.
4. **Das Modul wird in DispoHub angemeldet:**
   - `includes/functions.php`: Eintrag `'lkw'` in `modules_registry()`, also Admin → Module und Rechte je Benutzer.
   - `includes/layout.php`: Menüpunkt hinter dem Tourenplaner (`menu_base_items()`) und das Lkw-Piktogramm (`menu_icon_default()`). Neue Menüpunkte landen bei einer gespeicherten Menü-Reihenfolge hinter ihrem Vorgänger statt unter „Administration“ (`menu_ordered()`).
   - `admin.php`: Admin → Menü nutzt dieselbe Reihenfolge.
   - `404.php`: die Startseiten-Liste.
   - `assets/live.js`: Seitenname „LKW“ in der Anwesenheit.
   - `assets/style.css`: der Rahmen füllt das Fenster.

Was schon eingebaut ist, bleibt unverändert. Findet das Skript eine Stelle nicht, bricht es ab, ohne etwas zu ändern. Das passiert nur, wenn DispoHub an dieser Stelle umgebaut wurde. Dann die Punkte oben von Hand nachziehen.

## Verhalten in DispoHub

- **Rechte**
  - Das Modul ist nach dem Update eingeschaltet. Abschalten unter Admin → Module.
  - Benutzer mit eingeschränkten Rechten sehen „LKW“ erst, wenn es unter Admin → Benutzer → Rechte freigegeben ist.
- **Anmeldung**
  - Ohne Anmeldung wechselt das ganze Fenster zur Anmeldeseite, nicht nur der Rahmen.
  - Ruft man `lkw-app.php` direkt auf, leitet es zu `lkw.php` weiter.
- **Keine fremden Server, keine Datenbank-Änderung.** Der Ladeplan wird nur im Browser gespeichert.
- **Bedienung:** Die Tastenkürzel des Planers wirken sofort, weil der Rahmen beim Laden den Fokus bekommt. Vollbild und „Ladeliste kopieren“ sind im Rahmen erlaubt.
