# Ladeplan Hängerzug

Interaktiver 3D-Ladeplan für einen Kühl-Hängerzug im Filialverkehr: Iveco S-Way LNG als Maschine (Motorwagen) mit Tandem-Anhänger und Durchlade-Kühlkoffer von ROHR bzw. Wüllhorst. Dazu kommen Sattelzug, Solo-LKW und Anhänger allein. Vorbild für die Bedienung war [„The Plane of Focus“](https://sael.net/plane-of-focus/): ein echtes Fahrzeug, aufgemacht, mit Live-Werten direkt im 3D-Bild.

Alles steckt in einer Datei: `index.html`. Sie braucht keinen Build. Zum Starten die Datei im Browser öffnen; three.js (0.147, UMD) kommt von jsDelivr.

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
- **Nach Tour laden:** Die Märkte werden in Anfahrtsreihenfolge verteilt. Der letzte Markt steht an der Stirnwand, der erste an der Tür. Beim Durchladezug gilt das über beide Einheiten: Die Ware für den ersten Markt kommt in den Anhänger.
- **Auswertung**
  - belegte Stellplätze sowie „passt noch“ für Rollbehälter und Europaletten
  - Gewicht und Nutzlast
  - Achslasten als Hebel-Näherung: Vorderachse, Hinterachsen, Stützlast, Sattellast
  - Schwerpunkt, Ladungsfront und Sperrbalken
  - Kühlung je Einheit
  - Entladereihenfolge: Welche Behälter sind zugestellt?
- **Ansichten**
  - Tasten 1, 2 und 3 wählen Maschine, Anhänger oder den ganzen Zug.
  - X klappt den Aufbau auf: Dach und Wände heben sich, die Maschine fährt vor, die Stirnklappe wird zur Brücke.
  - V wechselt die Kamera: Übersicht, Seite, Draufsicht, Heck an der Rampe, über der Stirnwand.
  - C startet die Kamerafahrt.
- **Ladeliste:** kann als Text kopiert werden, gegliedert nach Markt und nach Reihe.

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
