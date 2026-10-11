import AppKit

/// One Word, RTF, ODT or text document. AppKit's text system does the reading and writing.
@objc(WordDocument)
final class WordDocument: NSDocument {
    var loaded = NSAttributedString(string: "")
    var meta: [NSAttributedString.DocumentAttributeKey: Any] = [:]
    weak var textView: NSTextView?

    static let docx = "org.openxmlformats.wordprocessingml.document"
    static let doc = "com.microsoft.word.doc"
    static let rtf = "public.rtf"
    static let odt = "org.oasis-open.opendocument.text"
    static let text = "public.plain-text"

    // Saving over a Word file only when asked keeps originals safe; no silent autosave in place.
    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(WordWindowController(document: self))
    }

    static func documentType(for typeName: String) -> NSAttributedString.DocumentType {
        let t = UTType(typeName)
        switch typeName {
        case docx: return .officeOpenXML
        case doc: return .docFormat
        case odt: return .openDocument
        case rtf: return .rtf
        default:
            if let t, t.conforms(to: .rtf) { return .rtf }
            if let t, t.conforms(to: .plainText) { return .plain }
            return .officeOpenXML
        }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let type = Self.documentType(for: typeName)
        var attrs: NSDictionary?
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        if type == .plain { options[.characterEncoding] = String.Encoding.utf8.rawValue }
        do {
            loaded = try NSAttributedString(data: data, options: options, documentAttributes: &attrs)
        } catch where type == .plain {
            let s = String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
            loaded = NSAttributedString(string: s)
        }
        meta = attrs as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        if type == .plain {
            loaded = NSAttributedString(string: loaded.string, attributes: WordStyles.normalAttributes(WordStyles.defaultBody))
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        let type = Self.documentType(for: typeName)
        let content = textView?.textStorage.map { NSAttributedString(attributedString: $0) } ?? loaded
        if type == .plain { return Data(content.string.utf8) }
        var da: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        for key in [NSAttributedString.DocumentAttributeKey.title, .subject, .keywords, .company, .copyright] {
            if let v = meta[key] { da[key] = v }
        }
        da[.author] = meta[.author] ?? NSFullUserName()
        return try content.data(from: NSRange(location: 0, length: content.length), documentAttributes: da)
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        [Self.docx, Self.doc, Self.odt, Self.rtf, Self.text]
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        switch typeName {
        case Self.docx: return "docx"
        case Self.doc: return "doc"
        case Self.odt: return "odt"
        case Self.rtf: return "rtf"
        case Self.text: return "txt"
        default: return super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
        }
    }

    // New documents are Word files.
    override var fileType: String? {
        get { super.fileType ?? Self.docx }
        set { super.fileType = newValue }
    }

    // MARK: Printing and PDF

    private func pageView(_ info: NSPrintInfo) -> NSTextView {
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        let content = textView?.textStorage.map { NSAttributedString(attributedString: $0) } ?? loaded
        view.textStorage?.setAttributedString(content)
        view.backgroundColor = .white
        view.appearance = NSAppearance(named: .aqua)
        view.isVerticallyResizable = true
        if let lm = view.layoutManager, let tc = view.textContainer {
            tc.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            lm.ensureLayout(for: tc)
            view.setFrameSize(NSSize(width: width, height: ceil(lm.usedRect(for: tc).height) + 20))
        }
        return view
    }

    private func pagedInfo(_ base: NSPrintInfo) -> NSPrintInfo {
        let info = (base.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = pagedInfo(printInfo)
        info.dictionary().addEntries(from: printSettings)
        let op = NSPrintOperation(view: pageView(info), printInfo: info)
        op.jobTitle = displayName
        return op
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let window = windowControllers.first?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (displayName as NSString).deletingPathExtension + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let info = self.pagedInfo(self.printInfo)
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let op = NSPrintOperation(view: self.pageView(info), printInfo: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            op.run()
        }
    }
}

import UniformTypeIdentifiers
