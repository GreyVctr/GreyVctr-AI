import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

/// Multimodal image analysis view using the official LiteRT-LM SDK.
struct AskImageView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: AskImageViewModel?
    @State private var selectedItem: PhotosPickerItem?
    @State private var showCamera = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                imagePickerSection
                promptSection
                submitButton

                if let errorMessage = viewModel?.error {
                    ErrorBanner(message: errorMessage)
                }

                if (viewModel?.isGenerating ?? false) || !(viewModel?.streamedOutput.isEmpty ?? true) {
                    outputSection
                }
            }
            .padding()
        }
        .navigationTitle("Ask Image")
        .onAppear { setupViewModel() }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraImagePicker { imageData in
                viewModel?.selectedImageData = imageData
            }
        }
        #endif
    }

    // MARK: - Setup

    private func setupViewModel() {
        guard viewModel == nil, let deps = appState.dependencies else { return }
        viewModel = AskImageViewModel(
            sessionCoordinator: deps.sessionCoordinator,
            configLoader: deps.configLoader,
            userSettings: appState.userSettings
        )
    }

    // MARK: - Subviews

    private var imagePickerSection: some View {
        VStack(spacing: 12) {
            #if os(iOS)
            if let imageData = viewModel?.selectedImageData,
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Selected image")
            }
            #endif

            HStack(spacing: 12) {
                // Camera button
                #if os(iOS)
                Button {
                    showCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel("Take photo with camera")
                #endif

                // Photo library picker
                PhotosPicker(
                    selection: $selectedItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel("Choose from photo library")
            }
            .onChange(of: selectedItem) { _, newItem in
                Task {
                    if let newItem {
                        viewModel?.selectedImageData = try? await newItem.loadTransferable(type: Data.self)
                    } else {
                        viewModel?.selectedImageData = nil
                    }
                }
            }
        }
    }

    private var promptSection: some View {
        TextField("Optional text prompt…", text: Binding(
            get: { viewModel?.textPrompt ?? "" },
            set: { viewModel?.textPrompt = $0 }
        ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
    }

    private var submitButton: some View {
        Button {
            Task { await viewModel?.analyzeImage() }
        } label: {
            HStack {
                if viewModel?.isGenerating ?? false {
                    ProgressView()
                        .tint(.white)
                }
                Text((viewModel?.isGenerating ?? false) ? "Analyzing…" : "Analyze Image")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel?.selectedImageData == nil || (viewModel?.isGenerating ?? false))
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Result")
                    .font(.headline)
                Spacer()
                if let output = viewModel?.streamedOutput, !output.isEmpty {
                    CopyButton(text: output)
                    ShareLink(item: output) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share output")
                }
            }

            if (viewModel?.isGenerating ?? false) && (viewModel?.streamedOutput.isEmpty ?? true) {
                HStack {
                    ProgressView()
                    Text("Generating…")
                        .foregroundStyle(.secondary)
                }
            }

            if let output = viewModel?.streamedOutput, !output.isEmpty {
                MarkdownText(content: output)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        AskImageView()
    }
    .environment(AppState())
}
#endif
