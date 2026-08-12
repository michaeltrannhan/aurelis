import SwiftUI

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
