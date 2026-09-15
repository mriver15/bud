// swift-tools-version: 6.2
import PackageDescription

// All application code lives in `BudKit` so the executable is a thin shell around
// `BudApp` and the assertion suite can be linked into it. There is deliberately
// no test target: this machine has only the Command Line Tools, which ship
// neither XCTest nor Swift Testing, so `swift test` cannot build here. The checks
// live behind `--self-test` instead — see Sources/Bud/SelfTest/.
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
