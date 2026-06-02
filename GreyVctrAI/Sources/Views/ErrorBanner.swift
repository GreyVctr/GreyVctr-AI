import SwiftUI

/// A reusable error banner displayed inline in views.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// An error banner with an actionable button (e.g., "Reload Engine").
struct ActionableErrorBanner: View {
    let message: String
    let actionLabel: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            Button {
                action()
            } label: {
                Label(actionLabel, systemImage: systemImage)
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Copy Button

/// A cross-platform copy-to-clipboard button.
struct CopyButton: View {
    let text: String

    var body: some View {
        Button {
            copyToClipboard(text)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .accessibilityLabel("Copy output")
    }
}

/// Copies text to the system clipboard, handling platform differences.
func copyToClipboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

#if DEBUG
#Preview {
    ErrorBanner(message: "Something went wrong. Please try again.")
        .padding()
}
#endif
