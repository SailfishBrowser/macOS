import SwiftUI

// The JavaScript dialog: a dark card with the app icon, centered over the dimmed page.
struct PageDialogView: View {
  let dialog: PageDialog
  @State private var text: String
  @FocusState private var focus: Focus?

  private enum Focus { case dialog, text }

  init(dialog: PageDialog) {
    self.dialog = dialog
    _text = State(initialValue: dialog.defaultText)
  }

  var body: some View {
    ZStack {
      Color.black.opacity(0.45)
      VStack(spacing: 0) {
        // Shot 52: the icon's art is 52 pt, so a 64 pt icon 20 pt below the top; the title's ascender 107 pt down.
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
        Text(dialog.title).font(.system(size: 13, weight: .bold)).padding(.top, 20)
        if !dialog.message.isEmpty {
          // Shot 52: the message 25 pt below the title, the button 29 pt below the message.
          Text(dialog.message).font(.system(size: 11)).multilineTextAlignment(.center).padding(.top, 9)
        }
        if dialog.type == .prompt {
          TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focus, equals: .text)
            .onSubmit { answer(true) }
            .onExitCommand { answer(false) }
            .padding(.top, 10)
        }
        HStack(spacing: 8) {
          if dialog.type != .alert {
            button(dialog.type == .beforeUnload ? "Stay" : "Cancel", isDefault: false) { answer(false) }
          }
          button(dialog.type == .beforeUnload ? "Leave" : "OK", isDefault: true) { answer(true) }
        }
        .padding(.top, 18)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.top, 20)
      .padding(.bottom, 16)
      .frame(width: 260)
      // Shot 52: body #36383B inside a light hairline, with a dark line outside it.
      .background(Color(hex: 0x36383B), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
      .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.black.opacity(0.45)).padding(-1))
      .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
      .environment(\.colorScheme, .dark)
    }
    // The page keeps the keyboard otherwise; Return answers OK and Escape cancels.
    .focusable()
    .focusEffectDisabled()
    .focused($focus, equals: .dialog)
    .onAppear { focus = dialog.type == .prompt ? .text : .dialog }
    .onKeyPress(.return) {
      answer(true)
      return .handled
    }
    .onKeyPress(.escape) {
      answer(dialog.type == .alert)
      return .handled
    }
  }

  private func answer(_ accepted: Bool) {
    dialog.answer(accepted, text)
  }

  private func button(_ title: String, isDefault: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).frame(height: 28)
        .background(isDefault ? Color(hex: 0x2F73E0) : .white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
