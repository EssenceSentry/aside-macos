// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Aside", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Aside", targets: ["Aside"]),
    .executable(name: "AsideAudioBench", targets: ["AsideAudioBench"]),
    .executable(name: "AsideWhisperBench", targets: ["AsideWhisperBench"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/FluidInference/FluidAudio.git",
      revision: "ee78635d23d52379117554ba72358b65a0612447", traits: []),
    .package(
      url: "https://github.com/argmaxinc/argmax-oss-swift.git",
      revision: "9f99b5cb6a907730543823ad271b82532782a899"),
  ],
  targets: [
    .target(
      name: "AsideAudio", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
      swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(
      name: "AsideAudioBench",
      dependencies: ["AsideAudio", .product(name: "FluidAudio", package: "FluidAudio")],
      swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(
      name: "AsideWhisper",
      dependencies: [
        .product(name: "WhisperKit", package: "argmax-oss-swift"),
        .product(name: "SpeakerKit", package: "argmax-oss-swift"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(
      name: "AsideWhisperBench", dependencies: ["AsideWhisper", "AsideAudio"],
      swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(
      name: "AsideAudioTests", dependencies: ["AsideAudio"],
      swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(
      name: "Aside",
      dependencies: [
        "AsideWhisper", "AsideAudio", .product(name: "FluidAudio", package: "FluidAudio"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(
      name: "AsideTests", dependencies: ["Aside"], swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
