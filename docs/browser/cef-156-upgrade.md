# CEF 145 → 156 upgrade

Moves the engine from CEF branch 7632 (Chromium 145.0.7632.117, CEF commit
`4ddda2e`) to CEF branch 8078 (Chromium 156.0.8078.80, CEF commit `cf671c0`,
the newest release branch as of 2026-10-30).

## What changed in this repo

- New build specs `Vendor/CEF/BuildSpecs/cef_156_codec_arm64{,_fast,_max}.json`.
  Same GN args as the 145 specs, with the CEF branch pinned explicitly to `8078`.
  The 145 specs are kept so a rollback is one scheme argument away.
- `CEFBuilder` and `CEFPackager` schemes point at the 156 spec and artifacts.
  The packager scheme's archive URLs now use `$(PROJECT_DIR)` instead of an
  absolute path from one developer's machine.

The binary runtime (`Vendor/CEF/Release`, `Vendor/CEF/Artifacts`) and the
generated headers in `Vendor/CEF/include` (`capi/`, `cef_version.h`,
`cef_api_hash.h` hashes, pack/command/color IDs) are produced by the build, so
they are refreshed by the steps below rather than hand-edited.

## API review (C++ headers, 4ddda2e..cf671c0)

25 header files changed, almost all additive. Nothing MiumKit calls was
removed or changed signature.

| Change | Impact on MiumKit |
| --- | --- |
| `CefRegisterExtension` / `cef_register_extension` removed (API 15400) | Not used. |
| `cef_version_info_t` gains `sandbox_compat_hash` and bootstrap installer fields | We only call `cef_version_info(int)`, not the struct. None. |
| `cef_settings_t` gains `use_views_default_popup`, `keychain_service_name`, `keychain_account_name` (macOS) | Struct is sized via `size`; zero-init keeps defaults. Keychain names are worth setting later so Chromium's "Safe Storage" item is branded Navigator. |
| `cef_browser_settings_t` gains `ax_viewport_collapse`; `SetAxViewportCollapse` (experimental) | None. |
| New `CEF_WOD_NEW_SPLIT_VIEW` disposition | `MiumCEFBridgePopup.mm` only matches foreground/background tab, so split-view opens fall through to the default popup path. Revisit if we want split view. |
| New permission types (`CEF_CPAIT_*`) and content settings | Unknown types fall through to the existing default handling. |
| `GetDownloadHandler` returning null now uses Chrome-style default download handling | Check downloads during smoke test. |
| New `CefComponentUpdater`, `CefV8BackingStore` | Optional new features. |

MiumKit compiles against `CEF_API_VERSION_EXPERIMENTAL` (no explicit
`CEF_API_VERSION` is defined), so headers and the framework must come from the
same build. The runtime ABI check in `MiumCEFBridgeRuntime.mm` already refuses
to start on a hash mismatch, which is the guard against a half-updated tree.

## Steps to finish on a Mac

1. Check toolchain: Chromium 156 needs a recent Xcode and macOS SDK. If GN
   complains about the SDK, update Xcode first.
2. Build CEF (several hours, ~100 GB disk):

   ```bash
   swift Tools/CEFBuilder/main.swift \
     --spec Vendor/CEF/BuildSpecs/cef_156_codec_arm64.json \
     --work-dir ~/Library/Caches/Navigator/CEFSource \
     --output-dir Vendor/CEF/Artifacts \
     --cache-dir ~/Library/Caches/Navigator/CEFBuilds \
     --verbose
   ```

   Use `cef_156_codec_arm64_fast.json` for a quicker local iteration build.
3. Run the `CEFPackager` scheme. It unpacks the new archives into
   `Vendor/CEF/Release` and `Vendor/CEF/include`.
4. Build and run the `Navigator` scheme, then `./scripts/verify_runtime.sh`
   on the app bundle.
5. Smoke test: tab spaces, popups/new tab links, permissions prompts (camera,
   mic, location), camera routing into a page, downloads, PiP, session restore.
6. Commit the refreshed `Vendor/CEF/include`, `Release` and `Artifacts`
   (LFS) to this branch, and remove the 145 artifacts once 156 is confirmed.
