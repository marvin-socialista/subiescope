import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// What the model asks of the desktop around it: opening a link, pointing at a file, showing a
/// message, asking where to save. A Mac answers with AppKit; Windows has its own answers in
/// Windows/Desktop+Windows.swift.
@MainActor
enum Desktop {
    #if canImport(AppKit)
    /// What a person calls this computer, and the program that shows its files.
    static let computer = "Mac"
    static let fileBrowser = "Finder"
    /// Why a report could not be put into a new email.
    static let noMailApp = "No email app is set up on this Mac"

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Shows the file in its folder, selected.
    static func reveal(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    /// Shows a message and waits for the answer. Without `buttons` there is one, "OK".
    /// Returns which button was pressed, counted from 0.
    @discardableResult
    static func alert(_ title: String, _ detail: String, buttons: [String] = []) -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// Asks where to save a file. Nil when the person changed their mind.
    static func chooseSaveLocation(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Asks for a file to open. `filter` is pairs of a description and a pattern: ["Logs", "*.csv"].
    /// Several patterns for one description are separated by a semicolon: "*.bin;*.hex".
    static func chooseFileToOpen(filter: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = stride(from: 1, to: filter.count, by: 2).flatMap { filter[$0].split(separator: ";") }
            .map { $0.replacingOccurrences(of: "*.", with: "") }.filter { $0 != "*" && !$0.isEmpty }
        if !types.isEmpty { panel.allowedFileTypes = types }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Asks for a folder. Nil when the person changed their mind.
    static func chooseFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = title
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Moves a file to the Trash. False when that did not work: the file is then still where it was.
    @discardableResult
    static func trash(_ file: URL) -> Bool {
        (try? FileManager.default.trashItem(at: file, resultingItemURL: nil)) != nil
    }

    /// Puts text on the clipboard.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens a new email with a file attached. False when no mail app here can do that.
    static func composeEmail(to recipient: String, subject: String, body: String, attachment: URL) -> Bool {
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [body, attachment]) else { return false }
        service.recipients = [recipient]
        service.subject = subject
        service.perform(withItems: [body, attachment])
        return true
    }
    #endif
}
