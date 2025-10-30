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
    ],
    dependencies: [
        .package(url: "https://github.com/schwa/Everything", branch: "jwight/ultraviolence-imports"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.2.0"),
        .package(url: "https://github.com/schwa/GeometryLite3D", branch: "main"),
        .package(url: "https://github.com/schwa/Interaction3D", branch: "main"),
        .package(url: "https://github.com/schwa/MetalCompilerPlugin", from: "0.1.4"),
        .package(url: "https://github.com/schwa/MetalSprockets", branch: "main"),
//        .package(path: "/Users/schwa/Shared/Projects/MetalSprocketsExamples/Packages/MetalSprocketsExamples"),
    ],
    targets: [
        .target(
            name: "MetalSprocketsGaussianSplats",
            dependencies: [
                "MetalSprocketsGaussianSplatShaders",
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "MetalSprocketsUI", package: "MetalSprockets"),
                .product(name: "Everything", package: "Everything"),

                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
                .product(name: "Interaction3D", package: "Interaction3D"),
            ]
        ),
        .target(
            name: "MetalSprocketsGaussianSplatShaders",
            exclude: ["Metal"],
            plugins: [
                .plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")
            ],

        ),
    ]
)
