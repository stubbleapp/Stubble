import Foundation
import Vision
import CoreGraphics
import TaskMinerShared

class OCREngine {

    func recognizeText(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Logger.warning("OCR failed: \(error.localizedDescription)")
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")

        return text.isEmpty ? nil : text
    }
}
