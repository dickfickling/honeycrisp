// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Honeycrisp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CompanionKit", targets: ["CompanionKit"]),
        .executable(name: "Honeycrisp", targets: ["Honeycrisp"])
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt", from: "5.3.0")
    ],
    targets: [
        .target(
            name: "CompanionKit",
            dependencies: [
                .product(name: "BigInt", package: "BigInt")
            ],
            path: "Sources/CompanionKit"
        ),
        .testTarget(
            name: "CompanionKitTests",
            dependencies: ["CompanionKit"],
            path: "Tests/CompanionKitTests"
        ),
        .executableTarget(
            name: "Honeycrisp",
            dependencies: ["CompanionKit"],
            path: "Sources/Honeycrisp"
        )
    ]
)
