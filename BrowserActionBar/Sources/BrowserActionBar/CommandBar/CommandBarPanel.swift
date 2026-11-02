import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Spotlight-style command bar: a borderless child window hosting a Liquid Glass card.
///
/// Drives the same `BrowserActionBarViewModel` as the classic `BrowserActionBarView`, with
/// `isCommandBarEnabled` turned on. The window is a fixed, transparent canvas; the card inside
/// it grows and shrinks with springs, so the window never has to animate its frame.
@MainActor
public final class CommandBarPanel: NSPanel, NSTextFieldDelegate {
	/// Screen-space rect to rise out of (the toolbar's address pill). When nil or empty the bar
	/// drops from the top of the window instead.
	public var presentationAnchor: (() -> NSRect?)?
	public var updateAnchorWindow: (() -> NSWindow?)?

	private let viewModel: BrowserActionBarViewModel
	private let chrome = CommandBarChromeState()
	private let queryField = CommandBarTextField()
	private weak var lastParentWindow: NSWindow?
	private var isPanelVisible = false
	private var isSynchronizingFromViewModel = false
	private var lastAppliedPresentationSeed: UUID?
	private var lastAppliedReplacementSeed: UUID?

	public init(viewModel: BrowserActionBarViewModel) {
		self.viewModel = viewModel
		super.init(
			contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
			styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		configureWindow()
		configureField()

		let rootView = CommandBarRootView(model: viewModel, chrome: chrome, field: queryField)
		let hostingView = NSHostingView(rootView: rootView)
		hostingView.sizingOptions = []
		hostingView.wantsLayer = true
		hostingView.layer?.backgroundColor = NSColor.clear.cgColor
		contentView = hostingView

		viewModel.onCopy = { value in
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(value, forType: .string)
		}
		viewModel.onStateChange = { [weak self] in
			self?.syncWithViewModelState()
		}
		orderOut(nil)
		syncWithViewModelState()
	}

	override public var canBecomeKey: Bool { true }
	override public var canBecomeMain: Bool { false }

	// MARK: Attachment (same surface as BrowserActionBarView)

	public func attach(to window: NSWindow?) {
		guard let parentWindow = resolvedParentWindow(explicitWindow: window) else { return }
		lastParentWindow = parentWindow
		if viewModel.isPresented {
			showPanel()
		}
	}

	public func removeFromWindow() {
		hidePanel()
		lastParentWindow = nil
	}

	public func repositionForCurrentWindow(window: NSWindow?) {
		guard isPanelVisible, let parentWindow = resolvedParentWindow(explicitWindow: window) else { return }
		layoutPanel(in: parentWindow)
	}

	// MARK: Window setup

	private func configureWindow() {
		isOpaque = false
		hasShadow = false // the card draws its own shadow
		backgroundColor = .clear
		level = .floating
		hidesOnDeactivate = false
		isMovableByWindowBackground = false
		animationBehavior = .none
		isReleasedWhenClosed = false
		becomesKeyOnlyIfNeeded = false
		isFloatingPanel = true
		collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
	}

	private func configureField() {
		queryField.delegate = self
		queryField.isEditable = true
		queryField.isSelectable = true
		queryField.isBordered = false
		queryField.isBezeled = false
		queryField.drawsBackground = false
		queryField.backgroundColor = .clear
		queryField.focusRingType = .none
		queryField.isAutomaticTextCompletionEnabled = false
		queryField.lineBreakMode = .byTruncatingHead
		queryField.usesSingleLineMode = true
		queryField.cell?.wraps = false
		queryField.cell?.isScrollable = true
		queryField.font = .systemFont(ofSize: 19, weight: .regular)
		queryField.textColor = .labelColor
		queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
		queryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
	}

	// MARK: Geometry

	private func resolvedParentWindow(explicitWindow: NSWindow?) -> NSWindow? {
		explicitWindow ?? lastParentWindow ?? updateAnchorWindow?()
	}

	private func layoutPanel(in parentWindow: NSWindow) {
		let parentFrame = parentWindow.frame
		let padding = CommandBarLayout.outerPadding
		let cardWidth = min(max(parentFrame.width * 0.56, 460), 720, parentFrame.width - 48)
		let anchor = presentationAnchor?().flatMap { $0.isEmpty ? nil : $0 }

		let placement: CommandBarPlacement = anchor == nil ? .top : .bottom
		let topInset: CGFloat = 96
		let available: CGFloat = switch placement {
		case .top:
			parentFrame.height - topInset - 24
		case .bottom:
			parentFrame.maxY - (anchor?.minY ?? parentFrame.minY) - 56
		}
		let maxResults = max(0, min(CommandBarLayout.maxResultsHeight, available - CommandBarLayout.fieldHeight))
		let height = CommandBarLayout.fieldHeight + maxResults + 1 + padding * 2
		let width = cardWidth + padding * 2

		var originX = (anchor?.midX ?? parentFrame.midX) - width / 2
		originX = min(max(originX, parentFrame.minX), parentFrame.maxX - width)
		let originY: CGFloat = switch placement {
		case .top:
			parentFrame.maxY - topInset + padding - height
		case .bottom:
			// Card's bottom edge sits on the pill's bottom edge, so it reads as the pill expanding.
			(anchor?.minY ?? parentFrame.minY) - padding
		}

		chrome.placement = placement
		chrome.cardWidth = cardWidth
		chrome.maxResultsHeight = maxResults

		let nextFrame = NSRect(x: originX, y: originY, width: width, height: height).integral
		if !frame.equalTo(nextFrame) {
			setFrame(nextFrame, display: true)
		}
	}

	// MARK: View-model sync

	private func syncWithViewModelState() {
		queryField.placeholderString = viewModel.placeholder

		let presentationChanged = lastAppliedPresentationSeed != viewModel.presentationSeed
		let replacementChanged = lastAppliedReplacementSeed != viewModel.queryReplacementSeed
		lastAppliedPresentationSeed = viewModel.presentationSeed
		lastAppliedReplacementSeed = viewModel.queryReplacementSeed

		if presentationChanged || replacementChanged || queryField.currentEditor() == nil {
			setFieldText(viewModel.query)
		}

		if viewModel.isPresented {
			showPanel()
			if presentationChanged {
				queryField.currentEditor()?.selectAll(nil)
			}
		}
		else {
			hidePanel()
		}
	}

	private func setFieldText(_ text: String) {
		guard currentQueryText() != text else { return }
		isSynchronizingFromViewModel = true
		queryField.stringValue = text
		if let editor = queryField.currentEditor() {
			editor.string = text
			editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
		}
		isSynchronizingFromViewModel = false
	}

	private func currentQueryText() -> String {
		queryField.currentEditor()?.string ?? queryField.stringValue
	}

	// MARK: Show / hide

	private func showPanel() {
		guard let parentWindow = resolvedParentWindow(explicitWindow: nil) else { return }
		if parentWindow.childWindows?.contains(where: { $0 === self }) != true {
			parentWindow.addChildWindow(self, ordered: .above)
		}
		lastParentWindow = parentWindow
		layoutPanel(in: parentWindow)

		let wasVisible = isPanelVisible
		isPanelVisible = true
		makeKeyAndOrderFront(nil)

		if !wasVisible || queryField.currentEditor() == nil {
			makeFirstResponder(queryField)
			setFieldText(viewModel.query)
			queryField.currentEditor()?.selectAll(nil)
		}

		guard !wasVisible else { return }
		chrome.isShown = false
		// Next runloop turn, so SwiftUI has a frame at the hidden state to spring from.
		DispatchQueue.main.async { [weak self] in
			guard let self, self.isPanelVisible else { return }
			self.chrome.isShown = true
		}
	}

	private func hidePanel() {
		guard isPanelVisible else { return }
		isPanelVisible = false
		chrome.isShown = false

		let parentWindow = lastParentWindow
		let wasKey = isKeyWindow
		parentWindow?.removeChildWindow(self)
		orderOut(nil)
		if let parentWindow, parentWindow.isVisible, wasKey {
			parentWindow.makeKey()
		}
	}

	override public func resignKey() {
		super.resignKey()
		// Clicking anywhere else (the page, the toolbar, another app) closes the bar.
		if isPanelVisible, viewModel.isPresented {
			viewModel.dismiss()
		}
	}

	// MARK: Keys

	override public func performKeyEquivalent(with event: NSEvent) -> Bool {
		let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		let isReturn = event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
		if isReturn, modifiers.contains(.command) {
			if !viewModel.activateHighlighted(forceNewTab: true) {
				viewModel.performPrimaryAction(with: currentQueryText())
			}
			return true
		}

		if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "k" {
			viewModel.dismiss()
			return true
		}

		let normalizedCharacter = event.charactersIgnoringModifiers?.lowercased()
		if BrowserActionBarShortcutForwardingResolver.shouldForwardToMainMenu(
			modifiers: event.modifierFlags,
			normalizedCharacter: normalizedCharacter,
			rawCharacter: event.characters?.lowercased()
		), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
			return true
		}
		return super.performKeyEquivalent(with: event)
	}

	public func controlTextDidChange(_ notification: Notification) {
		guard notification.object as? NSTextField === queryField, !isSynchronizingFromViewModel else { return }
		viewModel.updateQuery(currentQueryText())
	}

	public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
		switch commandSelector {
		case #selector(NSResponder.moveDown(_:)):
			viewModel.moveHighlight(by: 1)
			return true
		case #selector(NSResponder.moveUp(_:)):
			viewModel.moveHighlight(by: -1)
			return true
		case #selector(NSResponder.moveToEndOfDocument(_:)):
			viewModel.moveHighlightToSection(by: 1)
			return true
		case #selector(NSResponder.moveToBeginningOfDocument(_:)):
			viewModel.moveHighlightToSection(by: -1)
			return true
		// ⌥↓ / ⌥↑ send moveForward:/moveBackward: followed by a paragraph move. ⌃F/⌃B send the
		// same first selector, so only treat them as section jumps when Option is held.
		case #selector(NSResponder.moveForward(_:)) where isOptionHeld:
			viewModel.moveHighlightToSection(by: 1)
			return true
		case #selector(NSResponder.moveBackward(_:)) where isOptionHeld:
			viewModel.moveHighlightToSection(by: -1)
			return true
		case #selector(NSResponder.moveToEndOfParagraph(_:)) where isOptionHeld,
		     #selector(NSResponder.moveToBeginningOfParagraph(_:)) where isOptionHeld:
			return true
		case #selector(NSResponder.insertTab(_:)):
			// Always swallow Tab so focus never leaves the field.
			viewModel.acceptCompletion()
			return true
		case #selector(NSResponder.insertBacktab(_:)):
			return true
		case #selector(NSResponder.deleteBackward(_:)):
			return textView.selectedRange().location == 0 && textView.selectedRange().length == 0
				? viewModel.popScope()
				: false
		case #selector(NSResponder.insertNewline(_:)),
		     #selector(NSResponder.insertLineBreak(_:)),
		     #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
			let forceNewTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
			if !viewModel.activateHighlighted(forceNewTab: forceNewTab) {
				viewModel.performPrimaryAction(with: currentQueryText())
			}
			return true
		case #selector(NSResponder.cancelOperation(_:)):
			// Esc steps out of a scope first, then closes.
			if !viewModel.query.isEmpty, viewModel.scope != .all || viewModel.siteSearch != nil {
				viewModel.updateQuery("")
				setFieldText("")
			}
			else if !viewModel.popScope() {
				viewModel.dismiss()
			}
			return true
		default:
			return false
		}
	}
}

@MainActor
private var isOptionHeld: Bool {
	NSApp.currentEvent?.modifierFlags.contains(.option) == true
}

private final class CommandBarTextField: NSTextField {
	override var acceptsFirstResponder: Bool { true }
}
