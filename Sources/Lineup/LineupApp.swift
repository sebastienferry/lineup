import SwiftUI

@main
struct LineupApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(store)
                .frame(width: 520, height: 640)
                // Opaque: the default translucent material lets the window behind show through
                // the rows and blurs the text.
                .background(Color(nsColor: .windowBackgroundColor))
        } label: {
            MenuBarLabel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar item: an icon, and the number of unread notifications when there are any.
struct MenuBarLabel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let unread = store.unreadCount
        HStack(spacing: 2) {
            Image(systemName: "checklist")
            if unread > 0 {
                Image(systemName: "bell.badge")
                Text("\(unread)")
            }
        }
        .task { store.start() }
    }
}
