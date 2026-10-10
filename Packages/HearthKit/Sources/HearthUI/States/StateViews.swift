import HearthData
import HearthModel
import SwiftUI

/// Pulsing symbol + "Loading…".
public struct LoadingView: View {
    let title: String?
    let systemImage: String

    public init(_ title: String? = nil, systemImage: String = "books.vertical.fill") {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)
            Text(title ?? loc("Loading…"))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// "Content unavailable — make sure Hearth can reach your server" with a Retry button.
public struct ErrorView: View {
    let title: String?
    let message: String?
    let retry: (@MainActor () async -> Void)?

    public init(title: String? = nil, message: String? = nil, retry: (@MainActor () async -> Void)? = nil) {
        self.title = title
        self.message = message
        self.retry = retry
    }

    public init(error: any Error, retry: (@MainActor () async -> Void)? = nil) {
        self.init(title: nil, message: Self.message(for: error), retry: retry)
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title ?? loc("Content unavailable"), systemImage: "wifi.exclamationmark")
        } description: {
            Text(message ?? loc("Make sure Hearth can reach your server."))
        } actions: {
            if let retry {
                Button {
                    Task { await retry() }
                } label: {
                    Text(loc("Retry"))
                }
                #if !os(watchOS)
                .buttonStyle(.glass)
                #endif
            }
        }
    }

    static func message(for error: any Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return loc("Make sure Hearth can reach your server.")
    }
}

/// "No items" / custom empty state.
public struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String?

    public init(title: String? = nil, systemImage: String = "tray", message: String? = nil) {
        self.title = title ?? loc("No items")
        self.systemImage = systemImage
        self.message = message
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        }
    }
}

/// Generic async load state.
public enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(any Error)

    public var value: Value? {
        if case .loaded(let value) = self { value } else { nil }
    }

    public var isLoading: Bool {
        if case .loading = self { true } else { false }
    }
}

/// Renders a `LoadState` with the standard loading / error views.
public struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    let retry: (@MainActor () async -> Void)?
    let content: (Value) -> Content

    public init(_ state: LoadState<Value>, retry: (@MainActor () async -> Void)? = nil, @ViewBuilder content: @escaping (Value) -> Content) {
        self.state = state
        self.retry = retry
        self.content = content
    }

    public var body: some View {
        switch state {
        case .loading:
            LoadingView()
        case .failed(let error):
            ErrorView(error: error, retry: retry)
        case .loaded(let value):
            content(value)
        }
    }
}

#if DEBUG
#Preview("States") {
    TabView {
        LoadingView().tabItem { Text(verbatim: "Loading") }
        ErrorView(retry: {}).tabItem { Text(verbatim: "Error") }
        EmptyStateView().tabItem { Text(verbatim: "Empty") }
    }
    .tint(TintColor.hearth.color)
}
#endif
