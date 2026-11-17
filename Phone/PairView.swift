import SwiftUI
import VisionKit

/// First run: scan the QR code from AgentX on the Mac (Settings → iPhone).
struct PairView: View {
    @Environment(PhoneModel.self) private var model
    @State private var scanning = false
    @State private var entering = false
    @State private var code = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "desktopcomputer.and.iphone").font(.system(size: 60)).foregroundStyle(.tint)
                Text("Pair with your Mac").font(.largeTitle.bold())
                Text("On your Mac, open AgentX → Settings → iPhone and click Pair an iPhone. Then scan the code it shows.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
                if working { ProgressView("Connecting…") }
                Button("Scan Pairing Code", systemImage: "qrcode.viewfinder") { scanning = true }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(!DataScannerViewController.isSupported || working)
                Button("Enter Code") { entering = true }
                    .buttonStyle(.glass)
                    .disabled(working)
                Spacer()
                Text("The code works once, for 5 minutes, and you confirm this iPhone on your Mac before it can see anything. The connection is encrypted end to end.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    QRScanner { text in
                        scanning = false
                        use(text)
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan the code on your Mac")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Cancel") { scanning = false } }
                }
            }
            .alert("Enter pairing code", isPresented: $entering) {
                TextField("agentx-pair://…", text: $code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Pair") { use(code) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("On your Mac, click Copy Code, then paste it here.")
            }
        }
    }

    private func use(_ text: String) {
        working = true
        error = nil
        Task {
            error = await model.pair(with: text)
            working = false
        }
    }
}

/// The camera, looking for a QR code.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let barcode) in items {
                if let text = barcode.payloadStringValue, text.hasPrefix("agentx-pair://") {
                    done = true
                    scanner.stopScanning()
                    onCode(text)
                    return
                }
            }
        }
    }
}
