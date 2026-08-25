//
//  ImageMemory.swift
//  ByoKey
//
//  Entpackte Bildvorschauen im Arbeitsspeicher – mit **festen Regeln**.
//
//  Vorher lag das in einem `NSCache`. Der räumt nach Regeln, die Apple nicht
//  dokumentiert, und bei Speicherdruck auch mal komplett. Daraus entstand ein
//  Fehler, der sich sehr merkwürdig las: „alle Bilder sind da, nur das zuletzt
//  erzeugte wird bei jedem Chat-Wechsel neu geladen."
//
//  Der Ablauf dahinter:
//
//  1. Chat betreten. Der Verlauf setzt am Ende auf, also wird
//     zuerst die unterste Zeile gebaut – das neueste Bild.
//  2. Der Nutzer scrollt nach oben. Jedes ältere Bild wird dabei gelesen und
//     rückt in der Benutzungsreihenfolge nach vorn.
//  3. Das neueste Bild ist inzwischen ausserhalb des Sichtfelds. Der
//     `LazyVStack` baut seine Zeile nicht mehr, es wird nicht mehr gelesen –
//     und ist damit der **am längsten nicht benutzte** Eintrag.
//  4. Chat wechseln und zurück: gebaut wird wieder zuerst die unterste Zeile.
//     Genau der Eintrag, der als erster verdrängt wurde.
//
//  Deshalb hier ein eigener Speicher mit starken Referenzen, klarer
//  Verdrängung nach Alter – und einem Riegel: die Bilder des **gerade offenen
//  Chats** sind festgesteckt und fliegen nie heraus. Was man beim Betreten
//  eines Chats sieht, ist damit zugesichert da und nicht bloss wahrscheinlich.
//

import Foundation
import UIKit

/// Nicht an den Hauptaktor gebunden, sondern über eine Sperre geschützt:
/// gelesen wird beim Aufbau einer Ansicht, geschrieben nach dem Entpacken
/// abseits des Hauptthreads.
final class ImageMemory {

    static let shared = ImageMemory()

    /// Weiche Grenze. Bis hierher werden nur **nicht** festgesteckte
    /// Einträge verdrängt.
    ///
    /// Sie muss deutlich über dem liegen, was das Festgesteckte allein
    /// belegen kann: zwölf Vorschauen à 1200 Bildpunkten sind rund 70 MB.
    /// Läge die Grenze darunter, wäre sie schon vom Festgesteckten
    /// ausgeschöpft – jede frisch entpackte ältere Vorschau flöge unmittelbar
    /// nach dem Ablegen wieder heraus, und der Speicher wirkte gar nicht mehr.
    private let softLimit = 96 * 1024 * 1024

    /// Harte Grenze. Darüber fliegt auch Festgestecktes – sonst hielte ein
    /// einmal durchgescrollter Chat mit fünfzig Bildern knapp 300 MB fest,
    /// und iOS beendet die App, statt eine Ladeanzeige zu zeigen. Eine
    /// Ladeanzeige ist das kleinere Übel.
    private let hardLimit = 144 * 1024 * 1024

    private let lock = NSLock()
    private var images: [String: UIImage] = [:]
    private var costs: [String: Int] = [:]
    /// Ältester Zugriff zuerst.
    private var order: [String] = []
    private var pinned: Set<String> = []
    private var total = 0

    private init() {
        // `NSCache` gab bei Speicherdruck von selbst frei; starke Referenzen
        // tun das nicht. Ohne diesen Beobachter wäre der Umbau ein Rückschritt.
        // Der Beobachter-Schlüssel wird nicht aufgehoben: dieses Objekt lebt
        // so lange wie die App, es gibt nichts abzumelden. Ohne die Zuweisung
        // an `_` meldet der Übersetzer einen ungenutzten Rückgabewert.
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.purge()
        }
    }

    /// Bei Speicherwarnung: alles bis auf das Festgesteckte freigeben.
    func purge() {
        lock.lock()
        defer { lock.unlock() }
        for key in order where !pinned.contains(key) {
            images.removeValue(forKey: key)
            total -= costs.removeValue(forKey: key) ?? 0
        }
        order.removeAll { !pinned.contains($0) }
    }

    // MARK: - Lesen und Schreiben

    func image(for key: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let image = images[key] else { return nil }
        touch(key)
        return image
    }

    func store(_ image: UIImage, for key: String) {
        lock.lock()
        defer { lock.unlock() }

        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        if images[key] != nil { total -= costs[key] ?? 0 }
        images[key] = image
        costs[key] = cost
        total += cost
        touch(key)
        evictIfNeeded()
    }

    /// Steckt die Bilder des gerade offenen Chats fest und löst alle anderen.
    ///
    /// Wird beim Betreten eines Chats gerufen. Ohne diesen Riegel entscheidet
    /// allein die Reihenfolge der Zugriffe, was überlebt – und die läuft beim
    /// Scrollen genau gegen das Bild, das man als nächstes wieder braucht.
    func pin(_ keys: [String]) {
        lock.lock()
        defer { lock.unlock() }
        pinned = Set(keys)
        evictIfNeeded()
    }

    /// Teil von „Alle Daten löschen".
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        images.removeAll()
        costs.removeAll()
        order.removeAll()
        pinned.removeAll()
        total = 0
    }

    // MARK: - Innenleben

    /// Erwartet, dass die Sperre bereits gehalten wird.
    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }

    /// Erwartet, dass die Sperre bereits gehalten wird.
    private func evictIfNeeded() {
        // Erste Runde: nur Ungesteckte. `index` wird beim Entfernen bewusst
        // **nicht** erhöht – das nächste Element rückt auf denselben Platz.
        var index = 0
        while total > softLimit, index < order.count {
            let key = order[index]
            if pinned.contains(key) {
                index += 1
                continue
            }
            remove(at: index)
        }

        // Zweite Runde: über der harten Grenze zählt der Riegel nicht mehr.
        while total > hardLimit, !order.isEmpty {
            remove(at: 0)
        }
    }

    /// Erwartet, dass die Sperre bereits gehalten wird.
    private func remove(at index: Int) {
        let key = order.remove(at: index)
        images.removeValue(forKey: key)
        total -= costs.removeValue(forKey: key) ?? 0
    }
}
