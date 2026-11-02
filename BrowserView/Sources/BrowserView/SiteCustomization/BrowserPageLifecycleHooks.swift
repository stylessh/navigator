import BrowserRuntime
import ModelKit

/// Closures BrowserChromeView calls as pages move through their lifecycle.
/// Kept as a tiny value type so layered features don't need to subclass or edit the chrome view.
@MainActor
struct BrowserPageLifecycleHooks {
	/// Main frame committed a new URL (fires for same-document navigations too).
	var didCommit: ((BrowserTabID, CEFBridgeBrowserRef, String) -> Void)?
	/// Navigation state was re-read; `isLoading` false after true means the load finished.
	var didSyncLoadingState: ((BrowserTabID, CEFBridgeBrowserRef, Bool) -> Void)?
}
