// swift-tools-version: 5.9

import PackageDescription

// One Swift target for both platforms: the shared sources under
// `Camera/`, `File/` and `Video/` are extended by the per-platform files
// under `iOS/` and `macOS/` using `internal` access, which does not cross
// Swift module boundaries — so splitting the platforms into separate
// targets would force that whole surface public. Instead every file under
// `iOS/`/`macOS/` is wrapped in `#if os(...)`, and basenames are unique
// across the target (SPM emits one object file per basename, so a second
// `FilePlugin.swift` would collide).
//
// `url_detect.m` is its own C target: SPM forbids mixing Objective-C and
// Swift in a single target. Nothing imports it — Dart reaches
// `ux_match_url`/`ux_free` through dart:ffi — so it needs no headers
// exposed to the Swift side, only to be linked into the binary.
//
// `ux_extension` is the subset an app extension may link. `ux` itself is not
// linkable from one: keyboard, gallery, camera and url all go through
// `UIApplication`, which is unavailable there. Its plugins are plain classes —
// the `NativePlugin` conformances are declared by `ux`, which depends on it.
let package = Package(
  name: "ux",
  platforms: [
    .iOS("13.0"),
    .macOS("10.15"),
  ],
  products: [
    .library(name: "ux", targets: ["ux"]),
    .library(name: "ux_extension", targets: ["ux_extension"]),
  ],
  dependencies: [
    // DropPlugin.zipForUpload needs FileManager.zipItem(progress:) for
    // cancellable folder upload; macOS only.
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMinor(from: "0.9.20"))
  ],
  targets: [
    .target(
      name: "ux",
      dependencies: [
        .target(name: "ux_extension"),
        .target(name: "ux_url_detect"),
        .product(
          name: "ZIPFoundation",
          package: "ZIPFoundation",
          condition: .when(platforms: [.macOS])
        ),
      ],
      path: "Sources/ux",
      linkerSettings: [
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("CoreVideo"),
        .linkedFramework("Intents", .when(platforms: [.iOS])),
        .linkedFramework("Photos", .when(platforms: [.iOS])),
        .linkedFramework("PhotosUI", .when(platforms: [.iOS])),
      ]
    ),
    .target(
      name: "ux_extension",
      path: "Sources/ux_extension",
      swiftSettings: [.unsafeFlags(["-application-extension"])]
    ),
    .target(
      name: "ux_url_detect",
      path: "Sources/ux_url_detect",
      publicHeadersPath: "include"
    ),
  ]
)
