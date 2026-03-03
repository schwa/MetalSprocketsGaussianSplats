// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MetalSprocketsGaussianSplats",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS(.v26),
    ],
    products: [
        .library(
            name: "Splats",
            targets: ["Splats"]
        ),
        .library(
            name: "MetalSprocketsGaussianSplats",
            targets: ["MetalSprocketsGaussianSplats"]
        ),
        .executable(
            name: "gsplat-render",
            targets: ["gsplat-render"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/schwa/MetalCompilerPlugin", from: "0.1.4"),
        .package(url: "https://github.com/schwa/MetalSprockets", from: "0.1.5"),
        .package(url: "https://github.com/schwa/MetalSprocketsAddOns", branch: "main"),
        .package(url: "https://github.com/schwa/GeometryLite3D", from: "0.1.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.0"),
        .package(url: "https://github.com/schwa/GoldenImage", branch: "main"),
    ],
    targets: [
        .target(
            name: "Splats",
            dependencies: [
                "MetalSprocketsGaussianSplatShaders",
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "MetalCompilerPluginSupport", package: "MetalCompilerPlugin"),
            ],
            resources: [
                .copy("Empty.txt"),
            ]
        ),
        .target(
            name: "MetalSprocketsGaussianSplats",
            dependencies: [
                "Splats",
                "MetalSprocketsGaussianSplatShaders",
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "MetalCompilerPluginSupport", package: "MetalCompilerPlugin"),
                .product(name: "MetalSprocketsUI", package: "MetalSprockets"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
            ],
            resources: [
                .process("Resources/LDR_RGBA_0.png")
            ]
        ),
        .target(
            name: "MetalSprocketsGaussianSplatShaders",
            dependencies: [
                .product(name: "MetalSprocketsAddOnsShaders", package: "MetalSprocketsAddOns"),
            ],
            exclude: ["Metal"],
            plugins: [
                .plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")
            ]
        ),
        .executableTarget(
            name: "gsplat-render",
            dependencies: [
                "MetalSprocketsGaussianSplats",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
            ]
        ),
        .testTarget(
            name: "MetalSprocketsGaussianSplatsTests",
            dependencies: [
                "MetalSprocketsGaussianSplats",
                "MetalSprocketsGaussianSplatShaders",
                "GoldenImage",
            ],
            resources: [
                .copy("Fixtures"),
                .copy("Golden Images")
            ]
        ),
        .testTarget(
            name: "SplatsTests",
            dependencies: [
                "Splats",
                "MetalSprocketsGaussianSplatShaders",
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
