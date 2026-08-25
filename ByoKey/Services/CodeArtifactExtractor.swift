//
//  CodeArtifactExtractor.swift
//  ByoKey
//
//  Findet in einer Antwort die enthaltenen Quelltextdateien.
//
//  Modelle geben den Dateinamen auf sehr unterschiedliche Weise an. Die
//  Erkennung probiert deshalb mehrere Stellen in dieser Reihenfolge durch:
//
//    1. Im Zaun selbst:      ```php index.php      oder  ```php:index.php
//    2. In der Zeile davor:  **index.php**  ·  ### index.php  ·  Datei: index.php
//                            `index.php`   ·  <!-- index.php -->
//    3. In der ersten Codezeile: // index.php  ·  # index.php  ·  <!-- index.php -->
//    4. Ersatzname aus der Sprache: datei-1.php
//
//  Geraten heißt nicht falsch, aber der Nutzer soll es sehen: `isNameGuessed`
//  markiert solche Einträge in der Oberfläche, damit er sie vor dem Export
//  umbenennen kann.
//

import Foundation

struct CodeArtifact: Identifiable, Hashable {
    let id: Int
    var filename: String
    let language: String?
    let code: String
    var isSelected: Bool
    /// true, wenn kein Name im Text stand und einer erzeugt wurde.
    let isNameGuessed: Bool

    var byteCount: Int { code.utf8.count }

    var lineCount: Int {
        code.isEmpty ? 0 : code.components(separatedBy: "\n").count
    }
}

enum CodeArtifactExtractor {

    // MARK: - Sprache zu Dateiendung

    private static let extensions: [String: String] = [
        "php": "php", "html": "html", "htm": "html", "xhtml": "html",
        "css": "css", "scss": "scss", "sass": "sass", "less": "less",
        "js": "js", "javascript": "js", "mjs": "mjs", "cjs": "cjs",
        "ts": "ts", "typescript": "ts", "jsx": "jsx", "tsx": "tsx",
        "swift": "swift", "objc": "m", "objectivec": "m",
        "python": "py", "py": "py", "python3": "py",
        "json": "json", "jsonc": "json", "json5": "json5",
        "yaml": "yml", "yml": "yml", "toml": "toml", "ini": "ini", "conf": "conf",
        "sql": "sql", "graphql": "graphql", "gql": "graphql",
        "sh": "sh", "bash": "sh", "shell": "sh", "zsh": "sh", "fish": "fish",
        "md": "md", "markdown": "md", "xml": "xml", "svg": "svg", "plist": "plist",
        "java": "java", "kotlin": "kt", "kt": "kt", "groovy": "groovy",
        "c": "c", "h": "h", "cpp": "cpp", "c++": "cpp", "cc": "cpp", "hpp": "hpp",
        "cs": "cs", "csharp": "cs", "go": "go", "golang": "go",
        "rb": "rb", "ruby": "rb", "rs": "rs", "rust": "rs",
        "dart": "dart", "lua": "lua", "perl": "pl", "r": "R",
        "vue": "vue", "svelte": "svelte", "astro": "astro",
        "env": "env", "diff": "diff", "patch": "patch", "csv": "csv",
        "text": "txt", "txt": "txt", "plaintext": "txt"
    ]

    /// Sprachen, deren Datei per Konvention keinen Punkt im Namen hat.
    private static let bareNames: [String: String] = [
        "dockerfile": "Dockerfile",
        "makefile": "Makefile",
        "gitignore": ".gitignore",
        "editorconfig": ".editorconfig"
    ]

    static func fileExtension(for language: String?) -> String {
        guard let language = language?.lowercased(), !language.isEmpty else { return "txt" }
        return extensions[language] ?? "txt"
    }

    // MARK: - Erkennung

    static func artifacts(in text: String) -> [CodeArtifact] {
        let lines = text.components(separatedBy: "\n")
        var results: [CodeArtifact] = []
        var usedNames = Set<String>()
        var index = 0
        var counter = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") else {
                index += 1
                continue
            }

            let openIndex = index
            let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var body: [String] = []
            index += 1
            while index < lines.count {
                if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                body.append(lines[index])
                index += 1
            }
            index += 1   // schließenden Zaun überspringen

            let code = body.joined(separator: "\n")
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            counter += 1
            let (language, nameFromInfo) = parseInfoString(info)

            // Zeile vor dem Zaun: die letzte nicht leere davor.
            let heading = previousMeaningfulLine(lines, before: openIndex)

            var guessed = false
            var name = nameFromInfo
                ?? filename(fromHeading: heading)
                ?? filename(fromFirstCodeLine: body.first)

            if name == nil {
                guessed = true
                name = fallbackName(language: language, counter: counter)
            }

            var finalName = ZipArchive.sanitizeRelativePath(name ?? "datei.txt")
            finalName = uniqueName(finalName, taken: &usedNames)

            results.append(CodeArtifact(id: counter,
                                        filename: finalName,
                                        language: language,
                                        code: code,
                                        isSelected: true,
                                        isNameGuessed: guessed))
        }

        return results
    }

    /// Enthält die Antwort überhaupt Code? Steuert, ob der Menüpunkt
    /// "Dateien exportieren" erscheint.
    static func containsCode(_ text: String) -> Bool {
        text.contains("```")
    }

    // MARK: - Teilschritte

    /// "```php index.php" oder "```php:index.php" oder "```index.php"
    private static func parseInfoString(_ info: String) -> (language: String?, filename: String?) {
        guard !info.isEmpty else { return (nil, nil) }

        // Form mit Doppelpunkt
        if let separator = info.firstIndex(of: ":") {
            let left = String(info[info.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let right = String(info[info.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if looksLikeFilename(right) {
                return (left.isEmpty ? nil : left.lowercased(), right)
            }
            // "```php:" – rechts steht nichts Brauchbares, links aber die
            // Sprache. Ohne diesen Zweig läge die Endung bei .txt.
            if right.isEmpty { return (left.isEmpty ? nil : left.lowercased(), nil) }
        }

        let parts = info.split(separator: " ").map(String.init)
        if parts.count >= 2 {
            let candidate = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            if looksLikeFilename(candidate) {
                return (parts[0].lowercased(), candidate)
            }
        }

        // Einzelner Bestandteil: entweder Sprache oder direkt ein Dateiname.
        let single = parts.first ?? info
        if looksLikeFilename(single), extensions[single.lowercased()] == nil {
            return (languageFromExtension(single), single)
        }
        return (single.lowercased(), nil)
    }

    private static func filename(fromHeading heading: String?) -> String? {
        guard var line = heading?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }

        // Auszeichnungen abstreifen: **, ##, `, <!-- -->, Aufzählungszeichen
        line = line.replacingOccurrences(of: "<!--", with: " ")
            .replacingOccurrences(of: "-->", with: " ")
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_`•-–— \t"))

        // "Datei: index.php" / "File: index.php" / "Pfad: src/app.js"
        for prefix in ["datei:", "file:", "pfad:", "path:", "dateiname:", "filename:"] {
            if line.lowercased().hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "*_`\"' \t"))

        // Ein Satz ist kein Dateiname.
        guard line.split(separator: " ").count <= 2 else {
            // "index.php aktualisieren" – erstes Wort prüfen
            if let first = line.split(separator: " ").first, looksLikeFilename(String(first)) {
                return String(first)
            }
            return nil
        }
        let candidate = line.split(separator: " ").first.map(String.init) ?? line
        return looksLikeFilename(candidate) ? candidate : nil
    }

    private static func filename(fromFirstCodeLine line: String?) -> String? {
        guard var first = line?.trimmingCharacters(in: .whitespaces), !first.isEmpty else { return nil }
        let markers = ["<!--", "-->", "//", "#", "/*", "*/", "--", ";"]
        for marker in markers {
            first = first.replacingOccurrences(of: marker, with: " ")
        }
        first = first.trimmingCharacters(in: .whitespaces)
        guard first.split(separator: " ").count <= 2 else { return nil }
        let candidate = first.split(separator: " ").first.map(String.init) ?? first
        return looksLikeFilename(candidate) ? candidate : nil
    }

    private static func fallbackName(language: String?, counter: Int) -> String {
        if let language = language?.lowercased(), let bare = bareNames[language] {
            return bare
        }
        let suffix = fileExtension(for: language)
        return "datei-\(counter).\(suffix)"
    }

    private static func languageFromExtension(_ filename: String) -> String? {
        guard let dot = filename.lastIndex(of: ".") else { return nil }
        let suffix = String(filename[filename.index(after: dot)...]).lowercased()
        return extensions.first { $0.value == suffix }?.key ?? suffix
    }

    /// Ein Name muss einen Punkt und eine plausible Endung haben, darf keine
    /// Leerzeichen enthalten und nicht wie ein Satzzeichen enden.
    private static func looksLikeFilename(_ candidate: String) -> Bool {
        let value = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*_ \t"))
        guard value.count >= 3, value.count <= 100 else { return false }
        guard !value.contains(" ") else { return false }
        if bareNames.values.contains(value) { return true }
        guard let dot = value.lastIndex(of: "."), dot != value.startIndex else { return false }

        let suffix = String(value[value.index(after: dot)...]).lowercased()
        guard suffix.count >= 1, suffix.count <= 10 else { return false }
        guard suffix.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }

        // Endungen, die auf einen Satz statt auf eine Datei hindeuten.
        let sentenceEndings: Set<String> = ["de", "com", "org", "net", "app", "io"]
        if sentenceEndings.contains(suffix), !value.contains("/") { return false }

        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/+")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        guard taken.contains(name) else {
            taken.insert(name)
            return name
        }
        let base: String
        let suffix: String
        if let dot = name.lastIndex(of: ".") {
            base = String(name[name.startIndex..<dot])
            suffix = String(name[dot...])
        } else {
            base = name
            suffix = ""
        }
        var counter = 2
        while taken.contains("\(base)-\(counter)\(suffix)") { counter += 1 }
        let unique = "\(base)-\(counter)\(suffix)"
        taken.insert(unique)
        return unique
    }

    private static func previousMeaningfulLine(_ lines: [String], before index: Int) -> String? {
        var cursor = index - 1
        var skipped = 0
        while cursor >= 0, skipped < 3 {
            let line = lines[cursor].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
            cursor -= 1
            skipped += 1
        }
        return nil
    }
}
