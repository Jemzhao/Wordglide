// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wordglide",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Wordglide", targets: ["Wordglide"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Wordglide",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                // The app loads Contents/Frameworks; command-line SwiftPM
                // builds keep the framework next to the executable instead.
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path"
                ])
            ]
        ),
        .testTarget(
            name: "WordglideTests",
            dependencies: ["Wordglide"]
        )
    ]
)
