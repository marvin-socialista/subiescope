#if os(Windows) || DEBUG
import Foundation
import SSMKit

/// Trouble codes: the two lists with what each code means, reading and clearing them, and the export.
extension Bridge {
    struct CodesState: Encodable {
        /// One of the ECU's status flags next to the headline ("Test mode off").
        struct Chip: Encodable {
            let label: String
            /// Orange when on, gray when off.
            let on: Bool
        }

        struct Code: Encodable {
            /// Which code of its list this is, for `codes.copyCode`.
            let id: String
            /// "P0101", or the whole name for a code that has no number.
            let code: String
            /// "Mass air flow sensor range/performance"
            let title: String
            /// What the code means. Nil when SubieScope has no explanation for it; then there are no causes or fixes either.
            let meaning: String?
            /// Most likely first.
            let causes: [String]
            /// In the order to try them.
            let fixes: [String]
        }

        struct List: Encodable {
            /// "current" or "memorized": which of the two lists this is, for `codes.copyCode`.
            let id: String
            /// "Current" and "Memorized" with an SSM cable, "Confirmed" and "Pending" over OBD-II.
            let title: String
            let subtitle: String
            /// red or orange
            let tint: String
            let codes: [Code]
            /// What the list says while it has no codes: "None" after a read, a dash before.
            let emptyText: String
        }

        /// The question before the codes are cleared.
        struct ClearQuestion: Encodable {
            /// What the button that asks it says ("Clear Memory…").
            let button: String
            let title: String
            let message: String
            /// What the button that goes ahead says ("Clear Memory").
            let confirm: String
        }

        /// "3 codes found · read 14:03:22", or what to do to get there.
        let headline: String
        let chips: [Chip]
        let reading: Bool
        let canRead: Bool
        let canClear: Bool
        /// There is a read to copy or save.
        let canExport: Bool
        /// Why reading failed.
        let error: String?
        /// How clearing went, and what to do next.
        let notice: String?
        let lists: [List]
        let clear: ClearQuestion
        /// The small print under every explanation.
        let disclaimer: String
    }

    struct CodesSaveResult: Encodable {
        /// Why the file could not be written. Nil when it was saved, and when the person changed their mind.
        let error: String?
    }

    func registerCodes() {
        slice("codes") { [model] in
            let connected = model.connection.isConnected
            let obd = model.mode == .obd
            let total = model.currentCodes.count + model.memorizedCodes.count
            var isRead = false
            var error: String?
            let headline: String
            switch model.codeReadState {
            case .idle:
                headline = connected ? "Press Read Codes to check the car" : "Connect to read trouble codes"
            case .reading:
                headline = "Reading…"
            case .read(let date):
                isRead = true
                headline = "\(total == 0 ? "No trouble codes" : "\(total) code\(total == 1 ? "" : "s") found") · read \(Bridge.codesClock.string(from: date))"
            case .failed(let message):
                headline = "Reading failed"
                error = message
            }
            var chips: [CodesState.Chip] = []
            if let status = model.engineStatus {
                if let test = status.testMode {
                    chips.append(.init(label: test ? "Test mode ON" : "Test mode off", on: test))
                }
                if let dCheck = status.dCheckPending {
                    chips.append(.init(label: dCheck ? "Self check not completed" : "Self check done", on: dCheck))
                }
            }
            let lists = Bridge.codeLists(model).map { list in
                CodesState.List(
                    id: list.id, title: list.title, subtitle: list.subtitle, tint: list.tint,
                    codes: list.codes.map { code in
                        let help = code.help
                        return CodesState.Code(id: code.id, code: code.code, title: Bridge.codeTitle(code),
                                               meaning: help?.meaning, causes: help?.causes ?? [], fixes: help?.fixes ?? [])
                    },
                    emptyText: isRead ? "None" : "–")
            }
            let clear = obd
                ? CodesState.ClearQuestion(
                    button: "Clear Codes…", title: "Clear the trouble codes?",
                    message: "This erases the trouble codes and turns the check engine light off. It also resets what the car has learned (fuel trims) and its readiness for the emissions test, so a test may need a few days of driving before it passes. If a fault is still there, the code comes back.",
                    confirm: "Clear Codes")
                : CodesState.ClearQuestion(
                    button: "Clear Memory…", title: "Clear the ECU memory?",
                    message: "This erases all stored trouble codes and also resets what the ECU has learned: fuel trims (A/F learning), IAM and fine knock learning start over. The car may idle and drive slightly differently until it relearns.\n\nAfterwards: switch the ignition OFF, wait 10 seconds, switch it ON again.",
                    confirm: "Clear Memory")
            return CodesState(
                headline: headline, chips: chips, reading: model.codeReadState == .reading,
                canRead: connected && model.codeReadState != .reading, canClear: connected, canExport: isRead,
                error: error, notice: model.clearState, lists: lists, clear: clear, disclaimer: CodeReport.disclaimer)
        }

        action("codes.read") { [model] _ in
            guard model.connection.isConnected, model.codeReadState != .reading else { return }
            Task { await model.readTroubleCodes() }
        }
        // The page has asked "are you sure" before it sends this.
        action("codes.clear") { [model] _ in
            guard model.connection.isConnected else { return }
            Task { await model.clearTroubleCodes() }
        }
        // Every code of the last read on the clipboard. `help`: with causes and fixes.
        action("codes.copy") { [model] arguments in
            Desktop.copy(CodeReport(model: model).text(withHelp: arguments.bool("help")))
        }
        // One code on the clipboard. `help`: with its causes and fixes.
        action("codes.copyCode") { [model] arguments in
            guard let list = Bridge.codeLists(model).first(where: { $0.id == arguments.string("list") }),
                  let code = list.codes.first(where: { $0.id == arguments.string("id") }) else { return }
            Desktop.copy(arguments.bool("help") ? Bridge.codeHelpText(code) : Bridge.codeLine(code))
        }
        // Saves every code with its causes and fixes. `format`: "text", or "page" for a page to print.
        request("codes.save") { [model] arguments -> CodesSaveResult in
            let report = CodeReport(model: model)
            let asPage = arguments.string("format") == "page"
            guard let file = Desktop.chooseSaveLocation(suggestedName: report.fileName + (asPage ? ".html" : ".txt")) else {
                return CodesSaveResult(error: nil)
            }
            do {
                try (asPage ? report.page() : report.text(withHelp: true)).write(to: file, atomically: true, encoding: .utf8)
                return CodesSaveResult(error: nil)
            } catch {
                return CodesSaveResult(error: error.localizedDescription)
            }
        }
    }

    /// The model's two lists of codes, with what they are called in this mode. (The Mac app's `DiagnosticsView.body`.)
    static func codeLists(_ model: AppModel) -> [(id: String, title: String, subtitle: String, tint: String, codes: [DiagnosticCodeDefinition])] {
        if model.mode == .obd {
            return [("current", "Confirmed", "Faults the car has confirmed. The check engine light is on for these", "red", model.currentCodes),
                    ("memorized", "Pending", "Seen once, not confirmed yet. They may go away by themselves", "orange", model.memorizedCodes)]
        }
        return [("current", "Current", "Faults the ECU sees right now (temporary)", "red", model.currentCodes),
                ("memorized", "Memorized", "Stored faults, kept until memory is cleared", "orange", model.memorizedCodes)]
    }

    /// The time of day with seconds, the way this computer writes it ("14:03:22").
    private static let codesClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    // What follows restates what the Mac app keeps in its views (DiagnosticsView.swift), which the
    // Windows app does not have.

    /// "Crankshaft pos. sensor A malfunction", or the raw name when it has no code in front. (The Mac app's `DiagnosticCodeDefinition.title`.)
    static func codeTitle(_ code: DiagnosticCodeDefinition) -> String {
        code.summary.isEmpty ? code.name : sentenceCase(code.summary)
    }

    /// "P0420 Cat efficiency below threshold" (The Mac app's `DiagnosticCodeDefinition.line`.)
    static func codeLine(_ code: DiagnosticCodeDefinition) -> String {
        "\(code.code) \(codeTitle(code))"
    }

    /// The code with its meaning, causes and fixes as plain text. (The Mac app's `DiagnosticCodeDefinition.helpText`.)
    static func codeHelpText(_ code: DiagnosticCodeDefinition) -> String {
        guard let help = code.help else { return codeLine(code) }
        var lines = [codeLine(code), "", help.meaning, "", "Possible causes:"]
        lines += help.causes.map { "- \($0)" }
        lines += ["", "How to fix:"]
        lines += help.fixes.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return lines.joined(separator: "\n")
    }

    /// "CRANKSHAFT POS. SENSOR A MALFUNCTION" -> "Crankshaft pos. sensor A malfunction" (The Mac app's `String.capitalizedSentence`.)
    static func sentenceCase(_ text: String) -> String {
        guard text == text.uppercased() else { return text }
        let words = text.lowercased().split(separator: " ").map(String.init)
        let keepUpper: Set<String> = ["a", "b", "o2", "a/f", "ecm", "tcm", "egr", "ecu", "rpm", "pcv", "tgv", "avcs", "can", "abs", "vdc", "obd", "ac", "a/c", "evap", "dcv", "iat", "ect", "maf", "map"]
        return words.enumerated().map { index, word in
            if keepUpper.contains(word) && (word.count > 1 || index > 0) { return word.uppercased() }
            return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
        }.joined(separator: " ")
    }

    /// The trouble codes from one read, as plain text or as a page to print, with or without causes
    /// and fixes. (The Mac app's `TroubleCodeExport`. That one lays out a PDF with AppKit; this one
    /// writes the same report as a web page, which any browser shows and prints.)
    @MainActor
    struct CodeReport {
        struct Part {
            let title: String
            let subtitle: String
            let codes: [DiagnosticCodeDefinition]
            /// The colour of the codes on the page.
            let color: String
        }

        let readDate: Date?
        let ecu: String?
        let parts: [Part]

        static let disclaimer = "General guidance for Subaru engines. Check the service manual for your model's exact values and wiring."

        init(model: AppModel) {
            if case .read(let date) = model.codeReadState { readDate = date } else { readDate = nil }
            // The ECU ID is what an SSM cable reads. Over OBD-II there is none.
            ecu = model.mode == .obd ? nil : model.identity.map { "ECU ID \($0.ecuID) (\(model.knownECUDescription ?? "unknown car"))" }
            parts = Bridge.codeLists(model).map {
                Part(title: $0.title, subtitle: $0.subtitle, codes: $0.codes, color: $0.tint == "red" ? "#e0352b" : "#e08600")
            }
        }

        /// "SubieScope trouble codes 2026-09-24", without the file type.
        var fileName: String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return "SubieScope trouble codes \(formatter.string(from: readDate ?? Date()))"
        }

        private var readLine: String? {
            guard let readDate else { return nil }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return "Read by SubieScope on \(formatter.string(from: readDate))"
        }

        /// Codes that are in both lists are explained only the first time.
        private func entries(explain: Bool) -> [(part: Part, entries: [(code: DiagnosticCodeDefinition, explained: Bool)])] {
            var seen = Set<String>()
            return parts.map { part in
                (part, part.codes.map { code in
                    (code, explain && code.help != nil && seen.insert(code.code).inserted)
                })
            }
        }

        // MARK: Text

        func text(withHelp: Bool) -> String {
            var blocks = [(["Trouble codes"] + [readLine, ecu].compactMap { $0 }).joined(separator: "\n")]
            for (part, entries) in entries(explain: withHelp) {
                var lines = ["\(part.title.uppercased()): \(part.subtitle)"]
                if entries.isEmpty { lines.append("None") }
                for entry in entries {
                    if entry.explained {
                        lines.append(Bridge.codeHelpText(entry.code) + "\n")
                    } else {
                        lines.append(Bridge.codeLine(entry.code) + (withHelp && entry.code.help != nil ? " (explained above)" : ""))
                    }
                }
                blocks.append(lines.joined(separator: "\n").trimmingCharacters(in: .newlines))
            }
            if withHelp { blocks.append(Self.disclaimer) }
            return blocks.joined(separator: "\n\n") + "\n"
        }

        // MARK: A page to print

        /// The report as a web page of its own, set the way the Mac app's PDF is: black on white, on
        /// paper with the same margins. Printing it from a browser gives that PDF.
        func page() -> String {
            func escaped(_ text: String) -> String {
                text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            }
            var body = "<h1>Trouble codes</h1>\n"
            for line in [readLine, ecu].compactMap({ $0 }) {
                body += "<p class=\"small\">\(escaped(line))</p>\n"
            }
            for (part, entries) in entries(explain: true) {
                body += "<h2>\(escaped(part.title))</h2>\n<p class=\"small\">\(escaped(part.subtitle))</p>\n"
                if entries.isEmpty { body += "<p class=\"gray none\">None</p>\n" }
                for entry in entries {
                    let code = entry.code
                    body += "<h3><code style=\"color: \(part.color)\">\(escaped(code.code))</code>\(escaped(Bridge.codeTitle(code)))</h3>\n"
                    guard let help = code.help else { continue }
                    guard entry.explained else {
                        body += "<p class=\"gray\">Explained above.</p>\n"
                        continue
                    }
                    body += "<p>\(escaped(help.meaning))</p>\n"
                    body += "<h4>Possible causes</h4>\n<ul>\n" + help.causes.map { "<li>\(escaped($0))</li>\n" }.joined() + "</ul>\n"
                    body += "<h4>How to fix</h4>\n<ol>\n" + help.fixes.map { "<li>\(escaped($0))</li>\n" }.joined() + "</ol>\n"
                }
            }
            body += "<p class=\"small disclaimer\">\(escaped(Self.disclaimer))</p>\n"
            return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escaped(fileName))</title>
            <style>
            @page { margin: 54pt; }
            html { background: #fff; }
            body { max-width: 487pt; margin: 54pt auto; padding: 0 20pt; color: #000; font: 11pt/1.35 system-ui, "Segoe UI", "Helvetica Neue", Arial, sans-serif; }
            @media print { body { max-width: none; margin: 0; padding: 0; } }
            h1 { font-size: 22pt; margin: 0 0 4pt; }
            h2 { font-size: 16pt; margin: 22pt 0 0; }
            h3 { font-size: 12.5pt; font-weight: 600; margin: 16pt 0 4pt; break-after: avoid; }
            h3 code { font: bold 12.5pt ui-monospace, "Cascadia Mono", Consolas, Menlo, monospace; margin-right: 1.4em; }
            h4 { font-size: 11pt; font-weight: 600; margin: 6pt 0 2pt; break-after: avoid; }
            p { margin: 0 0 2pt; }
            ul, ol { margin: 0; padding-left: 16pt; }
            li { margin: 0 0 2pt; break-inside: avoid; }
            .small { font-size: 9.5pt; color: #555; }
            .gray { color: #555; }
            .none { margin-top: 8pt; }
            .disclaimer { margin-top: 24pt; }
            </style>
            </head>
            <body>
            \(body)</body>
            </html>

            """
        }
    }
}
#endif
