import AppKit

/// Compact native Settings surface for HAZ.
///
/// This window intentionally exposes only preferences that already exist in
/// the product. Changes apply immediately through HAZPreferences; there is no
/// second settings state and no explicit Save action.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let preferences: HAZPreferences
    private var preferenceObservation: UUID?

    private let activationControl = NSSegmentedControl(frame: .zero)
    private let zoomControl = NSSegmentedControl(frame: .zero)
    private let sizeControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displaysControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dimmingControl = NSPopUpButton(frame: .zero, pullsDown: false)

    private let sizeValues: [CGFloat] = [100, 140, 200]
    private let dimmingValues: [CGFloat] = [0.55, 0.75, 0.88]

    init(preferences: HAZPreferences) {
        self.preferences = preferences

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = settingsLocalized("settings.title", fallback: "Ajustes")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]

        super.init(window: window)

        configureControls()
        window.contentView = makeContentView()
        window.center()

        preferenceObservation = preferences.observe { [weak self] _ in
            self?.syncFromPreferences()
        }
        syncFromPreferences()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureControls() {
        activationControl.segmentCount = 2
        activationControl.setLabel(settingsLocalized("activation.hold", fallback: "Mantener"), forSegment: 0)
        activationControl.setLabel(settingsLocalized("activation.toggle", fallback: "Alternar"), forSegment: 1)
        activationControl.trackingMode = .selectOne
        activationControl.target = self
        activationControl.action = #selector(activationChanged(_:))
        activationControl.setAccessibilityLabel(settingsLocalized("menu.activation", fallback: "Activación"))

        zoomControl.segmentCount = 3
        zoomControl.setLabel("x1", forSegment: 0)
        zoomControl.setLabel("x2", forSegment: 1)
        zoomControl.setLabel("x3", forSegment: 2)
        zoomControl.trackingMode = .selectOne
        zoomControl.target = self
        zoomControl.action = #selector(zoomChanged(_:))
        zoomControl.setAccessibilityLabel(settingsLocalized("settings.zoomLevel", fallback: "Nivel"))

        sizeControl.addItems(withTitles: [
            settingsLocalized("size.small", fallback: "Pequeño"),
            settingsLocalized("size.medium", fallback: "Medio"),
            settingsLocalized("size.large", fallback: "Grande")
        ])
        sizeControl.target = self
        sizeControl.action = #selector(sizeChanged(_:))
        sizeControl.setAccessibilityLabel(settingsLocalized("menu.size", fallback: "Tamaño"))

        displaysControl.addItems(withTitles: [
            settingsLocalized("displays.current", fallback: "Solo pantalla del cursor"),
            settingsLocalized("displays.all", fallback: "Oscurecer todas")
        ])
        displaysControl.target = self
        displaysControl.action = #selector(displaysChanged(_:))
        displaysControl.setAccessibilityLabel(settingsLocalized("menu.displays", fallback: "Pantallas"))

        dimmingControl.addItems(withTitles: [
            settingsLocalized("dimming.soft", fallback: "Suave · 55%"),
            settingsLocalized("dimming.medium", fallback: "Media · 75%"),
            settingsLocalized("dimming.high", fallback: "Alta · 88%")
        ])
        dimmingControl.target = self
        dimmingControl.action = #selector(dimmingChanged(_:))
        dimmingControl.setAccessibilityLabel(settingsLocalized("menu.dimming", fallback: "Oscurecimiento"))

        activationControl.widthAnchor.constraint(equalToConstant: 230).isActive = true
        zoomControl.widthAnchor.constraint(equalToConstant: 230).isActive = true
        sizeControl.widthAnchor.constraint(equalToConstant: 230).isActive = true
        displaysControl.widthAnchor.constraint(equalToConstant: 230).isActive = true
        dimmingControl.widthAnchor.constraint(equalToConstant: 230).isActive = true
    }

    private func makeContentView() -> NSView {
        let contentView = NSView(frame: .zero)

        let magnifierTitle = sectionTitle(
            settingsLocalized("settings.section.magnifier", fallback: "Lupa")
        )
        let sharedTitle = sectionTitle(
            settingsLocalized("settings.section.shared", fallback: "Lupa y Área")
        )

        let activationRow = formRow(
            settingsLocalized("menu.activation", fallback: "Activación"),
            control: activationControl
        )
        let zoomRow = formRow(
            settingsLocalized("settings.zoomLevel", fallback: "Nivel"),
            control: zoomControl
        )
        let sizeRow = formRow(
            settingsLocalized("menu.size", fallback: "Tamaño"),
            control: sizeControl
        )
        let displaysRow = formRow(
            settingsLocalized("menu.displays", fallback: "Pantallas"),
            control: displaysControl
        )
        let dimmingRow = formRow(
            settingsLocalized("menu.dimming", fallback: "Oscurecimiento"),
            control: dimmingControl
        )

        let root = NSStackView(views: [
            magnifierTitle,
            activationRow,
            zoomRow,
            sizeRow,
            displaysRow,
            sharedTitle,
            dimmingRow
        ])

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.setCustomSpacing(16, after: magnifierTitle)
        root.setCustomSpacing(22, after: displaysRow)
        root.setCustomSpacing(16, after: sharedTitle)
        root.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24)
        ])

        return contentView
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    private func formRow(_ title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        return row
    }

    private func syncFromPreferences() {
        activationControl.selectedSegment = preferences.activationMode == .hold ? 0 : 1
        zoomControl.selectedSegment = preferences.zoomLevel.index

        if let index = sizeValues.firstIndex(where: { abs($0 - preferences.circleRadius) < 0.5 }) {
            sizeControl.selectItem(at: index)
        }

        displaysControl.selectItem(at: preferences.displayScope == .current ? 0 : 1)

        if let index = dimmingValues.firstIndex(where: { abs($0 - preferences.dimAlpha) < 0.005 }) {
            dimmingControl.selectItem(at: index)
        }
    }

    @objc private func activationChanged(_ sender: NSSegmentedControl) {
        preferences.activationMode = sender.selectedSegment == 1 ? .toggle : .hold
    }

    @objc private func zoomChanged(_ sender: NSSegmentedControl) {
        preferences.zoomLevel = HAZPreferences.ZoomLevel.at(index: sender.selectedSegment)
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        guard sizeValues.indices.contains(sender.indexOfSelectedItem) else { return }
        preferences.circleRadius = sizeValues[sender.indexOfSelectedItem]
    }

    @objc private func displaysChanged(_ sender: NSPopUpButton) {
        preferences.displayScope = sender.indexOfSelectedItem == 1 ? .all : .current
    }

    @objc private func dimmingChanged(_ sender: NSPopUpButton) {
        guard dimmingValues.indices.contains(sender.indexOfSelectedItem) else { return }
        preferences.dimAlpha = dimmingValues[sender.indexOfSelectedItem]
    }
}

private func settingsLocalized(_ key: String, fallback: String) -> String {
    NSLocalizedString(
        key,
        tableName: "Localizable",
        bundle: .main,
        value: fallback,
        comment: ""
    )
}
