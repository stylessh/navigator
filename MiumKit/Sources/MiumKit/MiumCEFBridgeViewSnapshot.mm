#import <AppKit/AppKit.h>

#include "CEFBridge.h"
#include "MiumCEFBridgeHostView.h"

// Captures what an on-screen view currently shows, including GPU-composited
// Chromium content that `cacheDisplayInRect:` cannot see. Used by the tab
// overview to grab page thumbnails. Returns a +1 CGImageRef (caller releases)
// or NULL when the view is hidden or off-screen.
void* CEFBridge_CopyViewSnapshotImage(void* view) {
  if (view == nullptr) {
    return nullptr;
  }
  if (![NSThread isMainThread]) {
    return nullptr;
  }
  NSView* hostView = (__bridge NSView*)view;
  const NSRect bounds = hostView.bounds;
  if (NSWidth(bounds) <= 0.0 || NSHeight(bounds) <= 0.0) {
    return nullptr;
  }

  NSBitmapImageRep* bitmap = snapshotBitmapRepForHostViewFromWindow(hostView, bounds);
  if (bitmap == nil) {
    bitmap = [hostView bitmapImageRepForCachingDisplayInRect:bounds];
    if (bitmap == nil) {
      return nullptr;
    }
    [hostView cacheDisplayInRect:bounds toBitmapImageRep:bitmap];
  }

  CGImageRef image = bitmap.CGImage;
  if (image == nullptr) {
    return nullptr;
  }
  CGImageRetain(image);
  return (void*)image;
}
