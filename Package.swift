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
        // ── Audio Engine ──
        // 解码策略：标准格式 → AVFoundation / ffmpeg CLI
        //           模块格式 → ffmpeg CLI（通过 system lib 插件）
        //           冷门格式 → ffmpeg CLI 降级
        // WASM 路径：Emscripten 编译 libopenmpt → 浏览器端解码
        .target(name: "OrzAudioKit", exclude: [
            "audio_engine.c", "audio_engine.h",
            "orz_dispatch.c",
            "openmpt_impl.c", "gme_impl.c", "asap_impl.c",
            "adplug_impl.c", "adplug_wrap.cpp",
            "sc68_impl.c", "ym6_impl.c",
            "sidplayfp_impl.cpp",
            "v2m_wasm.cpp", "v2mplayer_wasm.cpp", "v2m_types.h",
            "cxx_helpers.cpp",
            "uade_wasm.c", "score_data.h", "ahx_player_data.h",
            "include",
        ]),

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
