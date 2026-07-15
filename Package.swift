// swift-tools-version:6.0
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
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/leaf.git", from: "4.2.4"),
    ],
    targets: [
        // ── C/C++ 解码器引擎 ──
        // 纯 C/C++ target，按格式分类组织。
        // 同一份源码同时用于 WASM 浏览器端和原生服务端解码。
        // Phase 1: 仅编译自包含解码器（ym6）和调度层。
        // Phase 3+: 安装系统库后逐步取消 exclude 并加 linkedLibrary。
        .target(
            name: "OrzAudioKitCXX",
            dependencies: [],
            exclude: [
                // 需要外部系统库的解码器（Phase 3 起逐个启用）
                "helpers/",  // cxx_helpers.cpp 依赖 libopenmpt/GME
                "openmpt/",
                "gme/",
                "sidplayfp/",
                "sc68/",
                "adplug/",
                "asap/",
                "uade/",
                "v2m/",
            ],
            cSettings: [
                .headerSearchPath("include"),
            ],
            cxxSettings: [
                .headerSearchPath("include"),
            ]
        ),

        // ── Audio Engine (Swift) ──
        // 调用 OrzAudioKitCXX 的 C 解码器进行原生解码，
        // 标准格式走 AVFoundation / ffmpeg CLI 降级。
        .target(
            name: "OrzAudioKit",
            dependencies: [
                .target(name: "OrzAudioKitCXX"),
            ]
        ),

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
            .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
        ])
    ]
)
