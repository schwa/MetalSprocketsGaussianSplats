// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MetalSprocketsGaussianSplats",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .visionOS(.v26),
    ],
    products: [
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
//        .package(url: "https://github.com/schwa/MetalSprockets", from: "0.1.0"),
        .package(url: "https://github.com/schwa/MetalSprockets", branch: "main"),
        .package(url: "https://github.com/schwa/GeometryLite3D", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "MetalSprocketsGaussianSplats",
            dependencies: [
                "MetalSprocketsGaussianSplatShaders",
                .product(name: "MetalSprockets", package: "MetalSprockets"),
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
            exclude: ["Metal"],
            plugins: [
                .plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")
            ],

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
            dependencies: ["MetalSprocketsGaussianSplats"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
