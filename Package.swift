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
        // Phase 3（进行中）：已启用 openmpt，逐个增补解码器。
        // 解码器目录通过 exclude 控制编译与否，对应的库、头文件路径、
        // 以及链接器标志通过 cSettings/linkerSettings 逐项添加。
        .target(
            name: "OrzAudioKitCXX",
            dependencies: [],
            exclude: [],
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/sidplayfp"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/adplug"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/binio"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/sc68"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/v2m_headers"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/v2m_headers/v2m"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/ahx2play"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/uade_combined/include"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/uade_combined"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/uade_combined/frontends/include"),
                .define("ORZ_HAVE_OPENMPT"),
                .define("ORZ_HAVE_GME"),
            ],
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/sidplayfp"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/adplug"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/binio"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/sc68"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/v2m_headers"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/v2m_headers/v2m"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/ahx2play"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/uade_combined/include"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/uade_combined"),
                .headerSearchPath("../../Libraries/OrzAudioKit/thirdparty/uade_combined/frontends/include"),
                .define("ORZ_HAVE_OPENMPT"),
                .define("ORZ_HAVE_GME"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/Users/joker/Developer/OrzPlayer/Service/Libraries/OrzAudioKit/native"]),
                .linkedLibrary("openmpt"),
                .linkedLibrary("gme"),
                .linkedLibrary("sidplayfp"),
                .linkedLibrary("adplug"),
                .linkedLibrary("binio"),
                .linkedLibrary("asap"),
                .linkedLibrary("sc68"),
                .linkedLibrary("v2m"),
                .linkedLibrary("ahx2play"),
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
