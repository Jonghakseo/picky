// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PickyDiffReviewPlayground",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "diff-review-playground", targets: ["DiffReviewPlayground"])
    ],
    targets: [
        .executableTarget(
            name: "DiffReviewPlayground",
            path: "Sources/DiffReviewPlayground"
        ),
        .testTarget(
            name: "DiffReviewPlaygroundTests",
            dependencies: ["DiffReviewPlayground"],
            path: "Tests/DiffReviewPlaygroundTests"
        )
    ]
)
