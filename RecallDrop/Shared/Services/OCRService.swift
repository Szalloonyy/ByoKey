//
//  OCRService.swift
//  RecallDrop
//
//  On-device text recognition with Apple's Vision framework
//  (VNRecognizeTextRequest). Images never leave the device for OCR.
//  Runs on its own actor, so recognition stays off the main thread and
//  large screenshots are processed one at a time.
//

import Foundation
import CoreGraphics
import ImageIO
import NaturalLanguage
import Vision
import RecallDropKit

struct OCRResult: Sendable {
    var text: String
    var lines: [OCRLine]
    var averageConfidence: Double?
    /// BCP-47 code of the dominant language, e.g. "en" or "de".
    var languageCode: String?

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

actor OCRService {
    static let shared = OCRService()

    /// Vision works best below this size; larger images are downscaled first.
    private let maxRecognitionDimension = 4096

    func recognizeText(in imageData: Data, accuracy: OCRAccuracy, languageCorrection: Bool) throws -> OCRResult {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = ImageProcessor.downsampledImage(from: source, maxPixelSize: maxRecognitionDimension) else {
            throw ImageProcessingError.unreadable
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accuracy == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = languageCorrection
        request.automaticallyDetectsLanguage = true

        // The thumbnail API already applied the EXIF orientation.
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        let lines: [OCRLine] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return OCRLine(
                text: text,
                confidence: Double(candidate.confidence),
                x: Double(box.origin.x),
                y: Double(box.origin.y),
                width: Double(box.size.width),
                height: Double(box.size.height)
            )
        }

        let text = OCRLayout.joinedText(lines)
        return OCRResult(
            text: text,
            lines: lines,
            averageConfidence: OCRLayout.averageConfidence(lines),
            languageCode: Self.dominantLanguage(of: text)
        )
    }

    private static func dominantLanguage(of text: String) -> String? {
        guard text.count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4000)))
        return recognizer.dominantLanguage?.rawValue
    }
}
