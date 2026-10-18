import SwiftUI

/// macOS 27 CLT exports a same-named State macro without its plugin. A concrete
/// DynamicProperty wrapper keeps the macOS 14 State storage and avoids that macro.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>
    init(wrappedValue: Value) { storage = SwiftUI.State(initialValue: wrappedValue) }
    init(initialValue: Value) { storage = SwiftUI.State(initialValue: initialValue) }
    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { storage.projectedValue }
    mutating func update() { storage.update() }
}
