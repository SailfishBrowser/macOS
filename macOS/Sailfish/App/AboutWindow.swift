import AppKit
import ComposableArchitecture
import SwiftUI

// The About window: the chosen app icon, the name, the app and Chromium versions, and an update check. It follows
// the system appearance and is reused while the app runs.
@MainActor
func makeAboutWindow(checkForUpdates: (() -> Void)?, showAcknowledgements: @escaping () -> Void) -> NSWindow {
  let host = NSHostingController(
    rootView: AboutView(checkForUpdates: checkForUpdates, showAcknowledgements: showAcknowledgements))
  host.sizingOptions = .preferredContentSize
  let window = NSWindow(contentViewController: host)
  window.styleMask = [.titled, .closable, .fullSizeContentView]
  window.titlebarAppearsTransparent = true
  window.titleVisibility = .hidden
  window.title = "About \(AboutView.info("CFBundleName"))"
  window.isReleasedWhenClosed = false
  window.isExcludedFromWindowsMenu = true
  window.center()
  return window
}

private struct AboutView: View {
  let checkForUpdates: (() -> Void)?
  let showAcknowledgements: () -> Void
  @Shared(.appIcon) private var icon

  static func info(_ key: String, of bundle: Bundle = .main) -> String {
    bundle.object(forInfoDictionaryKey: key) as! String
  }

  private static let engine = Bundle(url: Bundle.main.privateFrameworksURL!.appending(path: "EngineCore.framework"))!

  var body: some View {
    VStack(spacing: 0) {
      Image(nsImage: icon.image()).resizable().frame(width: 96, height: 96)
      Text(Self.info("CFBundleName")).font(.system(size: 20, weight: .semibold)).padding(.top, 10)
      VStack(spacing: 3) {
        Text("Version \(Self.info("CFBundleShortVersionString")) (\(Self.info("CFBundleVersion")))")
        Text("Chromium \(Self.info("CFBundleShortVersionString", of: Self.engine))")
      }
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
      .padding(.top, 6)
      HStack(spacing: 8) {
        Button("Check for Updates…") { checkForUpdates?() }.disabled(checkForUpdates == nil)
        Button("Acknowledgements", action: showAcknowledgements)
      }
      .padding(.top, 20)
    }
    .padding(.top, 40)
    .padding(.bottom, 24)
    .frame(width: 340)
  }
}

// The open source components the app includes, each as its name over its license, from Acknowledgements.json.
@MainActor
func makeAcknowledgementsWindow() -> NSWindow {
  let host = NSHostingController(rootView: AcknowledgementsView())
  host.sizingOptions = .preferredContentSize
  let window = NSWindow(contentViewController: host)
  window.styleMask = [.titled, .closable, .miniaturizable]
  window.title = "Acknowledgements"
  window.isReleasedWhenClosed = false
  window.center()
  return window
}

private struct Acknowledgement: Decodable, Hashable {
  let name: String
  let license: String
}

private struct AcknowledgementsView: View {
  private static let all = try! JSONDecoder().decode(
    [Acknowledgement].self,
    from: Data(contentsOf: Bundle.main.url(forResource: "Acknowledgements", withExtension: "json")!))

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        ForEach(Self.all, id: \.self) { item in
          VStack(alignment: .leading, spacing: 2) {
            Text(item.name).font(.system(size: 13, weight: .semibold))
            Text(item.license).font(.system(size: 12)).foregroundStyle(.secondary)
          }
        }
      }
      .textSelection(.enabled)
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 440, height: 480)
  }
}
