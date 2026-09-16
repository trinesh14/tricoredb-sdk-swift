// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TriCoreDB",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "TriCoreDB", targets: ["TriCoreDB"])
    ],
    dependencies: [
        // SwiftNIO is what a networked database client is built on in Swift —
        // PostgresNIO, MySQLNIO and RediStack all sit on it. NIOSSL comes with it
        // because Linux has no system TLS to fall back on, and a client that
        // offered TLS only on Apple platforms would be the weaker library.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
    ],
    targets: [
        .target(
            name: "TriCoreDB",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .testTarget(
            name: "TriCoreDBTests",
            dependencies: [
                "TriCoreDB",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
