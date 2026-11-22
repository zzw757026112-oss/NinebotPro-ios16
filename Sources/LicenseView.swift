import SwiftUI
import UIKit

/// 授权门：App 启动时查一次钥匙串里的授权码，回到前台时再查一次
///（码过期后不用重装，重新打开 App 就会回到激活页）。
final class LicenseGate: ObservableObject {
    @Published var isActivated = false
    @Published var expiryText: String? = nil

    init() { refresh() }

    func refresh() {
        switch LicenseManager.currentStatus() {
        case .valid(let expiry):
            isActivated = true
            expiryText = expiry.map { LicenseManager.displayDate($0) }
        case .invalid, .expired:
            isActivated = false
            expiryText = nil
        }
    }
}

/// 激活页：未激活时全屏挡住主界面；激活成功后自动进主界面。
/// v2（一码一机）：页上显示本机设备号，未激活也能复制发给授权方。
struct LicenseView: View {
    @ObservedObject var gate: LicenseGate
    @State private var code = ""
    @State private var message: String? = nil
    @State private var copiedDeviceCode = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 60)
                Image(systemName: "key.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.blue)
                Text("激活 Ninebot Pro+")
                    .font(.title2.bold())
                Text("请输入授权码激活使用\n离线验证，无需联网")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                // 设备号：未激活时也要能看到，复制发给授权方才能生成专属码。
                VStack(spacing: 8) {
                    Text("本机设备号")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 10) {
                        Text(LicenseManager.deviceShortCode)
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                        Button(copiedDeviceCode ? "已复制" : "复制设备号") {
                            UIPasteboard.general.string = LicenseManager.deviceShortCode
                            copiedDeviceCode = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.blue))
                        .foregroundColor(.white)
                        .buttonStyle(.plain)
                    }
                    Text("把设备号发给授权码提供方，生成你的专属授权码")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(10)

                TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $code)
                    .textInputAutocapitalization(.characters)
                    .disableAutocorrection(true)
                    .keyboardType(.asciiCapable)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(10)
                    .focused($focused)
                    .onSubmit { activate() }

                Button(action: activate) {
                    Text("激活")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(LicenseManager.normalize(code).isEmpty)

                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                Text("授权码只对本机有效；过期后请重新输入新的授权码。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                Spacer()
            }
            .padding(.horizontal, 28)
        }
        .onAppear { focused = true }
    }

    private func activate() {
        let status = LicenseManager.activate(code: code)
        switch status {
        case .valid(let expiry):
            // 激活成功：门一开就进主界面，不用再看这页。
            // 1.1.6：扩展不再验授权码（只在 App 里验一次），
            // 不用再把码发给扩展。
            gate.refresh()
            if let expiry {
                message = "已激活，有效期至 \(LicenseManager.displayDate(expiry))"
            }
        case .invalid:
            message = "授权码无效，请检查后重新输入"
        case .expired(let expiry):
            message = "授权码已过期（到期 \(LicenseManager.displayDate(expiry))），请使用新的授权码"
        }
    }
}
