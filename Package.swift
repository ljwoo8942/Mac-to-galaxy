// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = []
var targets: [Target] = [
    .target(name: "GalaxyCore"),
    .testTarget(name: "GalaxyCoreTests", dependencies: ["GalaxyCore"]),
]

#if os(macOS)
products.append(.executable(name: "MacToGalaxy", targets: ["MacToGalaxy"]))
targets += [
    .systemLibrary(name: "CMTP", pkgConfig: "libmtp", providers: [.brew(["libmtp", "pkgconf"])]),
    .target(name: "MTPBridge", dependencies: ["CMTP"]),
    .executableTarget(name: "MacToGalaxy", dependencies: ["GalaxyCore", "MTPBridge"]),
]
#endif

let package = Package(
    name: "Mac-to-galaxy",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
