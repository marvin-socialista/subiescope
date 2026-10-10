import CWebView2
import Foundation
import WinSDK

/// The Windows answers to what the model asks of the desktop (see Desktop.swift).
extension Desktop {
    static let computer = "PC"
    static let fileBrowser = "File Explorer"
    static let noMailApp = "SubieScope cannot attach a file to a new email on Windows"

    /// The app's window: message boxes and dialogs belong to it.
    nonisolated(unsafe) static var window: HWND?

    /// A file's path the way Windows writes it (C:\Users\...).
    nonisolated static func path(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
    }

    static func open(_ url: URL) {
        shell("open", url.isFileURL ? path(url) : url.absoluteString, nil)
    }

    /// Shows the file in its folder, selected.
    static func reveal(_ file: URL) {
        shell("open", "explorer.exe", "/select,\"\(path(file))\"")
    }

    private static func shell(_ verb: String, _ target: String, _ arguments: String?) {
        verb.withCString(encodedAs: UTF16.self) { verb in
            target.withCString(encodedAs: UTF16.self) { target in
                if let arguments {
                    arguments.withCString(encodedAs: UTF16.self) { _ = ShellExecuteW(window, verb, target, $0, nil, SW_SHOWNORMAL) }
                } else {
                    _ = ShellExecuteW(window, verb, target, nil, nil, SW_SHOWNORMAL)
                }
            }
        }
    }

    /// Shows a message and waits for the answer. Without `buttons` there is one, "OK". A message
    /// box has no buttons with words of their own, so a second button becomes a question: Yes is that button.
    /// Returns which button was pressed, counted from 0.
    @discardableResult
    static func alert(_ title: String, _ detail: String, buttons: [String] = []) -> Int {
        let question = buttons.count > 1
        let text = question ? "\(detail)\n\n\(buttons[1])?" : detail
        let flags = UINT(question ? MB_YESNO | MB_ICONQUESTION : MB_OK | MB_ICONINFORMATION)
        let answer = text.withCString(encodedAs: UTF16.self) { text in
            title.withCString(encodedAs: UTF16.self) { MessageBoxW(window, text, $0, flags) }
        }
        return question && answer == IDYES ? 1 : 0
    }

    /// Asks where to save a file. Nil when the person changed their mind.
    static func chooseSaveLocation(suggestedName: String) -> URL? {
        chooseFile(saving: true, suggestedName: suggestedName, filter: nil)
    }

    /// Asks for a file to open. `filter` is pairs of a description and a pattern: ["Logs", "*.csv"].
    static func chooseFileToOpen(filter: [String]) -> URL? {
        chooseFile(saving: false, suggestedName: "", filter: filter)
    }

    static func chooseFile(saving: Bool, suggestedName: String, filter: [String]?) -> URL? {
        var file = [WCHAR](repeating: 0, count: 2048)
        for (i, unit) in suggestedName.utf16.prefix(file.count - 1).enumerated() { file[i] = unit }
        // Description and pattern in turn, each closed by a zero, and one more zero at the end.
        var pairs = filter ?? []
        let type = (suggestedName as NSString).pathExtension
        if pairs.isEmpty, !type.isEmpty { pairs = ["\(type.uppercased()) files", "*.\(type)"] }
        pairs += ["All files", "*.*"]
        var filterText: [WCHAR] = []
        for part in pairs { filterText += Array(part.utf16) + [0] }
        filterText.append(0)
        let defaultType = Array(type.utf16) + [0]

        var dialog = OPENFILENAMEW()
        dialog.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
        dialog.hwndOwner = window
        dialog.nMaxFile = DWORD(file.count)
        dialog.Flags = DWORD(OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST | (saving ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST))
        let chosen: Bool = file.withUnsafeMutableBufferPointer { file in
            filterText.withUnsafeBufferPointer { filterText in
                defaultType.withUnsafeBufferPointer { defaultType in
                    dialog.lpstrFile = file.baseAddress
                    dialog.lpstrFilter = filterText.baseAddress
                    dialog.lpstrDefExt = type.isEmpty ? nil : defaultType.baseAddress
                    return saving ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog)
                }
            }
        }
        guard chosen else { return nil }
        return URL(fileURLWithPath: String(decodingCString: file, as: UTF16.self))
    }

    /// Asks for a folder. Nil when the person changed their mind.
    static func chooseFolder(title: String) -> URL? {
        var path = [UInt16](repeating: 0, count: 2048)
        let chosen = title.withCString(encodedAs: UTF16.self) {
            host_choose_folder(window.map { UnsafeMutableRawPointer($0) }, $0, &path, Int32(path.count))
        }
        guard chosen != 0 else { return nil }
        return URL(fileURLWithPath: String(decodingCString: path, as: UTF16.self), isDirectory: true)
    }

    /// Moves a file to the Recycle Bin. False when that did not work: the file is then still where it was.
    @discardableResult
    static func trash(_ file: URL) -> Bool {
        path(file).withCString(encodedAs: UTF16.self) { host_recycle(window.map { UnsafeMutableRawPointer($0) }, $0) != 0 }
    }

    /// Puts text on the clipboard.
    static func copy(_ text: String) {
        text.withCString(encodedAs: UTF16.self) { host_copy_text(window.map { UnsafeMutableRawPointer($0) }, $0) }
    }

    /// Windows has no way to hand a file to a new email. The report is shown in its folder instead.
    static func composeEmail(to recipient: String, subject: String, body: String, attachment: URL) -> Bool {
        false
    }
}
