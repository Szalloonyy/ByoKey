//
//  HTMLPreviewView.swift
//  ByoKey
//
//  Zeigt die erzeugten Dateien als Seite an – zum Nachsehen, ob das Layout
//  stimmt, ohne das iPhone zu verlassen.
//
//  Die Anzeige ist bewusst eng eingezäunt, und zwar aus zwei Gründen:
//
//  1. Richtlinie 2.5.2 verbietet das Nachladen und Ausführen von Code, der
//     die App verändert. Hier wird nichts nachgeladen: die Dateien stammen
//     aus der Antwort, liegen im eigenen temporären Ordner und werden als
//     Inhalt angezeigt – wie ein Betrachter ein Dokument anzeigt. Die App
//     bekommt dadurch keine neue Fähigkeit.
//  2. Ein Fenster, das beliebige Adressen öffnen kann, wäre „unrestricted
//     web access" und zöge die Altersfreigabe auf 17+. Deshalb lässt der
//     Navigations-Wächter ausschließlich `file://`-Adressen unterhalb des
//     Vorschauordners durch. Alles andere wird abgewiesen und dem Nutzer
//     angezeigt – die Vorschau kann also nicht als Browser zweckentfremdet
//     werden.
//
//  Was hier nicht geht und auch nicht gehen kann: PHP. Dafür bräuchte es
//  einen Interpreter, und genau den darf eine iOS-App nicht mitbringen.
//  Die Vorschau sagt das offen, statt eine leere Seite zu zeigen.
//

import SwiftUI
import WebKit

struct HTMLPreviewView: View {
    @Environment(\.dismiss) private var dismiss

    let artifacts: [CodeArtifact]

    @State private var root: URL?
    @State private var entry: URL?
    @State private var entryName: String = ""
    @State private var blocked: String?
    @State private var setupError: String?
    @State private var reloadToken = 0

    private var htmlArtifacts: [CodeArtifact] {
        artifacts.filter { $0.filename.lowercased().hasSuffix(".html")
                        || $0.filename.lowercased().hasSuffix(".htm") }
    }

    private var phpArtifacts: [CodeArtifact] {
        artifacts.filter { $0.filename.lowercased().hasSuffix(".php") }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let setupError {
                    ContentUnavailableView("Vorschau nicht möglich",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(LocalizedStringKey(setupError)))
                } else if htmlArtifacts.isEmpty {
                    noHTML
                } else if let root, let entry {
                    VStack(spacing: 0) {
                        if let blocked {
                            banner(blocked)
                        }
                        if !phpArtifacts.isEmpty {
                            phpNotice
                        }
                        LocalWebView(entry: entry,
                                     root: root,
                                     reloadToken: reloadToken,
                                     blocked: $blocked)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(entryName.isEmpty ? Text("Vorschau") : Text(verbatim: entryName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if htmlArtifacts.count > 1 {
                        Menu {
                            ForEach(htmlArtifacts) { artifact in
                                Button(artifact.filename) { select(artifact) }
                            }
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                    } else {
                        Button {
                            blocked = nil
                            reloadToken += 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task { prepare() }
            .onDisappear { cleanup() }
        }
    }

    // MARK: - Bausteine

    private var noHTML: some View {
        ContentUnavailableView {
            Label("Nichts zum Anzeigen", systemImage: "safari")
        } description: {
            Text(phpArtifacts.isEmpty
                 ? "In dieser Auswahl ist keine HTML-Datei. Die Vorschau zeigt nur Seiten an."
                 : "Hier sind nur PHP-Dateien. PHP läuft auf einem Server – ein iPhone kann es nicht ausführen. Sichere die Dateien und lade sie auf deinen Webspace, oder lass dir vom Modell eine reine HTML-Fassung zum Ansehen geben.")
        }
    }

    private var phpNotice: some View {
        Label("PHP-Dateien werden nicht ausgeführt – nur die HTML-Seiten sind zu sehen.",
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.surfaceAlt)
    }

    private func banner(_ address: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Externer Aufruf blockiert")
                    .font(.caption.weight(.semibold))
                Text(address)
                    .font(.caption2.monospaced())
                    .lineLimit(2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Button {
                blocked = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.leading, 14)
        .background(Theme.surfaceAlt)
    }

    // MARK: - Ablauf

    private func prepare() {
        guard !htmlArtifacts.isEmpty else { return }
        do {
            let folder = try ZipArchive.writePreview(artifacts)
            root = folder
            // index.html gewinnt, sonst die erste Seite in der Antwort.
            let start = htmlArtifacts.first { $0.filename.lowercased().hasSuffix("index.html") }
                     ?? htmlArtifacts[0]
            select(start, in: folder)
        } catch {
            setupError = error.localizedDescription
        }
    }

    private func select(_ artifact: CodeArtifact) {
        guard let root else { return }
        select(artifact, in: root)
    }

    private func select(_ artifact: CodeArtifact, in folder: URL) {
        let relative = ZipArchive.sanitizeRelativePath(artifact.filename)
        entry = folder.appendingPathComponent(relative)
        entryName = relative
        blocked = nil
        reloadToken += 1
    }

    private func cleanup() {
        ZipArchive.clearPreview()
    }
}

// MARK: - Der eingezäunte Anzeigebereich

private struct LocalWebView: UIViewRepresentable {
    let entry: URL
    let root: URL
    let reloadToken: Int
    @Binding var blocked: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nichts aus der Vorschau überlebt sie: keine Cookies, kein Speicher.
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.loadedToken != reloadToken else { return }
        context.coordinator.loadedToken = reloadToken
        view.loadFileURL(entry, allowingReadAccessTo: root)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: LocalWebView
        var loadedToken = -1

        init(_ parent: LocalWebView) { self.parent = parent }

        /// Der Zaun für **Navigationen**: alles, was nicht als Datei im
        /// Vorschauordner liegt, wird abgewiesen – auch Weiterleitungen und
        /// eingebettete Rahmen.
        ///
        /// Für **Unterressourcen** (Bilder, Stylesheets, Schriften, `fetch`,
        /// `XMLHttpRequest`, `sendBeacon`) ruft WebKit diese Methode gar nicht
        /// auf. Die fängt die Content-Security-Policy ab, die
        /// `ZipArchive.withContentSecurityPolicy` beim Schreiben in jede
        /// HTML-Datei setzt. Erst beide zusammen halten, was die
        /// Review-Notizen versprechen – und erst dann ist „uneingeschränkter
        /// Webzugriff: nein" bei der Altersfreigabe belegbar.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let rootPath = parent.root.standardizedFileURL.path
            let targetPath = url.standardizedFileURL.path
            if url.isFileURL, targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") {
                decisionHandler(.allow)
            } else {
                if url.scheme != "about" {
                    report(url.absoluteString)
                }
                decisionHandler(.cancel)
            }
        }

        /// Kein zweites Fenster: `target="_blank"` soll nicht am Zaun vorbei.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, !url.isFileURL {
                report(url.absoluteString)
            }
            return nil
        }

        // Ohne diese drei bleibt eine Seite mit `alert()` hängen: WebKit
        // wartet auf einen Rückruf, den niemand gibt.
        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            report("alert(): \(message)")
            completionHandler()
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            report("confirm(): \(message)")
            completionHandler(true)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            report("prompt(): \(prompt)")
            completionHandler(defaultText)
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            reportFailure(error)
        }

        /// Der wichtigere der beiden Rückrufe: eine Datei, die gar nicht
        /// erst geladen werden kann, und jede Abweisung durch den Zaun oben
        /// scheitern **vorläufig** – `didFail` sieht davon nichts. Ohne
        /// diese Methode bliebe die Vorschau bei einem Fehler einfach weiss.
        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            reportFailure(error)
        }

        private func reportFailure(_ error: Error) {
            // Abbrüche durch den Zaun haben bereits eine bessere Meldung
            // bekommen; 102 ist „frame load interrupted by policy change".
            let code = (error as NSError).code
            guard code != NSURLErrorCancelled, code != 102 else { return }
            report(error.localizedDescription)
        }

        /// Delegate-Rückrufe kommen bereits auf dem Hauptstrang, aber ein
        /// direkter Schreibzugriff mitten in `decidePolicyFor` ändert den
        /// Zustand während SwiftUI gerade zeichnet. Ein Sprung in den
        /// nächsten Durchlauf vermeidet die Warnung.
        private func report(_ message: String) {
            DispatchQueue.main.async { [parent] in parent.blocked = message }
        }
    }
}
