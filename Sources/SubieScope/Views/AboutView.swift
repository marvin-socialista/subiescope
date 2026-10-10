import AppKit
import SwiftUI

extension About {
    /// The standard About panel, with the coffee link in its credits.
    static func showPanel() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(
            string: "SubieScope is free. If it helps you, you can\n",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centered])
        credits.append(NSAttributedString(
            string: "buy me a coffee",
            attributes: [.font: font, .link: coffeeURL, .paragraphStyle: centered]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The About tab in Settings.
struct AboutView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text("SubieScope")
                    .font(.title2.weight(.semibold))
                Text(About.version.map { "Version \($0)" } ?? "Development build")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("SSM logging, diagnostics and a virtual dyno for Subarus. SubieScope is free: if it saves you a trip to the dealer, you can buy me a coffee.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)

            Button {
                openURL(About.coffeeURL)
            } label: {
                Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help(About.coffeeURL.absoluteString)

            Spacer(minLength: 0)

            Text("Parameter definitions from the RomRaider project. Not affiliated with Subaru.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
