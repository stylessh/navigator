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

// MARK: - DevTools page capture
//
// Window captures from inside the app can't see Chromium's GPU-process layers without
// Screen Recording permission, so page pixels come from Chromium itself via the
// DevTools protocol (`Page.captureScreenshot`). This needs no permission and is not
// affected by native overlays drawn above the page.

#include <atomic>
#include <cstring>
#include <string>

#include "CefRef.h"
#include "MiumCEFBridgeBrowserRegistry.h"
#include "MiumCEFBridgeInternalAdapters.h"
#include "MiumCEFBridgeInternalRuntimeExecutionSupport.h"
#include "MiumCEFBridgeInternalState.h"

namespace {

struct MiumDevToolsCaptureState {
  cef_dev_tools_message_observer_t observer;
  std::atomic<int> refCount{1};
  int messageId = 0;
  bool finished = false;
  cef_registration_t* registration = nullptr;
  CEFBridgeSnapshotCallback callback = nullptr;
  void* userData = nullptr;
};

MiumDevToolsCaptureState* captureStateFromBase(cef_base_ref_counted_t* base) {
  return reinterpret_cast<MiumDevToolsCaptureState*>(base);
}

void CEF_CALLBACK captureAddRef(cef_base_ref_counted_t* base) {
  captureStateFromBase(base)->refCount.fetch_add(1, std::memory_order_relaxed);
}

int CEF_CALLBACK captureRelease(cef_base_ref_counted_t* base) {
  auto* state = captureStateFromBase(base);
  if (state->refCount.fetch_sub(1, std::memory_order_acq_rel) - 1 <= 0) {
    delete state;
    return 1;
  }
  return 0;
}

int CEF_CALLBACK captureHasOneRef(cef_base_ref_counted_t* base) {
  return captureStateFromBase(base)->refCount.load(std::memory_order_relaxed) == 1 ? 1 : 0;
}

int CEF_CALLBACK captureHasAtLeastOneRef(cef_base_ref_counted_t* base) {
  return captureStateFromBase(base)->refCount.load(std::memory_order_relaxed) > 0 ? 1 : 0;
}

CGImageRef copyImageFromDevToolsResult(const void* result, size_t resultSize) {
  if (result == nullptr || resultSize == 0) {
    return nullptr;
  }
  NSData* json = [NSData dataWithBytes:result length:resultSize];
  id object = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
  if (![object isKindOfClass:[NSDictionary class]]) {
    return nullptr;
  }
  id base64 = ((NSDictionary*)object)[@"data"];
  if (![base64 isKindOfClass:[NSString class]]) {
    return nullptr;
  }
  NSData* imageData = [[NSData alloc] initWithBase64EncodedString:(NSString*)base64 options:0];
  if (imageData == nil) {
    return nullptr;
  }
  NSBitmapImageRep* rep = [NSBitmapImageRep imageRepWithData:imageData];
  CGImageRef image = rep.CGImage;
  if (image != nullptr) {
    CGImageRetain(image);
  }
  return image;
}

// Main/UI thread only.
void finishCapture(MiumDevToolsCaptureState* state, CGImageRef image) {
  if (state->finished) {
    if (image != nullptr) {
      CGImageRelease(image);
    }
    return;
  }
  state->finished = true;
  if (state->callback != nullptr) {
    state->callback(state->userData, (void*)image);
  }
  else if (image != nullptr) {
    CGImageRelease(image);
  }
  state->callback = nullptr;
  cef_registration_t* registration = state->registration;
  state->registration = nullptr;
  if (registration != nullptr) {
    // Releasing the registration unregisters the observer (CEF drops its observer ref).
    releaseOwnedCefValue(registration);
  }
}

int CEF_CALLBACK captureOnMessage(cef_dev_tools_message_observer_t*, cef_browser_t*, const void*, size_t) {
  return 0;
}

void CEF_CALLBACK captureOnMethodResult(
  cef_dev_tools_message_observer_t* self,
  cef_browser_t*,
  int messageId,
  int success,
  const void* result,
  size_t resultSize
) {
  auto* state = reinterpret_cast<MiumDevToolsCaptureState*>(self);
  if (messageId != state->messageId) {
    return;
  }
  CGImageRef image = success ? copyImageFromDevToolsResult(result, resultSize) : nullptr;
  captureAddRef(&state->observer.base);
  dispatch_async(dispatch_get_main_queue(), ^{
    finishCapture(state, image);
    captureRelease(&state->observer.base);
  });
}

void CEF_CALLBACK captureOnEvent(cef_dev_tools_message_observer_t*, cef_browser_t*, const cef_string_t*, const void*, size_t) {}
void CEF_CALLBACK captureOnAgentAttached(cef_dev_tools_message_observer_t*, cef_browser_t*) {}
void CEF_CALLBACK captureOnAgentDetached(cef_dev_tools_message_observer_t*, cef_browser_t*) {}

std::atomic<int> gNextCaptureMessageId{900000};

}  // namespace

int CEFBridge_CapturePageSnapshot(
  CEFBridgeBrowserRef browser_ref,
  double timeout_seconds,
  CEFBridgeSnapshotCallback callback,
  void* user_data
) {
  if (browser_ref == nullptr || callback == nullptr || ![NSThread isMainThread]) {
    return 0;
  }
  const uint64_t browserId = miumCEFNativeHandleToId(browser_ref);
  cef_browser_t* nativeBrowser = nullptr;
  {
    CefStateLockGuard lock;
    auto* browserState = activeBrowserStateLocked(browserId);
    if (browserState == nullptr || !miumCEFIsCefRuntimeUsableLocked()) {
      return 0;
    }
    nativeBrowser = retainCefBorrowed(browserState->nativeBrowser.get());
  }
  if (nativeBrowser == nullptr) {
    return 0;
  }

  auto* state = new MiumDevToolsCaptureState();
  std::memset(&state->observer, 0, sizeof(state->observer));
  state->observer.base.size = sizeof(cef_dev_tools_message_observer_t);
  state->observer.base.add_ref = captureAddRef;
  state->observer.base.release = captureRelease;
  state->observer.base.has_one_ref = captureHasOneRef;
  state->observer.base.has_at_least_one_ref = captureHasAtLeastOneRef;
  state->observer.on_dev_tools_message = captureOnMessage;
  state->observer.on_dev_tools_method_result = captureOnMethodResult;
  state->observer.on_dev_tools_event = captureOnEvent;
  state->observer.on_dev_tools_agent_attached = captureOnAgentAttached;
  state->observer.on_dev_tools_agent_detached = captureOnAgentDetached;
  state->messageId = gNextCaptureMessageId.fetch_add(1);
  state->callback = callback;
  state->userData = user_data;

  bool sent = false;
  miumCEFNativeRunOnCefMainThread([&] {
    {
      CefStateLockGuard lock;
      if (!miumCEFIsCefRuntimeUsableLocked()) {
        return;
      }
    }
    if (nativeBrowser->get_host == nullptr) {
      return;
    }
    cef_browser_host_t* host = nativeBrowser->get_host(nativeBrowser);
    if (host == nullptr) {
      return;
    }
    if (host->add_dev_tools_message_observer != nullptr && host->send_dev_tools_message != nullptr) {
      state->registration = host->add_dev_tools_message_observer(host, &state->observer);
      const std::string message =
        "{\"id\":" + std::to_string(state->messageId) +
        ",\"method\":\"Page.captureScreenshot\",\"params\":{\"format\":\"jpeg\",\"quality\":72,\"optimizeForSpeed\":true}}";
      sent = host->send_dev_tools_message(host, message.data(), message.size()) != 0;
    }
    releaseOwnedCefValue(host);
  });
  miumCEFNativeReleaseBrowserOnCefMainThread(nativeBrowser);

  if (!sent) {
    state->callback = nullptr;  // Caller falls back synchronously; never call back.
    finishCapture(state, nullptr);
    captureRelease(&state->observer.base);
    return 0;
  }

  // Hidden or throttled pages may never produce a frame; give up after the timeout.
  const double timeout = timeout_seconds > 0 ? timeout_seconds : 1.5;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    finishCapture(state, nullptr);
    captureRelease(&state->observer.base);
  });
  return 1;
}
