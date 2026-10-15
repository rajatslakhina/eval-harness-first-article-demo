// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EvalLoop",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EvalLoop", targets: ["EvalLoop"])
    ],
    targets: [
        .target(name: "EvalLoop"),
        .testTarget(name: "EvalLoopTests", dependencies: ["EvalLoop"])
    ]
)
