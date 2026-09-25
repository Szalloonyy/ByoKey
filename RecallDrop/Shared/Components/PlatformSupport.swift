//
//  PlatformSupport.swift
//  RecallDrop
//
//  Tiny wrappers over the few APIs that differ between UIKit and AppKit.
//

import Foundation
import RecallDropKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Temporary files for sharing and exporting (file names matter to the receiver).
enum ShareableFiles {
    private static var directory: URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "Sharing", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ data: Data, fileName: String) -> URL? {
        let url = directory.appending(path: sanitized(fileName))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func markdownFile(named name: String, contents: String) -> URL? {
        write(Data(contents.utf8), fileName: name.hasSuffix(".md") ? name : "\(name).md")
    }

    static func imageFile(data: Data, title: String) -> URL? {
        let fileExtension = ImageProcessor.fileExtension(for: data)
        return write(data, fileName: "\(PersonaMarkdownCodec.slug(title)).\(fileExtension)")
    }

    static func sanitized(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "RecallDrop" : cleaned
    }
}
