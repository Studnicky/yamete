// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Yamete",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "YameteLib",
            path: "Sources",
            exclude: ["YameteApp.swift"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "YameteTests",
            dependencies: ["YameteLib"],
            path: "Tests"
        ),
    ]
)
