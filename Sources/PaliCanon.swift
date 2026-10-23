import Foundation

/// The Pali Canon's discourses in Bhikkhu Sujato's translation, from SuttaCentral (CC0), bundled in
/// the app. Tools/make_canon.swift builds the books and build.sh copies them into Resources/Canon.
enum PaliCanon {
    static let shelf = "Pali Canon"

    static let scripture = Scripture(tradition: "BUDDHISM", aliases: ["BUDDHIST", "PALI", "CANON"], shelf: shelf, folder: "Canon")

    /// Every book starts with this line. The translator asks that the work not be used with AI,
    /// so SUMMARIZE refuses any text that carries it.
    static let marker = "Published by SuttaCentral (suttacentral.net)"

    static func isCanon(_ text: String) -> Bool { text.contains(marker) }

    static func isCanon(_ url: URL?) -> Bool { url?.host?.hasSuffix("suttacentral.net") == true }
}
