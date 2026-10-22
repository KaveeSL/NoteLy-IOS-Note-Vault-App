import SwiftUI
import UIKit

/// Plain cover shown over private content in the app switcher and while the screen is captured.
/// It uses the notes icon on purpose so the snapshot does not advertise a separate locked area.
struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "note.text")
                    .font(.system(size: 44, weight: .regular))
                    .accessibilityHidden(true)
                Text("NoteLy")
                    .font(.title2.weight(.semibold))
            }
            .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("NoteLy")
    }
}

enum CaptureDetector {
    static var isCaptured: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.screen.isCaptured }
    }
}

/// A window above the app's content. Shown synchronously when the scene resigns active
/// so the app switcher is less likely to snapshot private notes. It is not made key,
/// so a system authentication sheet can stay in front.
final class PrivacyShieldWindow {
    static let shared = PrivacyShieldWindow()
    private var window: UIWindow?

    private init() {}

    func show() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState != .unattached }) ?? scenes.first else {
            return
        }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .systemBackground
        let controller = UIHostingController(rootView: PrivacyShieldView())
        controller.view.backgroundColor = .systemBackground
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }
}

/// Resets the inactivity timer on any touch without stealing the touch from buttons and lists.
struct IdleTouchMonitor: UIViewRepresentable {
    var onInteraction: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onInteraction = onInteraction
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(from: uiView)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onInteraction: () -> Void = {}
        private weak var installedOn: UIWindow?
        private var recognizer: IdleGestureRecognizer?

        func installIfNeeded(from view: UIView) {
            guard let window = view.window else { return }
            if installedOn === window, recognizer != nil { return }
            uninstall()
            let recognizer = IdleGestureRecognizer()
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            recognizer.onTouch = { [weak self] in
                self?.onInteraction()
            }
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
            installedOn = window
        }

        func uninstall() {
            if let recognizer {
                installedOn?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            installedOn = nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// Turns off autocorrect on the visible search field without using `UITextField.appearance`.
/// The appearance proxy crashes on iOS 27 when the search bar is added to the navigation bar,
/// which closed the app as soon as Notes was opened.
struct SearchFieldTraits: UIViewRepresentable {
    var onSubmit: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSubmit = onSubmit
        DispatchQueue.main.async {
            guard let window = uiView.window else { return }
            Self.apply(in: window, coordinator: context.coordinator)
        }
    }

    private static func apply(in view: UIView, coordinator: Coordinator) {
        if let field = view as? UISearchTextField {
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.smartDashesType = .no
            field.smartQuotesType = .no
            field.smartInsertDeleteType = .no
            field.textContentType = nil
            field.returnKeyType = .search
            coordinator.hook(field)
        }
        for subview in view.subviews {
            apply(in: subview, coordinator: coordinator)
        }
    }

    final class Coordinator: NSObject {
        var onSubmit: (String) -> Void = { _ in }
        private var hooked = Set<ObjectIdentifier>()

        func hook(_ field: UISearchTextField) {
            let id = ObjectIdentifier(field)
            guard hooked.insert(id).inserted else { return }
            field.addTarget(self, action: #selector(submitted(_:)), for: .editingDidEndOnExit)
        }

        @objc func submitted(_ sender: UISearchTextField) {
            onSubmit(sender.text ?? "")
        }
    }
}

final class IdleGestureRecognizer: UIGestureRecognizer {
    var onTouch: () -> Void = {}

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        onTouch()
        state = .failed
    }
}

