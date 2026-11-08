// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "AIYOUClean", platforms: [.macOS(.v13)],
    products: [.library(name: "CleanRoomCore", targets: ["CleanRoomCore"]), .executable(name: "AIYOUClean", targets: ["CleanRoomMac"]), .executable(name: "aiyouclean-cli", targets: ["cleanroom"])],
    targets: [.systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"), .target(name: "CleanRoomCore", dependencies: ["CSQLite"]), .executableTarget(name: "CleanRoomMac", dependencies: ["CleanRoomCore"]), .executableTarget(name: "cleanroom", dependencies: ["CleanRoomCore"]), .executableTarget(name: "CleanRoomChecks", dependencies: ["CleanRoomCore"], path: "Tests/CleanRoomCoreTests")])
