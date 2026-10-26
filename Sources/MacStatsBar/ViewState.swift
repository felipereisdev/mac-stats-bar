import SwiftUI

// SDK 27 also exports a State macro whose plugin is absent from Command Line Tools.
// Resolve the original property wrapper in type context, keeping Swift 5.9 builds working.
typealias ViewState<Value> = SwiftUI.State<Value>
