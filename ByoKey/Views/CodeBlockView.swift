//
//  CodeBlockView.swift
//  ByoKey
//
//  Code-Darstellung mit einfacher Syntaxhervorhebung. Der Tokenizer läuft
//  zeichenweise statt über reguläre Ausdrücke – das ist bei langen
//  Antworten deutlich schneller und hat kein Backtracking-Risiko.
//

import SwiftUI
import UIKit

struct CodeToken {
    let text: String
    let color: Color
}

enum SyntaxHighlighter {

    private static let keywords: Set<String> = [
        // Swift / Objective-C
        "func", "let", "var", "struct", "class", "enum", "protocol", "extension",
        "guard", "if", "else", "for", "while", "repeat", "switch", "case", "default",
        "return", "throw", "throws", "try", "catch", "defer", "init", "deinit",
        "self", "super", "nil", "true", "false", "in", "where", "as", "is",
        "public", "private", "internal", "fileprivate", "static", "final", "lazy",
        "weak", "unowned", "mutating", "some", "any", "async", "await", "actor",
        // JavaScript / TypeScript
        "const", "function", "=>", "import", "export", "from", "new", "typeof",
        "interface", "type", "implements", "extends", "null", "undefined", "of",
        // Python
        "def", "elif", "None", "True", "False", "lambda", "pass", "yield", "with",
        "global", "nonlocal", "assert", "raise", "except", "finally", "not", "and", "or",
        // Weitere
        "package", "void", "int", "float", "double", "bool", "string", "char",
        "select", "insert", "update", "delete", "where", "join", "group", "order"
    ]

    private static let hashCommentLanguages: Set<String> = [
        "python", "py", "ruby", "rb", "bash", "sh", "shell", "zsh", "yaml", "yml",
        "toml", "ini", "conf", "r", "perl", "makefile", "dockerfile"
    ]

    static func tokens(for code: String, language: String?) -> [CodeToken] {
        let lang = (language ?? "").lowercased()
        let hashComments = hashCommentLanguages.contains(lang)
        let characters = Array(code)
        var tokens: [CodeToken] = []
        var buffer = ""
        var index = 0

        func flushPlain() {
            guard !buffer.isEmpty else { return }
            tokens.append(CodeToken(text: buffer, color: Theme.Code.plain))
            buffer = ""
        }

        while index < characters.count {
            let character = characters[index]

            // Zeilenkommentar
            let isSlashComment = character == "/" && index + 1 < characters.count && characters[index + 1] == "/"
            let isHashComment = hashComments && character == "#"
            if isSlashComment || isHashComment {
                flushPlain()
                var comment = ""
                while index < characters.count, characters[index] != "\n" {
                    comment.append(characters[index])
                    index += 1
                }
                tokens.append(CodeToken(text: comment, color: Theme.Code.comment))
                continue
            }

            // Blockkommentar
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                flushPlain()
                var comment = "/*"
                index += 2
                while index < characters.count {
                    if characters[index] == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                        comment += "*/"
                        index += 2
                        break
                    }
                    comment.append(characters[index])
                    index += 1
                }
                tokens.append(CodeToken(text: comment, color: Theme.Code.comment))
                continue
            }

            // Zeichenkette
            if character == "\"" || character == "'" || character == "`" {
                flushPlain()
                let quote = character
                var literal = String(quote)
                index += 1
                while index < characters.count {
                    let current = characters[index]
                    literal.append(current)
                    index += 1
                    if current == "\\", index < characters.count {
                        literal.append(characters[index])
                        index += 1
                        continue
                    }
                    if current == quote { break }
                    if current == "\n" { break }
                }
                tokens.append(CodeToken(text: literal, color: Theme.Code.string))
                continue
            }

            // Zahl
            // Das erste Zeichen wird IMMER konsumiert. `isNumber` umfasst mehr
            // als `isHexDigit` (etwa "²" oder "½"); ohne diese Garantie stünde
            // der Index still und die Schleife liefe endlos.
            if character.isNumber, buffer.last?.isLetter != true {
                flushPlain()
                var number = ""
                repeat {
                    number.append(characters[index])
                    index += 1
                } while index < characters.count
                    && (characters[index].isHexDigit || characters[index] == "."
                        || characters[index] == "x" || characters[index] == "_")
                tokens.append(CodeToken(text: number, color: Theme.Code.number))
                continue
            }

            // Bezeichner
            if character.isLetter || character == "_" {
                var word = ""
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    word.append(characters[index])
                    index += 1
                }
                if keywords.contains(word) {
                    flushPlain()
                    tokens.append(CodeToken(text: word, color: Theme.Code.keyword))
                } else if let first = word.first, first.isUppercase {
                    flushPlain()
                    tokens.append(CodeToken(text: word, color: Theme.Code.type))
                } else {
                    buffer += word
                }
                continue
            }

            buffer.append(character)
            index += 1
        }

        flushPlain()
        return tokens
    }
}

struct CodeBlockView: View, Equatable {
    let language: String?
    let code: String

    @State private var didCopy = false
    @State private var isExpanded = false

    /// Ab wie vielen Zeilen ein Block eingeklappt wird.
    ///
    /// Das ist **nicht** nur Kosmetik, sondern die Stellschraube gegen einen
    /// handfesten Fehler im Verlauf. Der Code läuft waagerecht scrollend und
    /// bricht deshalb nicht um: eine HTML-Datei mit 200 Zeilen ergibt **eine**
    /// Zeile des `LazyVStack` von rund 3 000 Punkten Höhe, während eine
    /// gewöhnliche Nachricht 80 bis 200 Punkte misst.
    ///
    /// Ein `LazyVStack` schätzt die Höhe noch nicht gebauter Zeilen, indem er
    /// von den bereits gemessenen hochrechnet. Ein einziger solcher Ausreisser
    /// verdirbt diese Schätzung um den Faktor zwanzig – mit zwei sichtbaren
    /// Folgen: beim Öffnen setzt der Verlauf mitten drin auf (Schätzung zu
    /// klein, solange kein Block gemessen ist), und ein Sprung ans Ende
    /// schiesst ins Leere (Schätzung zu gross, sobald einer gemessen ist).
    ///
    /// Eingeklappt misst auch der längste Block rund 400 Punkte. Damit liegen
    /// alle Zeilen in derselben Grössenordnung, und die Schätzung stimmt.
    private static let collapsedLineLimit = 24

    nonisolated static func == (lhs: CodeBlockView, rhs: CodeBlockView) -> Bool {
        lhs.code == rhs.code && lhs.language == rhs.language
    }

    /// Über die UTF-8-Bytes und nicht über die Zeichen.
    ///
    /// `code.reduce` iteriert Grapheme – Unicode-Segmentierung über den
    /// gesamten Block, und der wird während des Streamens zwanzigmal pro
    /// Sekunde neu gemessen, bei einer langen Datei über hunderttausend
    /// Zeichen. Ein Zeilenumbruch ist in UTF-8 immer genau das Byte 0x0A und
    /// kann in keiner Mehrbyte-Folge vorkommen; die Bytefassung zählt dasselbe
    /// und ist um ein Vielfaches schneller.
    private var lineCount: Int {
        var count = 1
        for byte in code.utf8 where byte == 0x0A { count += 1 }
        return count
    }

    private var isLong: Bool { lineCount > Self.collapsedLineLimit }

    /// Der angezeigte Ausschnitt. Kopiert und exportiert wird immer der
    /// **ganze** Block – das Einklappen betrifft nur die Darstellung.
    ///
    /// Hört nach der 24. Zeile auf, statt erst den ganzen Block in Zeilen zu
    /// zerlegen und davon 24 zu behalten: `split` legte ein Array mit einem
    /// Eintrag je Zeile an – bei 3 000 Zeilen also 3 000 Teilstücke, um 24
    /// davon zu benutzen.
    private var visibleCode: String {
        guard isLong, !isExpanded else { return code }
        // `isNewline` und nicht `== "\n"`: eine Datei mit Windows-Zeilenenden
        // enthält „\r\n", und das ist in Swift **ein** Zeichen, das nicht
        // gleich „\n" ist. Verglichen wurde dann nie etwas – der Block galt
        // als lang, klappte aber nichts ein. `lineCount` zählt Bytes 0x0A und
        // sieht in „\r\n" genau eines; beide Zählweisen kommen so auf dieselbe
        // Zeile.
        var seen = 0
        for index in code.indices where code[index].isNewline {
            seen += 1
            if seen == Self.collapsedLineLimit { return String(code[..<index]) }
        }
        return code
    }

    /// Ein `Text` mit Farb-Runs statt hunderter addierter `Text`-Bausteine.
    ///
    /// Vorher entstand hier über `reduce` mit `+` ein linksverschachtelter Baum
    /// mit einem Knoten je Token – bei 4 000 Zeichen Quelltext sind das schnell
    /// 800 Knoten, und zwar bei **jedem** Bildaufbau. Während des Streamens
    /// wird der noch wachsende Block zwanzigmal pro Sekunde neu aufgebaut;
    /// `.equatable()` schützt nur die bereits fertigen Blöcke.
    ///
    /// Ein `AttributedString` ist ein Knoten. Die Farben stehen darin als Runs,
    /// und Core Text bekommt sie in einem Stück.
    private var highlighted: Text {
        var result = AttributedString()
        for token in SyntaxHighlighter.tokens(for: visibleCode, language: language) {
            var piece = AttributedString(token.text)
            piece.foregroundColor = token.color
            result.append(piece)
        }
        return Text(result)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    didCopy = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Kopiert" : "Kopieren",
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(didCopy ? "Code kopiert" : "Code kopieren")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.06))

            ScrollView(.horizontal, showsIndicators: false) {
                highlighted
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    // `fixedSize` statt `frame(maxWidth: .infinity)`: in der
                    // Scroll-Achse einer waagerechten `ScrollView` bietet der
                    // Rahmen keine feste Breite an. `.infinity` löste dort mal
                    // gegen die Idealbreite und mal gegen die Containerbreite
                    // auf – im zweiten Fall bricht der Text um, und dieselbe
                    // Zeile misst in zwei Durchgängen zwei verschiedene Höhen.
                    // Genau davon lebt das Springen im Verlauf.
                    .fixedSize(horizontal: true, vertical: false)
            }
            // Ausdrücklich links oben aufsetzen.
            //
            // Der Verlauf setzt an seiner eigenen `ScrollView`
            // `defaultScrollAnchor(.bottom, …)`. Solche Modifikatoren wirken
            // über die Umgebung und erreichen damit auch die hier
            // eingebettete waagerechte Liste – ein Code-Block begänne dann
            // waagerecht in der Mitte statt am Zeilenanfang. Diese Zeile
            // schneidet das ab, unabhängig davon, was aussen gesetzt ist.
            .defaultScrollAnchor(.topLeading)

            if isLong {
                Button {
                    isExpanded.toggle()
                } label: {
                    Group {
                        if isExpanded {
                            Text("Weniger anzeigen")
                        } else {
                            Text(verbatim: Loc.tr("Alle %lld Zeilen anzeigen", lineCount))
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.06))
            }
        }
        // Die Blöcke einer Antwort werden über ihre Position identifiziert –
        // das ist beim Streamen richtig, weil sich der Inhalt eines Blocks
        // laufend ändert. Verschieben sich die Blöcke aber, erbt ein anderer
        // Block diesen Zustand: ohne diese Zeile stünde „Kopiert" plötzlich an
        // Code, den niemand kopiert hat.
        .onChange(of: code) { _, _ in didCopy = false }
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
