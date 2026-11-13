import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?

    var body: some View {
        SettingsForm(
            preferences: model.preferences,
            launchAtLogin: $launchAtLogin,
            loginMessage: loginMessage
        ) { enabled in
            loginMessage = model.setLaunchAtLogin(enabled)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .frame(width: 460)
        .padding(20)
    }
}

private struct SettingsForm: View {
    @Bindable var preferences: Preferences
    @Binding var launchAtLogin: Bool
    var loginMessage: String?
    var setLaunchAtLogin: (Bool) -> Void

    var body: some View {
        Form {
            Section {
                Picker("Görünüm", selection: $preferences.style) {
                    ForEach(WallpaperStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Karartma") {
                        Slider(value: $preferences.dim, in: 0...0.55)
                            .frame(width: 180)
                    }
                    Text("Masaüstü simgeleri okunsun diye kapağı hafifçe koyulaştırır.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Tüm ekranlarda kullan", isOn: $preferences.allScreens)
                Toggle("Müzik durunca kapağı koru", isOn: $preferences.keepArtworkWhenIdle)
                Toggle("Çıkışta özgün duvar kağıdını geri yükle", isOn: $preferences.restoreOnQuit)
            } header: {
                Text("Duvar kağıdı")
            }

            Section {
                Toggle("Kontrolleri göster", isOn: $preferences.controlsVisible)
                Toggle("Masaüstünde sözleri göster", isOn: $preferences.lyricsVisible)
                Toggle("Pencerelerin üzerinde tut", isOn: $preferences.floatAboveWindows)
                Toggle("Açılışta başlat", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginMessage {
                    Text(loginMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Kontrol çubuğu")
            } footer: {
                Text("Kontroller yalnızca masaüstünde durur ve bir pencere açılınca arkada kalır.")
            }
        }
        .formStyle(.grouped)
    }
}
