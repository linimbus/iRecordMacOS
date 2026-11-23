// swift-tools-version:5.9
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "iRecord",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "iRecordApp", targets: ["iRecordApp"]),
        .executable(name: "irecord", targets: ["iRecordCLI"]),
        .library(name: "iRecordCore", targets: ["iRecordCore"])
    ],
    targets: [
        .target(name: "iRecordCore"),
        .executableTarget(name: "iRecordApp", dependencies: ["iRecordCore"]),
        .executableTarget(
            name: "iRecordCLI",
            dependencies: ["iRecordCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(packageRoot)/Resources/irecord-Info.plist"
                ])
            ]
        ),
        .testTarget(name: "iRecordCoreTests", dependencies: ["iRecordCore"])
    ]
)
