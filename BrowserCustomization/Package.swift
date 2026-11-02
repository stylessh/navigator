// swift-tools-version: 6.2

import PackageDescription

let package = Package(
	name: "BrowserCustomization",
	platforms: [
		.macOS(.v15),
	],
	products: [
		.library(name: "BrowserCustomization", targets: ["BrowserCustomization"]),
		.library(name: "BrowserCustomizationUI", targets: ["BrowserCustomizationUI"]),
	],
	targets: [
		.target(
			name: "BrowserCustomization",
			resources: [
				.copy("Resources/boost-runtime.js"),
			]
		),
		.target(
			name: "BrowserCustomizationUI",
			dependencies: ["BrowserCustomization"]
		),
		.testTarget(
			name: "BrowserCustomizationTests",
			dependencies: ["BrowserCustomization"]
		),
	]
)
