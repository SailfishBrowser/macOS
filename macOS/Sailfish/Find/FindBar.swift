import ComposableArchitecture
import SwiftUI

struct FindBar: View {
  @Bindable var store: StoreOf<FindFeature>
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color(hex: 0x979BA3))
      TextField(
        "", text: $store.query.sending(\.queryChanged),
        prompt: Text("Find on page").foregroundStyle(Theme.CommandBar.placeholder)
      )
      .textFieldStyle(.plain)
      .focused($isFocused)
      .onAppear { isFocused = true }
      .onSubmit { store.send(NSEvent.modifierFlags.contains(.shift) ? .previous : .next) }
      .onExitCommand { store.send(.close) }
      if store.isNotFound {
        Text("NOT FOUND").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.notFound)
      } else if !store.query.isEmpty, store.hasResult || store.matches > 0 {
        Text("\(store.activeMatch)/\(store.matches)").font(.system(size: 11)).monospacedDigit()
      }
      // Shot 51: the arrows 26 pt apart, the close button 32 past the down arrow and 16 from the end.
      HStack(spacing: 4) {
        button("arrow.up") { store.send(.previous) }
        button("arrow.down") { store.send(.next) }
      }
      button("xmark") { store.send(.close) }.padding(.leading, 2)
    }
    .font(.system(size: 13))
    .foregroundStyle(.white)
    .padding(.leading, 10)
    .padding(.trailing, 5)
    .frame(width: 300, height: 32)
    // Shot 51: radius 6, no edge light; a shadow of sigma 6 pt, 4 pt down, 63% at its core.
    .background(Theme.findBar, in: RoundedRectangle(cornerRadius: 6))
    .shadow(color: .black.opacity(0.6), radius: 6, y: 4)
  }

  private func button(_ systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName).font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
