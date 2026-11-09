import SwiftUI

enum AppTab: String, CaseIterable, Hashable {
    case home
    case servers
    case settings

    var title: String {
        switch self {
        case .home: return L("Подключение")
        case .servers: return L("Серверы")
        case .settings: return L("Настройки")
        }
    }

    var icon: String {
        switch self {
        case .home: return "power.circle"
        case .servers: return "server.rack"
        case .settings: return "gearshape"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: return "power.circle.fill"
        case .servers: return "server.rack"
        case .settings: return "gearshape.fill"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: AppTab = .home

    var body: some View {
        let settings = model.settings
        let palette = Palette.make(settings: settings, scheme: settings.theme.colorScheme ?? colorScheme)
        ZStack(alignment: .top) {
            tabs(palette)
            if let banner = model.banner {
                BannerView(banner: banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.banner = nil }
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.banner)
        .environment(\.palette, palette)
        .tint(palette.accent)
        .fontDesign(palette.usesRoundedFont ? .rounded : .default)
        .preferredColorScheme(settings.theme.colorScheme)
        .onChange(of: settings.fontFile) { _, _ in FontLibrary.applyAppearance(settings) }
        .onChange(of: settings.appearance) { _, _ in FontLibrary.applyAppearance(settings) }
    }

    @ViewBuilder
    private func tabs(_ palette: Palette) -> some View {
        if palette.appearance == .material {
            TabView(selection: $tab) {
                ForEach(AppTab.allCases, id: \.self) { item in
                    screen(item)
                        .toolbar(.hidden, for: .tabBar)
                        .tag(item)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MaterialNavigationBar(selection: $tab)
            }
        } else {
            TabView(selection: $tab) {
                ForEach(AppTab.allCases, id: \.self) { item in
                    screen(item)
                        .tabItem {
                            if model.settings.hideTabLabels {
                                Image(systemName: tab == item ? item.selectedIcon : item.icon)
                            } else {
                                Label(item.title, systemImage: tab == item ? item.selectedIcon : item.icon)
                            }
                        }
                        .tag(item)
                }
            }
        }
    }

    @ViewBuilder
    private func screen(_ item: AppTab) -> some View {
        switch item {
        case .home: HomeView(openServers: { tab = .servers })
        case .servers: ServersView()
        case .settings: SettingsView()
        }
    }
}

/// Material 3 navigation bar with a pill indicator behind the selected icon.
struct MaterialNavigationBar: View {
    @Binding var selection: AppTab
    @Environment(\.palette) private var palette
    @Environment(AppModel.self) private var model
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { item in
                Button {
                    if selection != item { Haptics.selection() }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = item }
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            if selection == item {
                                Capsule()
                                    .fill(palette.accentContainer)
                                    .frame(width: 64, height: 32)
                                    .matchedGeometryEffect(id: "pill", in: indicator)
                            }
                            Image(systemName: selection == item ? item.selectedIcon : item.icon)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(selection == item ? palette.onAccentContainer : palette.secondaryText)
                        }
                        .frame(height: 32)
                        if !model.settings.hideTabLabels {
                            Text(item.title)
                                .font(appFont(.caption, weight: selection == item ? .bold : .medium))
                                .foregroundStyle(selection == item ? palette.primaryText : palette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(palette.surface.ignoresSafeArea(edges: .bottom))
    }
}
