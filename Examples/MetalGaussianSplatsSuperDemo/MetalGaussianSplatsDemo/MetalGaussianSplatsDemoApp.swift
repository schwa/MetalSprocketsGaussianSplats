import SwiftUI
import UniformTypeIdentifiers

#if os(visionOS)
import MetalSprockets
import MetalSprocketsGaussianSplats
import MetalSprocketsUI
#endif

@main
struct MetalGaussianSplatsDemoApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        SplashScene()
        #endif

        #if os(iOS)
        WindowGroup {
            MobileLaunchView()
        }
        #endif

        #if os(visionOS)
        DocumentGroupLaunchScene()
        #endif

        DocumentGroup(viewing: SplatDocument.self) { file in
            SplatDocumentView(document: file.document, fileURL: file.fileURL)
        }
        .commands {
            InspectorCommands()
            #if os(macOS)
            AboutCommand()
            #endif
        }

        #if os(macOS) || os(iOS)
        DocumentGroup(newDocument: SplatSceneDocument()) { file in
            SplatSceneView(document: file.$document)
        }
        #endif

        #if os(macOS)
        Window("About Gaussian Splats Demo", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        #endif

        #if os(visionOS)
        ImmersiveSpace(id: "GaussianSplatImmersive") {
            ImmersiveRenderContent(progressive: false) { context in
                try ImmersiveRenderPass(context: context, label: "GaussianSplat") {
                    try GaussianSplatImmersiveContent(context: context)
                }
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.visible)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_: Notification) {
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowClose(notification)
        }
    }

    private func handleWindowClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }

        // Check if this is a document window (not splash, settings, etc.)
        guard closingWindow.identifier?.rawValue.contains("document") == true || NSDocumentController.shared.document(for: closingWindow) != nil else {
            return
        }

        // Delay slightly to allow the window to actually close
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.reopenSplashIfNeeded()
        }
    }

    private func reopenSplashIfNeeded() {
        // Count remaining document windows
        let documentWindows = NSApp.windows.filter { window in
            window.isVisible &&
                (window.identifier?.rawValue.contains("document") == true ||
                    NSDocumentController.shared.document(for: window) != nil)
        }

        // If no document windows remain, open splash
        if documentWindows.isEmpty {
            // Find existing splash window or it will be auto-created
            if let splashWindow = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("splash") == true }) {
                splashWindow.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // No visible windows, show splash
            if let splashWindow = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("splash") == true }) {
                splashWindow.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}
#endif
