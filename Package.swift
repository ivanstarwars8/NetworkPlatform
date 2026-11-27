// swift-tools-version:5.9
import PackageDescription

func lib(_ name: String, deps: [Target.Dependency] = []) -> [Target] {
    [
        .target(name: name, dependencies: deps, path: "Packages/\(name)/Sources"),
        .testTarget(name: "\(name)Tests", dependencies: [.target(name: name)], path: "Packages/\(name)/Tests"),
    ]
}

// The target list is built statement by statement: a single chained `+`
// expression of six arrays exceeds the Swift 5.10 type-checker time limit.
var allTargets: [Target] = []
allTargets += lib("DomainModels")
allTargets += lib("CoreAbstraction")
allTargets += lib("ConfigurationEngine", deps: ["DomainModels"])
allTargets += lib("RoutingEngine")
allTargets += lib("AdaptiveBalancer")
allTargets += lib("EngineXray", deps: ["CoreAbstraction"])
allTargets += [.executableTarget(name: "RoutingBench", dependencies: ["RoutingEngine"], path: "Benchmarks/RoutingBench", exclude: ["run-all.sh"])]

let package = Package(
    name: "NetworkPlatform",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "DomainModels", targets: ["DomainModels"]),
        .library(name: "CoreAbstraction", targets: ["CoreAbstraction"]),
        .library(name: "ConfigurationEngine", targets: ["ConfigurationEngine"]),
        .library(name: "RoutingEngine", targets: ["RoutingEngine"]),
        .library(name: "AdaptiveBalancer", targets: ["AdaptiveBalancer"]),
        .library(name: "EngineXray", targets: ["EngineXray"]),
    ],
    targets: allTargets
)
