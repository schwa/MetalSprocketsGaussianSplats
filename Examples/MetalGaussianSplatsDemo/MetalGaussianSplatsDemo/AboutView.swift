#if os(macOS)
import AppKit
import SwiftUI

struct AboutCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Gaussian Splats Demo") {
                openWindow(id: "about")
            }
        }
    }
}

struct AboutView: View {
    @State private var licenses: [(name: String, text: String)] = []

    var body: some View {
        VStack(spacing: 20) {
            // App Icon and Name
            VStack(spacing: 8) {
                if let appIcon = NSApplication.shared.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 128, height: 128)
                }

                Text("Gaussian Splats Demo")
                    .font(.title)
                    .fontWeight(.bold)

                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Text("Version \(version) (\(build))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    Link("metalsprockets.com", destination: URL(string: "https://metalsprockets.com")!)
                    Link("schwa.io", destination: URL(string: "https://schwa.io")!)
                }
                .font(.subheadline)
            }

            Divider()

            // Acknowledgements
            VStack(alignment: .leading, spacing: 12) {
                Text("Acknowledgements")
                    .font(.headline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(licenses, id: \.name) { license in
                            LicenseSection(title: license.name, text: license.text)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear {
            licenses = loadLicenses()
        }
    }

    private func loadLicenses() -> [(name: String, text: String)] {
        guard let resourceURL = Bundle.main.resourceURL else {
            return []
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains("-LICENSE") || $0.lastPathComponent.contains("_LICENSE") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            return files.compactMap { url -> (name: String, text: String)? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    return nil
                }
                let name = url.lastPathComponent
                    .replacingOccurrences(of: "-LICENSE", with: "")
                    .replacingOccurrences(of: "_LICENSE", with: "")
                    .replacingOccurrences(of: ".txt", with: "")
                    .replacingOccurrences(of: ".md", with: "")
                    .replacingOccurrences(of: "_", with: " ")
                return (name: name, text: text)
            }
        } catch {
            return []
        }
    }
}

private struct LicenseSection: View {
    let title: String
    let text: String

    var body: some View {
        Section {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } header: {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
    }
}

#Preview {
    AboutView()
}
#endif
