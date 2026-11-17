// swift-tools-version: 6.0
//
// Built with the Command Line Tools alone — no Xcode project. scripts/build-app.sh
// compiles each architecture separately, merges them with lipo and assembles
// the .app bundle by hand.

import PackageDescription

// libsodium, built from its signed release by scripts/fetch-libsodium.sh as
// one static library for both CPUs.
let sodiumLib = Context.packageDirectory + "/Vendor/libsodium/lib"

let package = Package(
    name: "Hash Lock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HashLock", targets: ["HashLockApp"]),
    ],
    targets: [
        // The C library: Argon2id, XChaCha20-Poly1305, secretstream, guarded
        // memory. Headers and the static library live in Vendor/libsodium.
        .systemLibrary(name: "Clibsodium", path: "Sources/Clibsodium"),
        // The vault: key derivation, key slots, encrypted blobs, the catalog,
        // atomic storage. No UI; everything the app keeps passes through here.
        .target(
            name: "VaultCore",
            dependencies: ["Clibsodium"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags(["-L", sodiumLib])]
        ),
        .testTarget(
            name: "VaultCoreTests",
            dependencies: ["VaultCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Everything the app shows: model, window, lock screen, settings.
        .target(
            name: "HashLockUI",
            dependencies: ["VaultCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "HashLockApp",
            dependencies: ["HashLockUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Development tool: renders the UI offscreen to PNGs (light and dark,
        // several states) with a throwaway vault, for layout review. Not shipped.
        .executableTarget(
            name: "ui-snapshots",
            dependencies: ["HashLockUI", "VaultCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
