// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Egaliseur",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "Egaliseur",
            path: "Sources/Egaliseur"
        )
    ]
)
