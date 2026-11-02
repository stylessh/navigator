#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>

#include "CEFBridge.h"

// Thumbnails for the spatial tab overview.
//
// Strategy 1: Chromium in the browser process often presents frames as IOSurface-backed
// CALayer contents. If we find one under the view, read it directly (exact page pixels,
// no WindowServer round trip, unaffected by overlays like the floating toolbar).
//
// Strategy 2: capture the whole window from the WindowServer and crop to the view.
// Cropping in window space avoids the Cocoa (bottom-left) vs CoreGraphics (top-left)
// screen coordinate mismatch that a screen-rect capture is prone to.

static IOSurfaceRef findLargestIOSurface(CALayer* layer, CGFloat* bestArea, int depth) {
  if (layer == nil || depth > 24) {
    return nullptr;
  }
  IOSurfaceRef best = nullptr;
  id contents = layer.contents;
  if (contents != nil && CFGetTypeID((__bridge CFTypeRef)contents) == IOSurfaceGetTypeID()) {
    IOSurfaceRef surface = (__bridge IOSurfaceRef)contents;
    const CGFloat area = (CGFloat)IOSurfaceGetWidth(surface) * (CGFloat)IOSurfaceGetHeight(surface);
    if (area > *bestArea) {
      *bestArea = area;
      best = surface;
    }
  }
  for (CALayer* sublayer in layer.sublayers) {
    IOSurfaceRef candidate = findLargestIOSurface(sublayer, bestArea, depth + 1);
    if (candidate != nullptr) {
      best = candidate;
    }
  }
  return best;
}

static CGImageRef copyImageFromLayerSurfaces(NSView* view) {
  if (view.layer == nil) {
    return nullptr;
  }
  CGFloat bestArea = 0;
  IOSurfaceRef surface = findLargestIOSurface(view.layer, &bestArea, 0);
  if (surface == nullptr) {
    return nullptr;
  }
  // Ignore tiny surfaces (spinners, scrollbars); we want the page.
  const CGFloat viewPixels = NSWidth(view.bounds) * NSHeight(view.bounds);
  if (bestArea < viewPixels * 0.25) {
    return nullptr;
  }
  CIImage* image = [CIImage imageWithIOSurface:surface];
  if (image == nil) {
    return nullptr;
  }
  static CIContext* context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO}];
  return [context createCGImage:image fromRect:image.extent];
}

static CGImageRef copyImageFromWindowCapture(NSView* view) {
  NSWindow* window = view.window;
  if (window == nil || window.windowNumber <= 0 || [view isHiddenOrHasHiddenAncestor]) {
    return nullptr;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CGImageRef windowImage = CGWindowListCreateImage(
    CGRectNull,
    kCGWindowListOptionIncludingWindow,
    static_cast<CGWindowID>(window.windowNumber),
    kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
  );
#pragma clang diagnostic pop
  if (windowImage == nullptr) {
    return nullptr;
  }

  NSView* contentView = window.contentView;
  const NSRect windowBounds = contentView != nil ? [contentView convertRect:contentView.bounds toView:nil] : NSMakeRect(0, 0, NSWidth(window.frame), NSHeight(window.frame));
  const NSRect viewInWindow = [view convertRect:view.bounds toView:nil];
  const CGFloat scaleX = (CGFloat)CGImageGetWidth(windowImage) / MAX(NSWidth(windowBounds), 1);
  const CGFloat scaleY = (CGFloat)CGImageGetHeight(windowImage) / MAX(NSHeight(windowBounds), 1);
  // Window coordinates are bottom-left; image rows start at the top.
  const CGRect crop = CGRectIntegral(CGRectMake(
    (NSMinX(viewInWindow) - NSMinX(windowBounds)) * scaleX,
    (NSMaxY(windowBounds) - NSMaxY(viewInWindow)) * scaleY,
    NSWidth(viewInWindow) * scaleX,
    NSHeight(viewInWindow) * scaleY
  ));
  CGImageRef cropped = CGImageCreateWithImageInRect(windowImage, crop);
  CGImageRelease(windowImage);
  return cropped;
}

void* CEFBridge_CopyViewSnapshotImage(void* view) {
  if (view == nullptr || ![NSThread isMainThread]) {
    return nullptr;
  }
  NSView* hostView = (__bridge NSView*)view;
  if (NSWidth(hostView.bounds) <= 0.0 || NSHeight(hostView.bounds) <= 0.0) {
    return nullptr;
  }
  const char* source = "iosurface";
  CGImageRef image = copyImageFromLayerSurfaces(hostView);
  if (image == nullptr) {
    source = "window";
    image = copyImageFromWindowCapture(hostView);
  }
#if DEBUG
  NSLog(@"[Navigator][Spatial] snapshot source=%s size=%zux%zu view=%.0fx%.0f",
        image != nullptr ? source : "none",
        image != nullptr ? CGImageGetWidth(image) : 0,
        image != nullptr ? CGImageGetHeight(image) : 0,
        NSWidth(hostView.bounds), NSHeight(hostView.bounds));
#endif
  return (void*)image;
}
