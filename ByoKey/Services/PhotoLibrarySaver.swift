//
//  PhotoLibrarySaver.swift
//  ByoKey
//
//  Ein erzeugtes Bild in „Fotos" sichern.
//
//  Bewusst **nur schreibend**: angefordert wird `.addOnly`. ByoKey liest die
//  Mediathek nie, sucht nichts darin und zählt nichts. Deshalb steht in der
//  `Info.plist` auch nur `NSPhotoLibraryAddUsageDescription` und nicht der
//  Zwecktext für Lesezugriff – iOS zeigt dem Nutzer entsprechend den kleinen
//  Dialog „Zu Fotos hinzufügen?" statt der vollen Freigabe.
//
//  Die Originaldaten werden unverändert übergeben (`addResource(with:data:)`),
//  nicht ein neu kodiertes `UIImage`. Ein PNG bleibt so ein PNG und verliert
//  weder Transparenz noch Qualität.
//

import Foundation
import Photos

enum PhotoLibrarySaver {

    enum Outcome {
        case saved
        /// Der Nutzer hat den Zugriff abgelehnt oder in den iOS-Einstellungen entzogen.
        case denied
        /// Bildschirmzeit oder eine Geräteverwaltung sperrt den Zugriff. Der
        /// Unterschied zu `denied` ist wichtig: hier hilft der Verweis auf die
        /// Einstellungen nicht, der Nutzer kann dort nichts ändern.
        case restricted
        case failed
    }

    static func save(imageAt url: URL) async -> Outcome {
        switch await authorize() {
        case .authorized, .limited:
            break
        case .restricted:
            return .restricted
        default:
            return .denied
        }

        guard let data = try? Data(contentsOf: url) else { return .failed }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            return .saved
        } catch {
            return .failed
        }
    }

    /// Fragt höchstens einmal. Ein bereits abgelehnter Zugriff lässt sich nur
    /// in den iOS-Einstellungen wieder erteilen – iOS zeigt den Dialog dann
    /// kein zweites Mal, und ein erneutes Fragen wäre eine leere Geste.
    private static func authorize() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }
}
