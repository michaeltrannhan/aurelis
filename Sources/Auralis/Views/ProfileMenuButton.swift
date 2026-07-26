import SwiftUI

struct ProfileMenuButton: View {
    @ObservedObject var store: AudioControlStore
    var compact = false

    @State private var isCreatingProfile = false
    @State private var profileName = ""

    var body: some View {
        Menu {
            if store.settings.profiles.isEmpty {
                Text("No profiles yet")
            } else {
                ForEach(store.settings.profiles) { profile in
                    Button {
                        store.applyProfileIntent(profile.id)
                    } label: {
                        Label(
                            profile.name,
                            systemImage: profile.id == store.settings.activeProfileID
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                    }
                }
            }

            Divider()

            Button {
                profileName = suggestedProfileName
                isCreatingProfile = true
            } label: {
                Label("Save Current as Profile…", systemImage: "plus")
            }

            if let activeProfile = store.activeProfile {
                Button {
                    store.updateProfileIntent(activeProfile.id)
                } label: {
                    Label("Update \(activeProfile.name)", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        } label: {
            if compact {
                Image(systemName: "square.stack.3d.up.fill")
                    .frame(width: 24, height: 24)
            } else {
                Label(
                    store.activeProfile?.name ?? "Profiles",
                    systemImage: "square.stack.3d.up.fill"
                )
                .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .help("Audio profiles")
        .accessibilityLabel("Audio profiles")
        .alert("Save Audio Profile", isPresented: $isCreatingProfile) {
            TextField("Profile name", text: $profileName)
            Button("Save") {
                store.createProfileIntent(named: profileName)
            }
            .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Captures app volume, mute, boost, EQ, routes, device levels, and the preferred output.")
        }
    }

    private var suggestedProfileName: String {
        let existing = Set(store.settings.profiles.map { $0.name.lowercased() })
        for candidate in ["Home", "Office", "Focus", "Profile"] where !existing.contains(candidate.lowercased()) {
            return candidate
        }
        return "Profile \(store.settings.profiles.count + 1)"
    }
}
