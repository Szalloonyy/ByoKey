# Ladeplan Hängerzug

Interaktiver 3D-Ladeplan für einen Kühl-Hängerzug im Filialverkehr: Iveco S-Way LNG als Maschine (Motorwagen) mit Tandem-Anhänger und Durchlade-Kühlkoffer von ROHR bzw. Wüllhorst. Dazu kommen das Kammer-Auto mit TK-Kammer, die Maschinen solo und die Anhänger allein. Vorbild für die Bedienung war [„The Plane of Focus“](https://sael.net/plane-of-focus/): ein echtes Fahrzeug, aufgemacht, mit Live-Werten direkt im 3D-Bild.

Der Ordner ist eine fertige, statische Website. Es gibt keinen Build, keinen Server-Code und keine Datenbank. Zum Ausprobieren `index.html` im Browser öffnen.

## Auf eine Website bringen

**Variante 1: eigener Webspace (Strato, IONOS, all-inkl. …)**

1. Den Ordner `LKW-Beladung` per FTP oder Dateimanager hochladen, zum Beispiel als `/ladeplan/`. Den Unterordner `dispohub/` braucht die Website nicht.
2. Fertig. Der Planer läuft unter `https://eure-domain.de/ladeplan/`.

**Variante 2: in eine bestehende Seite einbetten (z. B. WordPress, Block „Individuelles HTML“)**

Den Ordner wie oben hochladen und dann einbetten:

```html
<iframe src="/ladeplan/" title="Ladeplan Hängerzug"
        style="width:100%;height:85vh;min-height:620px;border:0;border-radius:12px"
        allow="fullscreen" loading="lazy"></iframe>
```

Auf dem Handy schaltet der Planer automatisch auf die Handy-Ansicht um. Mit dem Vollbild-Knopf füllt er den ganzen Bildschirm.

**Variante 3: in DispoHub (Menüpunkt „LKW“)**

Ab DispoHub Beta 9.7 ist der Planer als Modul „LKW“ eingebaut. Zum Neu-Einbauen nach Änderungen: `python3 dispohub/einbau.py /pfad/zu/dispohub`. Details in [`dispohub/README.md`](dispohub/README.md).

**Variante 4: kostenlos hosten**

Den Ordner bei Netlify („Deploy manually“, Ordner hineinziehen) oder Cloudflare Pages hochladen, oder GitHub Pages auf diesen Ordner zeigen lassen.

### Was die Website braucht

- **Nur statische Dateien.** HTTPS wird empfohlen. Über HTTPS funktioniert der Planer nach dem ersten Aufruf auch offline (`sw.js`), und man kann ihn auf dem Handy mit „Zum Home-Bildschirm“ wie eine App ablegen (`manifest.webmanifest`).
- **Datenschutz**
  - Die Seite lädt nichts von fremden Servern. Schriften (Barlow, JetBrains Mono) und three.js liegen in `fonts/` und `vendor/`.
  - Es gibt keine Cookies, kein Tracking und keine Formulare.
  - Der Ladeplan wird nur im Browser des Nutzers gespeichert (`localStorage`) und nie übertragen.
- **Lizenzen:** three.js steht unter MIT (`vendor/LICENSE-three.txt`), die Schriften unter der SIL Open Font License (`fonts/LICENSE-*.txt`).

### Seitenbild für alle

Wer den Planer auf eine Website stellt und allen dasselbe Seitenbild zeigen will, legt das Bild in den Ordner (z. B. `seitenbild.jpg`, Querformat etwa 3 : 1) und trägt es in `index.html` ein:

```html
<meta name="ladeplan-seitenbild" content="seitenbild.jpg">
```

Ein Bild, das jemand im Datenblatt selbst lädt, hat Vorrang.

### Dateien

| Datei | Zweck |
|---|---|
| `index.html` | die App (HTML, CSS, JavaScript in einer Datei) |
| `vendor/` | three.js 0.147 und OrbitControls |
| `fonts/` | selbst gehostete Schriften mit `fonts.css` |
| `sw.js` | Offline-Cache; bei Änderungen `VERSION` hochzählen |
| `manifest.webmanifest`, `icon*.svg/png` | App-Symbol und Startbildschirm-Eintrag |
| `dispohub/` | Einbau als Modul „LKW“ in DispoHub (nicht für die Website) |

## Was er kann

- **Fahrzeuge**
  - LKW 221: Durchlade-Hängerzug aus Maschine 219 und Anhänger, 33 + 30 = 63 Stellplätze
  - LKW 219: die Maschine von 221 solo, 33 Stellplätze
  - LKW 213: Hängerzug aus dem Kammer-Auto 211 und Anhänger, 30 + 24 = 54 Stellplätze
  - LKW 211: die Maschine von 213 solo, Kammer-Auto mit 30 Stellplätzen
  - Anhänger allein mit 30 oder 24 Stellplätzen
  - Die Innenlänge jeder Einheit lässt sich im Datenblatt ändern.
- **Kammer-Auto (211, 213)**
  - Vorn an der Stirnwand liegt eine TK-Kammer, dahinter eine isolierte Quertrennwand (im Planer 12 cm), dann die Frische.
  - Die Wand kostet eine Reihe: 10 statt 11 Reihen, also 30 statt 33 Stellplätze.
  - Die Kammer ist 3 Reihen lang (2,17 m, 9 Stellplätze) und steht auf −22 °C. Größe (1 bis 9 Reihen) und Temperatur lassen sich einstellen.
  - „Hochklappen“ nimmt die Wand heraus, dann gibt es 33 Plätze in einem Raum. TK-Ware bleibt markiert und kommt beim Zurückklappen wieder in die Kammer.
  - Unten wählt man „Frische“ oder „TK-Kammer“ für neue Behälter. „Automatisch verteilen“ stellt TK-Ware in die Kammer.
- **Ladungsträger:** Rollbehälter blau, Hygiene-Rollbehälter, TK-Isotainer (TKT-Thermobehälter, hellblau), I2 Fleisch (Isotainer silber), Euro-Palette und CH3-Palette (CHEP). Isotainer, I2, CH3 und Hygiene-RBH haben umschaltbare Formate.
- **Setzen, Ziehen, Drehen**
  - Behälter werden per Tippen gesetzt. Die Vorschau rastet in Spuren und Reihen ein.
  - Behälter lassen sich ziehen, auch von der Maschine in den Anhänger oder auf die Rampe.
  - Drehen geht mit T, Löschen mit Entf, Rückgängig mit Strg+Z.
- **Automatisch verteilen:** stellt alle Behälter neu. Paletten kommen nach vorn an die Stirnwand, dahinter die Rollware. Gefüllt wird erst die Maschine, dann der Anhänger. **Nachrücken** schiebt alles bündig nach vorn.
- **Auswertung**
  - belegte und freie Stellplätze
  - „passt noch“ für Rollbehälter und Europaletten
  - Ladungsfront und Sperrbalken
  - Kühlung je Einheit, beim Kammer-Auto getrennt für TK-Kammer und Frische
  - Gewichte rechnet der Planer bewusst nicht, weil die Ware immer anders gepackt ist.
- **Ansichten**
  - A zeigt den LKW von außen: Koffer geschlossen, mit Seitenbild. Ohne eigenes Bild ist es ein neutrales Obst-und-Gemüse-Motiv. Ein eigenes Bild (z. B. ein Foto eurer Beschriftung) lässt sich im Datenblatt laden.
  - Tasten 1, 2 und 3 wählen Maschine, Anhänger oder den ganzen Zug.
  - X klappt den Aufbau auf: Dach und Wände heben sich, die Maschine fährt vor, die Stirnklappe wird zur Brücke.
  - V wechselt die Kamera: Übersicht, Seite, Draufsicht, Heck an der Rampe, über der Stirnwand.
  - C startet die Kamerafahrt.
- **Ladeliste:** zeigt je Einheit, was geladen ist, und lässt sich als Text kopieren (Reihe für Reihe).

Der Plan wird nur im eigenen Browser gespeichert (`localStorage`). Es gibt keinen Server und kein Konto.

## Datengrundlage

Die Maße und Hersteller stehen im Datenblatt der App, mit Quellen und Einstufung der Sicherheit. Kurz:

- „Wülhordt“ ist Wüllhorst Fahrzeugbau aus Selm-Bork, „Rohraufbau“ ist ROHR Spezialfahrzeuge aus Straubing.
- ROHR nennt für den Durchladezug DLE31 bei EDEKA 20 + 18 Europaletten oder 33 + 30 Rollcontainer.
- TK-Isotainer: TKT-Thermobehälter A-580, außen 735 × 825 × 1770 mm, Tür auf der 735-mm-Seite. Mit der Tür nach hinten passen 3 nebeneinander, eine Reihe ist 825 mm tief. C-720 und C-780 (955 mm tief) sind wählbar.
- Rollbehälter 724 × 815 mm, Gitterseite quer: 3 je Reihe, Reihe 724 mm tief. 8,08 m innen ergeben 33 Stellplätze, 7,30 m ergeben 30, 6,10 m ergeben 24.
- Kammer-Auto: 11 Reihen brauchen 7,96 m, im 8,08-m-Koffer bleiben 12 cm. Das reicht für keine Trennwand mit Dichtung, deshalb hat 211 nur 30 Plätze.
- Offene Annahmen, die vor dem Einsatz zu prüfen sind:
  - Lage der Trennwand und Größe der TK-Kammer im Kammer-Auto 211
  - Innenlänge des 24er-Anhängers von LKW 213 (im Planer 6,10 m)
  - CH3 als CHEP-Palette
  - I2 als Isotainer (silber oder blau, gleiches Maß wie TK)
  - Innenmaße eurer Koffer

Inoffizielles Planungswerkzeug, nicht von EDEKA, IVECO, ROHR oder Wüllhorst. Alle Werte ohne Gewähr. Maßgeblich sind Fahrzeugpapiere, Waage und die Vorgaben der Niederlassung.
