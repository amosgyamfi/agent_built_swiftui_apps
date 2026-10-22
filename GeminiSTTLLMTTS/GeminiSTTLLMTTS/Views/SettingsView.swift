import SwiftUI

struct SettingsView: View {
    @Bindable var agent: VoiceAgent

    @Environment(\.dismiss) private var dismiss
    @State private var apiKeyDraft = ""

    private var trimmedDraft: String {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                apiKeySection

                Section("Voice") {
                    Picker("Voice", selection: $agent.voice) {
                        ForEach(GeminiModels.voices) { voice in
                            Text("\(voice.name) · \(voice.character)").tag(voice.name)
                        }
                    }
                }

                Section {
                    LabeledContent("Speech-to-text", value: GeminiModels.transcription.name)
                    modelPicker("Language model", options: GeminiModels.conversationOptions, selection: $agent.conversationModel)
                    modelPicker("Text-to-speech", options: GeminiModels.speechOptions, selection: $agent.speechModel)
                } header: {
                    Text("Pipeline")
                } footer: {
                    Text("Model changes apply from the next turn.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var apiKeySection: some View {
        Section {
            if APIKeyStore.environmentKey != nil {
                Label("Using GEMINI_API_KEY from the scheme environment.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }

            SecureField(agent.hasStoredAPIKey ? "Replace saved key" : "Paste your API key", text: $apiKeyDraft)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit(saveKey)

            Button("Save Key", action: saveKey)
                .disabled(trimmedDraft.isEmpty)

            if agent.hasStoredAPIKey {
                Button("Remove Saved Key", role: .destructive) {
                    agent.removeAPIKey()
                }
            }
        } header: {
            Text("Gemini API Key")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved to this device's Keychain. Calls go straight from the app to the Gemini API.")
                Link("Get a key in Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
            }
        }
    }

    private func modelPicker(_ title: String, options: [ModelOption], selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(options) { option in
                VStack(alignment: .leading) {
                    Text(option.name)
                    Text(option.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(option.id)
            }
        }
        #if os(iOS)
        .pickerStyle(.navigationLink)
        #endif
    }

    private func saveKey() {
        guard !trimmedDraft.isEmpty else { return }
        agent.saveAPIKey(trimmedDraft)
        apiKeyDraft = ""
    }
}

#Preview {
    SettingsView(agent: VoiceAgent())
}
