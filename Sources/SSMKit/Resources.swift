import Foundation

/// Locates SSMKit's resource bundle both in `swift run` builds and inside SubieScope.app.
///
/// SwiftPM's generated `Bundle.module` only looks next to the executable, which in
/// an app bundle would mean the unsigned top level of SubieScope.app, and it crashes when
/// the bundle is missing. The build script puts the bundle in Contents/Resources.
private final class BundleToken {}

enum SSMResources {
    static let bundleName = "SubieScope_SSMKit.bundle"

    static let bundle: Bundle? = {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            // The bundle that contains this code (e.g. a test .xctest), and its folder.
            Bundle(for: BundleToken.self).resourceURL?.appendingPathComponent(bundleName),
            Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName),
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        // Test runners live in their own bundle; search loaded bundles too.
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            let url = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(bundleName)
            if let found = Bundle(url: url) { return found }
        }
        return nil
    }()

    static func url(forDefinition name: String) -> URL? {
        bundle?.url(forResource: name, withExtension: nil, subdirectory: "Definitions")
    }

    static func url(forTroubleCodes name: String) -> URL? {
        bundle?.url(forResource: name, withExtension: "json", subdirectory: "TroubleCodes")
    }

    static func url(forExtendedPIDs name: String) -> URL? {
        bundle?.url(forResource: name, withExtension: "json", subdirectory: "ExtendedPIDs")
    }

    /// The car tables made by `scripts/build-car-data.py`: "known_ecus" and "dyno_cars".
    static func url(forCars name: String) -> URL? {
        bundle?.url(forResource: name, withExtension: "json", subdirectory: "Cars")
    }

    /// A kernel binary (the small helper program uploaded into ECU RAM to dump flash), e.g.
    /// "ssmk_can_tp_sh7058". From FastECU (GPLv3); credited in the README.
    static func url(forKernel name: String) -> URL? {
        bundle?.url(forResource: name, withExtension: "bin", subdirectory: "Kernels")
    }

    static func definitionFiles() -> [URL] {
        guard let dir = bundle?.resourceURL?.appendingPathComponent("Definitions") else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "xml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
