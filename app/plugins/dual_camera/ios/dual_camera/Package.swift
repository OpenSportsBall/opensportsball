// swift-tools-version: 5.9
// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "dual_camera",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "dual-camera", targets: ["dual_camera"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "dual_camera",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Declares the free-disk-space API (low-storage check).
                .process("PrivacyInfo.xcprivacy")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        )
    ]
)
