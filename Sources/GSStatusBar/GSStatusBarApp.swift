import SwiftUI

@main
enum Main {
    @MainActor
    static func main() {
        #if !APP_STORE
        // `GSStatusBar --snapshot <dir> [--sample]` renders the UI to PNGs and exits (for checking layout).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(outputDir: args[i + 1], useSampleData: args.contains("--sample"))
            return
        }
        #endif
        GSStatusBarApp.main()
    }
}

struct GSStatusBarApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store)
        } label: {
            Image(nsImage: MenuBarLabel.image(for: MenuBarLabel.segments(for: store)))
        }
        .menuBarExtraStyle(.window)
    }
}
