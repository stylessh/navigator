// swift-tools-version: 6.2

import PackageDescription

let package = Package(
	name: "DeveloperOverlay",
	platforms: [
		.macOS(.v15),
	],
	products: [
		.library(name: "DeveloperOverlay", targets: ["DeveloperOverlay"]),
	],
	targets: [
		.target(
			name: "DeveloperOverlay"
		),
		.testTarget(
			name: "DeveloperOverlayTests",
			dependencies: ["DeveloperOverlay"]
		),
	]
)
