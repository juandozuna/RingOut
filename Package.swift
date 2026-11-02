// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RingOutEngine",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "RingOutEngine", targets: ["RingOutEngine"]),
    ],
    targets: [
        .target(
            name: "RingOutEngine",
            path: "Sources/RingOutEngine",
            cxxSettings: [
                .unsafeFlags(["-std=c++20", "-O3", "-ffast-math"]),
            ],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .testTarget(
            name: "RingOutEngineTests",
            dependencies: ["RingOutEngine"],
            path: "Tests/RingOutEngineTests"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
