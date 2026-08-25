//
//  AppInfo.swift
//  ByoKey
//
//  ⚠️ VOR DER EINREICHUNG ANPASSEN ⚠️
//
//  App Store Richtlinie 1.2 verlangt bei nutzergenerierten Inhalten
//  "published contact information so users can easily reach you". Die hier
//  hinterlegte Adresse muss echt sein, im App Store Connect Eintrag stehen und
//  Meldungen zeitnah beantworten. Die Datenschutz-URL muss öffentlich
//  erreichbar sein – Apple prüft den Link.
//

import Foundation

enum AppInfo {

    /// Muss mit dem Support-Kontakt im App Store Connect übereinstimmen.
    static let supportEmail = "support@byokey.app"

    /// Die Rechtstexte auf der Website – unter **englischen** Adressen.
    ///
    /// Vorher standen hier `/datenschutz` und `/nutzungsbedingungen`. Deutsche
    /// Pfade in einem Angebot, dessen Grundsprache Englisch ist, sind nicht
    /// nur uneinheitlich: die Datenschutz-Adresse steht in App Store Connect
    /// und ist das erste, was ein Prüfer von ByoKey zu sehen bekommt.
    ///
    /// Die Seiten selbst richten sich weiterhin nach der Sprache, die in der
    /// App eingestellt ist – siehe `legalURL(_:)`. Ein deutscher Nutzer
    /// bekommt also den deutschen Text unter einer englischen Adresse, und
    /// genau so gehört es: die Adresse ist Technik, der Text ist Recht.
    ///
    /// Die alten Adressen bleiben als Umleitung bestehen (`.htaccess` der
    /// Website), damit bereits verschickte Links nicht ins Leere laufen.
    static var privacyPolicyURL: URL? { legalURL("privacy") }
    static var termsURL: URL? { legalURL("terms") }

    /// Baut die Adresse und hängt die eingestellte Sprache an.
    ///
    /// Ohne `?lang=` entscheidet der Browser über `Accept-Language`, und der
    /// weiss nichts von der Sprachwahl in ByoKey: wer die App auf Englisch
    /// stellt, sein iPhone aber auf Deutsch, bekäme den deutschen Text zu
    /// sehen. Beim Zustimmungsdialog und bei den Nutzungsbedingungen ist das
    /// kein Schönheitsfehler – das sind die Texte, denen zugestimmt wird.
    ///
    /// Für Polnisch geht `?lang=pl` mit: die Seite zeigt dann die englische
    /// Fassung mit dem Hinweis, dass sie die verbindliche ist. Das ist
    /// ehrlicher, als stillschweigend Deutsch zu liefern.
    ///
    /// Steht die App auf „Systemsprache", wird **nichts** angehängt: dann soll
    /// die Website selbst entscheiden, und ihre Vorgabe ist Englisch.
    private static func legalURL(_ path: String) -> URL? {
        let base = "https://byokey.app/" + path
        guard let code = Loc.language.code else { return URL(string: base) }
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: "lang", value: code)]
        return components?.url
    }

    /// Apples Standard-EULA. Nur ersetzen, wenn eigene Bedingungen in
    /// App Store Connect hinterlegt sind.
    static let appleEULAURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    /// Vorbefüllte Melde-Mail (Richtlinie 1.2 – Meldungen müssen bei dir ankommen).
    static func reportMailURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }
}
