// swift-tools-version: 6.2
// Throwaway design lab. No dependency on production modules. New files in a target's folder are picked up automatically,
// so design agents never need to edit this file.
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "DesignLabKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "LabCore", targets: ["LabCore"]),
        .library(name: "Design1Polish", targets: ["Design1Polish"]),
        .library(name: "Design2Glass", targets: ["Design2Glass"]),
        .library(name: "Design3Brutal", targets: ["Design3Brutal"]),
        .library(name: "Design4Store", targets: ["Design4Store"]),
    ],
    targets: [
        .target(name: "LabCore", swiftSettings: v5),
        .target(name: "Design1Polish", dependencies: ["LabCore"], swiftSettings: v5),
        .target(name: "Design2Glass", dependencies: ["LabCore"], swiftSettings: v5),
        .target(name: "Design3Brutal", dependencies: ["LabCore"], swiftSettings: v5),
        .target(name: "Design4Store", dependencies: ["LabCore"], swiftSettings: v5),
    ]
)
