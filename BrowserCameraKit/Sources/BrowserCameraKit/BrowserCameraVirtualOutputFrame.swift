import CoreVideo
import Foundation

enum BrowserCameraVirtualPublisherPixelFormat: Sendable {
	case bgra
}

struct BrowserCameraVirtualOutputFrame: @unchecked Sendable {
	let data: Data?
	let pixelBuffer: CVPixelBuffer?
	let payloadByteCount: Int
	let width: Int
	let height: Int
	let bytesPerRow: Int
	let pixelFormat: BrowserCameraVirtualPublisherPixelFormat
	let timestampHostTime: UInt64
	let durationHostTime: UInt64

	init(
		data: Data,
		width: Int,
		height: Int,
		bytesPerRow: Int,
		pixelFormat: BrowserCameraVirtualPublisherPixelFormat,
		timestampHostTime: UInt64,
		durationHostTime: UInt64
	) {
		self.data = data
		self.pixelBuffer = nil
		self.payloadByteCount = data.count
		self.width = width
		self.height = height
		self.bytesPerRow = bytesPerRow
		self.pixelFormat = pixelFormat
		self.timestampHostTime = timestampHostTime
		self.durationHostTime = durationHostTime
	}

	init(
		pixelBuffer: CVPixelBuffer,
		payloadByteCount: Int,
		width: Int,
		height: Int,
		bytesPerRow: Int,
		pixelFormat: BrowserCameraVirtualPublisherPixelFormat,
		timestampHostTime: UInt64,
		durationHostTime: UInt64
	) {
		self.data = nil
		self.pixelBuffer = pixelBuffer
		self.payloadByteCount = payloadByteCount
		self.width = width
		self.height = height
		self.bytesPerRow = bytesPerRow
		self.pixelFormat = pixelFormat
		self.timestampHostTime = timestampHostTime
		self.durationHostTime = durationHostTime
	}
}
