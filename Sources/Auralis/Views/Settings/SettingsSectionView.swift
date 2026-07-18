import SwiftUI

/// Shared helpers so each settings tab reads consistently. `settingsCustomizationBinding`
/// mirrors the pattern the old single-form SettingsView used.
@MainActor
func settingsCustomizationBinding<Value>(
    store: AudioControlStore,
    _ keyPath: WritableKeyPath<AppCustomization, Value>
) -> Binding<Value> {
    Binding(
        get: { store.settings.customization[keyPath: keyPath] },
        set: { newValue in
            var customization = store.settings.customization
            customization[keyPath: keyPath] = newValue
            store.applyCustomizationIntent(customization)
        }
    )
}

func settingsHelper(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
}
