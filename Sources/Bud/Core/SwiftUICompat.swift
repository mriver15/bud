import SwiftUI

/// Reaches SwiftUI's `State` property-wrapper struct under a name that is not
/// shadowed by a macro.
///
/// Why this exists: in the macOS 26 SDK, `@State` resolves to a *macro*
/// (`SwiftUIMacros.StateMacro`) rather than the property wrapper. The plugin that
/// implements it ships only inside Xcode's toolchain. On a machine with just the
/// Command Line Tools the plugin is absent and every `@State` fails to compile:
///
///     external macro implementation type 'SwiftUIMacros.StateMacro' could not be
///     found for macro 'State()'; plugin for module 'SwiftUIMacros' not found
///
/// The underlying `SwiftUICore.State` struct is still public and complete, and a
/// macro only wins the name `State` in attribute position. Aliasing the struct
/// under a different name therefore reaches the identical implementation with
/// identical semantics — storage, `$` projections and invalidation all behave
/// exactly as `@State` does, because it *is* `@State`'s type.
///
/// Every other wrapper is unaffected and must be used unqualified: `@StateObject`,
/// `@ObservedObject`, `@EnvironmentObject`, `@Environment`, `@Binding`,
/// `@FocusState`, `@AppStorage`, `@SceneStorage` and `@Bindable` all compile
/// against the Command Line Tools alone. Only `@State` (and `#Preview`) need
/// Xcode's plugin.
///
/// If Xcode is ever installed, `@State` becomes available again and this alias
/// keeps working unchanged — but do not mix the two spellings in one codebase.
public typealias BudState = SwiftUICore.State
