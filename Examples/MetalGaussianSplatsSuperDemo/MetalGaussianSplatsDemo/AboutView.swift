import SwiftUI

#if os(macOS)
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
#endif

struct AboutView: View {
    @State private var licenses: [(name: String, text: String)] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // App Icon and Name
                VStack(spacing: 8) {
                    Image(.splatCloud)
                        .resizable()
                        .accessibilityLabel("App Icon")
                        .frame(width: 180, height: 180)
                        .glimmer(
                            sweepDuration: 1.5,
                            pauseDuration: 4.0,
                            gradientWidth: 0.25,
                            maxLightness: 0.6,
                            angle: 35.0
                        )

                    #if !os(iOS)
                    Text("Gaussian Splats Demo")
                        .font(.title)
                        .fontWeight(.bold)
                    #endif

                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                        Text("Version \(version) (\(build))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 16) {
                        Link("metalsprockets.com", destination: URL(string: "https://metalsprockets.com")!)
                        Link("schwa.io", destination: URL(string: "https://schwa.io")!)
                        Link("github.com/schwa/MetalSprocketsGaussianSplats", destination: URL(string: "https://github.com/schwa/MetalSprocketsGaussianSplats")!)
                    }
                    .font(.subheadline)
                }

                Divider()

                // Acknowledgements
                VStack(alignment: .leading, spacing: 12) {
                    Text("Acknowledgements")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(licenses, id: \.name) { license in
                            LicenseSection(title: license.name, text: license.text)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(24)
        }
        #if os(macOS)
        .frame(width: 500, height: 600)
        #endif
        .onAppear {
            licenses = loadLicenses()
        }
        .navigationTitle("About Gaussian Splats Demo")
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
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                ShareLink(item: text) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                        .accessibilityLabel("Share license")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

#Preview {
    AboutView()
}
