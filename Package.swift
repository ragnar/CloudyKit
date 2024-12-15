// swift-tools-version:5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CloudyKit",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "CloudyKit",
            targets: ["CloudyKit"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/IBM-Swift/BlueCryptor.git",
            from: "1.0.32"
        ),
        .package(
            url: "https://github.com/IBM-Swift/BlueECC.git",
            from: "1.2.4"
        ),
        .package(
            url: "https://github.com/OpenCombine/OpenCombine.git",
            from: "0.11.0"
        ),
    ],
    targets: [
        .target(
            name: "CloudyKit",
            dependencies: [
                .product(name: "Cryptor", package: "BlueCryptor"),
                .product(name: "CryptorECC", package: "BlueECC"),
                .product(name: "OpenCombineFoundation", package: "OpenCombine"),
            ]
        ),
        .testTarget(
            name: "CloudyKitTests",
            dependencies: ["CloudyKit"],
            resources: [
                .copy("Assets"),
            ]
        ),
    ]
)
