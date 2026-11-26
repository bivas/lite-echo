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
