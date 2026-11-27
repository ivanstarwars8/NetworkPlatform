// swift-tools-version:5.9
import PackageDescription

func lib(_ name: String, deps: [Target.Dependency] = [], testDeps: [Target.Dependency] = []) -> [Target] {
    [
        .target(name: name, dependencies: deps, path: "Packages/\(name)/Sources"),
        .testTarget(name: "\(name)Tests", dependencies: [.target(name: name)] + testDeps, path: "Packages/\(name)/Tests"),
    ]
}

// The target list is built statement by statement: a single chained `+`
// expression of six arrays exceeds the Swift 5.10 type-checker time limit.
var allTargets: [Target] = []
allTargets += lib("DomainModels")
// The tests compile Extensions/PacketTunnel/Shared through a symbolic link; Shared/ uses DomainModels.
allTargets += lib("CoreAbstraction", testDeps: ["DomainModels"])
allTargets += lib("ConfigurationEngine", deps: ["DomainModels"])
allTargets += lib("RoutingEngine")
allTargets += lib("AdaptiveBalancer")
// The C ABI both bridges share: lifecycle driver, packet pump, log reader (pure Swift, no Go).
allTargets += lib("EngineBridge", deps: ["CoreAbstraction"], testDeps: ["EngineBridgeTestSupport"])
// Fakes of the bridge and of the packet flow for the tests of EngineBridge and of both adapters; no product.
allTargets += [.target(name: "EngineBridgeTestSupport", dependencies: ["EngineBridge"], path: "Packages/EngineBridge/TestSupport")]
allTargets += lib("EngineXray", deps: ["CoreAbstraction", "EngineBridge"], testDeps: ["DomainModels", "EngineBridgeTestSupport"])
allTargets += lib("EngineMihomo", deps: ["CoreAbstraction", "EngineBridge"], testDeps: ["DomainModels", "EngineBridgeTestSupport"])
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
        .library(name: "EngineBridge", targets: ["EngineBridge"]),
        .library(name: "EngineXray", targets: ["EngineXray"]),
        .library(name: "EngineMihomo", targets: ["EngineMihomo"]),
    ],
    targets: allTargets
)
