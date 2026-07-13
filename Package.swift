// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MusicService",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.3"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.8.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.2.4"),
    ],
    targets: [
        // ── Audio Engine ──
        .target(
            name: "OrzAudioKit",
            dependencies: [
                .target(name: "COpenMPT"),
                .target(name: "CGameMusicEmu"),
                .target(name: "CSIDPlay"),
                .target(name: "CSC68"),
                .target(name: "CSTSound"),
                .target(name: "CUADE"),
                .target(name: "CASAP"),
                .target(name: "CAdPlug"),
                .target(name: "CV2M"),
                .target(name: "CChromaprint"),
            ]
        ),
        // ── C Library Bridge Targets ──
        .target(name: "COpenMPT"),
        .target(name: "CGameMusicEmu"),
        .target(name: "CSIDPlay"),
        .target(name: "CSC68"),
        .target(name: "CSTSound"),
        .target(name: "CUADE"),
        .target(name: "CASAP"),
        .target(name: "CAdPlug"),
        .target(name: "CV2M"),
        .target(name: "CChromaprint"),

        // ── App ──
        .target(
            name: "App",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Leaf", package: "leaf"),
                .product(name: "Vapor", package: "vapor"),
                .target(name: "OrzAudioKit"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release))
            ]
        ),
        .executableTarget(name: "Run", dependencies: [.target(name: "App")]),
        .testTarget(name: "AppTests", dependencies: [
            .target(name: "App"),
            .target(name: "OrzAudioKit"),
            .product(name: "XCTVapor", package: "vapor"),
        ])
    ]
)
