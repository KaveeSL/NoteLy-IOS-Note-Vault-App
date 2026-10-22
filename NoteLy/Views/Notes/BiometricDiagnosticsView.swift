import LocalAuthentication
import SwiftUI

/// Face ID status for the private area. It does not appear on the notes side.
struct BiometricDiagnosticsView: View {
    var body: some View {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        Form {
            LabeledContent("Biometry", value: name(context.biometryType))
            LabeledContent("Can evaluate", value: canEvaluate ? "Yes" : "No")
            LabeledContent("Last error code", value: error.map { String($0.code) } ?? "None")
        }
        .navigationTitle("Face ID Diagnostics")
    }

    private func name(_ type: LABiometryType) -> String {
        switch type {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none: return "None"
        @unknown default: return "Unknown"
        }
    }
}
