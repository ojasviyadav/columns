// The tab sidebar: a window's tabs down its left side, with Reading settings at its foot. On a wide screen height is
// the scarce space, so the tabs take a little width instead of a bar above the text.
import AppKit

extension Notification.Name {
    static let sidebarChanged = Notification.Name("ColumnsSidebarChanged")  // shown, hidden, peeking, or its width
    static let tabsChanged = Notification.Name("ColumnsTabsChanged")        // a tab opened, closed, moved, renamed or chosen
}

// A window's sidebar: hidden, peeking (shown over the page while the pointer rests on the sidebar button or on the
// sidebar), or pinned (beside the page); and its width when shown: icons or names. Each window has its own; a new
// window starts as the last one was set.
@MainActor final class SidebarModel {
    enum State { case hidden, peeking, pinned }
    enum Width: String { case icons, names }
    static let iconsWidth: CGFloat = 104, namesWidth: CGFloat = 240
    private let d = UserDefaults.standard
    private(set) var state: State
    var width: Width { didSet { d.set(width.rawValue, forKey: "sidebarWidth"); changed() } }
    var points: CGFloat { width == .icons ? Self.iconsWidth : Self.namesWidth }
    init() {
        state = d.string(forKey: "sidebar") == "hidden" ? .hidden : .pinned
        width = Width(rawValue: d.string(forKey: "sidebarWidth") ?? "") ?? .names
    }
    func go(_ to: State) {
        guard to != state else { return }
        state = to
        if to != .peeking { d.set(to == .hidden ? "hidden" : "pinned", forKey: "sidebar") }
        changed()
    }
    // The sidebar button, or View > Show Sidebar: pinned in its last width, or hidden.
    func toggle() { go(state == .pinned ? .hidden : .pinned) }
    private func changed() { NotificationCenter.default.post(name: .sidebarChanged, object: self) }
    weak var shell: ReaderShell?

    // A peek lasts while the pointer is on the sidebar button or on the sidebar; a moment after it leaves both, the
    // sidebar hides again. A click on the button meanwhile pins it.
    private var watch: Timer?
    private var awaySince: Date?
    func peek() {
        guard state == .hidden else { return }
        go(.peeking)
        awaySince = nil
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }
    private func tick() {
        guard state == .peeking else { watch?.invalidate(); watch = nil; return }
        let p = NSEvent.mouseLocation
        // Reading settings open from this window keep it too.
        let inside = shell?.peekArea.contains(p) == true || shell?.host?.tabs.contains { $0.settingsOpen } == true
        if inside { awaySince = nil }
        else if let since = awaySince { if Date().timeIntervalSince(since) > 0.25 { go(.hidden) } }
        else { awaySince = Date() }
    }
}

// A window and its tabs. Each tab is a Reader with its own page (and its find bar and file banner); the window shows
// the chosen one beside the sidebar. Tabs move between windows (dragged, or by the Window menu); a window goes with
// its last tab.
@MainActor final class ReaderHost: NSObject, NSWindowDelegate, NSMenuItemValidation {
    static var all: [ReaderHost] = []
    // The window's delegate is in the menus' path, so a command for a document (Find, Print, Back, Settings, the
    // sidebar button…) reaches the tab that shows, and asks it whether it can be done.
    // AppKit asks these on the main thread only.
    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || MainActor.assumeIsolated { selected?.responds(to: aSelector) == true }
    }
    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if !super.responds(to: aSelector), let s = MainActor.assumeIsolated({ selected }), s.responds(to: aSelector) { return s }
        return super.forwardingTarget(for: aSelector)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { selected?.validateMenuItem(item) ?? false }
    let window: ReaderWindow
    private(set) var shell: ReaderShell!
    let sidebarModel = SidebarModel()
    private(set) var tabs: [Reader] = []
    private(set) weak var selected: Reader?
    static var key: ReaderHost? { all.first { $0.window.isKeyWindow } ?? all.first { $0.window.isMainWindow } }
    // The window a new tab joins: the one in front, if it can show one now.
    static var front: ReaderHost? {
        NSApp.orderedWindows.lazy.compactMap { w in all.first { $0.window === w } }.first { $0.window.isVisible && !$0.window.isMiniaturized }
    }

    init(alone: Bool) {
        window = ReaderWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.tabbingMode = .disallowed          // the tabs are in the sidebar, not macOS's tab bar
        window.titlebarAppearsTransparent = true  // the title bar takes the page's colour, so sepia is sepia to the top
        window.titleVisibility = .hidden          // the sidebar names the tabs; the page takes the full height beside it
        window.delegate = self
        shell = ReaderShell(host: self)
        sidebarModel.shell = shell
        window.contentView = shell
        let button = SidebarButton.make()
        window.addTitlebarAccessoryViewController(button)
        window.sidebarButton = button.view.subviews.first as? NSButton
        // The first window owns the saved frame; each further one opens at the same size, stepped down and right of the
        // front one (which stays where it is). A first window ever fills most of the screen, centred, so that Zoom (a
        // double-click on the title bar, the green button with ⌥) has a larger frame to go to and a smaller one to return to.
        let saved = UserDefaults.standard.object(forKey: "NSWindow Frame Reader") != nil
        if ReaderHost.all.isEmpty, window.setFrameAutosaveName("Reader") {
            if !saved, let area = NSScreen.main?.visibleFrame {
                let size = NSSize(width: (area.width * 0.85).rounded(), height: (area.height * 0.88).rounded())
                window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: false)
            }
        } else if let front = ReaderHost.front?.window {
            window.setFrame(window.constrainFrameRect(front.frame.offsetBy(dx: 24, dy: -24), to: front.screen), display: false)
        }
        #if CHECK_COPY  // the check copy only (CHECK_COPY=1 ./build.sh): open at COLUMNS_FRAME, e.g. on a display for checks
        if let frame = ProcessInfo.processInfo.environment["COLUMNS_FRAME"] { window.setFrame(NSRectFromString(frame), display: false) }
        #endif
        ReaderHost.all.append(self)
        applyTheme()
    }
    func applyTheme() {
        let theme = ReadingSettings.shared.theme
        window.appearance = theme.appearance
        window.backgroundColor = theme.page
        shell?.sidebar.updateLook()
    }
    // The window's title (for the Window menu, Mission Control and the Dock) is the tab that shows.
    func refreshTitle() {
        window.titleVisibility = sidebarModel.state == .pinned ? .hidden : .visible  // hidden sidebar: the strip names the file
        window.title = selected?.tabName.isEmpty == false ? selected!.tabName : selected?.title ?? "Columns"
        window.representedURL = selected.flatMap { $0.url == Reader.welcome ? nil : $0.url }
    }
    private func changed() { NotificationCenter.default.post(name: .tabsChanged, object: nil) }

    // A tab joins this window, after the one that shows (or at `index`), and shows.
    func insert(_ r: Reader, at index: Int? = nil) {
        r.host = self
        let after = selected.flatMap { s in tabs.firstIndex { $0 === s } }.map { $0 + 1 } ?? tabs.count
        tabs.insert(r, at: min(index ?? after, tabs.count))
        select(r)
        r.applyTheme()
    }
    func select(_ r: Reader) {
        guard tabs.contains(where: { $0 === r }) else { return }
        let same = selected === r
        if let old = selected, !same { old.focus = focusedView(in: old) }
        selected = r
        shell.show(r.pane)
        refreshTitle()
        if !same, window.isKeyWindow || !window.isVisible { restoreFocus(r) }
        changed()
        r.becameVisible()
    }
    // The tab leaves this window (to close, or for another); the window goes with its last tab.
    func release(_ r: Reader) {
        guard let i = tabs.firstIndex(where: { $0 === r }) else { return }
        tabs.remove(at: i)
        if tabs.isEmpty { window.close() }
        else if selected === r { select(tabs[min(i, tabs.count - 1)]) }
        else { changed() }
    }
    func close(_ r: Reader) { r.teardown(); release(r) }
    func step(_ by: Int) {
        guard tabs.count > 1, let s = selected, let i = tabs.firstIndex(where: { $0 === s }) else { return }
        select(tabs[(i + by + tabs.count) % tabs.count])
    }
    func move(_ r: Reader, to index: Int) {  // within this window
        guard let i = tabs.firstIndex(where: { $0 === r }) else { return }
        tabs.remove(at: i)
        tabs.insert(r, at: min(index > i ? index - 1 : index, tabs.count))
        changed()
    }
    // The tab gets a window of its own (at `point`, the top left in screen coordinates, when it is given).
    @discardableResult func detach(_ r: Reader, at point: NSPoint? = nil) -> ReaderHost {
        if tabs.count == 1 {
            if let point { window.setFrameTopLeftPoint(point) }
            return self
        }
        release(r)
        let h = ReaderHost(alone: false)
        h.window.setFrame(window.frame.offsetBy(dx: 30, dy: -30), display: false)
        if let point { h.window.setFrameTopLeftPoint(point) }
        h.insert(r)
        h.window.makeKeyAndOrderFront(nil)
        return h
    }
    // A tab from another window (or this one) lands here at `index`.
    func adopt(_ r: Reader, at index: Int) {
        if r.host === self { return move(r, to: index) }
        r.host.release(r)
        insert(r, at: index)
        window.makeKeyAndOrderFront(nil)
    }
    // Window > Merge All Windows: every tab into this window.
    static func mergeAll(into h: ReaderHost) {
        let reading = h.selected
        for other in all where other !== h { for r in other.tabs { h.adopt(r, at: h.tabs.count) } }
        if let s = reading ?? h.selected { h.select(s) }
    }
    // A tab to a place in the list (an index of the list as it ends up, not of the gap between two tabs).
    func place(_ r: Reader, at index: Int) {
        guard let i = tabs.firstIndex(where: { $0 === r }) else { return }
        tabs.remove(at: i)
        tabs.insert(r, at: max(0, min(index, tabs.count)))
        NotificationCenter.default.post(name: .tabsChanged, object: nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let s = selected { if focusedView(in: s) == nil { restoreFocus(s) }; s.becameVisible() }
        changed()
    }
    // The view in a tab that has the keyboard (a text field for its field editor), if one has.
    private func focusedView(in r: Reader) -> NSView? {
        var v = window.firstResponder as? NSView
        if let t = v as? NSTextView, t.isFieldEditor { v = t.delegate as? NSView }
        return v.flatMap { $0.isDescendant(of: r.pane) ? $0 : nil }
    }
    private func restoreFocus(_ r: Reader) {
        if let f = r.focus, f.window === window, f.isDescendant(of: r.pane) { window.makeFirstResponder(f) } else { window.makeFirstResponder(r.web) }
    }
    func windowWillClose(_ notification: Notification) {
        let closing = tabs
        Reader.rememberClosedWindow(closing, showing: selected)
        tabs = []
        closing.forEach { $0.teardown(remember: false) }
        ReaderHost.all.removeAll { $0 === self }
        changed()
    }
}

// One tab's page with its bars: a file's banner and the find bar sit above the page, under the title bar.
final class ReaderPane: NSView {
    var web: NSView? { didSet { oldValue?.removeFromSuperview(); if let web { addSubview(web, positioned: .below, relativeTo: nil) } } }
    var banner: NSView? { didSet { swap(oldValue, banner) } }
    var find: NSView? { didSet { swap(oldValue, find) } }
    var underTitleBar = false { didSet { if underTitleBar != oldValue { needsLayout = true } } }  // the pane's top runs under the title bar
    override var isFlipped: Bool { true }
    private func swap(_ old: NSView?, _ new: NSView?) {
        old?.removeFromSuperview()
        if let new { new.wantsLayer = true; addSubview(new) }
        applyTheme()
        needsLayout = true
    }
    func applyTheme() {
        let theme = ReadingSettings.shared.theme
        effectiveAppearance.performAsCurrentDrawingAppearance {
            [banner, find].compactMap { $0 }.forEach { $0.layer?.backgroundColor = theme.rail.cgColor }
        }
    }
    override func layout() {
        super.layout()
        let bars = [banner, find].compactMap { $0 }
        var y: CGFloat = bars.isEmpty || !underTitleBar ? 0 : ReaderShell.titleBar
        for bar in bars {
            let h = bar.frame.height > 0 ? bar.frame.height : 36
            bar.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
        }
        web?.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
    }
}

// The window's content: the sidebar on the left and the page beside it (pinned), or the page alone below the title
// bar with the sidebar over it for a peek (hidden and peeking).
final class ReaderShell: NSView {
    let sidebar: TabSidebar
    private(set) weak var host: ReaderHost?
    private var model: SidebarModel? { host?.sidebarModel }
    private(set) var page: ReaderPane?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var layoutWatch: NSKeyValueObservation?
    static let titleBar: CGFloat = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled]).height - 100

    init(host: ReaderHost) {
        self.host = host
        sidebar = TabSidebar(host: host)
        super.init(frame: .zero)
        addSubview(sidebar)
        observers.append(NotificationCenter.default.addObserver(forName: .sidebarChanged, object: host.sidebarModel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebarChanged() }
        })
    }
    required init?(coder: NSCoder) { nil }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    override var isFlipped: Bool { true }
    func show(_ p: ReaderPane) {  // the chosen tab's page
        guard p !== page else { return }
        page?.removeFromSuperview()
        page = p
        addSubview(p, positioned: .below, relativeTo: sidebar)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutWatch = window?.observe(\.contentLayoutRect) { [weak self] _, _ in MainActor.assumeIsolated { self?.needsLayout = true } }
    }
    // The title bar and the bars under it (find, a file's banner).
    var titleInset: CGFloat { window.map { max(ReaderShell.titleBar, bounds.height - $0.contentLayoutRect.height) } ?? ReaderShell.titleBar }
    // Where a peek stays open, in screen coordinates: the sidebar and the sidebar button.
    var peekArea: NSRect {
        guard let window, model?.state == .peeking else { return .zero }
        var r = window.convertToScreen(convert(sidebar.frame, to: nil))
        if let button = (window as? ReaderWindow)?.sidebarButton, button.window != nil {
            r = r.union(window.convertToScreen(button.convert(button.bounds, to: nil)))
        }
        return r.insetBy(dx: -4, dy: -4)
    }
    private func sidebarChanged() {
        let peek = model?.state == .peeking
        host?.refreshTitle()
        if peek && sidebar.isHidden {  // it slides in over the page
            layoutNow()
            let end = sidebar.frame
            sidebar.frame.origin.x = -end.width
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.18; c.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                sidebar.animator().frame = end
            }
        } else { layoutNow() }
        (window as? ReaderWindow)?.sidebarButton?.needsDisplay = true
    }
    private func layoutNow() { needsLayout = true; layoutSubtreeIfNeeded() }
    override func layout() {
        super.layout()
        guard let m = model else { return }
        let w = m.points, top = titleInset, bars = top - ReaderShell.titleBar
        sidebar.overlay = m.state == .peeking
        switch m.state {
        case .pinned:
            sidebar.isHidden = false
            sidebar.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
            page?.frame = NSRect(x: w, y: bars, width: bounds.width - w, height: bounds.height - bars)
            page?.underTitleBar = true
        case .hidden, .peeking:
            sidebar.isHidden = m.state == .hidden
            sidebar.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
            page?.frame = NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
            page?.underTitleBar = false
        }
        sidebar.topInset = top
    }
}

// The button beside the window's three dots: resting on it peeks at a hidden sidebar; a click pins or hides it.
final class SidebarButton: NSButton {
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area!)
    }
    override func mouseEntered(with event: NSEvent) { (window as? ReaderWindow)?.host?.sidebarModel.peek() }
    static func make() -> NSTitlebarAccessoryViewController {
        let b = SidebarButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")!, target: nil, action: #selector(Reader.toggleSidebar(_:)))
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "Show or hide the sidebar (⌃⌘S)"
        b.frame = NSRect(x: 6, y: 4, width: 22, height: 20)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: ReaderShell.titleBar))
        holder.addSubview(b)
        let vc = NSTitlebarAccessoryViewController()
        vc.layoutAttribute = .leading
        vc.view = holder
        return vc
    }
}

// The sidebar: the tabs of this window, + New Tab, and at the foot Reading settings and the width switch.
// Drag a tab along the list to reorder it, onto another window's sidebar to move it there, or out of every sidebar
// for a window of its own. A file dragged onto the sidebar opens as a tab.
final class TabSidebar: NSView, NSDraggingSource {
    weak var host: ReaderHost?
    var overlay = false { didSet { if overlay != oldValue { updateLook() } } }
    var topInset: CGFloat = 28 { didSet { if topInset != oldValue { needsLayout = true } } }
    private var rows: [TabRow] = []
    private let newTab = TabRow(kind: .action), settings = TabRow(kind: .action), widthSwitch = TabRow(kind: .action)
    private let insertion = NSView()
    private var shownHeight: CGFloat = -1
    private weak var revealed: Reader?
    private let list = NSScrollView(), listDoc = FlippedView()  // the tabs and New Tab; they scroll when they do not fit
    private var dropIndex: Int?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    static let tabType = NSPasteboard.PasteboardType("org.learningharness.columns.tab")
    var settingsAnchor: NSView { settings }

    init(host: ReaderHost) {
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        insertion.wantsLayer = true
        insertion.isHidden = true
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.scrollerStyle = .overlay
        list.contentView.drawsBackground = false
        list.documentView = listDoc
        addSubview(list)
        [newTab, insertion].forEach(listDoc.addSubview)
        [settings, widthSwitch].forEach(addSubview)
        newTab.onClick = { [weak self] in self?.host?.selected?.newWindowForTab(nil) }
        settings.onClick = { [weak self] in
            guard let h = self?.host else { return }
            if h.sidebarModel.state == .peeking { h.sidebarModel.go(.pinned) }  // settings from a peek: the sidebar stays
            h.selected?.showSettings(nil)
        }
        widthSwitch.onClick = { [weak self] in
            guard let m = self?.host?.sidebarModel else { return }
            m.width = m.width == .icons ? .names : .icons
        }
        registerForDraggedTypes([TabSidebar.tabType, .fileURL])
        for (name, object) in [(Notification.Name.tabsChanged, nil), (.sidebarChanged, host.sidebarModel as AnyObject?)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
        reload()
    }
    required init?(coder: NSCoder) { nil }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }  // its empty part moves the window, as a title bar does

    private var names: Bool { host?.sidebarModel.width != .icons }
    // The readers of this window's tabs, in their order.
    var tabs: [Reader] { host?.tabs ?? [] }
    func reload() {
        let list = tabs, selected = host?.selected
        while rows.count < list.count { let r = TabRow(kind: .tab); rows.append(r); listDoc.addSubview(r, positioned: .below, relativeTo: insertion) }
        while rows.count > list.count { rows.removeLast().removeFromSuperview() }
        for (row, (r, tile)) in zip(rows, zip(list, Reader.tiles(list))) {
            row.reader = r
            row.configure(title: r.title, folder: r.folder, monogram: tile, tip: r.tabTip, selected: r === selected, names: names, sidebar: self)
        }
        newTab.configureAction(symbol: "plus", title: "New Tab", shortcut: "⌘T", names: names, tip: "Open a file in a new tab (⌘T)")
        settings.configureAction(symbol: nil, title: "Reading settings", shortcut: "⌘,", names: names, tip: "Reading settings: columns, text size, theme and font (⌘,)")
        widthSwitch.configureAction(symbol: names ? "sidebar.squares.left" : "sidebar.left", title: names ? "Show icons only" : "Show tab names",
                                    shortcut: nil, names: names, tip: names ? "Show icons only (⌥⌃⌘S)" : "Show tab names (⌥⌃⌘S)")
        updateLook()
        needsLayout = true
        layoutSubtreeIfNeeded()
        if selected !== revealed, let i = tabs.firstIndex(where: { $0 === selected }), i < rows.count {  // a newly shown tab comes into view
            revealed = selected
            listDoc.scrollToVisible(rows[i].frame)
        }
    }
    func updateLook() {
        let theme = ReadingSettings.shared.theme
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = theme.rail.cgColor
            insertion.layer?.backgroundColor = theme.link.cgColor
        }
        layer?.shadowOpacity = overlay ? 0.28 : 0
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 4, height: 0)
        layer?.masksToBounds = false
        needsDisplay = true
        rows.forEach { $0.updateLook() }
        [newTab, settings, widthSwitch].forEach { $0.updateLook() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLook() }
    override func draw(_ dirtyRect: NSRect) {  // the hairline between the sidebar and the page
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ReadingSettings.shared.theme.ink.withAlphaComponent(overlay ? 0.12 : 0.08).setFill()
            NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    static let rowHeight: CGFloat = 34, tileHeight: CGFloat = 40, gap: CGFloat = 4
    private func rowFrame(_ i: Int) -> NSRect {  // in the list
        let h = names ? TabSidebar.rowHeight : TabSidebar.tileHeight
        return NSRect(x: 10, y: 4 + CGFloat(i) * (h + TabSidebar.gap), width: bounds.width - 20, height: h)
    }
    override func layout() {
        super.layout()
        let h = names ? TabSidebar.rowHeight : TabSidebar.tileHeight, top = max(40, topInset + 6)
        widthSwitch.frame = NSRect(x: 10, y: bounds.height - 10 - h, width: bounds.width - 20, height: h)
        settings.frame = NSRect(x: 10, y: widthSwitch.frame.minY - TabSidebar.gap - h, width: bounds.width - 20, height: h)
        list.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, settings.frame.minY - 8 - top))
        for (i, row) in rows.enumerated() { row.frame = rowFrame(i) }
        newTab.frame = rowFrame(rows.count)
        listDoc.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(list.contentSize.height, newTab.frame.maxY + 4))
        if list.frame.height != shownHeight {  // a resized list keeps the showing tab in view
            shownHeight = list.frame.height
            if let i = tabs.firstIndex(where: { $0 === host?.selected }), i < rows.count { listDoc.scrollToVisible(rows[i].frame) }
        }
        if let i = dropIndex {
            let y = i < rows.count ? rowFrame(i).minY - TabSidebar.gap / 2 : rowFrame(rows.count).minY - TabSidebar.gap / 2
            insertion.frame = NSRect(x: 12, y: y - 1, width: bounds.width - 24, height: 2)
        }
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { (window as? ReaderWindow)?.titleDoubleClick(); return }
        super.mouseDown(with: event)
    }

    // Dragging a tab.
    func startDrag(_ row: TabRow, event: NSEvent) {
        guard let r = row.reader else { return }
        let item = NSPasteboardItem()
        item.setString(r.uid, forType: TabSidebar.tabType)
        let drag = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: row.bounds.size)
        if let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) { row.cacheDisplay(in: row.bounds, to: rep); image.addRepresentation(rep) }
        drag.setDraggingFrame(convert(row.bounds, from: row), contents: image)
        beginDraggingSession(with: [drag], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    // Dropped where no sidebar took it: the tab gets a window of its own there.
    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        // A drag ended by Escape (or one the system cancels) ends without a mouse-up: the tab stays where it was.
        guard NSApp.currentEvent?.type == .leftMouseUp, operation == [], let id = session.draggingPasteboard.string(forType: TabSidebar.tabType),
              let r = Reader.all.first(where: { $0.uid == id }) else { return }
        r.host.detach(r, at: NSPoint(x: point.x - 60, y: point.y + 14)).window.makeKeyAndOrderFront(nil)
    }
    private func index(at windowPoint: NSPoint) -> Int {
        let p = listDoc.convert(windowPoint, from: nil)
        for i in 0..<rows.count where p.y < rowFrame(i).midY { return i }
        return rows.count
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.string(forType: TabSidebar.tabType) != nil {
            dropIndex = index(at: sender.draggingLocation); insertion.isHidden = false; needsLayout = true
            return .move
        }
        return ReaderWebView.textFiles(sender).isEmpty ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropIndex = nil; insertion.isHidden = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropIndex = nil; insertion.isHidden = true }
        guard let host else { return false }
        if let id = sender.draggingPasteboard.string(forType: TabSidebar.tabType), let moving = Reader.all.first(where: { $0.uid == id }) {
            host.adopt(moving, at: dropIndex ?? rows.count)
            return true
        }
        let files = ReaderWebView.textFiles(sender)
        files.forEach { _ = Reader.reader(showing: $0, into: host) }
        return !files.isEmpty
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

// A rounded tile with one or two letters in its middle (a tab's letters, or Aa).
final class Tile: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var font = NSFont.systemFont(ofSize: 13, weight: .semibold) { didSet { needsDisplay = true } }
    var color = NSColor.labelColor { didSet { needsDisplay = true } }
    var fill = NSColor.clear { didSet { needsDisplay = true } }
    var radius: CGFloat = 6
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let size = s.size()
            s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        }
    }
}

// One row of the sidebar: a tab (its two letters, its name, and a close button), or an action (New Tab, Reading
// settings, the width switch). In the icons width a row is a tile with its letters or symbol only.
final class TabRow: NSView {
    enum Kind { case tab, action }
    let kind: Kind
    weak var reader: Reader?
    weak var sidebar: TabSidebar?
    var onClick: (() -> Void)?
    private let tile = Tile(), name = NSTextField(labelWithString: ""), hint = NSTextField(labelWithString: "")
    private let icon = NSImageView(), close = NSButton()
    private var selected = false, names = true, hover = false, symbol: String?
    private var area: NSTrackingArea?, downAt: NSPoint?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        addSubview(tile)
        name.lineBreakMode = .byTruncatingMiddle; hint.lineBreakMode = .byTruncatingTail
        for f in [name, hint] { f.isEditable = false; f.isSelectable = false; addSubview(f) }
        name.font = .systemFont(ofSize: 13)
        hint.font = .systemFont(ofSize: 11)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        addSubview(icon)
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        close.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        close.target = self; close.action = #selector(closeTab)
        close.toolTip = "Close tab (⌘W)"
        addSubview(close)
    }
    required init?(coder: NSCoder) { nil }
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(title: String, folder: String?, monogram: String, tip: String?, selected: Bool, names: Bool, sidebar: TabSidebar) {
        self.selected = selected; self.names = names; self.sidebar = sidebar
        name.stringValue = title; hint.stringValue = folder ?? ""; tile.text = monogram; toolTip = tip
        setAccessibilityRole(.radioButton); setAccessibilityLabel(folder.map { "\(title), \($0)" } ?? title); setAccessibilityValue(selected ? 1 : 0)
        updateLook(); needsLayout = true
    }
    func configureAction(symbol: String?, title: String, shortcut: String?, names: Bool, tip: String) {
        self.symbol = symbol; self.names = names
        name.stringValue = title; hint.stringValue = shortcut ?? ""; toolTip = tip
        if let symbol { icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); tile.text = "" } else { icon.image = nil; tile.text = "Aa" }
        setAccessibilityRole(.button); setAccessibilityLabel(title)
        updateLook(); needsLayout = true
    }
    func updateLook() {
        let theme = ReadingSettings.shared.theme
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let ink = theme.ink, link = theme.link
            let fill: NSColor = selected ? link.withAlphaComponent(names ? 0.16 : 0.2) : hover ? ink.withAlphaComponent(0.07) : (kind == .tab && !names ? ink.withAlphaComponent(0.045) : .clear)
            layer?.backgroundColor = fill.cgColor
            tile.fill = kind == .tab && names ? (selected ? link.withAlphaComponent(0.28) : ink.withAlphaComponent(0.07)) : .clear
            let muted = ink.withAlphaComponent(0.6)
            tile.color = selected ? link : (kind == .action ? ink.withAlphaComponent(0.85) : muted)
            name.textColor = kind == .action && symbol != nil ? muted : ink.withAlphaComponent(0.92)
            hint.textColor = ink.withAlphaComponent(0.45)
            icon.contentTintColor = muted
            close.contentTintColor = muted
        }
        let mono: CGFloat = kind == .action ? 14 : (names ? 10.5 : 14)
        tile.font = kind == .action ? NSFont(name: "Libron-Regular", size: 15) ?? .systemFont(ofSize: 14, weight: .medium) : .systemFont(ofSize: mono, weight: .semibold)
        name.isHidden = !names; hint.isHidden = !names || hint.stringValue.isEmpty
        close.isHidden = kind != .tab || !(hover || (selected && names))
    }
    override func layout() {
        super.layout()
        let h = bounds.height
        if names {
            let t: CGFloat = 22
            tile.frame = NSRect(x: 8, y: (h - t) / 2, width: t, height: t)
            icon.frame = NSRect(x: 8, y: (h - 18) / 2, width: t, height: 18)
            let right = bounds.width - (kind == .tab ? 30 : 8)
            hint.sizeToFit()
            let hw = kind == .tab ? min(hint.frame.width, (right - 39) * 0.45) : hint.frame.width  // a twin's folder keeps up to almost half
            hint.frame = NSRect(x: right - hw, y: (h - hint.frame.height) / 2, width: hw, height: hint.frame.height)
            name.sizeToFit()
            let nameRight = hint.isHidden ? right : hint.frame.minX - 6
            name.frame = NSRect(x: 39, y: (h - name.frame.height) / 2, width: max(0, nameRight - 39), height: name.frame.height)
            close.frame = NSRect(x: bounds.width - 26, y: (h - 18) / 2, width: 18, height: 18)
        } else {
            tile.frame = bounds
            icon.frame = NSRect(x: (bounds.width - 20) / 2, y: (h - 18) / 2, width: 20, height: 18)
            close.frame = NSRect(x: bounds.width - 18, y: 3, width: 14, height: 14)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area!)
    }
    override func mouseEntered(with event: NSEvent) { hover = true; updateLook() }
    override func mouseExited(with event: NSEvent) { hover = false; updateLook() }
    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard kind == .tab, let start = downAt else { return }
        let p = event.locationInWindow
        if hypot(p.x - start.x, p.y - start.y) > 4 { downAt = nil; sidebar?.startDrag(self, event: event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard downAt != nil else { return }
        downAt = nil
        if event.buttonNumber == 2, kind == .tab { return closeTab() }
        if kind == .tab, let r = reader { r.host.select(r); r.window.makeKeyAndOrderFront(nil) }
        else { onClick?() }
    }
    // Accessibility (VoiceOver, and scripts): a row is a button or a tab that can be pressed.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        if kind == .tab, let r = reader { r.host.select(r); r.window.makeKeyAndOrderFront(nil) } else { onClick?() }
        return true
    }
    override func otherMouseUp(with event: NSEvent) { if kind == .tab, event.buttonNumber == 2 { closeTab() } }  // a middle click closes a tab
    @objc private func closeTab() { if let r = reader { r.host.close(r) } }
}
