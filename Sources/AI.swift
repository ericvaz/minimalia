import Foundation
import FoundationModels

/// Apple's on-device language model. Nothing is sent off this Mac.
@MainActor
final class AIEngine {
    static let shared = AIEngine()
    private var session: LanguageModelSession?

    private let instructions = """
    You are the assistant built into Minimalia, a quiet text-only computer in the style of the 1980s. \
    Answer in plain text only: no Markdown, no asterisks, no headings, no tables, no emoji. \
    Be brief and direct, in short paragraphs. Use numbered lines only when giving steps.
    """

    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac cannot run Apple's on-device model."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off. Turn it on in System Settings, under Apple Intelligence & Siri."
            case .modelNotReady:
                return "The on-device model is still downloading. Try again in a little while."
            @unknown default:
                return "The on-device model is not available."
            }
        }
    }

    func reset() { session = nil }

    /// Streams an answer into the console. Uses the running conversation unless `fresh` is set.
    func respond(_ prompt: String, fresh: Bool = false, to console: ConsoleTextView) async {
        let s: LanguageModelSession
        if fresh {
            s = LanguageModelSession(instructions: instructions)
        } else if let existing = session {
            s = existing
        } else {
            s = LanguageModelSession(instructions: instructions)
            session = s
        }

        var printed = ""
        var raw = ""
        do {
            for try await snapshot in s.streamResponse(to: prompt) {
                raw = snapshot.content
                let cleaned = Self.clean(raw, final: false)
                if cleaned.hasPrefix(printed), cleaned.count > printed.count {
                    console.write(String(cleaned.dropFirst(printed.count)))
                    printed = cleaned
                }
            }
            let final = Self.clean(raw, final: true)
            if final.hasPrefix(printed) { console.write(String(final.dropFirst(printed.count))) }
            console.write("\n")
        } catch is CancellationError {
            console.write("\n")
        } catch let e as LanguageModelSession.GenerationError {
            if !console.endsWithNewline { console.write("\n") }
            switch e {
            case .exceededContextWindowSize:
                session = nil
                console.writeLine("Memory full. The conversation has been cleared, so please ask again.", .error)
            case .guardrailViolation, .refusal:
                console.writeLine("The model declined to answer that.", .error)
            case .unsupportedLanguageOrLocale:
                console.writeLine("The model does not support that language yet.", .error)
            case .rateLimited, .concurrentRequests:
                console.writeLine("The model is busy. Try again in a moment.", .error)
            default:
                console.writeLine("The model could not answer: \(e.localizedDescription)", .error)
            }
        } catch {
            if !console.endsWithNewline { console.write("\n") }
            console.writeLine("The model could not answer: \(error.localizedDescription)", .error)
        }
    }

    /// Strips the Markdown habits small models fall into.
    static func clean(_ s: String, final: Bool) -> String {
        var t = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        t = t.components(separatedBy: "\n").map { line -> String in
            var l = line
            if l.hasPrefix("#") {
                while l.hasPrefix("#") { l.removeFirst() }
                l = l.trimmingCharacters(in: .whitespaces)
            }
            if l.hasPrefix("* ") { l = "- " + l.dropFirst(2) }
            return l
        }.joined(separator: "\n")
        if !final {
            while let last = t.last, "*#_".contains(last) { t.removeLast() }
        }
        return t
    }
}
