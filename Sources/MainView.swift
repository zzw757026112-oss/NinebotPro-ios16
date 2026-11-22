import SwiftUI
import PhotosUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ReplayKit

enum AppVersion {
    static var short: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }
    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
    static var display: String { "v\(short) (\(build))" }
}

struct MainView: View {
    @StateObject private var engine = CastEngine()
    @StateObject private var antbms = ANTBMS.shared
    @StateObject private var elk = ELKStrip.shared
    @StateObject private var ride = RideTracker.shared
    @Environment(\.colorScheme) private var scheme

    // 授权门（App 持有）：授权卡片显示状态、更换授权码用。
    @ObservedObject var licenseGate: LicenseGate
    @State private var showLicenseSheet = false

    // 设置持久化：下次打开不用重填
    @AppStorage("nbc.host") private var host = ""
    @AppStorage("nbc.preset") private var presetIndex = 0
    @AppStorage("nbc.quality") private var qualityIndex = 2   // 0 流畅 1 均衡 2 清晰 3 极致
    @AppStorage("nbc.dupKey") private var duplicateKeyframes = false
    @AppStorage("nbc.chunk1400") private var chunk1400 = true
    @AppStorage("nbc.mirrorRotation") private var mirrorRotationIndex = 0 // 0 自动 1 90° 2 180° 3 270°
    @AppStorage("nbc.displayMode") private var displayMode = 0 // 显示模式：0 铺满（裁两边，默认），1 完整（上下黑边），2 拉伸（整幅硬拉到仪表，横向略压扁）
    // HUD 自定义：显示哪些项、放哪个角、字号多大（发给录屏扩展）
    @AppStorage("nbc.hud.showDate") private var hudShowDate = true
    @AppStorage("nbc.hud.showWeather") private var hudShowWeather = true
    @AppStorage("nbc.hud.showSignal") private var hudShowSignal = true
    @AppStorage("nbc.hud.showBattery") private var hudShowBattery = true
    @AppStorage("nbc.hud.showVolume") private var hudShowVolume = true
    @AppStorage("nbc.hud.showBMS") private var hudShowBMS = true
    @AppStorage("nbc.hud.showSlot") private var hudShowSlot = false // 1.3.18 翻页时钟：和电池 BMS 互斥
    @AppStorage("nbc.hud.position") private var hudPosition = 0 // 0 右下 1 左下 2 左上 3 右上
    @AppStorage("nbc.hud.fontSize") private var hudFontSize = 1 // 0 小 1 中 2 大
    @AppStorage("nbc.keepAlive") private var keepAlive = true
    @AppStorage("nbc.speedLimit") private var speedLimit = 60 // 限速 km/h：35...80，每 5 一档，默认 60
    @AppStorage("nbc.speedAlert") private var speedAlert = true
    @State private var gopIndex = 25            // 关键帧间隔（帧）
    @State private var fpsIndex = 20
    @State private var bitrateIndex = 1200      // kbps
    @State private var resolutionIndex = 0      // 0 预设 / 2 一半
    @State private var pingOnly = false
    @State private var showTools = false
    @State private var showAdvanced = false
    @State private var showDiag = false
    @State private var showRideHistory = false
    @State private var elkBrightnessDraft: Double = 100 // 灯带亮度草稿：松手才发
    @State private var elkPickerColor: Color = .white // 灯带自选色
    @State private var elkColorFromPreset = false // 预设色块点的：不重复发颜色
    @State private var scanning = false
    @State private var tcpScanning = false
    @State private var probing = false
    @State private var scanSummary = ""
    @State private var diagText = Diag.tail(16)
    @State private var localIP = "-"

    // 图片：先选进 pending，预览确认后才生效
    @State private var pickedItem: PhotosPickerItem?
    @State private var pendingImage: UIImage?
    @State private var confirmedImage: UIImage?
    @State private var imageConfirmed = false
    @State private var showImagePreview = false

    // 视频：同样确认制
    @State private var pickedVideoItem: PhotosPickerItem?
    @State private var pendingVideoURL: URL?
    @State private var confirmedVideoURL: URL?
    @State private var videoConfirmed = false

    @State private var sourceIndex = 0         // 0 测试图 1 图片 2 视频 3 摄像头
    @State private var rotationIndex = 0       // 图片/视频/测试图 的方向
    @State private var cameraRotationIndex = 1  // 摄像头默认 90°（竖装/横装常态）
    @State private var cameraPositionIndex = 0 // 0 后置 1 前置

    private static let previewContext = CIContext(options: nil)
    private let accent = Color(red: 0.29, green: 0.47, blue: 0.98)
    private let accent2 = Color(red: 0.55, green: 0.36, blue: 0.96)

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                    connectionCard
                    sourceCard
                    mirrorCard
                    displayModeCard
                    hudCard
                    bmsCard
                    elkCard
                    rideCard
                    licenseCard
                    metricsCard
                    diagCard
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 132)
            }
        }
        .overlay(alignment: .bottom) { actionBar }
        .sheet(isPresented: $showImagePreview) { imagePreviewSheet }
        .sheet(isPresented: $showLicenseSheet) {
            NavigationStack {
                LicenseView(gate: licenseGate)
                    .navigationTitle("授权码")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showLicenseSheet = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showTools) { toolsSheet }
        .onAppear {
            localIP = LanScanner.localIPv4() ?? "未连 Wi-Fi"
            if host.isEmpty { host = LanScanner.gatewayGuess() ?? "" }
            applyQuality(qualityIndex)
            postHUDSettings()
            diagText = Diag.tail(16)
            Diag.log("MainView 出现，版本 \(AppVersion.display)，IP=\(host.isEmpty ? "未填" : host)")
        }
        .onChange(of: pickedItem) { item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                await MainActor.run {
                    pendingImage = image
                    imageConfirmed = false
                }
            }
        }
        .onChange(of: pickedVideoItem) { item in
            guard let item else { return }
            // matching is nil (see photoFlow/videoFlow): reject non-video picks here.
            if let first = item.supportedContentTypes.first,
               !first.conforms(to: .movie), !first.conforms(to: .video) {
                Task { await MainActor.run { scanSummary = "请选择视频文件" } }
                return
            }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cast-video-\(UUID().uuidString).mp4")
                do {
                    try data.write(to: url)
                } catch {
                    await MainActor.run { scanSummary = "视频保存失败：\(error.localizedDescription)" }
                    return
                }
                await MainActor.run {
                    pendingVideoURL = url
                    videoConfirmed = false
                }
            }
        }
        .onChange(of: sourceIndex) { _ in applySource() }
        .onChange(of: rotationIndex) { _ in applySource() }
        .onChange(of: cameraPositionIndex) { _ in
            if sourceIndex == 3 { applySource() }
        }
    }

    // MARK: - 背景
    private var backgroundGradient: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.06, green: 0.07, blue: 0.10), Color(red: 0.10, green: 0.11, blue: 0.16)]
                : [Color(red: 0.96, green: 0.97, blue: 1.0), Color(red: 0.93, green: 0.94, blue: 0.98)],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: - 顶部
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ninebot Pro+")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.isRunning ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(engine.statusText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text("v\(AppVersion.short)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    // MARK: - 卡片容器
    private func card<Content: View>(_ title: String,
                                     icon: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accent)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.055) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(scheme == .dark ? 0.07 : 0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 10, y: 4)
    }

    private func fieldBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selected ? accent.opacity(0.12) : Color.primary.opacity(0.045))
    }

    // MARK: - 连接
    private var connectionCard: some View {
        card("仪表连接", icon: "antenna.radiowaves.left.and.right") {
            HStack {
                Text("预设").foregroundColor(.secondary)
                Spacer()
                Picker("", selection: $presetIndex) {
                    ForEach(Array(DashboardPreset.all.enumerated()), id: \.element.id) { index, preset in
                        Text(preset.title).tag(index)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .font(.subheadline)

            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("仪表 IP", text: $host)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .font(.body.monospacedDigit())
                Button {
                    fillGateway()
                } label: {
                    Text("用网关")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(accent.opacity(0.12)))
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(fieldBackground(false))

            HStack {
                Text("本机 \(localIP)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    showTools = true
                } label: {
                    HStack(spacing: 4) {
                        Text("找不到 IP？")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundColor(accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 画面来源
    private var sourceCard: some View {
        card("画面来源", icon: "rectangle.on.rectangle") {
            HStack(spacing: 8) {
                sourceTile(0, "测试图", "chart.bar.doc.horizontal")
                sourceTile(1, "图片", "photo")
                sourceTile(2, "视频", "video")
                sourceTile(3, "摄像头", "camera")
            }

            rotationPicker

            if sourceIndex == 1 {
                photoFlow
            } else if sourceIndex == 2 {
                videoFlow
            } else if sourceIndex == 3 {
                cameraFlow
            } else {
                Text("彩条 + 移动方块，用来快速验证链路是否通。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func sourceTile(_ index: Int, _ title: String, _ icon: String) -> some View {
        Button {
            sourceIndex = index
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundColor(sourceIndex == index ? accent : Color.secondary)
            .background(fieldBackground(sourceIndex == index))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(sourceIndex == index ? accent.opacity(0.55) : Color.clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }

    private var rotationPicker: some View {
        HStack(spacing: 8) {
            Text("方向")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Button {
                        setRotation(step: i)
                    } label: {
                        Text(["0°", "90°", "180°", "270°"][i])
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .frame(width: 46, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(currentRotationStep == i ? accent : Color.clear)
                            )
                            .foregroundColor(currentRotationStep == i ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
        }
    }

    /// 摄像头与其它来源各自记住自己的方向
    private var currentRotationStep: Int {
        sourceIndex == 3 ? cameraRotationIndex : rotationIndex
    }

    private var currentRotationDegrees: Int {
        [0, 90, 180, 270][currentRotationStep]
    }

    private func setRotation(step: Int) {
        if sourceIndex == 3 {
            cameraRotationIndex = step
        } else {
            rotationIndex = step
        }
        applySource()
    }

    // 图片流程：选 → 预览 → 确认 → 才真正投
    private var photoFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $pickedItem, matching: nil) {
                Label(confirmedImage == nil ? "选择图片" : "换一张图片",
                      systemImage: "photo.on.rectangle.angled")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(fieldBackground(false))
            }
            .buttonStyle(.plain)

            if let pendingImage, !imageConfirmed {
                Button {
                    showImagePreview = true
                } label: {
                    previewImageView(pendingImage)
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Text("点开预览")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(9)
                        }
                }
                .buttonStyle(.plain)

                Button {
                    confirmedImage = pendingImage
                    imageConfirmed = true
                    applySource()
                } label: {
                    Label("确认投这张图", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            } else if let confirmedImage, imageConfirmed {
                HStack(spacing: 12) {
                    previewImageView(confirmedImage)
                        .frame(width: 92, height: 60)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已确认 · 铺满 \(DashboardPreset.all[presetIndex].width)×\(DashboardPreset.all[presetIndex].height)")
                            .font(.caption.weight(.medium))
                        Text("超出部分裁掉，换方向自动重排")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    // 视频流程：选 → 确认 → 才真正投
    private var videoFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $pickedVideoItem, matching: nil) {
                Label(confirmedVideoURL == nil ? "选择视频" : "换一个视频",
                      systemImage: "video.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(fieldBackground(false))
            }
            .buttonStyle(.plain)

            if let pendingVideoURL, !videoConfirmed {
                Text(pendingVideoURL.lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Button {
                    confirmedVideoURL = pendingVideoURL
                    videoConfirmed = true
                    applySource()
                } label: {
                    Label("确认投这段视频", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            } else if let confirmedVideoURL, videoConfirmed {
                Text("已确认 · \(confirmedVideoURL.lastPathComponent)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text("原速循环播放，独立线程解码，不占发送节拍。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var cameraFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 2) {
                cameraTile(0, "后置", "camera")
                cameraTile(1, "前置", "camera.rotate")
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.045)))

            Text("首次使用会请求相机权限。退后台后摄像头会停采集（iOS 限制），画面停在最后一帧但流不断。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func cameraTile(_ index: Int, _ title: String, _ icon: String) -> some View {
        Button {
            cameraPositionIndex = index
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(cameraPositionIndex == index ? Color.primary.opacity(0.08) : Color.clear)
            )
            .foregroundColor(cameraPositionIndex == index ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 屏幕镜像（录屏广播扩展）
    private var mirrorCard: some View {
        card("屏幕镜像", icon: "rectangle.on.rectangle") {
            Text("把整块手机屏幕实时投到仪表：抖音、地图、视频都能投。只传画面，没有声音。")
                .font(.footnote)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                BroadcastPickerButton()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("点左边按钮 → 选 Ninebot Pro+ → 开始直播")
                        .font(.subheadline.weight(.semibold))
                    Text("停止：控制中心长按屏幕录制 → 停止，或回 App 再点一次按钮。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Text("开始前：仪表先进投屏接收态，强退九号出行（它占着 5012/5013 端口），并先停掉上面的普通投屏；先用测试图成功投一次，让系统弹过局域网权限。手机横过来后画面自动转正、铺满整个仪表（左右各裁掉一点）；竖屏画面在横屏仪表上是中间一条竖条，两边黑边。只支持五寸 H.264 模式。")
                .font(.caption2)
                .foregroundColor(.secondary)
            mirrorRotationPicker
            Text("方向默认自动跟随手机；自动转不正时手动选 90° 或 270°，下一帧就生效，不用重开镜像。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 显示模式（铺满/完整/拉伸；普通投屏和屏幕镜像都用）
    private var displayModeCard: some View {
        card("显示模式", icon: "aspectratio") {
            Picker("显示", selection: $displayMode) {
                Text("铺满").tag(0)
                Text("完整").tag(1)
                Text("拉伸").tag(2)
            }
            .pickerStyle(.segmented)
            Text("铺满：铺满全屏，左右各裁掉一点；完整：整幅画面都可见，上下留黑边；拉伸：整幅画面铺满仪表，横向略压扁。手机画面比仪表宽，铺满和不裁剪没法同时做到。下一帧就生效，不用重开镜像。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onChange(of: displayMode) { value in
            // 模式一改就发给录屏扩展，下一帧就生效；图片源是静态 buffer，要重建
            DisplayFitRelay.setMode(value)
            engine.refreshDisplayFit()
        }
    }

    // MARK: - HUD 显示（自定义：显示哪些项、放哪个角、字号）
    private var hudSettings: HUDSettings {
        let positions = HUDSettings.Position.allCases
        let sizes = HUDSettings.FontSize.allCases
        return HUDSettings(
            showDate: hudShowDate,
            showWeather: hudShowWeather,
            showSignal: hudShowSignal,
            showBattery: hudShowBattery,
            showVolume: hudShowVolume,
            showBMS: hudShowBMS,
            showSlot: hudShowSlot,
            position: positions[min(max(hudPosition, 0), positions.count - 1)],
            fontSize: sizes[min(max(hudFontSize, 0), sizes.count - 1)])
    }

    /// 改了设置就立刻发给录屏扩展（Darwin 通知），之后每 2 秒还会重发。
    private func postHUDSettings() {
        HUDSettingsRelay.update(hudSettings)
    }

    private var hudCard: some View {
        card("HUD 显示", icon: "gauge") {
            Toggle("日期", isOn: $hudShowDate)
                .font(.subheadline)
            Toggle("天气温度", isOn: $hudShowWeather)
                .font(.subheadline)
            Toggle("信号", isOn: $hudShowSignal)
                .font(.subheadline)
            Toggle("电量", isOn: $hudShowBattery)
                .font(.subheadline)
            Toggle("音量", isOn: $hudShowVolume)
                .font(.subheadline)
            Toggle("电池 BMS", isOn: $hudShowBMS)
                .font(.subheadline)
            Toggle("翻页时钟", isOn: $hudShowSlot)
                .font(.subheadline)
            Picker("位置", selection: $hudPosition) {
                Text("右下").tag(0)
                Text("左下").tag(1)
                Text("左上").tag(2)
                Text("右上").tag(3)
            }
            .pickerStyle(.segmented)
            Picker("字号", selection: $hudFontSize) {
                Text("小").tag(0)
                Text("中").tag(1)
                Text("大").tag(2)
            }
            .pickerStyle(.segmented)
            Text("仪表右下角会叠加一个小胶囊：日期和天气、手机信号、手机电量等等，来电时左下角显示红色“来电”。位置和显示项可以在上面设置修改。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onChange(of: hudShowDate) { _ in postHUDSettings() }
        .onChange(of: hudShowWeather) { _ in postHUDSettings() }
        .onChange(of: hudShowSignal) { _ in postHUDSettings() }
        .onChange(of: hudShowBattery) { _ in postHUDSettings() }
        .onChange(of: hudShowVolume) { _ in postHUDSettings() }
        .onChange(of: hudShowBMS) { v in if v { hudShowSlot = false }; postHUDSettings() }
        .onChange(of: hudShowSlot) { v in if v { hudShowBMS = false }; postHUDSettings() }
        .onChange(of: hudPosition) { _ in postHUDSettings() }
        .onChange(of: hudFontSize) { _ in postHUDSettings() }
    }

    // MARK: - 电池 BMS (ANT)（朋友那辆换了锂电池的车，1.2.0）
    // 只支持 ANT BMS（MAYI/JNFN）新格式 7E A1 帧。内容由 ANTBMS 的
    // @Published 驱动，不用 timer 轮询 UI。
    private var bmsCard: some View {
        card("电池 BMS (ANT)", icon: "bolt.fill") {
            Toggle("启用 ANT BMS", isOn: $antbms.isEnabled)
                .font(.subheadline)
            if antbms.isEnabled {
                HStack(spacing: 6) {
                    Text(antbms.isConnected ? "已连接" : (antbms.isScanning ? "搜索中…" : "未连接"))
                    if let name = antbms.deviceName {
                        Text(name)
                    }
                    if let rssi = antbms.rssi {
                        Text("\(rssi)dBm")
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundColor(.secondary)
                BMSDiagLineView(antbms: antbms)
                if let info = antbms.lastFrameInfo {
                    Text(info)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                // 1.3.22（朋友版唤醒修法移植）：连的不是 ANT 设备时提示；FFE0 下全部特征列表。
                if let note = antbms.selectionNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                if let chars = antbms.charInfo {
                    Text("特征：\(chars)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let s = antbms.snapshot {
                    Text(String(format: "总电压 %.2fV　电流 %.1fA　功率 %.0fW　SOC %.1f%%",
                                s.voltage, s.current, s.power, s.soc))
                        .font(.caption)
                    Text("最高温 \(s.temps.max() ?? 0)°C　温度 \(s.temps.map(String.init).joined(separator: "/"))°C")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "电芯 %dS：最低 %.3fV (#%d)　最高 %.3fV (#%d)　均值 %.3fV　压差 %dmV",
                                s.cellCount, Double(s.cellMin) / 1000, s.minCellIndex,
                                Double(s.cellMax) / 1000, s.maxCellIndex,
                                Double(s.cellAvg) / 1000, s.cellDelta))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        Text("更新于")
                        Text(s.updatedAt, style: .time)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                } else {
                    Text("等连接…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let err = antbms.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            } else {
                Text("只支持 ANT BMS（MAYI/JNFN）新格式 7E A1 帧；打开后自动连信号最强的一台，数据同时显示在仪表 HUD 第三行。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 七彩日行灯（车上的 LED 灯带，ELK-BLEDOB，1.3.0）
    // duoCo Strip 同款控制器（服务 FFF0，9 字节 7E…EF 命令），
    // 内容由 ELKStrip 的 @Published 驱动，不用 timer 轮询 UI。
    // 注意：NinebotCastApp.swift 的 init 里还没像 ANTBMS 那样
    // touch ELKStrip.shared——App 被系统杀掉后在后台拉起时，
    // 灯的 BLE 会话恢复不了，要等 MainView 出现才重连。后台保活
    // 开着时很少被杀，先这样；要补只用在 init 里加一行
    // `_ = ELKStrip.shared`（同 ANTBMS 的写法）。
    private var elkCard: some View {
        card("七彩日行灯", icon: "lightbulb.fill") {
            Toggle("启用七彩日行灯", isOn: $elk.isEnabled)
                .font(.subheadline)
            if elk.isEnabled {
                HStack(spacing: 6) {
                    Text(elk.isConnected ? "已连接" : (elk.isScanning ? "搜索中…" : "未连接"))
                    if let name = elk.deviceName {
                        Text(name)
                    }
                    if let rssi = elk.rssi {
                        Text("\(rssi)dBm")
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundColor(.secondary)
                ELKDiagLineView(elk: elk)
                if let err = elk.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
                HStack(spacing: 12) {
                    Button {
                        elk.turnOn()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lightbulb.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text(elk.isOn ? "开着" : "开灯")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(elk.isOn ? accent : Color.primary.opacity(0.08)))
                        .foregroundColor(elk.isOn ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!elk.isConnected)
                    Button {
                        elk.turnOff()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 13, weight: .bold))
                            Text("关灯")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.08)))
                        .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!elk.isConnected)
                }
                // 7 个预设色：点一下就发颜色命令（灯关着时先开灯再变色）。
                HStack(spacing: 10) {
                    ForEach(Array(elkPresets.enumerated()), id: \.offset) { _, preset in
                        Button {
                            elkColorFromPreset = true
                            elkPickerColor = preset.color
                            elk.setColor(r: preset.r, g: preset.g, b: preset.b)
                        } label: {
                            Circle()
                                .fill(preset.color)
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                                )
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: 2)
                                        .opacity(elk.colorR == preset.r && elk.colorG == preset.g && elk.colorB == preset.b ? 1 : 0)
                                )
                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(!elk.isConnected)
                    }
                }
                ColorPicker("自选颜色", selection: $elkPickerColor)
                    .font(.subheadline)
                    .disabled(!elk.isConnected)
                    .onChange(of: elkPickerColor) { color in
                        if elkColorFromPreset {
                            elkColorFromPreset = false
                            return
                        }
                        let (r, g, b) = elkColorComponents(color)
                        elk.setColor(r: r, g: g, b: b)
                    }
                HStack {
                    Text("亮度 \(Int(elkBrightnessDraft))%")
                        .font(.subheadline)
                    Slider(value: $elkBrightnessDraft, in: 0...100, step: 1) { editing in
                        // 松手再发：拖动一路狂发会把灯的命令队列堵满。
                        if !editing {
                            elk.setBrightness(Int(elkBrightnessDraft))
                        }
                    }
                    .disabled(!elk.isConnected)
                    Button("白色") {
                        elk.setWhite()
                        elkBrightnessDraft = Double(elk.brightness)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.08)))
                    .buttonStyle(.plain)
                    .disabled(!elk.isConnected)
                }
                HStack(spacing: 8) {
                    ForEach(Array(elkEffects.enumerated()), id: \.offset) { _, effect in
                        Button(effect.name) {
                            elk.setEffect(effect.id, name: effect.name)
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(elk.lastEffect == effect.name ? accent.opacity(0.18) : Color.primary.opacity(0.06)))
                        .foregroundColor(elk.lastEffect == effect.name ? accent : .primary)
                        .buttonStyle(.plain)
                        .disabled(!elk.isConnected)
                    }
                }
                Text("连不上时：先退出 duoCo（一个灯一次只能连一个 App），再等它重连；卡片上的名字和信号帮你确认连的是自己车上的灯——开关一按，看车灯变不变就知道。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("车上的日行灯带（ELK-BLEDOB），duoCo Strip 同款控制器；打开后自动连信号最强的一台（邻居家同型号也在广播，弱信号那台不是车上的灯）。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            elkBrightnessDraft = Double(elk.brightness)
            elkPickerColor = Color(red: Double(elk.colorR) / 255,
                                   green: Double(elk.colorG) / 255,
                                   blue: Double(elk.colorB) / 255)
        }
    }

    /// 预设色块（红/橙/黄/绿/青/蓝/紫）。
    private var elkPresets: [(name: String, r: UInt8, g: UInt8, b: UInt8, color: Color)] {
        [
            ("红", 255, 0, 0, .red),
            ("橙", 255, 165, 0, .orange),
            ("黄", 255, 255, 0, .yellow),
            ("绿", 0, 255, 0, .green),
            ("青", 0, 255, 255, .cyan),
            ("蓝", 0, 0, 255, .blue),
            ("紫", 128, 0, 255, .purple),
        ]
    }

    /// 灯效按钮（id 来自 elkbledom definitions.json 的 EFFECTS 枚举，
    /// 已核实；命令是 7E 07 03 <id> 03 FF FF 00 EF）。
    private var elkEffects: [(name: String, id: Int)] {
        [
            ("七彩跳变", ELKStrip.effectJump7),
            ("七彩渐变", ELKStrip.effectFade7),
            ("红绿蓝跳变", ELKStrip.effectJumpRGB),
        ]
    }

    /// 从 SwiftUI Color 取 0–255 的 RGB（ColorPicker 回调用）。
    private func elkColorComponents(_ color: Color) -> (UInt8, UInt8, UInt8) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt8(max(0, min(255, Int((r * 255).rounded())))),
                UInt8(max(0, min(255, Int((g * 255).rounded())))),
                UInt8(max(0, min(255, Int((b * 255).rounded())))))
    }

    // MARK: - 骑行记录（GPS，不接车，1.2.9）
    // 开始/结束手动点；骑行中每 10 米记一个点，算里程、时长、
    // 当前速度和最高速度。超速提醒在下面设限速；历史存在本地。
    private var rideCard: some View {
        card("骑行记录", icon: "map") {
            HStack(spacing: 12) {
                Button {
                    if ride.riding { ride.stop() } else { ride.start() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: ride.riding ? "stop.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text(ride.riding ? "结束骑行" : "开始骑行")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(ride.riding ? Color.red : accent))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                if ride.overspeed {
                    Text("超速！")
                        .font(.headline)
                        .foregroundColor(.red)
                }
            }
            if ride.riding {
                HStack(spacing: 0) {
                    metric(formatClock(ride.elapsedSec), "时长")
                    dividerView()
                    metric(formatDistance(ride.distanceM), "里程")
                    dividerView()
                    metric("\(Int(ride.currentSpeedKmh))", "当前 km/h")
                    dividerView()
                    metric("\(Int(ride.maxSpeedKmh))", "最高 km/h")
                }
                Text("退后台也继续记（定位后台模式已开）。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if ride.locationDenied {
                Text("定位未授权：去系统设置里打开 Ninebot Pro+ 的定位，骑行记录和天气都要用它。")
                    .font(.caption2)
                    .foregroundColor(.red)
            } else {
                Text("用手机 GPS 记骑行：里程、时长、最高速度和平均速度，不用接车。App 被杀后 30 分钟内重开能续上。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Stepper(value: $speedLimit, in: 35...80, step: 5) {
                Text("限速 \(speedLimit) km/h").font(.subheadline)
            }
            Toggle("超速提醒", isOn: $speedAlert)
                .font(.subheadline)
                .onChange(of: speedAlert) { on in
                    if on { OverspeedNotifier.requestAuthorization() }
                }
            Text("震动 + 提示音 + 手机通知，仪表 HUD 变红。")
                .font(.caption2)
                .foregroundColor(.secondary)
            if !ride.rides.isEmpty {
                DisclosureGroup(isExpanded: $showRideHistory) {
                    List {
                        ForEach(ride.rides) { r in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(r.startTime, format: .dateTime.month().day().hour().minute())
                                        .font(.subheadline.weight(.medium))
                                    Text("\(formatDistance(r.distanceM)) · \(formatDuration(r.durationSec))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("最高 \(Int(r.maxSpeedKmh)) km/h")
                                        .font(.caption)
                                    Text("平均 \(Int(r.avgSpeedKmh)) km/h")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets { ride.deleteRide(id: ride.rides[i].id) }
                        }
                    }
                    .listStyle(.plain)
                    .frame(height: CGFloat(min(ride.rides.count, 5)) * 56 + 8)
                } label: {
                    Text("历史记录（\(ride.rides.count) 次）")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - 授权（状态 + 更换授权码）
    // 1.1.3 的教训：App 里激活了，扩展却读不到码（钥匙串访问组
    // 不同），主界面又没有输入框，用户卡死。这里常驻一个入口，
    // 换码、查有效期都在这。1.1.6：扩展不再验授权码（只在 App
    // 里验一次），中继已删除。
    private var licenseCard: some View {
        card("授权", icon: "key.fill") {
            HStack(spacing: 6) {
                Image(systemName: licenseGate.isActivated ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                Text(licenseGate.isActivated
                     ? (licenseGate.expiryText.map { "已激活，有效期至 \($0)" } ?? "已激活（永久）")
                     : "未激活")
                    .font(.caption)
                Spacer()
                Button("更换授权码") {
                    showLicenseSheet = true
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent))
                .foregroundColor(.white)
                .buttonStyle(.plain)
            }
            Text("授权码由作者提供；换码后重新开一次镜像就生效。")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("本机设备号：\(LicenseManager.deviceShortCode)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// 镜像方向：和图片来源同一个样式。0=自动（走方向接力），
    /// 90°/180°/270° 手动指定；点的那一下立即发给扩展，下一帧就转。
    private var mirrorRotationPicker: some View {
        HStack(spacing: 8) {
            Text("方向")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Button {
                        mirrorRotationIndex = i
                        OrientationRelay.setManualRotation([0, 90, 180, 270][i])
                    } label: {
                        Text(["自动", "90°", "180°", "270°"][i])
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .frame(width: 46, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(mirrorRotationIndex == i ? accent : Color.clear)
                            )
                            .foregroundColor(mirrorRotationIndex == i ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
        }
    }

    // MARK: - 指标
    private var metricsCard: some View {
        card("运行状态", icon: "waveform.path.ecg") {
            // 每秒都在变的那几行关进独立子视图，只订阅 CastEngine，
            // 再怎么变也只重画这个小卡片，不重算整个 MainView（1.3.9）。
            EngineLiveStatsView(engine: engine, accent: accent)

            Toggle("后台保活（退后台继续跑）", isOn: $keepAlive)
                .font(.subheadline)
                .onChange(of: keepAlive) { value in
                    if value {
                        BackgroundKeeper.shared.startAlwaysOn()
                    } else {
                        BackgroundKeeper.shared.stopAlwaysOn()
                    }
                }
            Text("开着时 App 退后台也不停：BMS 继续轮询、接力继续发；关了只在投屏时保活")
                .font(.caption2)
                .foregroundColor(.secondary)

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("画质", selection: $qualityIndex) {
                        Text("流畅").tag(0)
                        Text("均衡").tag(1)
                        Text("清晰").tag(2)
                        Text("极致").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: qualityIndex) { value in
                        applyQuality(value)
                    }
                    Text("画质一键设好帧率和码率；下面还能单项微调")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    HStack {
                        Text("帧率").font(.subheadline)
                        Spacer()
                        Picker("", selection: $fpsIndex) {
                            Text("跟随预设").tag(0)
                            Text("10").tag(10)
                            Text("15").tag(15)
                            Text("20").tag(20)
                            Text("25").tag(25)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    HStack {
                        Text("码率").font(.subheadline)
                        Spacer()
                        Picker("", selection: $bitrateIndex) {
                            Text("跟随预设").tag(0)
                            Text("400k").tag(400)
                            Text("600k").tag(600)
                            Text("800k").tag(800)
                            Text("1.2M").tag(1200)
                            Text("2M").tag(2000)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    HStack {
                        Text("关键帧间隔").font(.subheadline)
                        Spacer()
                        Picker("", selection: $gopIndex) {
                            Text("10 帧").tag(10)
                            Text("25 帧").tag(25)
                            Text("50 帧").tag(50)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    HStack {
                        Text("分辨率").font(.subheadline)
                        Spacer()
                        Picker("", selection: $resolutionIndex) {
                            Text("跟随预设").tag(0)
                            Text("一半（更省解码）").tag(2)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    Toggle("关键帧重发（更稳但更占带宽）", isOn: $duplicateKeyframes)
                        .font(.subheadline)
                    Toggle("分片 1400 字节", isOn: $chunk1400)
                        .font(.subheadline)
                    Toggle("只发 ping（排查用）", isOn: $pingOnly)
                        .font(.subheadline)
                }
                .padding(.top, 8)
            } label: {
                Text("发送参数 · \(fpsLabel) / \(bitrateLabel)")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var fpsLabel: String { fpsIndex == 0 ? "预设帧率" : "\(fpsIndex)fps" }
    private var bitrateLabel: String { bitrateIndex == 0 ? "预设码率" : "\(bitrateIndex)kbps" }

    /// 骑行时长（中文）：12秒 / 12分34秒 / 1小时23分
    private func formatDuration(_ sec: Int) -> String {
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        if h > 0 { return String(format: "%d小时%02d分", h, m) }
        if m > 0 { return String(format: "%d分%02d秒", m, s) }
        return "\(s)秒"
    }

    /// 骑行时长（紧凑）：12:34 / 1:23:45（实时统计行用）
    private func formatClock(_ sec: Int) -> String {
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// 里程：850 m / 12.3 km
    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 { return String(format: "%.0f m", meters) }
        return String(format: "%.1f km", meters / 1000)
    }

    /// 画质档位 = 帧率 + 码率 + GOP 的组合，一键设定
    private func applyQuality(_ value: Int) {
        switch value {
        case 0: fpsIndex = 10; bitrateIndex = 400; gopIndex = 10
        case 1: fpsIndex = 15; bitrateIndex = 800; gopIndex = 25
        case 2: fpsIndex = 20; bitrateIndex = 1200; gopIndex = 25
        default: fpsIndex = 25; bitrateIndex = 2000; gopIndex = 10
        }
    }

    // MARK: - 诊断
    private var diagCard: some View {
        card("诊断", icon: "stethoscope") {
            DisclosureGroup(isExpanded: $showDiag) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(diagText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 14) {
                        Button("刷新") { diagText = Diag.tail(20) }
                        Button("复制") {
                            UIPasteboard.general.string = Diag.tail(60)
                        }
                        Spacer()
                        Button("清空") {
                            Diag.reset()
                            diagText = Diag.tail(4)
                        }
                        .foregroundColor(.red)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundColor(accent)
                }
                .padding(.top, 8)
            } label: {
                Text("展开日志（出问题把这段发我）")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // 项目主页：点开用 Safari 打开 GitHub 仓库
    private static let projectURL = URL(string: "https://github.com/zzw757026112-oss/NinebotPro-ios16")!

    private var footer: some View {
        VStack(spacing: 6) {
            Link(destination: Self.projectURL) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text("点击打开项目")
                    Image(systemName: "arrow.up.forward.app")
                }
                .font(.caption.weight(.medium))
                .foregroundColor(accent)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - 底部主按钮
    private var actionBar: some View {
        VStack(spacing: 10) {
            Button {
                if engine.isRunning {
                    engine.stop()
                } else {
                    engine.start(preset: DashboardPreset.all[presetIndex],
                                 host: host,
                                 duplicateKeyframes: duplicateKeyframes,
                                 packetSize: chunk1400 ? 1400 : 1380,
                                 gop: gopIndex,
                                 pingOnly: pingOnly,
                                 fpsOverride: fpsIndex,
                                 bitrateOverride: UInt32(max(0, bitrateIndex) * 1000),
                                 resolutionDivisor: resolutionIndex == 0 ? 1 : 2)
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: engine.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text(engine.isRunning ? "停止投屏" : (pingOnly ? "开始（仅 ping）" : "开始投屏"))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(
                    Capsule(style: .continuous)
                        .fill(engine.isRunning
                              ? AnyShapeStyle(Color.red.gradient)
                              : AnyShapeStyle(LinearGradient(colors: [accent, accent2],
                                                             startPoint: .topLeading,
                                                             endPoint: .bottomTrailing)))
                )
                .foregroundColor(.white)
                .shadow(color: (engine.isRunning ? Color.red : accent).opacity(0.32),
                        radius: 14, y: 7)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [
                (scheme == .dark ? Color.black : Color.white).opacity(0.0),
                (scheme == .dark ? Color(red: 0.06, green: 0.07, blue: 0.10) : Color.white).opacity(0.95)
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - 图片预览 sheet
    private var imagePreviewSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let pendingImage {
                    previewImageView(pendingImage)
                        .frame(maxHeight: 340)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal)
                    Text("仪表上实际显示的样子（已按 \(rotationLabel) 铺满 \(DashboardPreset.all[presetIndex].width)×\(DashboardPreset.all[presetIndex].height)，超出部分裁掉）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Spacer()
                    Button {
                        confirmedImage = pendingImage
                        imageConfirmed = true
                        applySource()
                        showImagePreview = false
                    } label: {
                        Label("确认投这张图", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Capsule().fill(LinearGradient(colors: [accent, accent2],
                                                                     startPoint: .topLeading,
                                                                     endPoint: .bottomTrailing)))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("图片预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showImagePreview = false }
                }
            }
        }
    }

    private var rotationLabel: String { ["0°", "90°", "180°", "270°"][currentRotationStep] }

    // MARK: - 找 IP 工具 sheet
    private var toolsSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("仪表必须已由九号自己的巡航逻辑进入投屏接收态（官方 App 车辆页 → 仪表投屏导航 → 投屏导航，等仪表出地图）。然后从后台强退九号出行——它活着会占住本机 5012/5013 端口，包根本发不出去。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("按顺序试") {
                    Button {
                        fillGateway()
                    } label: {
                        Label("填入网关 .1（热点网关通常就是车机）", systemImage: "1.circle")
                    }
                    Button {
                        runProbe()
                    } label: {
                        Label(probing ? "体检中…" : "体检当前 IP（TCP 端口 + RTCP 5013）",
                              systemImage: "2.circle")
                    }
                    .disabled(probing)
                    Button {
                        runScan()
                    } label: {
                        Label(scanning ? "RTCP 扫描中…（约 2 秒）" : "扫全段 RTCP 5013",
                              systemImage: "3.circle")
                    }
                    .disabled(scanning)
                    Button {
                        runTcpScan()
                    } label: {
                        Label(tcpScanning ? "端口扫描中…（约 8 秒）" : "扫全段常见 TCP 端口",
                              systemImage: "4.circle")
                    }
                    .disabled(tcpScanning)
                }
                if !scanSummary.isEmpty {
                    Section("结果") {
                        Text(scanSummary)
                            .font(.footnote.monospaced())
                    }
                }
                Section {
                    Text("8443 只是车机常见网页端口之一，不同车型/固件不一样。真正的投屏通道只有 UDP 5012/5013。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("找仪表 IP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showTools = false }
                }
            }
        }
    }

    /// 按当前方向渲染「仪表上会看到的样子」
    private func previewImageView(_ image: UIImage) -> some View {
        let preset = DashboardPreset.all[presetIndex]
        let rotation = currentRotationDegrees
        let rendered = Self.renderPreview(image,
                                          rotation: rotation,
                                          width: preset.width,
                                          height: preset.height)
        return Image(uiImage: rendered)
            .resizable()
            .scaledToFill()
    }

    /// 用 CI 走一遍和投屏完全相同的旋转+铺满管线，所见即所得
    static func renderPreview(_ image: UIImage, rotation: Int, width: Int, height: Int) -> UIImage {
        guard var ci = CIImage(image: image) else {
            return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in }
        }
        switch rotation {
        case 90: ci = ci.oriented(.right)
        case 180: ci = ci.oriented(.down)
        case 270: ci = ci.oriented(.left)
        default: break
        }
        ci = FrameRenderer.aspectFillTransform(ci, destWidth: width, destHeight: height,
                                               mode: UserDefaults.standard.integer(forKey: "nbc.displayMode"))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let cg = previewContext.createCGImage(ci, from: rect) {
            return UIImage(cgImage: cg)
        }
        return UIGraphicsImageRenderer(size: rect.size).image { _ in }
    }

    // MARK: - 来源应用逻辑（只有确认过的素材才会真正上屏）
    private func applySource() {
        let rotation = currentRotationDegrees
        switch sourceIndex {
        case 0:
            engine.useTestImage()
        case 1:
            if imageConfirmed, let confirmedImage {
                engine.usePhoto(confirmedImage, rotation: rotation)
            } else {
                engine.useTestImage()
            }
        case 2:
            if videoConfirmed, let confirmedVideoURL {
                engine.useVideo(url: confirmedVideoURL, rotation: rotation)
            } else {
                engine.useTestImage()
            }
        case 3:
            engine.useCamera(position: cameraPositionIndex == 0 ? .back : .front,
                             rotation: rotation)
        default:
            break
        }
    }

    // MARK: - 找 IP 工具
    private func fillGateway() {
        guard let gateway = LanScanner.gatewayGuess() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        host = gateway
        scanSummary = "已填入网关 \(gateway)（车机热点自己发 DHCP，网关通常就是它）。\n填好点「体检」验一下，再开始投屏。"
    }

    private func runProbe() {
        let ip = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            scanSummary = "先填一个 IP 再体检"
            return
        }
        guard ip != localIP else {
            scanSummary = "这是本机地址（\(ip)），换仪表的 IP"
            return
        }
        probing = true
        scanSummary = "体检 \(ip) …（端口 + RTCP，约 3 秒）"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LanScanner.probe(ip: ip)
            DispatchQueue.main.async {
                probing = false
                var lines: [String] = []
                if result.openPorts.isEmpty {
                    lines.append("TCP：常见端口都没开")
                } else {
                    lines.append("TCP 开放：\(result.openPorts.map { String($0) }.joined(separator: ", "))")
                }
                lines.append(result.rtcpPong
                             ? "RTCP 5013：有 pong（\(result.rttMs)ms）"
                             : "RTCP 5013：无回应（不在接收态，或 IP 不对）")
                if !result.pongHex.isEmpty {
                    lines.append(result.pongHex)
                }
                scanSummary = lines.joined(separator: "\n")
            }
        }
    }

    private func runTcpScan() {
        guard let prefix = LanScanner.localPrefix() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        tcpScanning = true
        scanSummary = "扫 \(prefix).1-254 的 8443/80/443/5000/8080/8000/9000 …"
        LanScanner.tcpScan(prefix: prefix) { ip in
            host = ip
            scanSummary = "发现有开放端口：\(ip)（已回填）"
        } completion: { hits in
            tcpScanning = false
            if hits.isEmpty {
                scanSummary = "\(prefix).0/24 没有主机开放这些端口。\n换「网关 .1」或「扫 RTCP 5013」试试——端口只是线索，投屏通道是 UDP 5012/5013。"
            } else {
                scanSummary = hits
                    .map { "\($0.ip)  端口 \($0.ports.map { String($0) }.joined(separator: "/"))" }
                    .joined(separator: "\n")
            }
        }
    }

    private func runScan() {
        guard let prefix = LanScanner.localPrefix() else {
            scanSummary = "拿不到本机 Wi-Fi 地址：先连上仪表热点"
            return
        }
        scanning = true
        scanSummary = "扫描 \(prefix).1-254 的 5013（含广播探测）…"
        LanScanner.scan(prefix: prefix) { hit in
            host = hit.ip
            scanSummary = "先回应的：\(hit.ip) \(hit.rttMs)ms\n\(hit.replyHex)"
        } completion: { hits in
            scanning = false
            if hits.isEmpty {
                scanSummary = "\(prefix).0/24 没有主机在 5013 回应（本机已排除）。\n仪表多半还没进入投屏接收态——先在仪表/官方 App 里进接收态，再扫一次。"
            } else {
                scanSummary = hits.map { "\($0.ip)  \($0.rttMs)ms  ×\($0.replyCount)  \($0.replyHex)" }
                    .joined(separator: "\n")
            }
        }
    }
}

/// 系统录屏选择器：点一下弹出广播列表，选 Ninebot Pro+ 即开始屏幕镜像。
/// preferredExtension 预选我们的录屏扩展，省得用户在列表里找。
struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        // 必须带一个非零 frame 创建：零 frame 创建时内部按钮按零尺寸布局，
        // 之后 SwiftUI 再改尺寸也不会重新布局，按钮就一直空白。
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.preferredExtension = "com.corpsezhao.ninebotcast.screencast"
        view.showsMicrophoneButton = false
        return view
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

// MARK: - 实时小视图（1.3.9，修滑动卡顿）
// MainView 自己持有 @StateObject，body 里直接读每秒都在变的量会逼整个
// body 每秒重算。把高频刷新的行关进各自的独立 View，它们自己订阅对象，
// 只重画自己，MainView 不再直接读这些量。

/// 指标小格：原来是 MainView 的 private 成员，rideCard 和
/// EngineLiveStatsView 都要用，挪到文件级 private，两边共用。
private func metric(_ value: String, _ label: String,
                    highlight: Bool = false, warn: Bool = false) -> some View {
    VStack(spacing: 3) {
        Text(value)
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(warn ? Color.orange : (highlight ? Color.green : Color.primary))
        Text(label)
            .font(.caption2)
            .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity)
}

/// 指标之间的竖分隔线：同上，挪到文件级 private（函数形式，
//  避免文件级 some View 全局变量的写法风险）。
private func dividerView() -> some View {
    Rectangle()
        .fill(Color.primary.opacity(0.07))
        .frame(width: 1, height: 26)
}

/// 运行状态卡片里每秒都在变的那几行（帧/包/往返、实测 fps、心跳状态、
/// 仪表报告）：只订阅 CastEngine。帧计数原来每帧改一次 @Published，
/// 现在由 statTimer 每秒同步一次（CastEngine.sentFramesTotal），
/// 这里最多每秒刷新一次。
private struct EngineLiveStatsView: View {
    @ObservedObject var engine: CastEngine
    var accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                metric(String(engine.sentFrames), "帧已发送")
                dividerView()
                metric(String(engine.sentPackets), "包已发送")
                dividerView()
                metric(engine.rtcpPongCount > 0 ? "\(max(0, engine.lastRTTMs))" : "—",
                       "往返 ms",
                       highlight: engine.rtcpPongCount > 0)
            }
            if engine.isRunning {
                HStack(spacing: 0) {
                    metric("\(engine.measuredFps)", "实测 fps")
                    dividerView()
                    metric("\(engine.avgFrameKB)", "帧均 KB")
                    dividerView()
                    metric("\(engine.backlogPackets)", "待发积压",
                           warn: engine.backlogPackets > 120)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: engine.rtcpPongCount > 0 ? "checkmark.circle.fill" : "clock")
                    .font(.system(size: 12))
                Text(engine.rtcpPongCount > 0
                     ? (engine.droppedFrames > 0
                        ? "仪表在线 · 已回应 \(engine.rtcpPongCount) 次心跳 · 主动丢 \(engine.droppedFrames) 帧"
                        : "仪表在线，已回应 \(engine.rtcpPongCount) 次心跳")
                     : "等仪表回应心跳（2 秒以上）")
                    .font(.caption)
            }
            .foregroundColor(engine.rtcpPongCount > 0 ? .green : .secondary)

            if !engine.dashboardReport.isEmpty {
                Text(engine.dashboardReport)
                    .font(.caption)
                    .foregroundColor(accent)
            }
        }
    }
}

/// BMS 卡片里每秒变的诊断行（阶段/已发/收到）：只订阅 ANTBMS。
private struct BMSDiagLineView: View {
    @ObservedObject var antbms: ANTBMS

    var body: some View {
        Text("阶段：\(antbms.stage)　已发 \(antbms.pollCount) 次　收到 \(antbms.rxBytes) 字节\(antbms.notifyOn ? "　通知已开" : "")")
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}

/// 灯带卡片里每秒变的诊断行（阶段/已发/收到）：只订阅 ELKStrip。
private struct ELKDiagLineView: View {
    @ObservedObject var elk: ELKStrip

    var body: some View {
        Text("阶段：\(elk.stage)　已发 \(elk.writeCount) 次　收到 \(elk.rxBytes) 字节\(elk.notifyOn ? "　通知已开" : "")")
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}
