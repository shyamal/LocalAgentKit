import Foundation
import LocalAgentKitCore
import LocalAgentKitProviders
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
  import UIKit
  import VisionKit
#elseif os(macOS)
  import AppKit
#endif

struct ReceiptPhotoView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var controller: ReceiptController?
  @State private var setupFailure: String?

  var body: some View {
    NavigationStack {
      Group {
        if let setupFailure {
          Text(setupFailure).foregroundStyle(.red).padding()
        } else if let controller {
          ReceiptForm(controller: controller)
        } else {
          ProgressView("Preparing receipt reader…")
        }
      }
      .navigationTitle("Receipt expense")
      .toolbar {
        Button("Done") {
          controller?.cancel(clearDraft: true)
          dismiss()
        }
      }
      .task {
        guard controller == nil else { return }
        do {
          let vision = try AppleVisionProvider(
            textRecognition: .init(maximumObservations: 100, maximumCharacters: 12_000))
          controller = ReceiptController(vision: vision)
          await controller?.refresh()
          if ProcessInfo.processInfo.environment["LOCALAGENTKIT_RECEIPT_SAMPLE"] == "1" {
            guard let url = Bundle.main.url(forResource: "receipt-sample", withExtension: "png")
            else {
              throw AgentError.inputFailure("The sample receipt is missing from this app build.")
            }
            controller?.read(ImageInput(data: try Data(contentsOf: url)))
          }
        } catch { setupFailure = String(describing: error) }
      }
      .onDisappear { controller?.cancel(clearDraft: true) }
    }
    .frame(minWidth: 320, minHeight: 480)
  }
}

private struct ReceiptForm: View {
  @Bindable var controller: ReceiptController
  @State private var selection: PhotosPickerItem?
  @State private var importing = false
  @State private var camera = false
  @State private var showingApproval = false
  @State private var photoLoad: Task<Void, Never>?
  @State private var photoFailure: String?

  var body: some View {
    Form {
      Section("Receipt photo") {
        Text(
          "Read a clear receipt, then check every field. Ambiguous dates and currencies need your input."
        )
        .font(.caption)
        PhotosPicker("Choose photo", selection: $selection, matching: .images)
          .disabled(controller.busy || photoLoad != nil)
        Button("Try sample receipt") {
          if let url = Bundle.main.url(forResource: "receipt-sample", withExtension: "png") {
            startLoading { ImageInput(data: try Data(contentsOf: url)) }
          } else {
            photoFailure = "The sample receipt is missing from this app build."
          }
        }.disabled(controller.busy || photoLoad != nil)
        Button("Choose image file") { importing = true }
          .disabled(controller.busy || photoLoad != nil)
        #if os(iOS)
          Button("Scan receipt") {
            controller.cancel(clearDraft: true)
            photoFailure = nil
            camera = true
          }
          .disabled(
            controller.busy || photoLoad != nil
              || !VNDocumentCameraViewController.isSupported)
        #endif
        Text(
          "Only approved expense fields are saved locally. The photo and raw recognized text are not saved by this demo. Cloud photo/file providers may download your selection."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if photoLoad != nil { ProgressView("Loading photo…") }
      if controller.busy {
        ProgressView(
          controller.pendingCall == nil ? "Processing receipt…" : "Waiting for approval…")
        Button("Cancel") {
          photoLoad?.cancel()
          controller.cancel()
        }
      }
      if let failure = photoFailure ?? controller.failure { Text(failure).foregroundStyle(.red) }
      if controller.draft != nil {
        Section("Review expense") {
          if let data = controller.imageData {
            #if os(iOS)
              if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
              }
            #elseif os(macOS)
              if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
              }
            #endif
          }
          if controller.draft?.date.isEmpty == true || controller.draft?.total.isEmpty == true {
            Text(
              "Date or total was not read. Scan closer in good light, or fill in the missing fields before saving."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          TextField("Merchant", text: field(\.merchant))
          TextField("Date (YYYY-MM-DD)", text: field(\.date))
          TextField("Total (use a dot, e.g. 12.50)", text: field(\.total))
          Picker("Currency", selection: field(\.currency)) {
            Text("Choose currency").tag("")
            ForEach(ReceiptExpense.currencies, id: \.self) { Text($0).tag($0) }
          }
          DisclosureGroup("Recognized text") {
            Text(controller.draft?.sourceText ?? "").font(.caption).textSelection(.enabled)
          }
          Button("Review and save expense") { controller.save() }
        }
        .disabled(controller.busy || photoLoad != nil)
      }
      if let notice = controller.notice {
        Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      }
      Section("Saved expenses on this device") {
        if controller.records.isEmpty { Text("No saved expenses.").foregroundStyle(.secondary) }
        ForEach(controller.records.reversed()) { record in
          VStack(alignment: .leading) {
            Text(record.merchant).font(.headline)
            Text("\(record.date) · \(record.formattedTotal)")
          }
        }
      }
    }
    .interactiveDismissDisabled(controller.busy || photoLoad != nil)
    .onChange(of: controller.pendingCall?.id) { _, id in showingApproval = id != nil }
    .alert("Save expense?", isPresented: $showingApproval) {
      Button("Save expense") { controller.resolve(true) }
      Button("Don't save", role: .cancel) { controller.resolve(false) }
    } message: {
      if let json = controller.pendingCall?.arguments.string("record"),
        let record = try? JSONDecoder().decode(ReceiptExpense.self, from: Data(json.utf8))
      {
        Text(
          "\(record.merchant)\n\(record.date)\n\(record.formattedTotal)\n\nSave these fields to this device?"
        )
      }
    }
    .onChange(of: selection) { _, item in
      guard let item else { return }
      startLoading {
        guard let data = try await item.loadTransferable(type: Data.self) else {
          throw AgentError.inputFailure("Could not load this photo.")
        }
        return ImageInput(data: data)
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
      switch result {
      case .success(let url):
        startLoading {
          try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard url.isFileURL, size <= 16 * 1024 * 1024 else {
              throw AgentError.inputFailure("Choose an image up to 16 MiB.")
            }
            return ImageInput(data: try Data(contentsOf: url, options: .mappedIfSafe))
          }.value
        }
      case .failure: photoFailure = "Could not open the image selection."
      }
    }
    #if os(iOS)
      .fullScreenCover(isPresented: $camera) {
        ReceiptCamera { image, failure in
          camera = false
          photoFailure = failure
          if let image {
            photoFailure = nil
            controller.read(image)
          }
        }
      }
    #endif
    .onDisappear {
      photoLoad?.cancel()
      controller.cancel(clearDraft: true)
    }
  }

  private func field(_ key: WritableKeyPath<ReceiptDraft, String>) -> Binding<String> {
    Binding(
      get: { controller.draft?[keyPath: key] ?? "" }, set: { controller.draft?[keyPath: key] = $0 })
  }

  private func startLoading(_ load: @escaping @Sendable () async throws -> ImageInput) {
    photoLoad?.cancel()
    controller.cancel(clearDraft: true)
    photoFailure = nil
    photoLoad = Task {
      do {
        let image = try await load()
        try Task.checkCancellation()
        controller.read(image)
      } catch { if !Task.isCancelled { photoFailure = String(describing: error) } }
      selection = nil
      photoLoad = nil
    }
  }
}

#if os(iOS)
  private struct ReceiptCamera: UIViewControllerRepresentable {
    let receive: @MainActor (ImageInput?, String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(receive: receive) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
      let scanner = VNDocumentCameraViewController()
      scanner.delegate = context.coordinator
      return scanner
    }
    func updateUIViewController(
      _ uiViewController: VNDocumentCameraViewController, context: Context
    ) {}

    @MainActor final class Coordinator: NSObject, @MainActor VNDocumentCameraViewControllerDelegate
    {
      let receive: @MainActor (ImageInput?, String?) -> Void
      init(receive: @escaping @MainActor (ImageInput?, String?) -> Void) { self.receive = receive }
      func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        receive(nil, nil)
      }
      func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFailWithError error: any Error
      ) {
        receive(nil, "Could not scan the receipt. Try a clearer page or choose a photo.")
      }
      func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
      ) {
        guard scan.pageCount == 1 else {
          receive(nil, "Scan one receipt page at a time.")
          return
        }
        let image = scan.imageOfPage(at: 0)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        // Drawing applies UIImage orientation once; encoded output is upright for Vision.
        let data = renderer.jpegData(withCompressionQuality: 0.95) { _ in
          image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        receive(ImageInput(data: data, orientation: .up), nil)
      }
    }
  }
#endif
