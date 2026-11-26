import SwiftUI
import EhModels
import EhSettings
import EhDatabase

@MainActor
struct DownloadSetupRequest {
    let galleries: [GalleryInfo]
    let labels: [String]
    let submit: @MainActor (DownloadQuality, String?) -> Void

    init(galleries: [GalleryInfo], chooseLabel: Bool = false,
         submit: @escaping @MainActor (DownloadQuality, String?) -> Void) {
        self.galleries = galleries
        if chooseLabel && GalleryActionService.shared.downloadLabelChoiceNeeded() {
            labels = ((try? EhDatabase.shared.getAllDownloadLabels()) ?? []).map(\.label)
        } else {
            labels = []
        }
        self.submit = submit
    }
}

struct DownloadSetupNavigation: Sendable {
    let open: @MainActor @Sendable (DownloadSetupRequest) -> Void

    @MainActor
    func callAsFunction(_ request: DownloadSetupRequest) { open(request) }
}

private struct DownloadSetupNavigationKey: EnvironmentKey {
    static let defaultValue: DownloadSetupNavigation? = nil
}

extension EnvironmentValues {
    var ehDownloadSetupNavigation: DownloadSetupNavigation? {
        get { self[DownloadSetupNavigationKey.self] }
        set { self[DownloadSetupNavigationKey.self] = newValue }
    }
}

/// A full window page. It lives above the retained source workspace and
/// dismisses back to that same selection/scroll state, without modal alerts.
struct DownloadSetupView: View {
    let request: DownloadSetupRequest
    let close: () -> Void
    @State private var quality = AppSettings.shared.defaultDownloadQuality
    @State private var label: String?
    @State private var rememberLabel = false
    @State private var requiresConsent = DownloadNetworkPrompt.requiresConfirmation
    @State private var submitted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: close) {
                    Image(systemName: "chevron.backward")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("返回")
                .accessibilityIdentifier("download-setup-back")
                Text("下载设置")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    summary
                    if requiresConsent { networkWarning }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本次清晰度").font(.headline).accessibilityAddTraits(.isHeader)
                        DownloadQualityChoices(selection: quality) { quality = $0 }
                    }
                    if !request.labels.isEmpty { labelChoices }
                    Text("已有下载任务沿用原清晰度。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 560)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                Text(quality.title)
                    .foregroundStyle(.secondary)
                    .font(.subheadline.monospacedDigit())
                Spacer()
                Button(action: submit) {
                    Label(requiresConsent ? "继续下载" : "加入下载队列", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(submitted)
                .accessibilityIdentifier("download-setup-submit")
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .tint(EhColor.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EhColor.groupedBackground.ignoresSafeArea())
        .accessibilityIdentifier("download-setup-page")
    }

    private var summary: some View {
        HStack(spacing: 14) {
            Image(systemName: request.galleries.count == 1 ? "arrow.down.to.line" : "tray.full")
                .font(.title2.weight(.semibold))
                .foregroundStyle(EhColor.accent)
                .frame(width: 54, height: 54)
                .background(EhColor.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(request.galleries.count == 1
                     ? request.galleries[0].bestTitle
                     : "\(request.galleries.count) 项下载")
                    .font(.headline)
                    .lineLimit(3)
                if let gallery = request.galleries.first, request.galleries.count == 1, gallery.pages > 0 {
                    Text("\(gallery.pages) 页").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .ehCard(cornerRadius: 18)
    }

    private var networkWarning: some View {
        Label("当前使用蜂窝网络或受限网络。", systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(EhColor.warning)
            .accessibilityIdentifier("download-setup-network-warning")
    }

    private var labelChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("下载分类").font(.headline).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                labelRow("未分类", value: nil)
                ForEach(request.labels, id: \.self) { label in
                    Divider().padding(.leading, 14)
                    labelRow(label, value: label)
                }
            }
            .ehCard()
            Toggle("记住下载分类", isOn: $rememberLabel)
                .font(.subheadline)
        }
    }

    private func labelRow(_ title: String, value: String?) -> some View {
        Button {
            label = value
        } label: {
            HStack {
                Text(title).foregroundStyle(EhColor.label)
                Spacer()
                if label == value {
                    Image(systemName: "checkmark").foregroundStyle(EhColor.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(label == value ? .isSelected : [])
    }

    private func submit() {
        guard !submitted else { return }
        // A switch to a metered network while this page is open must not
        // silently enqueue on the first tap.
        if !requiresConsent && DownloadNetworkPrompt.requiresConfirmation {
            requiresConsent = true
            return
        }
        submitted = true
        if !request.labels.isEmpty && rememberLabel {
            AppSettings.shared.hasDefaultDownloadLabel = true
            AppSettings.shared.defaultDownloadLabel = label
        }
        request.submit(quality, label)
        close()
    }
}

struct DefaultDownloadQualityView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("用于新下载。单次选择不会修改默认值。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                DownloadQualityChoices(selection: AppSettings.shared.defaultDownloadQuality) {
                    AppSettings.shared.defaultDownloadQuality = $0
                }
            }
            .frame(maxWidth: 560)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(EhColor.groupedBackground)
        .navigationTitle("默认下载清晰度")
    }
}

private struct DownloadQualityChoices: View {
    let selection: DownloadQuality
    let choose: (DownloadQuality) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            choices(columns: 2, minimum: 126)
            choices(columns: 1, minimum: 0)
        }
    }

    private func choices(columns: Int, minimum: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: minimum), spacing: 9), count: columns), spacing: 9) {
            ForEach(DownloadQuality.allCases) { quality in
                let selected = quality == selection
                Button {
                    choose(quality)
                } label: {
                    HStack(spacing: 9) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(quality.title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(EhColor.label)
                            if let detail = detail(for: quality) {
                                Text(detail).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 2)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? EhColor.accent : EhColor.tertiaryLabel)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(minHeight: 51)
                    .background(selected ? EhColor.accent.opacity(0.09) : EhColor.card,
                                in: RoundedRectangle(cornerRadius: 13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .strokeBorder(selected ? EhColor.accent.opacity(0.65) : EhColor.cardStroke, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("download-quality-\(quality.rawValue)")
            }
        }
    }

    private func detail(for quality: DownloadQuality) -> String? {
        switch quality {
        case .auto: return "使用站点自动分辨率"
        case .original: return "无原图链接时使用自动"
        default: return nil
        }
    }
}
