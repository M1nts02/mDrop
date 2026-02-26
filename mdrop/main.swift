//
//  main.swift
//  mdrop
//
//  Created by M1nts02 on 2026/2/26.
//

import Cocoa
import Combine

// MARK: - Notification Names

extension Notification.Name {
    static let selectAllItems = Notification.Name("selectAllItems")
    static let deleteSelectedItems = Notification.Name("deleteSelectedItems")
}

// MARK: - Array Safe Access

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Drop Item Model

struct DropItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    let icon: NSImage
    let fileSize: Int64?

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        self.icon = NSWorkspace.shared.icon(forFile: url.path)

        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        self.fileSize = resourceValues?.fileSize.map(Int64.init)
    }
}

// MARK: - View Model

class DropViewModel: ObservableObject {
    @Published var items: [DropItem] = []

    var totalSize: Int64 {
        items.compactMap { $0.fileSize }.reduce(0, +)
    }

    func addItem(_ url: URL) {
        if !items.contains(where: { $0.url == url }) {
            items.append(DropItem(url: url))
        }
    }

    func removeItems(_ itemsToRemove: [DropItem]) {
        let idsToRemove = Set(itemsToRemove.map(\.id))
        items.removeAll { idsToRemove.contains($0.id) }
    }

    func clearAll() {
        items.removeAll()
    }

    func formatTotalSize() -> String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

// MARK: - Main Entry Point

autoreleasepool {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var viewModel: DropViewModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewModel = DropViewModel()
        setupMenu()
        createWindow()
        setupKeyHandlers()

        // Process command line arguments
        for arg in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: arg)
            if FileManager.default.fileExists(atPath: url.path) {
                viewModel.addItem(url)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(NSMenuItem(
            title: "Quit mDrop",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = NSMenu(title: "Edit")
        mainMenu.addItem(editMenuItem)

        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: #selector(selectAllMenuAction),
            keyEquivalent: "a"
        )
        selectAllItem.target = self
        editMenuItem.submenu?.addItem(selectAllItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    @objc private func selectAllMenuAction() {
        NotificationCenter.default.post(name: .selectAllItems, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func createWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "mDrop"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.minSize = NSSize(width: 280, height: 200)
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.center()

        let contentView = DropContentView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 320, height: 400))
        contentView.viewModel = viewModel
        contentView.autoresizingMask = [.width, .height]

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
    }

    private func setupKeyHandlers() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: // ESC
                NSApplication.shared.terminate(nil)
                return nil
            case 51, 117: // Backspace or Delete
                NotificationCenter.default.post(name: .deleteSelectedItems, object: nil)
                return nil
            default:
                return event
            }
        }
    }
}

// MARK: - Drop Content View

class DropContentView: NSView {
    weak var viewModel: DropViewModel? {
        didSet {
            setupViewModelObservation()
            tableView.viewModel = viewModel
            updateUI()
        }
    }

    private var headerView: NSView!
    private var scrollView: NSScrollView!
    private var tableView: FileListTableView!
    private var statusView: NSView!
    private var dragOverlay: NSView?
    private var cancellables = Set<AnyCancellable>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        registerForDraggedTypes([.fileURL, .URL])

        NotificationCenter.default.addObserver(
            self, selector: #selector(selectAllItems),
            name: .selectAllItems, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(deleteSelectedItems),
            name: .deleteSelectedItems, object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        headerView = createHeaderView()
        addSubview(headerView)

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        tableView = FileListTableView()
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.unregisterDraggedTypes()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.width = bounds.width
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        addSubview(scrollView)

        statusView = createStatusView()
        statusView.isHidden = true
        addSubview(statusView)

        headerView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        statusView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 40),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusView.topAnchor),

            statusView.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusView.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func setupViewModelObservation() {
        guard let viewModel = viewModel else { return }
        viewModel.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateUI() }
            .store(in: &cancellables)
    }

    private func createHeaderView() -> NSView {
        let container = NSView()

        let closeButton = NSButton(title: "", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .circular
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        closeButton.contentTintColor = .systemRed

        let titleLabel = NSTextField(labelWithString: "mDrop")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .center

        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.tag = 100

        let clearButton = NSButton(title: "", target: self, action: #selector(clearAll))
        clearButton.bezelStyle = .texturedRounded
        clearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.tag = 101
        clearButton.isHidden = true

        container.addSubview(closeButton)
        container.addSubview(titleLabel)
        container.addSubview(countLabel)
        container.addSubview(clearButton)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 24),
            clearButton.heightAnchor.constraint(equalToConstant: 24),

            countLabel.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            countLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    @objc private func closeWindow() {
        NSApplication.shared.terminate(nil)
    }

    private func createStatusView() -> NSView {
        let container = NSView()

        let sizeLabel = NSTextField(labelWithString: "")
        sizeLabel.font = NSFont.systemFont(ofSize: 11)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.tag = 200

        container.addSubview(sizeLabel)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            sizeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            sizeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    private func updateUI() {
        tableView.reloadData()

        let count = viewModel?.items.count ?? 0
        (headerView.viewWithTag(100) as? NSTextField)?.stringValue = count > 0 ? "\(count)" : ""
        (headerView.viewWithTag(101) as? NSButton)?.isHidden = count == 0
        (statusView.viewWithTag(200) as? NSTextField)?.stringValue = viewModel?.formatTotalSize() ?? ""
        statusView.isHidden = count == 0
    }

    @objc private func clearAll() {
        viewModel?.clearAll()
    }

    @objc private func selectAllItems() {
        let count = viewModel?.items.count ?? 0
        if count > 0 {
            tableView.selectRowIndexes(IndexSet(0..<count), byExtendingSelection: false)
        }
    }

    @objc private func deleteSelectedItems() {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty, let viewModel = viewModel else { return }

        let itemsToRemove = selectedRows.compactMap { viewModel.items[safe: $0] }
        if !itemsToRemove.isEmpty {
            tableView.selectRowIndexes(IndexSet(), byExtendingSelection: false)
            viewModel.removeItems(itemsToRemove)
        }
    }

    // MARK: - Drag & Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        let canAccept = pasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
            || pasteboard.types?.contains(.fileURL) == true

        if canAccept {
            showDragOverlay()
            return .copy
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDragOverlay()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDragOverlay()

        let pasteboard = sender.draggingPasteboard

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            urls.forEach { viewModel?.addItem($0) }
            return true
        }

        if let stringPaths = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] {
            stringPaths
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .forEach { viewModel?.addItem($0) }
            return true
        }

        if let propertyList = pasteboard.propertyList(forType: .fileURL) as? Data,
           let url = URL(dataRepresentation: propertyList, relativeTo: nil) {
            viewModel?.addItem(url)
            return true
        }

        return false
    }

    private func showDragOverlay() {
        guard dragOverlay == nil else { return }

        let overlay = NSView(frame: bounds.insetBy(dx: 4, dy: 4))
        overlay.wantsLayer = true
        overlay.layer?.borderWidth = 2
        overlay.layer?.borderColor = NSColor.systemBlue.cgColor
        overlay.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.1).cgColor
        overlay.layer?.cornerRadius = 8
        overlay.autoresizingMask = [.width, .height]

        addSubview(overlay)
        dragOverlay = overlay
    }

    private func hideDragOverlay() {
        dragOverlay?.removeFromSuperview()
        dragOverlay = nil
    }
}

// MARK: - TableView DataSource & Delegate

extension DropContentView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel?.items.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let item = viewModel?.items[safe: row] else { return nil }
        let cell = FileTableCellView()
        cell.configure(with: item)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        44
    }
}

// MARK: - File Table Cell

class FileTableCellView: NSTableCellView {
    private let iconImageView = NSImageView()
    private let nameLabel = NSTextField()
    private let sizeLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconImageView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.backgroundColor = .clear
        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(nameLabel)

        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.isEditable = false
        sizeLabel.isBordered = false
        sizeLabel.backgroundColor = .clear
        sizeLabel.font = NSFont.systemFont(ofSize: 10)
        sizeLabel.textColor = .secondaryLabelColor
        addSubview(sizeLabel)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 32),
            iconImageView.heightAnchor.constraint(equalToConstant: 32),

            nameLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            nameLabel.heightAnchor.constraint(equalToConstant: 17),

            sizeLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            sizeLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            sizeLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            sizeLabel.heightAnchor.constraint(equalToConstant: 13)
        ])
    }

    func configure(with item: DropItem) {
        iconImageView.image = item.icon
        nameLabel.stringValue = item.name
        sizeLabel.stringValue = item.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
    }
}

// MARK: - Custom TableView with Drag Support

class FileListTableView: NSTableView {
    weak var viewModel: DropViewModel?
    private var draggedItems: [DropItem] = []
    private var dragSource: DragSource?
    private var mouseDownLocation: NSPoint = .zero
    private var isDragging = false

    override var acceptsFirstResponder: Bool { true }

    func beginDrag(with event: NSEvent, items: [DropItem]) {
        guard !items.isEmpty, draggedItems.isEmpty else { return }

        draggedItems = items
        isDragging = true

        let draggingItems = items.map { item -> NSDraggingItem in
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(item.url.dataRepresentation, forType: .fileURL)
            pasteboardItem.setString(item.url.path, forType: .string)

            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let icon = item.icon
            draggingItem.setDraggingFrame(
                NSRect(origin: NSPoint(x: -icon.size.width/2, y: -icon.size.height/2), size: icon.size),
                contents: icon
            )
            return draggingItem
        }

        dragSource = DragSource { [weak self] operation in
            self?.handleDragEnd(operation: operation)
        }

        let session = beginDraggingSession(with: draggingItems, event: event, source: dragSource!)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private func handleDragEnd(operation: NSDragOperation) {
        isDragging = false

        if operation.rawValue != 0 && !draggedItems.isEmpty {
            let itemsToRemove = draggedItems
            selectRowIndexes(IndexSet(), byExtendingSelection: false)
            draggedItems = []

            DispatchQueue.main.async { [weak self] in
                if let contentView = self?.superview?.superview?.superview as? DropContentView {
                    itemsToRemove.forEach { item in
                        if let vm = contentView.viewModel {
                            vm.removeItems([item])
                        }
                    }
                }
            }
        } else {
            draggedItems = []
        }

        dragSource = nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        isDragging = false

        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        guard clickedRow >= 0 && clickedRow < numberOfRows else { return }

        let modifierFlags = event.modifierFlags

        if modifierFlags.contains(.command) {
            if isRowSelected(clickedRow) {
                deselectRow(clickedRow)
            } else {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: true)
            }
        } else if modifierFlags.contains(.shift) {
            let lastRow = selectedRowIndexes.max() ?? clickedRow
            let range = min(lastRow, clickedRow)...max(lastRow, clickedRow)
            selectRowIndexes(IndexSet(range), byExtendingSelection: false)
        } else if !isRowSelected(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, draggedItems.isEmpty else { return }

        let distance = hypot(event.locationInWindow.x - mouseDownLocation.x,
                            event.locationInWindow.y - mouseDownLocation.y)
        guard distance > 5 else { return }

        let selectedRows = selectedRowIndexes
        guard !selectedRows.isEmpty else { return }

        let itemsToDrag = selectedRows.compactMap { row -> DropItem? in
            guard let contentView = superview?.superview?.superview as? DropContentView else { return nil }
            return contentView.viewModel?.items[safe: row]
        }

        if !itemsToDrag.isEmpty {
            beginDrag(with: event, items: itemsToDrag)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false

        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        if clickedRow < 0 || clickedRow >= numberOfRows {
            selectRowIndexes(IndexSet(), byExtendingSelection: false)
        } else {
            let modifierFlags = event.modifierFlags
            let noModifiers = !modifierFlags.contains(.command) && !modifierFlags.contains(.shift)

            if noModifiers && !isDragging {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)

        if row >= 0 && row < numberOfRows && !isRowSelected(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        super.rightMouseDown(with: event)
    }
}

// MARK: - Drag Source

class DragSource: NSObject, NSDraggingSource {
    private let completion: (NSDragOperation) -> Void

    init(completion: @escaping (NSDragOperation) -> Void) {
        self.completion = completion
        super.init()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        completion(operation)
    }
}
