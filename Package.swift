// swift-tools-version: 6.0
import PackageDescription

// The app is one target with two faces. Its model is shared; the windows are SwiftUI on a Mac,
// and on Windows (which has no SwiftUI) a web view in a Win32 window, in Sources/SubieScope/Windows.
#if os(Windows)
let appExcludes = ["SubieScopeApp.swift", "Views"]
let appDependencies: [Target.Dependency] = ["SSMKit", "CWebView2"]
// The page the web view shows. It ends up in SubieScope_SubieScope.resources next to the program.
let appResources: [Resource] = [.copy("Windows/Web")]
// A window, not a console: without this Windows opens a black terminal next to the app.
let appLinkerSettings: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"])]
// The C face on WebView2 (scripts\fetch-webview2.ps1 gets the SDK it is compiled against).
let windowsTargets: [Target] = [.target(name: "CWebView2")]
#else
let appExcludes = ["Windows"]
let appDependencies: [Target.Dependency] = ["SSMKit"]
let appResources: [Resource] = []
let appLinkerSettings: [LinkerSetting] = []
let windowsTargets: [Target] = []
#endif

let package = Package(
    name: "SubieScope",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SubieScope", targets: ["SubieScope"]),
        .executable(name: "subiescope-cli", targets: ["SubieScopeCLI"]),
        .library(name: "SSMKit", targets: ["SSMKit"]),
    ],
    targets: [
        .target(
            name: "CSerial",
            linkerSettings: [
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedLibrary("setupapi", .when(platforms: [.windows])),
                .linkedLibrary("cfgmgr32", .when(platforms: [.windows])),
                .linkedLibrary("ws2_32", .when(platforms: [.windows])),
                .linkedLibrary("winmm", .when(platforms: [.windows])),
                .linkedLibrary("advapi32", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "SSMKit",
            dependencies: ["CSerial"],
            resources: [.copy("Resources/Definitions"), .copy("Resources/TroubleCodes"), .copy("Resources/ExtendedPIDs"), .copy("Resources/Kernels"), .copy("Resources/Cars")],
            linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS]))]
        ),
        .executableTarget(
            name: "SubieScope",
            dependencies: appDependencies,
            exclude: appExcludes,
            resources: appResources,
            linkerSettings: appLinkerSettings
        ),
        .executableTarget(
            name: "SubieScopeCLI",
            dependencies: ["SSMKit"]
        ),
        .testTarget(
            name: "SSMKitTests",
            dependencies: ["SSMKit"]
        ),
    ] + windowsTargets,
    swiftLanguageModes: [.v5]
)
