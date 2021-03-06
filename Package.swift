// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "BarcodeScanner",
	platforms: [
		.iOS("10.0")
	],
	products: [
		// Products define the executables and libraries produced by a package, and make them visible to other packages.
		.library(
			name: "BarcodeScanner",
			targets: ["BarcodeScanner"]),
	],
	dependencies: [],
	targets: [
		.target(
			name: "BarcodeScanner",
			dependencies: [],
			path: "Sources"),
	]
)
