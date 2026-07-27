// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HIDTouch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "HIDDriverCore", targets: ["HIDDriverCore"]),
        .executable(name: "hidtouch-daemon", targets: ["TouchDaemon"]),
        .executable(name: "hidtouch-studio", targets: ["TouchStudio"]),
        .executable(name: "core-selftest", targets: ["CoreSelfTest"])
    ],
    targets: [
        .target(
            name: "CHIDUserDevice",
            dependencies: [],
            path: "Sources/CHIDUserDevice",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "HIDDriverCore",
            dependencies: ["CHIDUserDevice"],
            path: "Sources/HIDDriverCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .executableTarget(
            name: "TouchDaemon",
            dependencies: ["HIDDriverCore"],
            path: "Sources/TouchDaemon"
        ),
        .executableTarget(
            name: "TouchStudio",
            dependencies: ["HIDDriverCore"],
            path: "Sources/TouchStudio"
        ),
        // XCTest / swift-testing ship with Xcode, not with the Command Line
        // Tools, so the core checks live in a plain executable that `swift run`
        // can drive on any machine.
        .executableTarget(
            name: "CoreSelfTest",
            dependencies: ["HIDDriverCore"],
            path: "Sources/CoreSelfTest"
        )
    ]
)
