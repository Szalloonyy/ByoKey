//
//  ArtifactExportView.swift
//  ByoKey
//
//  Nimmt die Quelltextdateien aus einer Antwort und legt sie als ZIP ins
//  Teilen-Blatt. Von dort geht "In Dateien sichern" – auf iPhone und iPad der
//  übliche Weg, um an ein Archiv zu kommen, das sich anschließend in einem
//  Editor oder per iCloud weiterverarbeiten lässt.
//
//  Vor dem Export darf jeder Name geändert und jede Datei abgewählt werden.
//  Geratene Namen sind markiert, damit niemand versehentlich "datei-3.txt"
//  exportiert, wo "config.php" gemeint war.
//

import SwiftUI

/// Ein Formatierer statt einer Neuanlage pro Aufruf: `ByteCountFormatter` ist
/// teuer im Aufbau und wird hier in einer Schleife über alle Dateien gebraucht.
///
/// Am Hauptaktor und **nicht** `nonisolated(unsafe)`: Formatierer sind nicht
/// threadsicher. Gebraucht wird er nur in Ansichten, die ohnehin dort laufen.
@MainActor private let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
}()

struct ArtifactExportView: View {
    @Environment(\.dismiss) private var dismiss

    let sourceText: String
    let suggestedName: String

    @State private var artifacts: [CodeArtifact] = []
    @State private var archiveName: String = "projekt"
    @State private var archiveURL: URL?
    @State private var fileURLs: [Int: URL] = [:]
    @State private var buildError: String?
    @State private var showPreview = false

    private var selected: [CodeArtifact] {
        artifacts.filter(\.isSelected)
    }

    /// Die Einzeldateien in der Reihenfolge der Liste. Über `ShareLink(items:)`
    /// landen sie beim Sichern alle im selben Zielordner – das ist der Weg zu
    /// „index.php und style.css liegen nebeneinander" ohne Umweg über ein
    /// Archiv, das erst wieder entpackt werden muss.
    private var plainFileURLs: [URL] {
        selected.compactMap { fileURLs[$0.id] }
    }

    private var hasPreviewableHTML: Bool {
        selected.contains {
            let name = $0.filename.lowercased()
            return name.hasSuffix(".html") || name.hasSuffix(".htm")
        }
    }

    private var totalBytes: Int {
        selected.reduce(0) { $0 + $1.byteCount }
    }

    /// Ändert sich, sobald Auswahl, Name oder Archivname sich ändern.
    /// Steuert den Neuaufbau, ohne bei jedem Bildaufbau zu packen.
    private var buildKey: String {
        archiveName + "|" + selected.map { "\($0.id):\($0.filename)" }.joined(separator: ",")
    }

    var body: some View {
        NavigationStack {
            Group {
                if artifacts.isEmpty {
                    ContentUnavailableView("Keine Dateien gefunden",
                                           systemImage: "doc.text.magnifyingglass",
                                           description: Text("In dieser Antwort stehen keine Code-Blöcke, die sich als Datei sichern lassen."))
                } else {
                    form
                }
            }
            .navigationTitle("Dateien exportieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .task {
                // Reste früherer Exporte entfernen: Quelltext soll nicht
                // länger als nötig im temporären Ordner liegen.
                ZipArchive.clearExports()
                artifacts = CodeArtifactExtractor.artifacts(in: sourceText)
                archiveName = Self.projectName(from: suggestedName)
            }
            .task(id: buildKey) {
                // Entprellen: beim Tippen im Namensfeld wird der vorherige Lauf
                // abgebrochen, bevor überhaupt gepackt wird. Ohne das liefe
                // CRC, Kompression und Schreiben bei jedem Tastendruck.
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                rebuild()
            }
            .fullScreenCover(isPresented: $showPreview) {
                // Vollbild, weil eine Seitenvorschau in einem halbhohen Blatt
                // nichts über das Layout aussagt.
                HTMLPreviewView(artifacts: selected)
            }
        }
    }

    // MARK: - Inhalt

    private var form: some View {
        Form {
            Section {
                ForEach($artifacts) { $artifact in
                    row(for: $artifact)
                }
            } header: {
                HStack {
                    Text("Gefundene Dateien")
                    Spacer()
                    Button(allSelected ? "Keine" : "Alle") {
                        let target = !allSelected
                        for index in artifacts.indices { artifacts[index].isSelected = target }
                    }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
                }
            } footer: {
                Text("Namen lassen sich antippen und ändern. Unterordner wie „inc/config.php“ bleiben im Archiv erhalten.")
            }

            Section {
                HStack {
                    TextField("projekt", text: $archiveName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(".zip")
                        .foregroundStyle(Theme.textSecondary)
                }
            } header: {
                Text("Archivname")
            }

            Section {
                if hasPreviewableHTML {
                    Button {
                        showPreview = true
                    } label: {
                        Label("Seite ansehen", systemImage: "safari")
                            .font(.body.weight(.semibold))
                    }
                    .disabled(selected.isEmpty)
                }

                if !plainFileURLs.isEmpty {
                    ShareLink(items: plainFileURLs) {
                        Label(plainFileURLs.count == 1
                              ? "Datei einzeln sichern"
                              : "\(plainFileURLs.count) Dateien einzeln sichern",
                              systemImage: "doc.badge.arrow.up")
                    }
                }

                if let archiveURL, !selected.isEmpty {
                    ShareLink(item: archiveURL) {
                        // Die Mehrzahl im Text zusammenzubauen erzeugt einen
                        // Schlüssel, den kein Katalog findet – und im
                        // Polnischen wäre die Regel ohnehin eine andere.
                        if selected.count == 1 {
                            Label("1 Datei als ZIP sichern",
                                  systemImage: "square.and.arrow.down")
                        } else {
                            Label("\(selected.count) Dateien als ZIP sichern",
                                  systemImage: "square.and.arrow.down")
                        }
                    }
                } else if plainFileURLs.isEmpty {
                    Label("Keine Datei ausgewählt", systemImage: "square.and.arrow.down")
                        .foregroundStyle(Theme.textSecondary)
                }

                if let buildError {
                    Label(LocalizedStringKey(buildError), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Im Teilen-Blatt „In Dateien sichern“ wählen. Einzeln gesichert landen die Dateien so, wie sie heißen, im gewählten Ordner – etwa als index.php und style.css. Das ZIP ist der bessere Weg, wenn Unterordner erhalten bleiben sollen.")
                    if hasPreviewableHTML {
                        Text("„Seite ansehen“ zeigt die HTML-Dateien direkt hier. PHP kann ein iPhone nicht ausführen – dafür braucht es einen Server.")
                    }
                    if totalBytes > 0 {
                        Text("Gesamtgröße unkomprimiert: \(byteFormatter.string(fromByteCount: Int64(totalBytes)))")
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func row(for artifact: Binding<CodeArtifact>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                artifact.wrappedValue.isSelected.toggle()
            } label: {
                Image(systemName: artifact.wrappedValue.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(artifact.wrappedValue.isSelected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(artifact.wrappedValue.isSelected ? "Abwählen" : "Auswählen")

            VStack(alignment: .leading, spacing: 3) {
                TextField("Dateiname", text: artifact.filename)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())

                HStack(spacing: 6) {
                    if artifact.wrappedValue.isNameGuessed {
                        Label("Name geraten", systemImage: "questionmark.circle")
                            .foregroundStyle(Theme.warning)
                    }
                    Text("\(artifact.wrappedValue.lineCount) Zeilen")
                    Text("·")
                    Text(byteFormatter.string(fromByteCount: Int64(artifact.wrappedValue.byteCount)))
                }
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            }

            if let url = fileURLs[artifact.wrappedValue.id] {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                // Die Tippfläche ist breiter als das Symbol. Ohne diesen
                // Ausgleich stünde es sichtbar weiter innen als die Werte
                // in den Zeilen darüber.
                .padding(.trailing, -10)
                .accessibilityLabel("Einzeln teilen")
            }
        }
    }

    private var allSelected: Bool {
        !artifacts.isEmpty && artifacts.allSatisfy(\.isSelected)
    }

    // MARK: - Archiv bauen

    private func rebuild() {
        buildError = nil
        fileURLs = [:]
        archiveURL = nil

        let chosen = selected
        guard !chosen.isEmpty else { return }

        do {
            let entries = chosen.map {
                ZipArchive.Entry(name: ZipArchive.sanitizeRelativePath($0.filename), text: $0.code)
            }
            let name = ZipArchive.sanitizeFilename(
                (archiveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "projekt" : archiveName) + ".zip"
            )
            archiveURL = try ZipArchive.write(entries, filename: name)

            for artifact in chosen {
                let single = ZipArchive.sanitizeFilename(
                    artifact.filename.components(separatedBy: "/").last ?? artifact.filename
                )
                // Eigener Unterordner je Datei: "src/index.php" und
                // "inc/index.php" würden sonst beide als "index.php" landen
                // und sich gegenseitig überschreiben.
                fileURLs[artifact.id] = try ZipArchive.writeSingle(name: single,
                                                                   text: artifact.code,
                                                                   subfolder: "datei-\(artifact.id)")
            }
        } catch {
            buildError = Loc.tr("Das Archiv konnte nicht erstellt werden: %@",
                                error.localizedDescription)
        }
    }

    /// Aus dem Chat-Titel einen brauchbaren Dateinamen machen.
    private static func projectName(from title: String) -> String {
        let lowered = title.lowercased()
            .replacingOccurrences(of: "ä", with: "ae")
            .replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue")
            .replacingOccurrences(of: "ß", with: "ss")

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        var result = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = scalar == "-"
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        let trimmed = String(result.prefix(40))
        return trimmed.isEmpty ? "projekt" : trimmed
    }
}
