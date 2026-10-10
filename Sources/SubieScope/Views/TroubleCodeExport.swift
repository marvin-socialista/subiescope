import AppKit
import SSMKit

/// The trouble codes from one read, as plain text or a paginated PDF, with or without causes and fixes.
@MainActor
struct TroubleCodeExport {
    struct Section {
        let title: String
        let subtitle: String
        let codes: [DiagnosticCodeDefinition]
        let tint: NSColor
    }

    let readDate: Date?
    let ecu: String?
    let sections: [Section]
    /// The freeze frame's heading line and its values, when the ECU had one.
    let freezeFrame: (summary: String, lines: [FreezeFrame.Line])?

    static let disclaimer = "General guidance for Subaru engines. Check the service manual for your model's exact values and wiring."

    init(model: AppModel) {
        if case .read(let date) = model.codeReadState { readDate = date } else { readDate = nil }
        ecu = model.identity.map { "ECU ID \($0.ecuID) (\(model.knownECUDescription ?? "unknown car"))" }
        sections = [
            Section(title: "Current", subtitle: "Faults the ECU sees right now (temporary)", codes: model.currentCodes, tint: .systemRed),
            Section(title: "Memorized", subtitle: "Stored faults, kept until memory is cleared", codes: model.memorizedCodes, tint: .systemOrange),
        ]
        freezeFrame = model.freezeFrame.map { ($0.summary, model.freezeFrameLines) }
    }

    /// "SubieScope trouble codes 2026-09-24"
    var fileName: String {
        "SubieScope trouble codes \((readDate ?? .now).formatted(.iso8601.year().month().day()))"
    }

    private var readLine: String? {
        readDate.map { "Read by SubieScope on \($0.formatted(date: .abbreviated, time: .shortened))" }
    }

    /// Codes that are in both lists are explained only the first time.
    private func entries(explain: Bool) -> [(section: Section, entries: [(code: DiagnosticCodeDefinition, explained: Bool)])] {
        var seen = Set<String>()
        return sections.map { section in
            (section, section.codes.map { code in
                (code, explain && code.help != nil && seen.insert(code.code).inserted)
            })
        }
    }

    // MARK: Text

    func text(withHelp: Bool) -> String {
        var blocks = [(["Trouble codes"] + [readLine, ecu].compactMap { $0 }).joined(separator: "\n")]
        for (section, entries) in entries(explain: withHelp) {
            var lines = ["\(section.title.uppercased()): \(section.subtitle)"]
            if entries.isEmpty { lines.append("None") }
            for entry in entries {
                if entry.explained {
                    lines.append(entry.code.helpText + "\n")
                } else {
                    lines.append(entry.code.line + (withHelp && entry.code.help != nil ? " (explained above)" : ""))
                }
            }
            blocks.append(lines.joined(separator: "\n").trimmingCharacters(in: .newlines))
        }
        if let freezeFrame {
            blocks.append((["FREEZE FRAME: \(freezeFrame.summary)"] + freezeFrame.lines.map { "\($0.name): \($0.value)" }).joined(separator: "\n"))
        }
        if withHelp { blocks.append(Self.disclaimer) }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: PDF

    /// Lays the report out on the default paper size (A4 or Letter, from the Mac's region) and saves it as a PDF.
    func writePDF(to url: URL) throws {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = false
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        textView.appearance = NSAppearance(named: .aqua)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(attributedReport())
        textView.sizeToFit()

        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = fileName
        guard operation.run() else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]) }
    }

    private func attributedReport() -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ string: String, font: NSFont, color: NSColor = .black, before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat? = nil) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = before
            paragraph.paragraphSpacing = after
            paragraph.lineHeightMultiple = 1.12
            if let indent {
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = indent
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }
            out.append(NSAttributedString(string: string + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        let body = NSFont.systemFont(ofSize: 11)
        let bold = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let small = NSFont.systemFont(ofSize: 9.5)

        add("Trouble codes", font: .systemFont(ofSize: 22, weight: .bold), after: 4)
        for line in [readLine, ecu].compactMap({ $0 }) {
            add(line, font: small, color: .darkGray)
        }

        for (section, entries) in entries(explain: true) {
            add(section.title, font: .systemFont(ofSize: 16, weight: .bold), before: 22)
            add(section.subtitle, font: small, color: .darkGray, after: 4)
            if entries.isEmpty { add("None", font: body, color: .darkGray, before: 8) }
            for entry in entries {
                let code = entry.code
                let heading = NSMutableAttributedString(string: code.code, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold), .foregroundColor: section.tint,
                ])
                heading.append(NSAttributedString(string: "   " + code.title + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.black,
                ]))
                let paragraph = NSMutableParagraphStyle()
                paragraph.paragraphSpacingBefore = 16
                paragraph.paragraphSpacing = 4
                heading.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: heading.length))
                out.append(heading)

                guard let help = code.help else { continue }
                guard entry.explained else {
                    add("Explained above.", font: body, color: .darkGray)
                    continue
                }
                add(help.meaning, font: body, after: 2)
                add("Possible causes", font: bold, before: 6, after: 2)
                for cause in help.causes { add("•\t" + cause, font: body, after: 2, indent: 16) }
                add("How to fix", font: bold, before: 6, after: 2)
                for (index, fix) in help.fixes.enumerated() { add("\(index + 1).\t" + fix, font: body, after: 2, indent: 16) }
            }
        }
        if let freezeFrame {
            add("Freeze frame", font: .systemFont(ofSize: 16, weight: .bold), before: 22)
            add(freezeFrame.summary, font: small, color: .darkGray, after: 4)
            for line in freezeFrame.lines { add("\(line.name):\t\(line.value)", font: body, after: 2, indent: 220) }
        }
        add(Self.disclaimer, font: small, color: .darkGray, before: 24)
        return out
    }
}
