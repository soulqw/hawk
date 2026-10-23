import SwiftUI

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified)
    }
}
