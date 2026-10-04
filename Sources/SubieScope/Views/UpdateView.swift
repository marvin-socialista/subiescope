import AppKit
import SSMKit
import SwiftUI

/// "A new version is available": what changed and how to get it.
struct UpdateView: View {
    @Environment(AppModel.self) private var model
    let release: UpdateRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SubieScope \(release.version) is available").font(.title2.weight(.semibold))
                    Text(About.version.map { "You have version \($0)." } ?? "You are running a development build.")
                        .foregroundStyle(.secondary)
                }
            }

            if !release.whatsNew.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What's new").font(.headline)
                    ScrollView {
                        ReleaseNotesText(markdown: release.whatsNew)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Without this the notes open scrolled to their end when they are longer than the box.
                    .defaultScrollAnchor(.top)
                    .frame(maxHeight: 280)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Text("Download fetches the new version with your browser. Then quit SubieScope, open the downloaded file and drag SubieScope to Applications, replacing the old one. Your settings and logs stay as they are.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Skip This Version") { model.skipUpdate(release) }
                Spacer()
                Button("Later") { model.updateOffer = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { model.downloadUpdate(release) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 580)
    }
}

/// Release notes close to how GitHub shows them: paragraphs and "- " lists, with bold, links and code.
private struct ReleaseNotesText: View {
    let markdown: String

    private var lines: [String] {
        markdown.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(String(line.dropFirst(2))))
                    }
                    .accessibilityElement(children: .combine)
                } else if line.hasPrefix("#") {
                    Text(Self.inline(String(line.drop { $0 == "#" || $0 == " " }))).font(.headline)
                } else {
                    Text(Self.inline(line))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
