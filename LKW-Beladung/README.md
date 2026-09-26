# Ladeplan Hängerzug

Interaktiver 3D-Ladeplan für einen Kühl-Hängerzug im Filialverkehr: Iveco S-Way LNG als Maschine (Motorwagen) mit Tandem-Anhänger und Durchlade-Kühlkoffer von ROHR bzw. Wüllhorst. Dazu kommen Sattelzug, Solo-LKW und Anhänger allein. Vorbild für die Bedienung war [„The Plane of Focus“](https://sael.net/plane-of-focus/): ein echtes Fahrzeug, aufgemacht, mit Live-Werten direkt im 3D-Bild.

Der Ordner ist eine fertige, statische Website. Es gibt keinen Build, keinen Server-Code und keine Datenbank. Zum Ausprobieren `index.html` im Browser öffnen.

## Auf eine Website bringen

**Variante 1: eigener Webspace (Strato, IONOS, all-inkl. …)**

1. Den kompletten Ordner `LKW-Beladung` per FTP oder Dateimanager hochladen, zum Beispiel als `/ladeplan/`.
2. Fertig. Der Planer läuft unter `https://eure-domain.de/ladeplan/`.

**Variante 2: in eine bestehende Seite einbetten (z. B. WordPress, Block „Individuelles HTML“)**

Den Ordner wie oben hochladen und dann einbetten:

```html
<iframe src="/ladeplan/" title="Ladeplan Hängerzug"
        style="width:100%;height:85vh;min-height:620px;border:0;border-radius:12px"
        allow="fullscreen" loading="lazy"></iframe>
```

Auf dem Handy schaltet der Planer automatisch auf die Handy-Ansicht um. Mit dem Vollbild-Knopf füllt er den ganzen Bildschirm.

**Variante 3: kostenlos hosten**

Den Ordner bei Netlify („Deploy manually“, Ordner hineinziehen) oder Cloudflare Pages hochladen, oder GitHub Pages auf diesen Ordner zeigen lassen.

### Was die Website braucht

- **Nur statische Dateien.** HTTPS wird empfohlen. Über HTTPS funktioniert der Planer nach dem ersten Aufruf auch offline (`sw.js`), und man kann ihn auf dem Handy mit „Zum Home-Bildschirm“ wie eine App ablegen (`manifest.webmanifest`).
- **Datenschutz**
  - Die Seite lädt nichts von fremden Servern. Schriften (Barlow, JetBrains Mono) und three.js liegen in `fonts/` und `vendor/`.
  - Es gibt keine Cookies, kein Tracking und keine Formulare.
  - Der Ladeplan wird nur im Browser des Nutzers gespeichert (`localStorage`) und nie übertragen.
- **Lizenzen:** three.js steht unter MIT (`vendor/LICENSE-three.txt`), die Schriften unter der SIL Open Font License (`fonts/LICENSE-*.txt`).

### Dateien

| Datei | Zweck |
|---|---|
| `index.html` | die App (HTML, CSS, JavaScript in einer Datei) |
| `vendor/` | three.js 0.147 und OrbitControls |
| `fonts/` | selbst gehostete Schriften mit `fonts.css` |
| `sw.js` | Offline-Cache; bei Änderungen `VERSION` hochzählen |
| `manifest.webmanifest`, `icon*.svg/png` | App-Symbol und Startbildschirm-Eintrag |

## Was er kann

- **Fahrzeuge**
  - LKW 221: Durchlade-Hängerzug mit 33 + 30 = 63 Stellplätzen
  - LKW 219: Sattelzug mit 54 Stellplätzen, alternativ Hängerzug 24 + 30 oder 27 + 27
  - Hängerzug 30 + 30, Solo-LKW mit 33 oder 30 Stellplätzen, Anhänger mit 30
  - Die Innenlänge jeder Einheit lässt sich im Datenblatt ändern.
- **Ladungsträger:** Rollbehälter blau, Hygiene-Rollbehälter, TK-Isotainer, I2 Fleisch (E2-Kisten), Euro-Palette und CH3-Palette (CHEP). Isotainer, I2, CH3 und Hygiene-RBH haben umschaltbare Formate.
- **Setzen, Ziehen, Drehen**
  - Behälter werden per Tippen gesetzt. Die Vorschau rastet in Spuren und Reihen ein.
  - Behälter lassen sich ziehen, auch von der Maschine in den Anhänger oder auf die Rampe.
  - Drehen geht mit T, Löschen mit Entf, Rückgängig mit Strg+Z.
- **Automatisch verteilen:** stellt alle Behälter neu. Paletten stehen vorn an der Stirnwand. Das Gewicht wird im Verhältnis zur Nutzlast auf Maschine und Anhänger verteilt. Im Zentralachs-Anhänger kommen schwere Paletten über die Achsen, damit die Stützlast im Rahmen bleibt. **Nachrücken** schiebt alles bündig nach vorn.
- **Auswertung**
  - belegte Stellplätze sowie „passt noch“ für Rollbehälter und Europaletten
  - Gewicht und Nutzlast
  - Achslasten als Hebel-Näherung: Vorderachse, Hinterachsen, Stützlast, Sattellast
  - Schwerpunkt, Ladungsfront und Sperrbalken
  - Kühlung je Einheit
- **Ansichten**
  - Tasten 1, 2 und 3 wählen Maschine, Anhänger oder den ganzen Zug.
  - X klappt den Aufbau auf: Dach und Wände heben sich, die Maschine fährt vor, die Stirnklappe wird zur Brücke.
  - V wechselt die Kamera: Übersicht, Seite, Draufsicht, Heck an der Rampe, über der Stirnwand.
  - C startet die Kamerafahrt.
- **Ladeliste:** zeigt je Einheit, was geladen ist, und lässt sich als Text kopieren (Reihe für Reihe).

Der Plan wird nur im eigenen Browser gespeichert (`localStorage`). Es gibt keinen Server und kein Konto.

## Datengrundlage

Die Maße, Gewichte und Hersteller stehen im Datenblatt der App, mit Quellen und Einstufung der Sicherheit. Kurz:

- „Wülhordt“ ist Wüllhorst Fahrzeugbau aus Selm-Bork, „Rohraufbau“ ist ROHR Spezialfahrzeuge aus Straubing.
- ROHR nennt für den Durchladezug DLE31 bei EDEKA 20 + 18 Europaletten oder 33 + 30 Rollcontainer.
- Rollbehälter 724 × 815 mm, Gitterseite quer: 3 je Reihe, Reihe 724 mm tief. 8,08 m innen ergeben 33 Stellplätze, 7,30 m ergeben 30.
- Offene Annahmen, die vor dem Einsatz zu prüfen sind:
  - LKW 219 als Sattelzug
  - CH3 als CHEP-Palette
  - I2 als E2-Kisten
  - Leergewichte und Achsgeometrie

Inoffizielles Planungswerkzeug, nicht von EDEKA, IVECO, ROHR oder Wüllhorst. Alle Werte ohne Gewähr. Maßgeblich sind Fahrzeugpapiere, Waage und die Vorgaben der Niederlassung.
