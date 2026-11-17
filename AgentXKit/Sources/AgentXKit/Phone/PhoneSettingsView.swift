import AgentXRemote
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings → iPhone: pair the AgentX iPhone app, see and remove paired
/// phones, and choose what they may do.
struct PhoneSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showPairing = false
    @State private var removing: PairedDevice?

    private var link: PhoneLink { model.phone }

    var body: some View {
        @Bindable var link = link
        Form {
            Section {
                Toggle("Let a paired iPhone connect", isOn: $link.isEnabled)
                LabeledContent("Status") { statusLabel }
                HStack {
                    Text("Open the AgentX app on your iPhone and scan a pairing code. A code works once, for 5 minutes, and you confirm the phone here before it sees anything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Pair an iPhone…") {
                        link.startPairing()
                        showPairing = true
                    }
                    .primaryButton()
                    .disabled(!link.isEnabled)
                }
            } header: {
                Text("iPhone")
            }

            Section("Paired iPhones") {
                let paired = link.devices.filter(\.confirmed)
                if paired.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(paired) { device in
                    HStack(spacing: 10) {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(detail(for: device)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if link.connected.contains(device.id) {
                            Label("Connected", systemImage: "circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Button("Remove…") { removing = device }.secondaryButton()
                    }
                }
            }

            Section {
                Toggle("Answer approvals (confirmed with Face ID on the phone)", isOn: $link.allowApprovals)
                Toggle("Message Claude on this Mac", isOn: $link.allowMessages)
                Toggle("Tick off today's reminders", isOn: $link.allowReminders)
            } header: {
                Text("What a paired iPhone can do")
            } footer: {
                Text("It can always see this Mac's status (vitals, plan usage, sessions, today, automations, activity) and use Stop Everything. Everything it does is in Settings → Activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("How it connects") {
                Text("Your iPhone finds this Mac on the same Wi-Fi. Away from home, install Tailscale on both: the pairing code includes this Mac's Tailscale address. The connection is encrypted and both sides prove they hold the pairing key, which lives in your Keychain. AgentX listens on the network only while an iPhone is paired or being paired.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("With a free Apple account, reinstall the iPhone app from Xcode every 7 days (scripts/run-phone.sh). Approvals show up when you open the app; there are no push notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPairing, onDismiss: {
            if link.pairing != nil || link.awaitingConfirmation != nil { link.cancelPairing() }
        }) {
            PairingSheet().environment(model)
        }
        .confirmationDialog("Remove \(removing?.name ?? "this iPhone")?", isPresented: .constant(removing != nil), presenting: removing) { device in
            Button("Remove", role: .destructive) {
                link.revoke(device.id)
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { _ in
            Text("It's disconnected and its pairing key is deleted. To use it again, pair it with a new code.")
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch link.status {
        case .off:
            Label("Off", systemImage: "iphone.slash").foregroundStyle(.secondary)
        case .idle:
            Label("Not listening (nothing paired)", systemImage: "moon.zzz").foregroundStyle(.secondary)
        case .listening(let port):
            Label(link.connected.isEmpty ? "Waiting for your iPhone (port \(port))" : "\(link.connected.count) connected (port \(port))",
                  systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(link.connected.isEmpty ? Color.secondary : Color.green)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    private func detail(for device: PairedDevice) -> String {
        var parts = ["Paired " + device.pairedAt.formatted(.dateTime.day().month(.abbreviated).year())]
        if let seen = device.lastSeen { parts.append("last seen " + seen.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}

/// The QR code, then "<phone> wants to connect", then "Paired".
private struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pairedName: String?
    @State private var copied = false

    private var link: PhoneLink { model.phone }

    var body: some View {
        VStack(spacing: 18) {
            if let name = pairedName {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
                Text("Paired with \(name)").font(.title2.bold())
                Text("You can close this. The iPhone reconnects by itself whenever you open AgentX on it.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { dismiss() }.primaryButton().keyboardShortcut(.defaultAction)
            } else if let pending = link.awaitingConfirmation {
                Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 44)).foregroundStyle(.tint)
                Text("“\(pending.name)” wants to connect").font(.title2.bold()).multilineTextAlignment(.center)
                Text("Only allow it if it's your iPhone and you just scanned the code. It will see this Mac's status and, depending on Settings, answer approvals and message Claude.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Decline", role: .destructive) {
                        link.decline()
                        dismiss()
                    }
                    .secondaryButton()
                    Button("Allow") {
                        pairedName = pending.name
                        link.confirm()
                    }
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
                }
            } else if let code = link.pairing {
                Text("Pair your iPhone").font(.title2.bold())
                if let image = QRCode.image(for: code.url) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 240, height: 240)
                        .padding(12)
                        .background(.white, in: .rect(cornerRadius: Radius.field))
                }
                Text("In the AgentX app on your iPhone, tap Pair with Mac and scan this code.")
                    .multilineTextAlignment(.center)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(code.expires.timeIntervalSince(context.date)))
                    Text(left > 0 ? "Works once, for \(left / 60):\(String(format: "%02d", left % 60)) more" : "This code has expired")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.url, forType: .string)
                        copied = true
                    }
                    .secondaryButton()
                    .help("For Enter Code on the iPhone (Universal Clipboard pastes it there). Anyone with this code can ask to pair, so don't share it.")
                    Button("Cancel") { dismiss() }.secondaryButton().keyboardShortcut(.cancelAction)
                }
                if case .failed(let why) = link.status {
                    Text(why).font(.caption).foregroundStyle(.red)
                }
            } else {
                Text("This pairing code has expired.").font(.title3)
                HStack {
                    Button("Close") { dismiss() }.secondaryButton()
                    Button("New Code") { link.startPairing() }.primaryButton()
                }
            }
        }
        .padding(28)
        .frame(width: 420)
    }
}

/// QR codes for pairing.
enum QRCode {
    static func image(for text: String, scale: CGFloat = 10) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
