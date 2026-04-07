// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Yamete",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "YameteCore", targets: ["YameteCore"]),
        .library(name: "IOHIDPublic", targets: ["IOHIDPublic"]),
        .library(name: "SensorKit", targets: ["SensorKit"]),
        .library(name: "ResponseKit", targets: ["ResponseKit"]),
        .library(name: "YameteApp", targets: ["YameteApp"]),
    ],
    targets: [
        // Shared types: Vec3, SensorID, ImpactTier, protocols, logging, signal processing
        .target(
            name: "YameteCore",
            path: "Sources/YameteCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),

        // C bridging module for IOKit HID Event System public API
        .target(
            name: "IOHIDPublic",
            path: "Sources/IOHIDPublic",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),

        // Sensor abstraction, impact detection engine, accelerometer adapter
        .target(
            name: "SensorKit",
            dependencies: ["YameteCore", "IOHIDPublic"],
            path: "Sources/SensorKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMotion"),
            ]
        ),

        // Audio playback, device enumeration, screen flash overlay
        .target(
            name: "ResponseKit",
            dependencies: ["YameteCore"],
            path: "Sources/ResponseKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("SwiftUI"),
            ]
        ),

        // App layer: controller, settings, updater, views
        .target(
            name: "YameteApp",
            dependencies: ["YameteCore", "SensorKit", "ResponseKit"],
            path: "Sources/YameteApp",
            exclude: ["YameteApp.swift"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        ),

        .testTarget(
            name: "YameteTests",
            dependencies: ["YameteCore", "SensorKit", "ResponseKit", "YameteApp"],
            path: "Tests"
        ),
    ]
)
