import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LogFile: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let date: Date
    let size: Int
}

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var files: [LogFile] = []
    @State private var selection: LogFile?
    @State private var confirmDelete: LogFile?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(files, selection: $selection) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.url.lastPathComponent).lineLimit(1)
                        Text("\(file.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(file)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        Button("Open With Default App") { NSWorkspace.shared.open(file.url) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { confirmDelete = file }
                    }
                }
                .overlay {
                    if files.isEmpty {
                        ContentUnavailableView("No logs yet", systemImage: "doc.text",
                                               description: Text("Recordings are saved to\n\(model.logsFolder.path)"))
                    }
                }
                Divider()
                HStack {
                    Button {
                        try? FileManager.default.createDirectory(at: model.logsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.logsFolder)
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    Button {
                        openLogPanel(model)
                    } label: {
                        Label("Open…", systemImage: "doc.badge.plus")
                    }
                    .help("Open any RomRaider CSV log (⌘O)")
                    Spacer()
                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Reload")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 290)
            Divider()

            Group {
                if let playback = model.playback {
                    LogViewerView(playback: playback)
                        .id(playback.url)
                } else if let error = model.playbackError {
                    ContentUnavailableView("Could not open the log", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ContentUnavailableView("Select a log", systemImage: "chart.xyaxis.line",
                                           description: Text("Pick a recording to replay it. You can also open RomRaider logs from elsewhere (⌘O). The files are standard RomRaider CSV, so Datazap, DataLog Lab and Virtual Dyno open them too."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            reload()
            if let url = model.playback?.url { selection = files.first { $0.url == url } }
        }
        .onChange(of: selection) { _, file in
            if let file { Task { await model.openLog(file.url) } }
        }
        .onChange(of: model.isRecording) { _, _ in reload() }
        .confirmationDialog("Move \(confirmDelete?.url.lastPathComponent ?? "") to the Trash?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let file = confirmDelete {
                    try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                    if selection == file { selection = nil }
                    reload()
                }
            }
        }
    }

    private func reload() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: model.logsFolder, includingPropertiesForKeys: keys)) ?? []
        files = urls.filter { $0.pathExtension.lowercased() == "csv" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return LogFile(url: url, date: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0)
        }
        .sorted { $0.date > $1.date }
    }
}

@MainActor
func openLogPanel(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.commaSeparatedText, .plainText]
    panel.directoryURL = model.logsFolder
    panel.message = "Choose a SubieScope or RomRaider CSV log"
    if panel.runModal() == .OK, let url = panel.url {
        model.section = .logs
        Task { await model.openLog(url) }
    }
}
