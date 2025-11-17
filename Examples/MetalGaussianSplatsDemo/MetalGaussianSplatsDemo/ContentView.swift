import SwiftUI

enum Renderer: String, CaseIterable, Identifiable {
    case antimatter15 = "Antimatter15"
    case spark = "Spark"

    var id: String { rawValue }
}

struct ContentView: View {
    @State private var selectedRenderer: Renderer? = .antimatter15

    var body: some View {
        NavigationView {
            List(selection: $selectedRenderer) {
                ForEach(Renderer.allCases) { renderer in
                    NavigationLink(value: renderer) {
                        Label(renderer.rawValue, systemImage: "scope")
                    }
                }
            }
            .navigationTitle("Renderers")
            .frame(minWidth: 200)

            rendererView
        }
    }

    @ViewBuilder
    private var rendererView: some View {
        if let selectedRenderer {
            switch selectedRenderer {
            case .antimatter15:
                Antimatter15GaussianSplatDemoView()
            case .spark:
                SparkGaussianSplatDemoView()
            }
        } else {
            Text("Select a renderer")
                .font(.title)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
