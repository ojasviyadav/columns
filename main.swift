// Columns: shows one Markdown file in 1-6 continuous, synchronised columns.
// The page (Resources/index.html) renders and lays out; this file owns windows, menus, settings and file watching.
import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// Keyboard commands act at once, with no animation; the same command by pointer keeps its motion.
@MainActor func byKeyboard() -> Bool { NSApp.currentEvent?.type == .keyDown }

@MainActor
enum Prefs {
    static let d = UserDefaults.standard
    static var columns: Int {
        get { let n = d.integer(forKey: "columns"); return (1...maxColumns).contains(n) ? n : defaultColumns }
        set { d.set(newValue, forKey: "columns") }
    }
    static var fontSize: Int {
        get { let n = d.integer(forKey: "fontSize"); return n > 0 ? n : 16 }
        set { d.set(min(48, max(8, newValue)), forKey: "fontSize") }
    }
    static var theme: Theme {
        get { Theme(rawValue: d.string(forKey: "theme") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "theme") }
    }
    static var family: Family {
        get { Family(rawValue: d.string(forKey: "family") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "family") }
    }
    static var bigDots: Bool {
        get { d.bool(forKey: "bigDots") }
        set { d.set(newValue, forKey: "bigDots") }
    }
    static var boldStarts: Bool {
        get { d.bool(forKey: "boldStarts") }
        set { d.set(newValue, forKey: "boldStarts") }
    }
    static var lastFile: URL? {
        get { d.url(forKey: "lastFile") }
        set { d.set(newValue, forKey: "lastFile") }
    }
    static var launchedBefore: Bool {  // the Welcome page opens by itself once, at the first launch
        get { d.bool(forKey: "launchedBefore") || d.object(forKey: "lastFile") != nil }
        set { d.set(newValue, forKey: "launchedBefore") }
    }
    static var openGroups: [[String: Any]] {  // the windows open when Columns last quit, each with its tabs
        get { d.array(forKey: "openGroups") as? [[String: Any]] ?? [] }
        set { d.set(newValue, forKey: "openGroups") }
    }
    static var openFiles: [URL] {  // the files open when Columns last quit, the front one last
        get { (d.stringArray(forKey: "openFiles") ?? []).map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue.map(\.path), forKey: "openFiles") }
    }
    // About one column per 1000 points of screen width: 5 on a 5120-wide display.
    static let maxColumns = 6
    static var defaultColumns: Int { min(maxColumns, max(1, Int(((NSScreen.main?.frame.width ?? 1440) / 1000).rounded()))) }
}

@MainActor
final class Reader: NSObject, NSWindowDelegate, WKNavigationDelegate, NSToolbarDelegate, WKScriptMessageHandler, NSMenuItemValidation {
    static var all: [Reader] = []
    // The window the menus act on: the key one, or the main one while a panel or the popover is key.
    static var current: Reader? { all.first { $0.window.isKeyWindow } ?? all.first { $0.window.isMainWindow } ?? all.last }
    private static let settingsItem = NSToolbarItem.Identifier("settings")

    private(set) var url: URL
    let window: NSWindow
    let web = ReaderWebView()
    private var settingsButton: NSButton?
    private lazy var settings: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        let host = NSHostingController(rootView: SettingsView(s: ReadingSettings.shared, folds: folds) { [weak self] in self?.call("foldAll", $0) })
        host.sizingOptions = .preferredContentSize
        p.contentViewController = host
        return p
    }()
    private var ready = false
    private var pending: [String] = []
    private var stamp: [FileAttributeKey: Any]? = nil
    private var timer: Timer?
    private var bookmark: Data?          // finds the file again after it is renamed or moved
    // What the window shows of its file. One value, set only in `reload`; the banner and the menus follow it.
    private enum Showing: Equatable {
        case nothing              // no file read yet
        case text                 // the file's text
        case lastVersion(String)  // the last text Columns could open, and why the file cannot be read now
        case empty                // the file has no text; the page says so
        case problem(String)      // the file cannot be read and the page holds no version of it; page and banner say why
        var banner: String? { switch self { case .lastVersion(let why), .problem(let why): why; default: nil } }
        var hasText: Bool { switch self { case .text, .lastVersion: true; default: false } }
    }
    private var showing = Showing.nothing { didSet { if showing.banner != oldValue.banner { showBanner() } } }
    private var problem: String? { showing.banner }  // what the banner says while the file cannot be shown
    private var shown: Bool { showing.hasText }      // the page holds the file's text (an old version stays while there is a problem)
    private var banner: NSTitlebarAccessoryViewController?
    private var printJob: PrintJob?
    private lazy var findBar = FindBar(reader: self)
    var outline: [[String: Any]] = []    // the headings, for Go > Go to Section
    private(set) var state: [String: Any] = [:]  // what the page can do now (it reports on every change), for the menus
    private let folds = FoldState()

    // The welcome page ships inside the app; it is shown, but never remembered as the reader's own file.
    static let welcome = Bundle.main.url(forResource: "Welcome to Columns", withExtension: "md")

    static func show(_ url: URL) { _ = reader(showing: url) }
    // Files open as tabs, as in a browser: in the window in front (`into` names another one), or in a window of their
    // own with `newWindow`. A file that is open already comes to the front where it is.
    static func reader(showing url: URL, into host: NSWindow? = nil, newWindow: Bool = false) -> Reader {
        let same = { (a: URL) in a.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL }
        if let r = all.first(where: { same($0.url) }) { r.window.makeKeyAndOrderFront(nil); return r }
        let front = newWindow ? nil : host ?? frontWindow
        let r = Reader(url: url, alone: front == nil)
        all.append(r)
        if let front { front.addTabbedWindow(r.window, ordered: .above) }
        r.window.makeKeyAndOrderFront(nil)
        (r.window as? ReaderWindow)?.keepTabBar()
        updateTabTitles()
        guard url != welcome else { return r }
        Prefs.lastFile = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return r
    }

    // The reader window a new tab joins: the one in front, if it can show one now.
    static var frontWindow: NSWindow? {
        let readers = Set(all.map { ObjectIdentifier($0.window) })
        return NSApp.orderedWindows.first { readers.contains(ObjectIdentifier($0)) && $0.isVisible && !$0.isMiniaturized }
    }
    // A tab shows its file's name; two files of the same name also show their folders, and the tooltip the whole path.
    static func updateTabTitles() {
        let names = Dictionary(grouping: all, by: { $0.window.title })
        for r in all {
            let twins = (names[r.window.title]?.count ?? 0) > 1 && r.url != welcome
            r.window.tab.title = twins ? "\(r.window.title) — \(r.url.deletingLastPathComponent().lastPathComponent)" : r.window.title
            r.window.tab.toolTip = r.url == welcome ? nil : (r.url.path as NSString).abbreviatingWithTildeInPath
        }
    }
    // Tabs closed in this session, the latest last, for File > Reopen Closed Tab.
    static var closed: [URL] = []

    private init(url: URL, alone: Bool = true) {
        self.url = url
        window = ReaderWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        if url == Reader.welcome {
            window.title = "Welcome to Columns"
        } else {
            window.title = url.lastPathComponent
            window.representedURL = url
            bookmark = try? url.bookmarkData()
        }
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.tabbingIdentifier = "Columns"  // every reader can be a tab of any other; drag a tab out for a window of its own
        window.tabbingMode = .preferred
        window.titlebarAppearsTransparent = true  // the title bar takes the page's colour, so sepia is sepia to the top
        window.contentView = web
        window.delegate = self
        // The first window owns the saved frame; each further one opens at the same size, stepped down and right of the
        // front one (which stays where it is). A first window ever fills most of the screen, centred, so that Zoom (a
        // double-click on the title bar, the green button with ⌥) has a larger frame to go to and a smaller one to return to.
        let saved = UserDefaults.standard.object(forKey: "NSWindow Frame Reader") != nil
        if !alone {
            // a tab takes the size of its window
        } else if window.setFrameAutosaveName("Reader") {
            if !saved, let area = NSScreen.main?.visibleFrame {
                let size = NSSize(width: (area.width * 0.85).rounded(), height: (area.height * 0.88).rounded())
                window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: false)
            }
        } else if let front = Reader.current?.window {
            let next = front.frame.offsetBy(dx: 24, dy: -24)
            window.setFrame(window.constrainFrameRect(next, to: front.screen), display: false)
        }
        #if CHECK_COPY  // the check copy only (CHECK_COPY=1 ./build.sh): open at COLUMNS_FRAME, e.g. on a display for checks
        if let frame = ProcessInfo.processInfo.environment["COLUMNS_FRAME"] { window.setFrame(NSRectFromString(frame), display: false) }
        if let pdf = ProcessInfo.processInfo.environment["COLUMNS_EXPORT"] {  // and save the file as PDF there once it shows
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.printCopy(to: URL(fileURLWithPath: pdf)) }
        }
        #endif
        let toolbar = NSToolbar(identifier: "reader")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        web.navigationDelegate = self
        web.reader = self
        web.configuration.userContentController.add(self, name: "menu")
        web.configuration.userContentController.add(self, name: "outline")
        web.configuration.userContentController.add(self, name: "state")
        web.configuration.userContentController.add(self, name: "link")
        #if CHECK_COPY
        web.configuration.userContentController.add(self, name: "log")
        web.configuration.userContentController.add(self, name: "zoom")  // checks/check-window.sh: what a title bar double-click does
        web.configuration.userContentController.add(self, name: "titleDoubleClick")
        web.configuration.userContentController.add(self, name: "act")  // checks/check-window.sh: a window or app command, by name
        web.configuration.userContentController.addUserScript(WKUserScript(source: "addEventListener('error', e => webkit.messageHandlers.log.postMessage(e.message + ' @' + e.lineno)); addEventListener('unhandledrejection', e => webkit.messageHandlers.log.postMessage('rejection: ' + e.reason));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #endif
        loadShell()
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
    }

    private func loadShell() {
        ready = false
        pending = []
        let shell = Bundle.main.url(forResource: "index", withExtension: "html")!
        web.loadFileURL(shell, allowingReadAccessTo: URL(fileURLWithPath: "/"))  // images may sit anywhere relative to the file
        let s = ReadingSettings.shared
        applyTheme()
        call("setFamily", s.family.rawValue)
        call("setDots", s.bigDots)
        updateScroller()
        call("setBoldStarts", s.boldStarts)
        call("setColumns", s.columns)
        call("setFont", s.fontSize)
        reload(keep: false)
    }

    // The page's position bar follows the Mac's scroll bar settings (System Settings > Appearance).
    func updateScroller() {
        call("setScroller", NSScroller.preferredScrollerStyle == .overlay, UserDefaults.standard.bool(forKey: "AppleScrollerPagingBehavior"))
    }

    func applyTheme() {
        let theme = ReadingSettings.shared.theme
        window.appearance = theme.appearance
        window.backgroundColor = theme.page
        web.underPageBackgroundColor = theme.page
        // The popover is open while the theme changes, so it follows at once instead of keeping the old look.
        settings.appearance = theme.appearance  // nil: it follows the system, also when the system changes
        settings.contentViewController?.view.appearance = theme.appearance
        call("setTheme", theme.rawValue)
    }

    // The + in the tab bar, and File > New Tab: choose files to open as tabs of this window.
    @objc func newWindowForTab(_ sender: Any?) {
        let panel = AppDelegate.openPanel()
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK else { return }
            MainActor.assumeIsolated { panel.urls.forEach { _ = Reader.reader(showing: $0, into: self?.window) } }
        }
    }
    // File > Close Window: every tab of this window.
    @objc func closeWindow(_ sender: Any?) { (window.tabbedWindows ?? [window]).forEach { $0.performClose(sender) } }

    @objc func showInFinder(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // Find: a find bar under the title bar, as in Safari; the page finds and marks the matches.
    @objc func showFind(_ sender: Any?) { open(findBar) }
    @objc func findNextMatch(_ sender: Any?) { adoptSharedFind(); findBar.field.stringValue.isEmpty || !findBar.isOpen ? open(findBar) : findBar.search(1) }
    @objc func findPreviousMatch(_ sender: Any?) { adoptSharedFind(); findBar.field.stringValue.isEmpty || !findBar.isOpen ? open(findBar) : findBar.search(-1) }
    // The find text is shared between the apps on a Mac (⌘E in one, ⌘G in another) and between Columns' windows:
    // when it changed elsewhere since this window last looked, the find bar takes it.
    private var sharedFindSeen = -1
    private func adoptSharedFind() {
        let shared = NSPasteboard(name: .find)
        guard shared.changeCount != sharedFindSeen else { return }
        sharedFindSeen = shared.changeCount
        if let text = shared.string(forType: .string), !text.isEmpty { findBar.field.stringValue = text }
    }
    func shareFind(_ text: String) {
        let shared = NSPasteboard(name: .find)
        guard !text.isEmpty else { return }
        if shared.string(forType: .string) != text {
            shared.clearContents()
            shared.setString(text, forType: .string)
        }
        sharedFindSeen = shared.changeCount  // what is there now is this window's own text
    }
    @objc func useSelectionForFind(_ sender: Any?) {
        web.evaluateJavaScript("R.selection()") { [weak self] value, _ in
            guard let self, let text = value as? String, !text.isEmpty else { return }
            self.shareFind(text)
            self.findBar.field.stringValue = text
            self.open(self.findBar)
        }
    }
    private func open(_ bar: FindBar) {
        adoptSharedFind()
        if !bar.isOpen { window.addTitlebarAccessoryViewController(bar) }
        window.makeFirstResponder(bar.field)
        if !bar.field.stringValue.isEmpty { bar.search(0) }
    }
    func find(_ query: String, _ dir: Int, _ done: @escaping @MainActor (Int, Int) -> Void) {
        let json = String(data: try! JSONSerialization.data(withJSONObject: [query, dir, byKeyboard()]), encoding: .utf8)!
        web.evaluateJavaScript("R.find.apply(null, \(json))") { value, _ in
            let d = value as? [String: Any]
            MainActor.assumeIsolated { done(d?["count"] as? Int ?? 0, d?["index"] as? Int ?? 0) }
        }
    }
    func endFind() { call("endFind"); window.makeFirstResponder(web) }
    @objc func cancelOperation(_ sender: Any?) { if findBar.isOpen { findBar.close() } }

    // Go: the top, the end, the sections.
    @objc func goBeginning(_ sender: Any?) { call("go", "top", byKeyboard()) }
    @objc func goEnd(_ sender: Any?) { call("go", "end", byKeyboard()) }
    @objc func nextSection(_ sender: Any?) { call("heading", 1, byKeyboard()) }
    @objc func previousSection(_ sender: Any?) { call("heading", -1, byKeyboard()) }
    @objc func goToSection(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { call("jump", id, false) } }
    // Back to where the last jump left from, and forward again. (Not goBack/goForward: the web view answers those itself.)
    @objc func backInDocument(_ sender: Any?) { call("back", byKeyboard()) }
    @objc func forwardInDocument(_ sender: Any?) { call("forward", byKeyboard()) }

    // Print and Export as PDF: one clean copy of the document (light, every section open), in pages.
    @objc func printReader(_ sender: Any?) { printCopy(to: nil) }
    @objc func exportPDF(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let target = panel.url else { return }
            MainActor.assumeIsolated { self?.printCopy(to: target) }
        }
    }
    func printCopy(to pdf: URL?) {
        web.evaluateJavaScript("R.printable()") { [weak self] value, error in
            let html = value as? String, reason = error?.localizedDescription
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let html else { return self.exportFailed(pdf, reason) }
                do {
                    self.printJob = try PrintJob(html: html, title: self.window.title, window: self.window, pdf: pdf) { [weak self] ok in
                        guard let self else { return }
                        self.printJob = nil
                        if let pdf, !ok || !FileManager.default.fileExists(atPath: pdf.path) { self.exportFailed(pdf, nil) }
                    }
                } catch { self.exportFailed(pdf, error.localizedDescription) }
            }
        }
    }
    // Export as PDF made no file: say so, with the reason when there is one. A cancelled print says nothing.
    private func exportFailed(_ pdf: URL?, _ reason: String?) {
        guard let pdf else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Columns couldn’t export “\(pdf.lastPathComponent)”"
        alert.informativeText = reason ?? "The PDF could not be saved in “\(pdf.deletingLastPathComponent().lastPathComponent)”. Check that you can save files in that folder, then choose File > Export as PDF… again."
        alert.beginSheetModal(for: window)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tabs = window.tabbedWindows?.count ?? 1
        if item.action == #selector(NSWindow.performClose(_:)) { item.title = tabs > 1 ? "Close Tab" : "Close" }
        switch item.action {
        case #selector(closeWindow(_:)): return tabs > 1
        case #selector(showInFinder(_:)): return url != Reader.welcome && FileManager.default.fileExists(atPath: url.path)
        case #selector(printReader(_:)), #selector(exportPDF(_:)): return shown
        case #selector(nextSection(_:)), #selector(previousSection(_:)): return shown && !outline.isEmpty
        case #selector(collapseAll(_:)): return shown && state["canCollapse"] as? Bool ?? false
        case #selector(expandAll(_:)): return shown && state["canExpand"] as? Bool ?? false
        case #selector(backInDocument(_:)): return shown && state["canBack"] as? Bool ?? false
        case #selector(forwardInDocument(_:)): return shown && state["canForward"] as? Bool ?? false
        case #selector(useSelectionForFind(_:)): return shown && state["selection"] as? Bool ?? false
        case #selector(showFind(_:)), #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)),
             #selector(goBeginning(_:)), #selector(goEnd(_:)): return shown
        default: return true
        }
    }
    @objc func collapseAll(_ sender: Any?) { call("foldAll", true, byKeyboard()) }
    @objc func expandAll(_ sender: Any?) { call("foldAll", false, byKeyboard()) }

    @objc func showSettings(_ sender: Any?) {
        settings.animates = !byKeyboard()
        if settings.isShown { return settings.performClose(sender) }
        if let button = settingsButton, button.window != nil {
            settings.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else {  // toolbar hidden: hang it from the top-right corner of the page
            settings.show(relativeTo: NSRect(x: web.bounds.maxX - 40, y: web.bounds.maxY - 1, width: 1, height: 1), of: web, preferredEdge: .minY)
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Reader.settingsItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Reader.settingsItem] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == Reader.settingsItem else { return nil }
        // A real button, so the popover can hang from it.
        let image = NSImage(systemSymbolName: "textformat.size", accessibilityDescription: "Reading settings")!
        let button = NSButton(image: image, target: self, action: #selector(showSettings(_:)))
        button.bezelStyle = .toolbar
        button.toolTip = "Settings: columns, text size, theme and font (⌘,)"
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = button
        item.label = "Settings"
        settingsButton = button
        return item
    }

    func reload(keep: Bool = true) {
        stamp = try? FileManager.default.attributesOfItem(atPath: url.path)
        switch read() {
        case .text(let text) where text.allSatisfy(\.isWhitespace):
            showing = .empty
            noDocument()
            call("message", "“\(url.lastPathComponent)” is empty", "Its text shows here as soon as the file has some. Columns reloads it by itself.")
        case .text(let text):
            showing = .text
            call("load", text, url.deletingLastPathComponent().absoluteString, keep, url.path, url != Reader.welcome)
        case .problem(let title, let detail):
            // With text already on the page, keep it and say so; with none, say what happened in its place.
            if shown { showing = .lastVersion("\(title). You are reading the last version Columns could open.") }
            else { showing = .problem(title); noDocument(); call("message", title, detail) }
        }
    }

    // The page shows a message in place of the text: nothing is left to find or to go to.
    private func noDocument() {
        if findBar.isOpen { findBar.close() }
        outline = []
        state = [:]  // nothing to collapse, expand or go back to
        folds.canCollapse = false
        folds.canExpand = false
    }

    private enum Contents { case text(String), problem(String, String) }
    private func read() -> Contents {
        let name = "“\(url.lastPathComponent)”"
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) else {
            return .problem("\(name) was moved or deleted", "Columns can’t find it in \(url.deletingLastPathComponent().path). Choose Open File… to open it from where it is now.")
        }
        if folder.boolValue { return .problem("\(name) is a folder", "Columns shows one Markdown file at a time. Choose Open File… to pick one inside it.") }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            if (error as NSError).code == NSFileReadNoPermissionError {
                return .problem("Columns isn’t allowed to read \(name)", "Give yourself read access in Finder (File > Get Info > Sharing & Permissions), then choose File > Reload.")
            }
            return .problem("Columns can’t read \(name)", error.localizedDescription)
        }
        // UTF-16 text is full of zero bytes: it is read by its byte-order mark, before the test for a file that is not text.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return .text(text) }
        if data.prefix(8192).contains(0) { return .problem("\(name) isn’t a text file", "Columns shows Markdown and plain text. Choose Open File… to open another file.") }
        return .text(String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(decoding: data, as: UTF8.self))
    }

    // A banner under the title bar while the file cannot be shown, with what to do about it.
    private func showBanner() {
        banner?.removeFromParent()
        banner = nil
        guard let text = problem else { return }
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Problem")!)
        icon.contentTintColor = .systemOrange
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let choose = NSButton(title: "Open File…", target: self, action: #selector(chooseFile(_:)))
        let bar = NSStackView()
        bar.addView(icon, in: .leading)
        bar.addView(label, in: .leading)
        bar.addView(choose, in: .trailing)
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 12)
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 36)
        let vc = NSTitlebarAccessoryViewController()
        vc.layoutAttribute = .bottom
        vc.view = bar
        window.addTitlebarAccessoryViewController(vc)
        banner = vc
    }

    // Open File… from the banner: opens the chosen file in place of this one.
    @objc private func chooseFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("net.daringfireball.markdown"), .plainText].compactMap { $0 }
        var folder = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" { folder.deleteLastPathComponent() }
        panel.directoryURL = folder
        panel.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .OK, let chosen = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if Reader.all.contains(where: { $0.url == chosen }) { Reader.show(chosen); self.window.close() } else { self.adopt(chosen, moved: false) }
            }
        }
    }

    // This window now shows the file at another place. Renamed or moved, it is the same document and keeps its
    // place and its collapsed sections; chosen from the banner, it is read as a document of its own.
    private func adopt(_ file: URL, moved: Bool) {
        let wasLast = Prefs.lastFile?.path == url.path
        url = file
        window.title = file.lastPathComponent
        window.representedURL = file
        bookmark = try? file.bookmarkData()
        if wasLast || !moved { Prefs.lastFile = file }
        NSDocumentController.shared.noteNewRecentDocumentURL(file)
        reload(keep: moved)
    }

    // Where a renamed or moved file went; a file in the Trash counts as deleted.
    private func whereItWent() -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
              found.standardizedFileURL.path != url.standardizedFileURL.path, !found.path.contains("/.Trash/"),
              FileManager.default.fileExists(atPath: found.path) else { return nil }
        return found
    }

    // Editors often save by replacing the file, so compare attributes instead of watching one file handle.
    @objc private func poll() {
        #if CHECK_COPY
        if self === Reader.current, let path = ProcessInfo.processInfo.environment["COLUMNS_EVAL"],
           let js = try? String(contentsOfFile: path, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: path)
            web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                let text: String
                switch result { case .success(let v): text = "\(v)"; case .failure(let e): text = "ERROR \(e)" }
                try? text.write(toFile: path + ".out", atomically: true, encoding: .utf8)
            }
        }
        #endif
        guard let now = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            if let moved = whereItWent() { adopt(moved, moved: true) } else if problem == nil { reload() }
            return
        }
        if now[.modificationDate] as? Date != stamp?[.modificationDate] as? Date || now[.size] as? Int != stamp?[.size] as? Int {
            reload()
        }
    }

    func call(_ fn: String, _ args: Any...) {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let js = "R.\(fn).apply(null, \(json))"
        if ready { web.evaluateJavaScript(js) } else { pending.append(js) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        pending.forEach { web.evaluateJavaScript($0) }
        pending = []
        window.makeFirstResponder(web)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loadShell() }

    // The page itself is the only thing the web view ever loads; every link opens elsewhere.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let shell = Bundle.main.url(forResource: "index", withExtension: "html")!.standardizedFileURL.path
        guard let target = action.request.url, !(target.isFileURL && target.standardizedFileURL.path == shell) else {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        open(target)
    }

    // A link to a Markdown file opens it in Columns, at the heading the link names. A link to a file that is not
    // there says so; one written without ".md" (as in a wiki) finds the file with it.
    private func open(_ target: URL) {
        guard target.isFileURL else {
            if !NSWorkspace.shared.open(target) { linkFailed(target.absoluteString, "No app on this Mac opens this kind of link.") }
            return
        }
        var file = URL(fileURLWithPath: target.path)
        if !FileManager.default.fileExists(atPath: file.path) {
            let named = file.appendingPathExtension("md")
            guard FileManager.default.fileExists(atPath: named.path) else {
                return linkFailed(file.lastPathComponent, "This link points to \((file.path as NSString).abbreviatingWithTildeInPath), and no file is there. The file may have been moved or renamed.")
            }
            file = named
        }
        if ["md", "markdown"].contains(file.pathExtension.lowercased()) {
            let reader = Reader.reader(showing: file)
            if let heading = target.fragment?.removingPercentEncoding, !heading.isEmpty { reader.call("jump", heading, true) }
        } else if !NSWorkspace.shared.open(file) {
            linkFailed(file.lastPathComponent, "No app on this Mac opens this kind of file.")
        }
    }
    private func linkFailed(_ name: String, _ why: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Columns couldn’t open “\(name)”"
        alert.informativeText = why
        alert.beginSheetModal(for: window)
    }

    // What the page tells the app: a link that was clicked, what the last right-click was on, the headings, its state.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "menu", let context = message.body as? [String: Any] { web.context = context }
        if message.name == "link", let address = message.body as? String, let target = URL(string: address) { open(target) }
        if message.name == "outline", let headings = message.body as? [[String: Any]] { outline = headings }
        if message.name == "state", let now = message.body as? [String: Any] {
            state = now
            folds.canCollapse = now["canCollapse"] as? Bool ?? false
            folds.canExpand = now["canExpand"] as? Bool ?? false
            // A reload can change how many matches there are: the find bar follows.
            if findBar.isOpen, let f = now["find"] as? [String: Any] { findBar.show(total: f["count"] as? Int ?? 0, index: f["index"] as? Int ?? 0) }
        }
        #if CHECK_COPY
        if message.name == "zoom" { window.performZoom(nil) }
        if message.name == "act", let name = message.body as? String {
            let window = self.window.tabGroup?.selectedWindow ?? self.window  // the tab showing in this window
            switch name {
            case "moveTab": window.moveTabToNewWindow(nil)
            case "merge": window.mergeAllWindows(nil)
            case "previousTab": window.selectPreviousTab(nil)
            case "nextTab": window.selectNextTab(nil)
            case "closeTab": window.performClose(nil)
            case "closeWindow": (window.tabbedWindows ?? [window]).forEach { $0.performClose(nil) }
            case "reopen": (NSApp.delegate as? AppDelegate)?.reopenClosedTab(nil)
            default: break
            }
        }
        if message.name == "titleDoubleClick" {  // checks/check-window.sh: a double-click in the middle of the title bar
            let p = NSPoint(x: window.frame.width / 2, y: window.frame.height - 10)
            for n in 1...2 { for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1) { window.sendEvent(e) }
            } }
        }
        if message.name == "log", let line = message.body as? String, let log = ProcessInfo.processInfo.environment["COLUMNS_LOG"] {
            let old = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            try? (old + line + "\n").write(toFile: log, atomically: true, encoding: .utf8)
        }
        #endif
    }

    // The right-click menu: what fits where you clicked first, then the reading options.
    func addMenuItems(to menu: NSMenu) {
        let c = web.context
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, _ value: Any? = nil, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.isEnabled = enabled
            menu.addItem(item)
        }
        func group() { if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) } }
        if let link = c["link"] as? String, let target = URL(string: link), !link.isEmpty {
            // Open goes first, as in every Mac app; Copy Link follows (the system's, or ours if it is missing).
            let md = target.isFileURL && ["md", "markdown"].contains(target.pathExtension.lowercased())
            add(md ? "Open in Columns" : "Open Link", #selector(openLink(_:)), target)
            menu.insertItem(menu.items.removeLast(), at: 0)
            if !menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink" }) {
                add("Copy Link", #selector(copyLink(_:)), target)
                menu.insertItem(menu.items.removeLast(), at: 1)
            }
        }
        if let id = c["section"] as? String, !id.isEmpty, let title = c["title"] as? String {
            group()
            let short = title.count > 40 ? String(title.prefix(39)) + "…" : title
            add("\((c["folded"] as? Bool ?? false) ? "Expand" : "Collapse") “\(short)”", #selector(toggleSection(_:)), id)
        }
        if (c["sections"] as? Int ?? 0) > 0 {
            group()
            add("Collapse All Sections", #selector(collapseAll(_:)), enabled: c["canCollapse"] as? Bool ?? true)
            add("Expand All Sections", #selector(expandAll(_:)), enabled: c["canExpand"] as? Bool ?? true)
        }
        group()
        let columns = NSMenu()
        for n in 1...Prefs.maxColumns {
            let item = NSMenuItem(title: n == 1 ? "1 Column" : "\(n) Columns", action: #selector(AppDelegate.setColumns(_:)), keyEquivalent: "")
            item.tag = n
            item.state = n == ReadingSettings.shared.columns ? .on : .off
            columns.addItem(item)
        }
        let columnsItem = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
        columnsItem.submenu = columns
        menu.addItem(columnsItem)
        add("Settings…", #selector(showSettings(_:)))
    }

    @objc private func openLink(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { open(u) } }
    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
    }
    @objc private func toggleSection(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { call("toggleSection", id) } }

    func windowDidBecomeKey(_ notification: Notification) {
        (window as? ReaderWindow)?.keepTabBar()  // a tab dragged out is a window of its own now: it keeps a tab bar too
        poll()
    }

    func windowWillClose(_ notification: Notification) {
        if url != Reader.welcome, !AppDelegate.quitting { Reader.closed.removeAll { $0 == url }; Reader.closed.append(url) }
        DispatchQueue.main.async { Reader.updateTabTitles() }
        timer?.invalidate()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "menu")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "outline")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "state")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "link")
        #if CHECK_COPY
        web.configuration.userContentController.removeScriptMessageHandler(forName: "log")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "zoom")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "titleDoubleClick")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "act")
        #endif
        Reader.all.removeAll { $0 === self }
    }
}

// A reader's window. A double-click on its title bar does what the Mac is set to do (System Settings > Desktop & Dock,
// "Double-click a window's title bar to"): Fill or Zoom (here both fill the screen and toggle back), Minimize, or nothing.
// With the compact toolbar, AppKit's title view in the bar takes the double-click and does none of these (seen on
// macOS 27, 11 Nov 2026; a plain window in the same app zooms), so the window answers it itself. A double-click on a
// control in the bar (the window buttons, Settings) stays the control's.
final class ReaderWindow: NSWindow {
    // The tab bar shows even with one tab, as in Chrome, so a tab can always be dropped into any window, and the + is
    // always there. View > Hide Tab Bar turns it off for every window, and Show Tab Bar back on.
    static var showsTabBar: Bool {
        get { UserDefaults.standard.object(forKey: "showsTabBar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showsTabBar") }
    }
    override func toggleTabBar(_ sender: Any?) {
        super.toggleTabBar(sender)
        guard sender != nil else { return }
        ReaderWindow.showsTabBar = tabGroup?.isTabBarVisible ?? true
        for w in NSApp.windows { (w as? ReaderWindow)?.keepTabBar() }
    }
    func keepTabBar() {
        if let group = tabGroup, group.isTabBarVisible != ReaderWindow.showsTabBar { super.toggleTabBar(nil) }
    }
    // The next and previous tab, wrapping round, also when Columns is not the active app (AppKit's own does nothing then).
    override func selectNextTab(_ sender: Any?) { step(1) }
    override func selectPreviousTab(_ sender: Any?) { step(-1) }
    private func step(_ by: Int) {
        guard let group = tabGroup, group.windows.count > 1, let now = group.selectedWindow, let i = group.windows.firstIndex(of: now) else { return }
        let next = group.windows[(i + by + group.windows.count) % group.windows.count]
        group.selectedWindow = next
        next.makeKeyAndOrderFront(nil)
    }
    // A tab that leaves for a window of its own (menu, or dragged out) gets its tab bar there too.
    override func moveTabToNewWindow(_ sender: Any?) {
        super.moveTabToNewWindow(sender)
        DispatchQueue.main.async { [weak self] in self?.keepTabBar() }
    }
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown, event.clickCount == 2, inTitleBar(event.locationInWindow) else { return super.sendEvent(event) }
        let d = UserDefaults.standard
        switch d.string(forKey: "AppleActionOnDoubleClick") {
        case "None": break
        case "Minimize": miniaturize(nil)
        case "Maximize", "Fill": zoom(nil)
        default: if d.bool(forKey: "AppleMiniaturizeOnDoubleClick") { miniaturize(nil) } else { zoom(nil) }
        }
    }
    private func inTitleBar(_ p: NSPoint) -> Bool {
        guard p.y >= contentLayoutRect.maxY, let frameView = contentView?.superview else { return false }
        let bars = titlebarAccessoryViewControllers.map(\.view)  // the find bar and the file banner are not the title bar
        var hit = frameView.hitTest(frameView.convert(p, from: nil))
        while let v = hit {  // a control, the find bar, the banner or the tab bar keeps its own double-click
            if v is NSControl || bars.contains(v) || String(describing: type(of: v)).contains("Tab") { return false }
            hit = v.superview
        }
        return true
    }
}

// The page's web view, with a right-click menu that keeps only the useful system items (Copy, Look Up,
// Translate, Search, Share, Speech, Copy Link, Copy Image) and adds the reader's own.
@MainActor
final class ReaderWebView: WKWebView {
    var context: [String: Any] = [:]
    weak var reader: Reader?
    private static let kept: Set<String> = ["Copy", "LookUp", "Translate", "SearchWeb", "ShareMenu", "SpeechMenu", "CopyLink", "CopyImage"]

    // A Markdown or text file dropped on the page opens in Columns, like one dropped on the Dock icon.
    private func textFiles(_ drag: NSDraggingInfo) -> [URL] {
        let urls = drag.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .text) == true || ["md", "markdown"].contains($0.pathExtension.lowercased()) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { textFiles(sender).isEmpty ? super.draggingEntered(sender) : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { textFiles(sender).isEmpty ? super.draggingUpdated(sender) : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = textFiles(sender)
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        files.forEach(Reader.show)
        return true
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let system = menu.items.filter {
            guard let id = $0.identifier?.rawValue, id.hasPrefix("WKMenuItemIdentifier") else { return false }
            return Self.kept.contains(String(id.dropFirst("WKMenuItemIdentifier".count)))
        }
        menu.removeAllItems()
        system.forEach(menu.addItem)
        reader?.addMenuItems(to: menu)
        super.willOpenMenu(menu, with: event)
    }
}

// The find bar under the title bar: a search field, previous and next, how many matches, Done.
@MainActor
final class FindBar: NSTitlebarAccessoryViewController, NSSearchFieldDelegate {
    weak var reader: Reader?
    var isOpen: Bool { parent != nil }  // the bar is open while it sits under the title bar
    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let arrows = NSSegmentedControl(images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous match")!,
                                                      NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next match")!],
                                             trackingMode: .momentary, target: nil, action: nil)

    init(reader: Reader) {
        self.reader = reader
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
        field.placeholderString = "Find in document"
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        arrows.target = self
        arrows.action = #selector(step(_:))
        arrows.isEnabled = false
        arrows.setToolTip("Previous match (⇧⌘G)", forSegment: 0)
        arrows.setToolTip("Next match (⌘G)", forSegment: 1)
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        let bar = NSStackView()
        [field, arrows, count].forEach { bar.addView($0, in: .leading) }
        bar.addView(done, in: .trailing)
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: 38)
        view = bar
    }
    required init?(coder: NSCoder) { nil }

    func controlTextDidChange(_ obj: Notification) { search(0) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.insertNewline(_:)) { search(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1); return true }
        if command == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
    @objc private func step(_ sender: NSSegmentedControl) { search(sender.selectedSegment == 0 ? -1 : 1) }

    // dir 0: a new or changed search, from the first match on screen; 1 and -1: the next or previous match.
    func search(_ dir: Int) {
        let query = field.stringValue
        reader?.shareFind(query)  // what is typed here is the Mac's find text at once, so ⌘G never brings an older one back
        reader?.find(query, dir) { [weak self] total, index in
            guard let self, self.field.stringValue == query else { return }
            self.show(total: total, index: index)
        }
    }
    func show(total: Int, index: Int) {
        count.stringValue = field.stringValue.isEmpty ? "" : total == 0 ? "Not found" : index == 0 ? "\(total) found" : "\(index) of \(total)"
        arrows.isEnabled = total > 0
    }
    @objc func close() { removeFromParent(); reader?.endFind() }
}

// Prints (or saves as PDF) a clean copy of a document from a web view of its own, so the reader's columns stay as they are.
@MainActor
final class PrintJob: NSObject, WKNavigationDelegate {
    private let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
    private let file: URL
    private let title: String
    private let window: NSWindow
    private let pdf: URL?
    private let done: (Bool) -> Void

    init(html: String, title: String, window: NSWindow, pdf: URL?, done: @escaping (Bool) -> Void) throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("Columns-\(UUID().uuidString).html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        self.title = title
        self.window = window
        self.pdf = pdf
        self.done = done
        super.init()
        web.navigationDelegate = self
        web.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        if let pdf {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdf
        }
        let op = web.printOperation(with: info)
        op.jobTitle = title
        op.showsPrintPanel = pdf == nil
        op.showsProgressPanel = pdf == nil
        op.view?.frame = web.bounds
        op.runModal(for: window, delegate: self, didRun: #selector(finished(_:success:contextInfo:)), contextInfo: nil)
    }

    // AppKit may end a print (a PDF save above all) on its own thread: come back to the main thread to clean up.
    @objc nonisolated private func finished(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.cleanUp(success) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { cleanUp(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { cleanUp(false) }
    private func cleanUp(_ success: Bool) {
        try? FileManager.default.removeItem(at: file)
        done(success)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    // App Nap would throttle the file-change timer while the reader sits beside the editor.
    private let watching = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                                 reason: "Reload open Markdown files when they change")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        // Libron for the settings popover; the page loads its own copy with @font-face.
        let fonts = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Reader.all.forEach { $0.updateScroller() } }
        }
        DispatchQueue.main.async {
            guard Reader.all.isEmpty else { return }  // opened with files (from Finder, the Dock): only those
            // The files that were open when Columns quit, if the Mac keeps windows on quit (System Settings > Desktop &
            // Dock, "Close windows when quitting an application" off, or ⌥⌘Q). A first launch shows what the app does;
            // with nothing to reopen, the Open panel, as in TextEdit and Preview.
            let exists = { (p: String) in FileManager.default.fileExists(atPath: p) }
            let groups = Prefs.openGroups.map { ($0["files"] as? [String] ?? []).filter(exists) }.filter { !$0.isEmpty }
            let open = Prefs.openFiles.filter { exists($0.path) }
            if !groups.isEmpty {
                for (g, files) in zip(Prefs.openGroups.filter { !(($0["files"] as? [String] ?? []).filter(exists)).isEmpty }, groups) {
                    let host = Reader.reader(showing: URL(fileURLWithPath: files[0]), newWindow: true).window
                    files.dropFirst().forEach { _ = Reader.reader(showing: URL(fileURLWithPath: $0), into: host) }
                    let selected = min(g["selected"] as? Int ?? 0, files.count - 1)
                    Reader.all.first { $0.url.path == files[selected] }?.window.makeKeyAndOrderFront(nil)
                }
            } else if !open.isEmpty { open.forEach(Reader.show) }
            else if !Prefs.launchedBefore, let welcome = Reader.welcome { Reader.show(welcome) }
            else { self.openDocument(nil) }
            Prefs.launchedBefore = true
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach(Reader.show) }
    // Like other Mac document apps, Columns stays open when its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    // A click on the Dock icon brings back a minimized window, or with no window at all shows the Open panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if Reader.all.isEmpty { openDocument(nil); return false }
        return true
    }
    // Whether this quit keeps the windows for the next launch: the Mac's setting, the other way round with ⌥⌘Q.
    static var keepsWindows: Bool { UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows") }
    private var invertKeep = false
    @objc func quitInverted(_ sender: Any?) { invertKeep = true; NSApp.terminate(sender) }
    static var quitting = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { AppDelegate.quitting = true; return .terminateNow }
    // The windows as they were, back to front, each with its tabs in order and the one that was showing.
    func applicationWillTerminate(_ notification: Notification) {
        let keep = AppDelegate.keepsWindows != invertKeep
        var seen = Set<ObjectIdentifier>(), groups: [[String: Any]] = []
        for w in NSApp.orderedWindows.reversed() where !seen.contains(ObjectIdentifier(w)) {
            let tabs = w.tabbedWindows ?? [w]
            tabs.forEach { seen.insert(ObjectIdentifier($0)) }
            let readers = tabs.compactMap { t in Reader.all.first { $0.window === t } }.filter { $0.url != Reader.welcome }
            guard !readers.isEmpty else { continue }
            let selected = readers.firstIndex { $0.window === (w.tabGroup?.selectedWindow ?? w) } ?? 0
            groups.append(["files": readers.map(\.url.path), "selected": selected])
        }
        Prefs.openGroups = keep ? groups : []
        Prefs.openFiles = keep ? groups.flatMap { ($0["files"] as? [String] ?? []).map { URL(fileURLWithPath: $0) } } : []
    }

    static func openPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("net.daringfireball.markdown"), .plainText].compactMap { $0 }
        panel.allowsMultipleSelection = true
        return panel
    }
    // Open…: as tabs of the window in front. New Window: a window of its own, the other files as its tabs.
    @objc func openDocument(_ sender: Any?) {
        let panel = AppDelegate.openPanel()
        if panel.runModal() == .OK { panel.urls.forEach(Reader.show) }
    }
    @objc func newWindow(_ sender: Any?) {
        let panel = AppDelegate.openPanel()
        guard panel.runModal() == .OK, let first = panel.urls.first else { return }
        let host = Reader.reader(showing: first, newWindow: true).window
        panel.urls.dropFirst().forEach { _ = Reader.reader(showing: $0, into: host) }
    }
    @objc func reopenClosedTab(_ sender: Any?) {
        while let url = Reader.closed.popLast() {
            if FileManager.default.fileExists(atPath: url.path) { Reader.show(url); return }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func showAbout(_ sender: Any?) {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let credits = NSAttributedString(string: "Lightweight Markdown reader for ultrawide screens", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centred,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // The project's page and its issues: where to read the source, report a problem or ask for a feature.
    static let project = URL(string: "https://github.com/ojasviyadav/columns")!
    @objc func showProject(_ sender: Any?) { NSWorkspace.shared.open(AppDelegate.project) }
    @objc func sendFeedback(_ sender: Any?) { NSWorkspace.shared.open(AppDelegate.project.appendingPathComponent("issues/new")) }
    @objc func showWelcome(_ sender: Any?) { if let welcome = Reader.welcome { Reader.show(welcome) } }
    @objc func showShortcuts(_ sender: Any?) { if let welcome = Reader.welcome { Reader.reader(showing: welcome).call("jump", "keyboard-shortcuts", true) } }

    private var sectionsMenu: NSMenu?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === sectionsMenu { return fillSections(menu) }
        fillRecent(menu)
    }

    // Go > Go to Section: the document's headings (levels 1 to 3), indented by level.
    private func fillSections(_ menu: NSMenu) {
        let headings = Reader.current?.outline ?? []
        for h in headings {
            guard let id = h["id"] as? String, let title = h["title"] as? String else { continue }
            let short = title.count > 60 ? String(title.prefix(59)) + "…" : title
            let item = NSMenuItem(title: short, action: #selector(Reader.goToSection(_:)), keyEquivalent: "")
            item.representedObject = id
            item.indentationLevel = max(0, (h["level"] as? Int ?? 1) - 1)
            item.state = id == Reader.current?.state["section"] as? String ? .on : .off  // the section being read
            menu.addItem(item)
        }
        if headings.isEmpty { menu.addItem(NSMenuItem(title: "No Sections", action: nil, keyEquivalent: "")) }
    }

    // File > Open Recent, kept by the system's recent-documents list (the Dock menu shows the same files).
    private func fillRecent(_ menu: NSMenu) {
        let recent = NSDocumentController.shared.recentDocumentURLs
        for url in recent {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !recent.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: recent.isEmpty ? nil : #selector(clearRecent(_:)), keyEquivalent: "")
        menu.addItem(clear)
    }
    @objc func openRecent(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { Reader.show(url) } }
    @objc func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(nil) }

    @objc func reloadFile(_ sender: Any?) { Reader.current?.reload() }
    @objc func biggerText(_ sender: Any?) { ReadingSettings.shared.resize(1) }
    @objc func smallerText(_ sender: Any?) { ReadingSettings.shared.resize(-1) }
    @objc func actualSizeText(_ sender: Any?) { ReadingSettings.shared.fontSize = ReadingSettings.defaultFontSize }
    @objc func setColumns(_ sender: NSMenuItem) { ReadingSettings.shared.columns = sender.tag }
    @objc func toggleBoldStarts(_ sender: Any?) { ReadingSettings.shared.boldStarts.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setColumns(_:)) { item.state = item.tag == ReadingSettings.shared.columns ? .on : .off }
        if item.action == #selector(toggleBoldStarts(_:)) { item.state = ReadingSettings.shared.boldStarts ? .on : .off }
        switch item.action {
        case #selector(biggerText(_:)): return ReadingSettings.shared.fontSize < ReadingSettings.maxFontSize
        case #selector(smallerText(_:)): return ReadingSettings.shared.fontSize > ReadingSettings.minFontSize
        case #selector(actualSizeText(_:)): return ReadingSettings.shared.fontSize != ReadingSettings.defaultFontSize
        case #selector(reloadFile(_:)): return Reader.current != nil
        default: return true
        }
    }

    private func makeMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }
        func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(key)!)) }
        // Hold ⌥ in the Columns menu: Quit and Keep Windows, or Quit and Close All Windows, the other way round from the Mac's setting.
        let quitOther = item(AppDelegate.keepsWindows ? "Quit and Close All Windows" : "Quit and Keep Windows", #selector(quitInverted(_:)), "q", [.command, .option])
        quitOther.isAlternate = true
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            return top
        }
        let zoomInAlias = item("Bigger", #selector(biggerText(_:)), "=")  // Cmd+= is the unshifted Cmd++ key
        zoomInAlias.isHidden = true
        zoomInAlias.allowsKeyEquivalentWhenHidden = true
        // Tabs: the next and previous one with ⇧⌘] and ⇧⌘[ (as in Safari and Chrome) or ⌃⇥ and ⌃⇧⇥.
        let nextTabAlias = item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control])
        let previousTabAlias = item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift])
        for alias in [nextTabAlias, previousTabAlias] { alias.isHidden = true; alias.allowsKeyEquivalentWhenHidden = true }
        let window = menu("Window", [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                                     item("Zoom", #selector(NSWindow.performZoom(_:))), .separator(),
                                     item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift]),
                                     item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift]),
                                     nextTabAlias, previousTabAlias,
                                     item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))),
                                     item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))), .separator(),
                                     item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))])
        NSApp.windowsMenu = window.submenu
        let services = menu("Services", [])
        NSApp.servicesMenu = services.submenu
        let recent = menu("Open Recent", [])
        recent.submenu?.delegate = self
        let sections = menu("Go to Section", [])
        sections.submenu?.delegate = self
        sectionsMenu = sections.submenu
        let go = menu("Go", [item("Back", #selector(Reader.backInDocument(_:)), "["),
                             item("Forward", #selector(Reader.forwardInDocument(_:)), "]"), .separator(),
                             item("Beginning", #selector(Reader.goBeginning(_:)), arrow(NSUpArrowFunctionKey)),
                             item("End", #selector(Reader.goEnd(_:)), arrow(NSDownArrowFunctionKey)), .separator(),
                             item("Previous Section", #selector(Reader.previousSection(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]),
                             item("Next Section", #selector(Reader.nextSection(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]), .separator(),
                             sections])
        let help = menu("Help", [item("Columns Help", #selector(showWelcome(_:)), "?"),
                                 item("Keyboard Shortcuts", #selector(showShortcuts(_:))), .separator(),
                                 item("Columns on GitHub", #selector(showProject(_:))),
                                 item("Send Feedback…", #selector(sendFeedback(_:)))])
        NSApp.helpMenu = help.submenu
        // ⌥⌘, opened Reading Settings before ⌘, did; it keeps working.
        let settingsAlias = item("Settings", #selector(Reader.showSettings(_:)), ",", [.command, .option])
        settingsAlias.isHidden = true
        settingsAlias.allowsKeyEquivalentWhenHidden = true

        let main = NSMenu()
        [menu("Columns", [item("About Columns", #selector(showAbout(_:))), .separator(),
                          item("Settings…", #selector(Reader.showSettings(_:)), ","), settingsAlias, .separator(),
                          services, .separator(),
                          item("Hide Columns", #selector(NSApplication.hide(_:)), "h"),
                          item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                          item("Show All", #selector(NSApplication.unhideAllApplications(_:))), .separator(),
                          item("Quit Columns", #selector(NSApplication.terminate(_:)), "q"), quitOther]),
         menu("File", [item("New Tab…", #selector(Reader.newWindowForTab(_:)), "t"),
                       item("New Window…", #selector(newWindow(_:)), "n"),
                       item("Open…", #selector(openDocument(_:)), "o"), recent, .separator(),
                       item("Reopen Closed Tab", #selector(reopenClosedTab(_:)), "t", [.command, .shift]), .separator(),
                       item("Close", #selector(NSWindow.performClose(_:)), "w"),
                       item("Close Window", #selector(Reader.closeWindow(_:)), "w", [.command, .shift]), .separator(),
                       item("Reload", #selector(reloadFile(_:)), "r"),
                       item("Show in Finder", #selector(Reader.showInFinder(_:)), "r", [.command, .shift]), .separator(),
                       item("Export as PDF…", #selector(Reader.exportPDF(_:))), .separator(),
                       item("Page Setup…", #selector(NSApplication.runPageLayout(_:)), "p", [.command, .shift]),
                       item("Print…", #selector(Reader.printReader(_:)), "p")]),
         menu("Edit", [item("Undo", Selector(("undo:")), "z"),
                       item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                       item("Cut", #selector(NSText.cut(_:)), "x"),
                       item("Copy", #selector(NSText.copy(_:)), "c"),
                       item("Paste", #selector(NSText.paste(_:)), "v"),
                       item("Select All", #selector(NSText.selectAll(_:)), "a"), .separator(),
                       menu("Find", [item("Find…", #selector(Reader.showFind(_:)), "f"),
                                     item("Find Next", #selector(Reader.findNextMatch(_:)), "g"),
                                     item("Find Previous", #selector(Reader.findPreviousMatch(_:)), "g", [.command, .shift]),
                                     item("Use Selection for Find", #selector(Reader.useSelectionForFind(_:)), "e")])]),
         menu("View", [item("Bigger Text", #selector(biggerText(_:)), "+"), zoomInAlias,
                       item("Smaller Text", #selector(smallerText(_:)), "-"),
                       item("Actual Size", #selector(actualSizeText(_:)), "0"), .separator()]
                      + (1...Prefs.maxColumns).map { item($0 == 1 ? "1 Column" : "\($0) Columns", #selector(setColumns(_:)), "\($0)", tag: $0) }
                      + [.separator(), item("Bold Word Starts", #selector(toggleBoldStarts(_:))),
                         .separator(),
                         item("Collapse All Sections", #selector(Reader.collapseAll(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option, .shift]),
                         item("Expand All Sections", #selector(Reader.expandAll(_:)), arrow(NSRightArrowFunctionKey), [.command, .option, .shift]),
                         .separator(),
                         item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])]),
         go, window, help].forEach(main.addItem)
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
