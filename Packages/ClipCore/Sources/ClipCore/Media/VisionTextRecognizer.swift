import Foundation
import CoreGraphics
import ImageIO
#if canImport(Vision)
import Vision
#endif

// Owned by the extensions engineer. Cross-platform (macOS 14 / iOS 17).

/// On-device OCR with `VNRecognizeTextRequest` (`.accurate`, language correction on).
///
/// - Input is downsampled with ImageIO first (longest side ≤ `maxPixelSize`), so a
///   50 MB screenshot never becomes a full-size bitmap.
/// - Vision runs on a global utility queue, never on the main thread.
/// - `timeout` cancels the request; a timeout or Vision error returns nil
///   ("failed"), an image without text returns "".
public struct VisionTextRecognizer: TextRecognizing {
    public var maxPixelSize: Int
    public var timeout: TimeInterval
    /// nil = automatic language detection.
    public var recognitionLanguages: [String]?

    public init(maxPixelSize: Int = 3000, timeout: TimeInterval = 30, recognitionLanguages: [String]? = nil) {
        self.maxPixelSize = maxPixelSize
        self.timeout = timeout
        self.recognitionLanguages = recognitionLanguages
    }

    public func recognizeText(in imageData: Data) async -> String? {
        #if canImport(Vision)
        guard !imageData.isEmpty,
              let image = ImageEncoding.downsampledImage(from: imageData, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return await VisionTextRecognizer.recognize(
            image: image,
            languages: recognitionLanguages,
            timeout: max(1, timeout)
        )
        #else
        return nil
        #endif
    }

    #if canImport(Vision)
    private static func recognize(image: CGImage, languages: [String]?, timeout: TimeInterval) async -> String? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = OneShotContinuation<String?>(continuation)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if let languages = languages, !languages.isEmpty {
                request.recognitionLanguages = languages
                request.automaticallyDetectsLanguage = false
            } else {
                request.automaticallyDetectsLanguage = true
            }

            DispatchQueue.global(qos: .utility).async {
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let observations = request.results ?? []
                    once.resume(returning: VisionTextRecognizer.joinedText(observations))
                } catch {
                    once.resume(returning: nil)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.resume(returning: nil) {
                    request.cancel()
                }
            }
        }
    }

    /// Top candidate of each observation, one per line, in Vision's reading order.
    static func joinedText(_ observations: [VNRecognizedTextObservation]) -> String {
        var lines: [String] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
    #endif
}
