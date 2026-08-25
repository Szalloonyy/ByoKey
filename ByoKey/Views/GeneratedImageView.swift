//
//  GeneratedImageView.swift
//  ByoKey
//
//  Ein erzeugtes Bild im Chat – und die Vollbildansicht dahinter.
//
//  Drei Wege zum Sichern, weil jeder Nutzer einen anderen erwartet:
//  antippen und unten links auf „Bild sichern“, das Bild gedrückt halten,
//  oder die Zeile unter dem Bild. Alle drei landen im selben Aufruf.
//

import SwiftUI
import UIKit

struct GeneratedImageView: View {
    let url: URL

    /// Breite geteilt durch Höhe, auf ein anzeigbares Fenster begrenzt.
    /// **Ein `let`, kein berechneter Wert:** die reservierte Höhe darf sich
    /// über die Lebensdauer der Zeile nicht ändern, sonst springt genau das,
    /// was sie verhindern soll. `nil` heisst: das Format kann iOS nicht
    /// anzeigen, dann wird kein Platz reserviert.
    private let reservedRatio: Double?

    @State private var image: UIImage?
    /// Zu welcher Datei das gehaltene Bild gehört. Ohne diese Notiz bliebe
    /// nach einem Fehlversuch mit anschliessender Wiederholung das Bild der
    /// alten Datei stehen – `@State` überlebt den Wechsel, die Ansichts-
    /// Identität hängt an der Nachricht, nicht am Dateinamen.
    @State private var loadedURL: URL?
    @State private var failure: LoadFailure?
    @State private var showsViewer = false
    @State private var saveNotice: SaveNotice?

    /// Untergrenze: hochformatige Bilder werden nicht höher als etwa das
    /// 1,6-fache der Blasenbreite. Obergrenze: sehr breite Banner behalten
    /// eine sichtbare Höhe.
    private static let minRatio: Double = 0.62
    private static let maxRatio: Double = 2.4

    /// Der `init` ist der ganze Trick.
    ///
    /// Verlässt die Zeile den sichtbaren Bereich, gibt sie ihr Bild frei
    /// (siehe `onScrollVisibilityChange` im `body`) und holt es beim
    /// Zurückscrollen wieder. Beides passiert **ohne** Ladeanzeige und
    /// **ohne** Höhenänderung: das Seitenverhältnis steht schon fest, und ein
    /// bereits entpacktes Bild kommt unmittelbar aus dem Zwischenspeicher.
    init(url: URL, aspectRatio: Double?) {
        self.url = url
        let cached = ImageFileLoader.cached(url, maxPixel: ImageFileLoader.previewMaxPixel)
        _image = State(initialValue: cached)
        _loadedURL = State(initialValue: cached == nil ? nil : url)

        // Bewusst **nicht** aus dem entpackten Bild: `reservedAspectRatio`
        // schreibt den Wert einmal fest, damit jeder spätere Aufbau derselben
        // Zeile exakt dieselbe Höhe bekommt.
        reservedRatio = ImageFileLoader.reservedAspectRatio(for: url, known: aspectRatio)
            .map { min(max($0, Self.minRatio), Self.maxRatio) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            placeholderBox
                .overlay { preview }
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .onTapGesture {
                    guard image != nil else { return }
                    showsViewer = true
                }
                // Gedrückt halten: der Weg, den iOS-Nutzer aus Nachrichten
                // und Safari kennen.
                // Einträge immer anlegen, nur abgeschaltet: ein Menü ohne
                // jeden Eintrag öffnet sich als leeres graues Kästchen.
                .contextMenu {
                    Button {
                        save()
                    } label: {
                        Label("Bild sichern", systemImage: "arrow.down.to.line")
                    }
                    .disabled(image == nil)
                    ShareLink(item: url) {
                        Label("Teilen", systemImage: "square.and.arrow.up")
                    }
                    .disabled(image == nil)
                }
                .accessibilityElement()
                .accessibilityLabel("Erzeugtes Bild")
                .accessibilityHint("Antippen, um es groß anzusehen. Gedrückt halten zum Sichern.")

            // Immer sichtbar, nur abgeschaltet, solange nichts geladen ist.
            // Erschiene die Zeile erst mit dem Bild, wäre das eine zweite
            // Höhenänderung – und damit ein zweiter Sprung im Verlauf.
            HStack(spacing: 18) {
                Button {
                    save()
                } label: {
                    Label("Bild sichern", systemImage: "arrow.down.to.line")
                }
                .disabled(image == nil)
                ShareLink(item: url) {
                    Label("Teilen", systemImage: "square.and.arrow.up")
                }
                .disabled(image == nil)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(image == nil ? Theme.textSecondary : Theme.accent)
        }
        .task(id: url) {
            await loadPreview()
        }
        // Bild freigeben, sobald die Zeile aus dem Bild scrollt – und
        // zurückholen, sobald sie wieder hereinkommt.
        //
        // Das übernahm früher der `LazyVStack`: er warf den Zustand einer
        // Zeile weg, wenn sie den sichtbaren Bereich verliess. Seit der
        // Verlauf ein `VStack` ist (siehe `ChatView.transcript`), bleibt jede
        // Zeile am Leben – und mit ihr jedes entpackte Bild. Ein entpacktes
        // Vorschaubild sind 1200 × 1200 × 4 Byte, also **5,8 MB**. Zwanzig
        // Bilder in einem Chat wären 115 MB, die dauerhaft stehen bleiben,
        // und zwar **am Riegel von `ImageMemory` vorbei**: dessen Verdrängung
        // gibt nur die eigene Referenz frei, die Ansicht hält das Bild
        // weiter. Ohne diese Zeilen wäre der Wechsel auf `VStack` gegen einen
        // Speicherfehler eingetauscht.
        //
        // Kostenlos zu haben, weil die Höhe der Zeile **nicht** am Bild
        // hängt: `reservedRatio` steht vor dem Laden fest, der Platzhalter ist
        // exakt so gross wie das Bild. Freigeben und Nachladen ändern also
        // keine einzige Höhe – genau die Eigenschaft, für die es den `VStack`
        // gibt, bleibt unangetastet.
        //
        // Ein kleiner Schwellwert: schon ein Zipfel im Bild soll laden.
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            if visible {
                guard image == nil else { return }
                Task { await loadPreview() }
            } else {
                image = nil
                loadedURL = nil
            }
        }
        .fullScreenCover(isPresented: $showsViewer) {
            ImageViewerView(url: url)
        }
        .alert(Text(LocalizedStringKey(saveNotice?.title ?? "")),
               isPresented: saveNoticeBinding) {
            Button("OK", role: .cancel) { saveNotice = nil }
        } message: {
            Text(LocalizedStringKey(saveNotice?.text ?? ""))
        }
    }

    /// `alert(_:isPresented:)` statt des alten `alert(item:)`: letzteres ist
    /// seit iOS 15 überholt und würde beim Übersetzen eine Warnung erzeugen.
    private var saveNoticeBinding: Binding<Bool> {
        Binding(get: { saveNotice != nil },
                set: { if !$0 { saveNotice = nil } })
    }

    /// Der reservierte Platz. `Rectangle` ist in beiden Richtungen dehnbar,
    /// `aspectRatio(_:contentMode: .fit)` macht daraus eine feste Höhe zur
    /// angebotenen Breite. Dieser Kasten steht ab dem ersten Zeichnen und
    /// ändert seine Größe nie wieder – weder wenn das Bild eintrifft noch
    /// wenn die Zeile beim Scrollen neu aufgebaut wird.
    @ViewBuilder
    private var placeholderBox: some View {
        if let reservedRatio {
            Rectangle()
                .fill(Theme.surfaceAlt)
                .aspectRatio(CGFloat(reservedRatio), contentMode: .fit)
        } else {
            // Nicht anzeigbares Format: ein leerer Kasten über die ganze
            // Blasenbreite wäre hier nur eine grosse graue Fläche. Die
            // Information steht ab dem ersten Zeichnen fest, ein Sprung kann
            // daraus also nicht entstehen.
            Color.clear.frame(height: 0)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            // `.fill`, wenn das Bild hochformatiger ist als der reservierte
            // Kasten: dann wird beschnitten statt geschrumpft. Vollständig
            // ist es eine Berührung entfernt in der Vollbildansicht.
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: needsCropping ? .fill : .fit)
        } else if let failure {
            Label(LocalizedStringKey(failure.text), systemImage: "photo.badge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(12)
        } else {
            ProgressView()
        }
    }

    /// Weicht das Bild vom reservierten Kasten ab, wird gefüllt und
    /// beschnitten statt geschrumpft – graue Balken sähen schlechter aus als
    /// ein Ausschnitt, und vollständig ist das Bild eine Berührung entfernt.
    private var needsCropping: Bool {
        guard let image, let reservedRatio, image.size.height > 0 else { return false }
        return abs(Double(image.size.width / image.size.height) - reservedRatio) > 0.001
    }

    private func loadPreview() async {
        let target = url
        // Kam das Bild schon aus dem Zwischenspeicher, ist hier nichts zu tun.
        // Es auf `nil` zu setzen und neu zu laden wäre ein Flackern ohne Zweck.
        if image != nil, loadedURL == target { return }
        if loadedURL != target { image = nil }
        failure = nil
        let loaded = await Task.detached(priority: .userInitiated) {
            ImageFileLoader.load(target, maxPixel: ImageFileLoader.previewMaxPixel)
        }.value
        guard !Task.isCancelled else { return }
        image = loaded
        loadedURL = loaded == nil ? nil : target
        failure = loaded == nil ? LoadFailure(url: target) : nil
    }

    private func save() {
        Task {
            saveNotice = SaveNotice(outcome: await PhotoLibrarySaver.save(imageAt: url))
        }
    }
}

/// Vollbild: das Bild in voller Auflösung, zoombar, mit dem Sichern-Knopf
/// unten links.
struct ImageViewerView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var failure: LoadFailure?
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var isSaving = false
    @State private var saveNotice: SaveNotice?

    private let maxZoom: CGFloat = 6

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                            // Sichtbar 36 Punkte, treffbar 44 – Apples
                            // Mindestgrösse für Bedienelemente.
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("Schließen")
                }
                Spacer()
                // Unten links, wie gewünscht – und weit genug vom rechten
                // Rand, dass das Teilen-Blatt daneben Platz hat.
                HStack(spacing: 12) {
                    saveButton
                    if image != nil {
                        ShareLink(item: url) {
                            Label("Teilen", systemImage: "square.and.arrow.up")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    Spacer()
                }
            }
            .padding(16)
            .foregroundStyle(.white)
        }
        .task {
            await loadFullSize()
        }
        .onDisappear {
            // 36 MB, die sonst stehen blieben, bis das nächste Bild geöffnet
            // wird.
            ImageFileLoader.releaseFullSize()
        }
        .alert(Text(LocalizedStringKey(saveNotice?.title ?? "")),
               isPresented: saveNoticeBinding) {
            Button("OK", role: .cancel) { saveNotice = nil }
        } message: {
            Text(LocalizedStringKey(saveNotice?.text ?? ""))
        }
    }

    /// `alert(_:isPresented:)` statt des alten `alert(item:)`: letzteres ist
    /// seit iOS 15 überholt und würde beim Übersetzen eine Warnung erzeugen.
    private var saveNoticeBinding: Binding<Bool> {
        Binding(get: { saveNotice != nil },
                set: { if !$0 { saveNotice = nil } })
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            zoom = min(max(1, committedZoom * value.magnification), maxZoom)
                        }
                        .onEnded { _ in
                            committedZoom = zoom
                            if zoom <= 1 { resetPosition() }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            // Ohne Zoom bleibt das Bild stehen; sonst
                            // verschöbe es sich beim Wischen ins Nichts.
                            guard committedZoom > 1 else { return }
                            offset = CGSize(width: committedOffset.width + value.translation.width,
                                            height: committedOffset.height + value.translation.height)
                        }
                        .onEnded { _ in
                            committedOffset = offset
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if committedZoom > 1 {
                            zoom = 1
                            committedZoom = 1
                            resetPosition()
                        } else {
                            zoom = 2.5
                            committedZoom = 2.5
                        }
                    }
                }
                .accessibilityLabel("Erzeugtes Bild in voller Größe")
        } else if let failure {
            Label(LocalizedStringKey(failure.text), systemImage: "photo.badge.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        } else {
            ProgressView()
                .tint(.white)
        }
    }

    private var saveButton: some View {
        Button {
            guard !isSaving else { return }
            isSaving = true
            Task {
                saveNotice = SaveNotice(outcome: await PhotoLibrarySaver.save(imageAt: url))
                isSaving = false
            }
        } label: {
            HStack(spacing: 6) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.down.to.line")
                }
                Text("Bild sichern")
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .disabled(image == nil || isSaving)
    }

    private func resetPosition() {
        offset = .zero
        committedOffset = .zero
    }

    private func loadFullSize() async {
        let target = url
        let loaded = await Task.detached(priority: .userInitiated) {
            ImageFileLoader.load(target, maxPixel: ImageFileLoader.fullMaxPixel)
        }.value
        guard !Task.isCancelled else { return }
        image = loaded
        failure = loaded == nil ? LoadFailure(url: target) : nil
    }
}

/// Rückmeldung nach dem Sichern. Kurzer Titel, Erklärung im Rumpf – ein
/// zweisätziger Fettdruck-Titel ohne Rumpf liest sich schlecht.
struct SaveNotice: Identifiable {
    let id = UUID()
    let outcome: PhotoLibrarySaver.Outcome

    /// Deutscher Text = Schlüssel im Katalog.
    var title: String {
        switch outcome {
        case .saved:      return "In „Fotos“ gesichert"
        case .denied:     return "Kein Zugriff auf „Fotos“"
        case .restricted: return "Kein Zugriff auf „Fotos“"
        case .failed:     return "Nicht gesichert"
        }
    }

    var text: String {
        switch outcome {
        case .saved:
            return "Du findest das Bild jetzt in deiner Fotomediathek."
        case .denied:
            return "ByoKey darf keine Bilder hinzufügen. Du kannst das in den iOS-Einstellungen unter Datenschutz › Fotos ändern."
        case .restricted:
            return "Der Zugriff auf die Fotomediathek ist auf diesem Gerät eingeschränkt – etwa durch die Bildschirmzeit oder eine Geräteverwaltung."
        case .failed:
            return "Das Bild konnte nicht in die Fotomediathek übernommen werden."
        }
    }
}

/// Warum das Bild nicht angezeigt werden kann. Der Unterschied zählt: ein
/// Format, das iOS gar nicht kennt (SVG), ist kein Fehler der App, und
/// „lässt sich nicht anzeigen“ wäre dort eine irreführende Auskunft.
struct LoadFailure {
    let isUnsupportedFormat: Bool

    init(url: URL) {
        isUnsupportedFormat = !ImageFileLoader.isDisplayable(url)
    }

    var text: String {
        isUnsupportedFormat
            ? "Dieses Bildformat kann iOS nicht anzeigen. Über „Teilen“ lässt es sich trotzdem sichern."
            : "Das Bild lässt sich nicht anzeigen."
    }
}
