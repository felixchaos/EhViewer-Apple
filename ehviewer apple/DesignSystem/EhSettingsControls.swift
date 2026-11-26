#if os(iOS)
import SwiftUI

/// Settings rows carry one activation and one accessibility element. The
/// native switch draws the indicator; pressing anywhere on the row changes it.
struct EhSettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: 12)
                Toggle(isOn: configuration.$isOn) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}
#endif
