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
allTargets += lib("ConfigurationEngine", deps: ["DomainModels", "RoutingEngine"])
allTargets += lib("RoutingEngine")
allTargets += lib("AdaptiveBalancer")
// The C ABI both bridges share: lifecycle driver, packet pump, log reader (pure Swift, no Go).
allTargets += lib("EngineBridge", deps: ["CoreAbstraction"], testDeps: ["EngineBridgeTestSupport"])
// Fakes of the bridge and of the packet flow for the tests of EngineBridge and of both adapters; no product.
allTargets += [.target(name: "EngineBridgeTestSupport", dependencies: ["EngineBridge"], path: "Packages/EngineBridge/TestSupport")]
allTargets += lib("EngineXray", deps: ["CoreAbstraction", "EngineBridge"], testDeps: ["DomainModels", "EngineBridgeTestSupport"])
allTargets += lib("EngineMihomo", deps: ["CoreAbstraction", "EngineBridge", "ConfigurationEngine"], testDeps: ["DomainModels", "EngineBridgeTestSupport"])
// What the app keeps and compiles: import of links and subscriptions, the profile file with secrets in a
// secret store, compilation for the Packet Tunnel. App-side only, no engine adapters (ADR-0001 rule 2).
// The tests compile Extensions/PacketTunnel/Shared and the app's start-request mapping through symbolic links.
// The user's routing and DNS settings (presets, own rules, downloaded lists, resolvers) compiled into the
// RoutingTable both engine compilers take, and the route simulator's explanations. App-side, no engine code.
allTargets += lib("RoutingPolicy", deps: ["DomainModels", "RoutingEngine", "ConfigurationEngine"], testDeps: ["DomainModels", "RoutingEngine", "ConfigurationEngine"])
allTargets += lib("ProfileLibrary", deps: ["DomainModels", "ConfigurationEngine", "AdaptiveBalancer", "RoutingPolicy"], testDeps: ["DomainModels", "ConfigurationEngine", "RoutingPolicy"])
// Design tokens, the horn connect control and the app's components (Documentation/Design/DESIGN.md). The tokens,
// state mapping and horn geometry are platform-neutral and tested on Linux; the SwiftUI parts compile only where
// SwiftUI exists. Bundled fonts (SIL OFL 1.1) are resources. The tests also compile the app's screen registry
// (Apps/SharedApp/Features/AppDestination.swift) through a symbolic link.
allTargets += [
    .target(name: "DesignSystem", path: "Packages/DesignSystem/Sources/DesignSystem", resources: [.copy("Resources/Fonts")]),
    .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"], path: "Packages/DesignSystem/Tests/DesignSystemTests"),
]
// The network toolbox and traffic analyser of the Профи level: TCP connect timing, DNS over UDP to a chosen
// resolver, certificate summaries, HTTP phase timing, the DNS leak check, bounded analyser history and the
// redacted diagnostics bundle. App-side only, no engine code. The C target reads the system DNS configuration
// (resolv.h), which no Swift system module exposes.
allTargets += [
    .target(name: "CNetworkToolbox", path: "Packages/NetworkToolbox/Sources/CNetworkToolbox", linkerSettings: [.linkedLibrary("resolv")]),
    .target(name: "NetworkToolbox", dependencies: ["CNetworkToolbox"], path: "Packages/NetworkToolbox/Sources/NetworkToolbox"),
    .testTarget(name: "NetworkToolboxTests", dependencies: ["NetworkToolbox"], path: "Packages/NetworkToolbox/Tests/NetworkToolboxTests"),
]
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
        .library(name: "RoutingPolicy", targets: ["RoutingPolicy"]),
        .library(name: "ProfileLibrary", targets: ["ProfileLibrary"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "NetworkToolbox", targets: ["NetworkToolbox"]),
        .library(name: "EngineBridge", targets: ["EngineBridge"]),
        .library(name: "EngineXray", targets: ["EngineXray"]),
        .library(name: "EngineMihomo", targets: ["EngineMihomo"]),
    ],
    targets: allTargets
)
