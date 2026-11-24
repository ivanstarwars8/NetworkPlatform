// swift-tools-version:5.9
import PackageDescription

func lib(_ name: String, deps: [Target.Dependency] = []) -> [Target] {
    [
        .target(name: name, dependencies: deps, path: "Packages/\(name)/Sources"),
        .testTarget(name: "\(name)Tests", dependencies: [.target(name: name)], path: "Packages/\(name)/Tests"),
    ]
}

let package = Package(
    name: "NetworkPlatform",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "DomainModels", targets: ["DomainModels"]),
        .library(name: "CoreAbstraction", targets: ["CoreAbstraction"]),
        .library(name: "ConfigurationEngine", targets: ["ConfigurationEngine"]),
        .library(name: "RoutingEngine", targets: ["RoutingEngine"]),
    ],
    targets: lib("DomainModels")
        + lib("CoreAbstraction")
        + lib("ConfigurationEngine", deps: ["DomainModels"])
        + lib("RoutingEngine")
)
