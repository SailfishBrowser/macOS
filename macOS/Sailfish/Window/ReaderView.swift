import SwiftUI
import WebKit

enum ReaderTheme: String, CaseIterable, Equatable {
  case light, sepia, dark

  var background: Color {
    switch self {
    case .light: Color(red: 1, green: 1, blue: 1)
    case .sepia: Color(red: 0.97, green: 0.94, blue: 0.87)
    case .dark: Color(red: 0.12, green: 0.12, blue: 0.13)
    }
  }
}

struct ReaderSettings: Equatable {
  static let sizes = [14, 16, 18, 20, 22, 24, 28, 32]
  var step: Int
  var isSerif: Bool
  var theme: ReaderTheme
}

// The article as a page of its own: no script of its own runs, it keeps no data, and it loads only https and inline
// images.
enum ReaderDocument {
  static let contentSecurityPolicy = "default-src 'none'; img-src https: data:; style-src 'unsafe-inline'"
  static let stylesheet = """
    :root { --size: 20px; background: #fff; color: #1d1d1f; }
    :root[data-theme=sepia] { background: #f8f0de; color: #4f3a24; }
    :root[data-theme=dark] { background: #1f1f21; color: #dcdcde; }
    :root[data-theme=dark] a { color: #8ab4f8; }
    body { margin: 0; font: 400 var(--size)/1.6 ui-serif, Georgia, serif; overflow-wrap: break-word; }
    :root[data-font=sans] body { font-family: system-ui, -apple-system, sans-serif; }
    article { max-width: 680px; margin: 0 auto; padding: 56px 32px 96px; }
    h1 { font-size: 1.7em; line-height: 1.2; margin: 0 0 0.4em; }
    .byline { opacity: 0.6; font-size: 0.85em; margin: 0 0 2em; }
    img, video, figure { max-width: 100%; height: auto; }
    pre, table { display: block; overflow-x: auto; }
    table { border-collapse: collapse; font-size: 0.85em; }
    td, th { padding: 4px 8px; vertical-align: top; }
    pre, code { font-size: 0.85em; }
    """

  static func html(_ article: ReaderArticle, _ settings: ReaderSettings) -> String {
    let lang = article.lang.map { #" lang="\#(escaped($0))""# } ?? ""
    let dir = article.dir.map { #" dir="\#(escaped($0))""# } ?? ""
    let byline = article.byline.map { #"<p class="byline">\#(escaped($0))</p>"# } ?? ""
    return """
      <!doctype html>
      <html\(lang)\(dir) data-theme="\(settings.theme.rawValue)" data-font="\(settings.isSerif ? "serif" : "sans")" \
      style="--size: \(ReaderSettings.sizes[settings.step])px">
      <head>
      <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
      <meta charset="utf-8">
      <title>\(escaped(article.title))</title>
      <style>\(stylesheet)</style>
      </head>
      <body><article><h1>\(escaped(article.title))</h1>\(byline)\(article.content)</article></body>
      </html>
      """
  }

  private static func escaped(_ text: String) -> String {
    text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
      .replacing("\"", with: "&quot;")
  }
}

// Reader View over the tab's page, with its type and theme controls; a link opens in the tab.
struct ReaderOverlay: View {
  let tab: UUID
  let url: URL
  @AppStorage("readerTextSize") private var step = 3
  @AppStorage("readerSerif") private var isSerif = true
  @AppStorage("readerTheme") private var theme = ReaderTheme.light

  var body: some View {
    if let article = Engine.shared.readers[tab] {
      let settings = ReaderSettings(step: step, isSerif: isSerif, theme: theme)
      ReaderPage(article: article, baseURL: url, settings: settings) { Engine.shared.load(tab, $0) }
        .background(settings.theme.background)
        .overlay(alignment: .topTrailing) { controls(settings).padding(10) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
  }

  private func controls(_ settings: ReaderSettings) -> some View {
    HStack(spacing: 2) {
      button("textformat.size.smaller", "Smaller Text", enabled: step > 0) { step -= 1 }
      button("textformat.size.larger", "Larger Text", enabled: step < ReaderSettings.sizes.count - 1) { step += 1 }
      Divider().frame(height: 14).padding(.horizontal, 4)
      Button { isSerif.toggle() } label: {
        Text("Aa").font(.system(size: 13, weight: .medium, design: settings.isSerif ? .serif : .default))
          .frame(width: 26, height: 24).contentShape(Rectangle())
      }
      .help(settings.isSerif ? "Sans Serif" : "Serif")
      Divider().frame(height: 14).padding(.horizontal, 4)
      ForEach(ReaderTheme.allCases, id: \.self) { option in
        Button { theme = option } label: {
          Circle().fill(option.background)
            .overlay(Circle().strokeBorder(option == settings.theme ? Color.accentColor : .gray.opacity(0.5), lineWidth: option == settings.theme ? 2 : 1))
            .frame(width: 16, height: 16).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .help(option.rawValue.capitalized)
      }
      Divider().frame(height: 14).padding(.horizontal, 4)
      button("xmark", "Hide Reader View", enabled: true) { Engine.shared.toggleReader(tab) }
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(.regularMaterial, in: Capsule())
    .environment(\.colorScheme, settings.theme == .dark ? .dark : .light)
  }

  private func button(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 13)).frame(width: 26, height: 24).contentShape(Rectangle())
    }
    .disabled(!enabled)
    .help(help)
  }
}

private struct ReaderPage: NSViewRepresentable {
  let article: ReaderArticle
  let baseURL: URL
  let settings: ReaderSettings
  let open: (URL) -> Void

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let page = WKWebView(frame: .zero, configuration: configuration)
    page.underPageBackgroundColor = .clear
    page.navigationDelegate = context.coordinator
    return page
  }

  func updateNSView(_ page: WKWebView, context: Context) {
    let coordinator = context.coordinator
    coordinator.open = open
    if coordinator.article != article {
      coordinator.article = article
      coordinator.settings = settings
      coordinator.awaitsShell = true
      page.loadHTMLString(ReaderDocument.html(article, settings), baseURL: baseURL)
    } else if coordinator.settings != settings {
      // Applied in place, so the article keeps its scroll position.
      coordinator.settings = settings
      page.callAsyncJavaScript(
        """
        const root = document.documentElement;
        root.dataset.theme = theme;
        root.dataset.font = font;
        root.style.setProperty('--size', size + 'px');
        """,
        arguments: [
          "theme": settings.theme.rawValue, "font": settings.isSerif ? "serif" : "sans",
          "size": ReaderSettings.sizes[settings.step],
        ],
        in: nil, in: .defaultClient)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var article: ReaderArticle?
    var settings: ReaderSettings?
    var open: (URL) -> Void = { _ in }
    // The shell's own load is the only navigation the page makes on its own.
    var awaitsShell = false

    // A web link opens in the tab; one to a place in the article stays here. The tab loads a link as the browser's
    // own navigation, which a page's links never get, so any other scheme, such as file: or chrome:, is dropped.
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      guard let url = action.request.url else { return .cancel }
      switch action.navigationType {
      case .other where awaitsShell:
        awaitsShell = false
        return .allow
      case .linkActivated where url.fragment != nil && webView.url.map(url.isSamePage(as:)) == true:
        return .allow
      case .linkActivated where ["http", "https"].contains(url.scheme):
        open(url)
        return .cancel
      default:
        return .cancel
      }
    }
  }
}
