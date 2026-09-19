// swift-tools-version: 6.2
import PackageDescription

// All application code lives in `BudKit` so the executable is a thin shell around
// `BudApp` and the assertion suite can be linked into it.
//
// There is deliberately no test target. Bud assembles its own app bundle from
// SwiftPM and builds with either the Command Line Tools or a full Xcode; the
// checks are compiled into the app rather than into a separate test bundle, so
// they exercise the same binary that ships, and run without XCTest being present.
// Run them with `--self-test`, `--verify-ui`, `--verify-browser` and
// `--verify-live` — see Sources/Bud/SelfTest/.
let package = Package(
    name: "Bud",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "BudKit",
            path: "Sources/Bud",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Bud",
            dependencies: ["BudKit"],
            path: "Sources/BudMain"
        ),
    ]
)
