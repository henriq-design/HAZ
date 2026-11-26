import AppKit

/// First-run product introduction for HAZ.
///
/// The flow deliberately teaches only the two core actions and explains screen
/// capture before asking macOS for access. Permission is always user-initiated
/// and goes through the ScreenCapturePermission instance owned by AppDelegate.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private enum Step {
        case introduction
        case permission
    }

    private let isScreenCaptureGranted: () -> Bool
    private let requestScreenCaptureAccess: () -> Bool
    private let openScreenCaptureSettings: () -> Void
    private let onComplete: () -> Void

    private let contentStack = NSStackView()
    private let secondaryButton = NSButton()
    private let primaryButton = NSButton()
    private var step: Step = .introduction
    private var didAttemptPermission = false
    private var didComplete = false

    init(
        isScreenCaptureGranted: @escaping () -> Bool,
        requestScreenCaptureAccess: @escaping () -> Bool,
        openScreenCaptureSettings: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.isScreenCaptureGranted = isScreenCaptureGranted
        self.requestScreenCaptureAccess = requestScreenCaptureAccess
        self.openScreenCaptureSettings = openScreenCaptureSettings
        self.onComplete = onComplete

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = onboardingLocalized("onboarding.windowTitle", fallback: "Bienvenido a HAZ")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]

        super.init(window: window)

        window.delegate = self
        window.contentView = makeRootView()
        window.center()
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard step == .permission else { return }
        render()
    }

    func windowWillClose(_ notification: Notification) {
        completeIfNeeded()
    }

    private func makeRootView() -> NSView {
        let rootView = NSView(frame: .zero)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        secondaryButton.bezelStyle = .rounded
        secondaryButton.target = self

        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self

        let buttonRow = NSStackView(views: [secondaryButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(contentStack)
        rootView.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 34),
            contentStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 38),
            contentStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -38),

            buttonRow.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -30),
            buttonRow.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -26),
            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor, constant: 24)
        ])

        return rootView
    }

    private func render() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        switch step {
        case .introduction:
            renderIntroduction()
        case .permission:
            renderPermission()
        }
    }

    private func renderIntroduction() {
        contentStack.addArrangedSubview(stepLabel(
            onboardingLocalized("onboarding.step1", fallback: "1 de 2")
        ))
        contentStack.addArrangedSubview(titleLabel(
            onboardingLocalized("onboarding.intro.title", fallback: "Foco donde importa.")
        ))
        contentStack.addArrangedSubview(bodyLabel(
            onboardingLocalized(
                "onboarding.intro.body",
                fallback: "HAZ te ayuda a dirigir y mantener la atención sobre interfaces sin modificarlas."
            )
        ))
        contentStack.setCustomSpacing(24, after: contentStack.arrangedSubviews.last!)

        contentStack.addArrangedSubview(shortcutRow(
            title: onboardingLocalized("onboarding.magnifier.title", fallback: "Lupa"),
            body: onboardingLocalized(
                "onboarding.magnifier.body",
                fallback: "Amplía lo que estás señalando sin perder el contexto."
            ),
            shortcut: "⌃⌥F"
        ))
        contentStack.addArrangedSubview(shortcutRow(
            title: onboardingLocalized("onboarding.area.title", fallback: "Área"),
            body: onboardingLocalized(
                "onboarding.area.body",
                fallback: "Aísla una región para revisarla con calma."
            ),
            shortcut: "⌃⌥A"
        ))

        secondaryButton.title = onboardingLocalized("onboarding.skip", fallback: "Omitir")
        secondaryButton.action = #selector(skipOnboarding(_:))
        primaryButton.title = onboardingLocalized("onboarding.continue", fallback: "Continuar")
        primaryButton.action = #selector(continueToPermission(_:))
    }

    private func renderPermission() {
        let granted = isScreenCaptureGranted()

        contentStack.addArrangedSubview(stepLabel(
            onboardingLocalized("onboarding.step2", fallback: "2 de 2")
        ))
        contentStack.addArrangedSubview(titleLabel(
            onboardingLocalized("onboarding.permission.title", fallback: "Amplía sin perder contexto.")
        ))
        contentStack.addArrangedSubview(bodyLabel(
            onboardingLocalized(
                "onboarding.permission.body",
                fallback: "Lupa y Área x2/x3 necesitan Grabación de pantalla para ampliar contenido de otras apps. HAZ solo captura mientras estas herramientas están activas. Área x1 y Guías funcionan sin este permiso."
            )
        ))
        contentStack.setCustomSpacing(22, after: contentStack.arrangedSubviews.last!)

        if granted {
            contentStack.addArrangedSubview(statusRow(
                symbolName: "checkmark.circle.fill",
                color: .systemGreen,
                text: onboardingLocalized(
                    "onboarding.permission.granted",
                    fallback: "Acceso a Grabación de pantalla concedido"
                )
            ))

            secondaryButton.isHidden = true
            primaryButton.title = onboardingLocalized("onboarding.start", fallback: "Empezar")
            primaryButton.action = #selector(finishOnboarding(_:))
            return
        }

        secondaryButton.isHidden = false

        if didAttemptPermission {
            contentStack.addArrangedSubview(statusRow(
                symbolName: "gearshape",
                color: .secondaryLabelColor,
                text: onboardingLocalized(
                    "onboarding.permission.pending",
                    fallback: "Completa el acceso en Ajustes del Sistema. HAZ puede seguir usándose con Área x1 y Guías."
                )
            ))

            secondaryButton.title = onboardingLocalized(
                "onboarding.permission.withoutAccess",
                fallback: "Empezar sin permiso"
            )
            secondaryButton.action = #selector(finishOnboarding(_:))
            primaryButton.title = onboardingLocalized(
                "onboarding.permission.openSettings",
                fallback: "Abrir Ajustes del Sistema"
            )
            primaryButton.action = #selector(openPermissionSettings(_:))
        } else {
            secondaryButton.title = onboardingLocalized("onboarding.notNow", fallback: "Ahora no")
            secondaryButton.action = #selector(finishOnboarding(_:))
            primaryButton.title = onboardingLocalized(
                "onboarding.permission.request",
                fallback: "Permitir Grabación de pantalla"
            )
            primaryButton.action = #selector(requestPermission(_:))
        }
    }

    private func titleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        return label
    }

    private func bodyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func stepLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func shortcutRow(title: String, body: String, shortcut: String) -> NSStackView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)

        let bodyField = NSTextField(wrappingLabelWithString: body)
        bodyField.font = .systemFont(ofSize: 12)
        bodyField.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleField, bodyField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let shortcutField = NSTextField(labelWithString: shortcut)
        shortcutField.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        shortcutField.alignment = .center
        shortcutField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let row = NSStackView(views: [textStack, shortcutField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.widthAnchor.constraint(equalToConstant: 464).isActive = true
        return row
    }

    private func statusRow(symbolName: String, color: NSColor, text: String) -> NSStackView {
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imageView.contentTintColor = color
        imageView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        let row = NSStackView(views: [imageView, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func continueToPermission(_ sender: Any?) {
        step = .permission
        render()
    }

    @objc private func requestPermission(_ sender: Any?) {
        didAttemptPermission = true
        _ = requestScreenCaptureAccess()
        render()
    }

    @objc private func openPermissionSettings(_ sender: Any?) {
        openScreenCaptureSettings()
    }

    @objc private func skipOnboarding(_ sender: Any?) {
        completeAndClose()
    }

    @objc private func finishOnboarding(_ sender: Any?) {
        completeAndClose()
    }

    private func completeAndClose() {
        completeIfNeeded()
        close()
    }

    private func completeIfNeeded() {
        guard !didComplete else { return }
        didComplete = true
        onComplete()
    }
}

private func onboardingLocalized(_ key: String, fallback: String) -> String {
    NSLocalizedString(
        key,
        tableName: "Localizable",
        bundle: .main,
        value: fallback,
        comment: ""
    )
}
