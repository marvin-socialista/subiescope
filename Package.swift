// swift-tools-version: 6.0
import PackageDescription

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
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(
            name: "SSMKit",
            dependencies: ["CSerial"],
            resources: [.copy("Resources/Definitions"), .copy("Resources/TroubleCodes"), .copy("Resources/ExtendedPIDs")],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "SubieScope",
            dependencies: ["SSMKit"]
        ),
        .executableTarget(
            name: "SubieScopeCLI",
            dependencies: ["SSMKit"]
        ),
        .testTarget(
            name: "SSMKitTests",
            dependencies: ["SSMKit"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
