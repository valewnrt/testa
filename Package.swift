// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "testa",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "testa", targets: ["testa"]),
    ],
    targets: [
        // Objective-C engine: touches Apple's private CoreSimulator / SimulatorKit /
        // AccessibilityPlatformTranslation frameworks via dlopen + the Obj-C runtime.
        // Zero third-party dependencies — only Apple frameworks shipped with Xcode.
        .target(
            name: "TestaEngine",
            path: "Sources/TestaEngine",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Vision"),
            ]
        ),
        // Pure, simulator-free logic (the screen model) — unit-tested.
        .target(name: "TestaKit"),
        .executableTarget(
            name: "testa",
            dependencies: ["TestaEngine", "TestaKit"],
            path: "Sources/testa"
        ),
        .testTarget(
            name: "TestaKitTests",
            dependencies: ["TestaKit"],
            path: "Tests/TestaKitTests"
        ),
        // Pure helpers that live in the CLI target (OCR matching, key combos).
        .testTarget(
            name: "TestaCLITests",
            dependencies: ["testa"],
            path: "Tests/TestaCLITests"
        ),
    ]
)
