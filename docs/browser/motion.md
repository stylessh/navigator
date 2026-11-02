# Motion tokens

Every animated surface in Navigator (floating toolbar, command bar, link peek, link hints,
tab overview and splits, site tint, developer overlay, site boosts) uses the same small set of
springs. Each module keeps its own enum because the packages don't share a dependency, but the
numbers are the same everywhere. Change a value here and in every enum together.

| Token  | Response | Damping | Use it for |
|--------|---------:|--------:|------------|
| morph  | 0.40 s   | 0.82    | Shapes changing: toolbar expand/collapse, panels and shelves appearing, the overview zoom |
| reflow | 0.32 s   | 0.90    | Layout following content: result lists, log rows, grid reflow, tab chips added or removed |
| snappy | 0.24 s   | 0.86    | Small feedback: hover, selection, highlight sliding between rows |
| press  | 0.18 s   | 0.64    | Button press-down |
| exit   | 0.22–0.26 s | 1.0  | Dismissals. Faster than the entrance and never bounces |
| tint   | 0.55 s   | 1.0     | Colors (site tint, page theme). Critically damped so hues never overshoot |

Response and damping are SwiftUI's `.spring(response:dampingFraction:)`. For Core Animation,
mass 1, stiffness `(2π / response)²`, damping `4π · damping / response`.

| Module | Where |
|--------|-------|
| Floating toolbar | `FloatingMotion` in `Navigator/FloatingToolbar/FloatingGlass.swift` |
| Command bar | `CommandBarMotion` in `BrowserActionBar/.../CommandBarGlass.swift` |
| Site boosts panel | `Animation.navigator*` in `BrowserCustomizationUI/Glass.swift` |
| Developer overlay | `DeveloperMotion` in `DeveloperGlass.swift`, `DeveloperSpring` for AppKit |
| Tab overview, splits | `SpatialMotion` in `BrowserView/.../Spatial/SpatialMotion.swift` |
| Link peek | `BrowserLinkPeekController.Spring` |
| Site tint | `BrowserSiteTintStyle` |

## Rules that keep it smooth

- **Never resize an NSHostingView mid-animation.** Host SwiftUI chrome in a fixed canvas and
  let the content spring inside it; use `hitTest` to pass clicks outside the glass through.
  An intrinsic-size host jumps to the final size in one frame while SwiftUI is still springing.
- **One curve per change.** Scope slow animations (tint, theme color) to their own transaction
  with `onChange` + `withAnimation`; a root `.animation(_:value:)` animates everything else
  that changed in the same update with that curve too.
- **No blur, shadow or scale transition on glass.** Blur and SwiftUI shadows render glass
  offscreen every frame. On macOS 26 insert and remove glass with
  `glassEffectTransition(.matchedGeometry)` and a fade; a scale transition fights the morph.
- **Give layer shadows a `shadowPath`.** Otherwise Core Animation derives the shadow from
  every sublayer's alpha, offscreen, on every frame.
- **Drive main-thread springs from a display link**, not a `Timer`.
- **Keep heavy work off the main thread during a transition** (image downscaling, parsing).
- **Don't animate typing.** Text edits update without animation; discrete changes animate.
