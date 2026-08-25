// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MetalSprocketsGaussianSplats",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS(.v26)
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
        .library(
            name: "MetalSprocketsGaussianSplatsDebug",
            targets: ["MetalSprocketsGaussianSplatsDebug"]
        ),
        .executable(
            name: "metalsprockets-gaussian-splat",
            targets: ["metalsprockets-gaussian-splat"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/schwa/MetalCompilerPlugin", from: "0.1.4"),
        .package(url: "https://github.com/schwa/MetalSprockets", from: "0.1.12"),
        .package(url: "https://github.com/schwa/GeometryLite3D", from: "0.1.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.0"),
        .package(url: "https://github.com/schwa/GoldenImage", from: "0.1.2"),
        .package(url: "https://github.com/schwa/MetalSupport", from: "1.0.5"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.1.0"),
        .package(url: "https://github.com/facebook/zstd", from: "1.5.5")
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
                .product(name: "libzstd", package: "zstd")
            ],
            resources: [
                .copy("Empty.txt")
            ]
        ),
        .target(
            name: "MetalSprocketsGaussianSplats",
            dependencies: [
                "Splats",
                "MetalSprocketsGaussianSplatShaders",
                .product(name: "MetalSupport", package: "MetalSupport"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "MetalSprocketsSupport", package: "MetalSprockets"),
                .product(name: "MetalCompilerPluginSupport", package: "MetalCompilerPlugin"),
                .product(name: "MetalSprocketsUI", package: "MetalSprockets"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D")
            ],
            resources: [
                .process("Resources/LDR_RGBA_0.png")
            ]
        ),
        .target(
            name: "MetalSprocketsGaussianSplatsDebug",
            dependencies: [
                "MetalSprocketsGaussianSplats",
                "MetalSprocketsGaussianSplatShaders",
                "Splats",
                "MetalSprocketsGaussianSplatsDebugShaders",
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "MetalSprocketsSupport", package: "MetalSprockets"),
                .product(name: "MetalCompilerPluginSupport", package: "MetalCompilerPlugin")
            ],
            resources: [.copy("Empty.txt")]
        ),
        .target(
            name: "MetalSprocketsGaussianSplatShaders",
            dependencies: [
                .product(name: "MetalSprocketsShaders", package: "MetalSprockets")
            ],
            exclude: ["Metal"],
            plugins: [
                .plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")
            ]
        ),
        .target(
            name: "MetalSprocketsGaussianSplatsDebugShaders",
            dependencies: [
                "MetalSprocketsGaussianSplatShaders",
                .product(name: "MetalSprocketsShaders", package: "MetalSprockets")
            ],
            exclude: ["Metal"],
            plugins: [
                .plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")
            ]
        ),
        .executableTarget(
            name: "metalsprockets-gaussian-splat",
            dependencies: [
                "MetalSprocketsGaussianSplats",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MetalSupport", package: "MetalSupport"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D")
            ]
        ),
        .testTarget(
            name: "MetalSprocketsGaussianSplatsTests",
            dependencies: [
                "MetalSprocketsGaussianSplats",
                "MetalSprocketsGaussianSplatShaders",
                "GoldenImage"
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
                .product(name: "GeometryLite3D", package: "GeometryLite3D")
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
