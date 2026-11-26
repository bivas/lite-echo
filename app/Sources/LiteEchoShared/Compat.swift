import SwiftUI

/// Building without Xcode (Command Line Tools only) has no SwiftUI macro plugin, so the
/// macro forms `@State` and `@Entry` do not compile. The classic property wrapper still exists:
///
///     @StateVar private var count = 0        // instead of @State
///
/// For environment values, write an `EnvironmentKey` instead of `@Entry`.
/// `@Observable`, `@Environment`, `@Binding`, `@StateObject`, `@AppStorage`, `@FocusState`
/// all work as usual.
public typealias StateVar = SwiftUI.State

/// Window identifiers for `openWindow(id:)` / `openWindow(id:value:)`.
public enum WindowID {
    /// The main queue window (`Window`).
    public static let main = "main"
}

public extension Binding where Value: Equatable {
    /// A binding that ignores writes of the value it already holds.
    ///
    /// Some SwiftUI scenes write their binding back on every update: `MenuBarExtra(isInserted:)`
    /// does when the app is built against the macOS 15 SDK. With an `@Observable` source each
    /// write counts as a change, even for the same value, so the scene body runs again, the
    /// binding is written again, and the app spins at 100% CPU without ever drawing a window.
    func ignoringRepeatedValues() -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { newValue, transaction in
            guard newValue != wrappedValue else { return }
            self.transaction(transaction).wrappedValue = newValue
        })
    }
}
