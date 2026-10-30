import AppKit
import ComposableArchitecture
import EngineCore
import Security

if isTesting {
  NSApplication.shared.run()
} else {
  // The Anthropic API key and setting the removed Settings > AI kept.
  SecItemDelete(
    [kSecClass: kSecClassGenericPassword, kSecAttrService: "\(Bundle.main.bundleIdentifier!).anthropic-api-key"]
      as CFDictionary)
  UserDefaults.standard.removeObject(forKey: "tidyTabTitles")
  // Settings and files saved under Little Sailfish's former name.
  for (old, new) in [
    ("littleArcHintShown", "littleSailfishHintShown"), ("littleArcStaysOnTop", "littleSailfishStaysOnTop"),
    ("littleArcHotKey", "littleSailfishHotKey"), ("littleArcsOnOptionCommandClick", "littleSailfishOnOptionCommandClick"),
  ] {
    if let value = UserDefaults.standard.object(forKey: old) {
      UserDefaults.standard.set(value, forKey: new)
      UserDefaults.standard.removeObject(forKey: old)
    }
  }
  try? FileManager.default.moveItem(
    at: URL.dataDirectory.appending(path: "LittleArcProfiles.json"),
    to: URL.dataDirectory.appending(path: "LittleSailfishProfiles.json"))
  let routes = URL.dataDirectory.appending(path: "LinkRoutes.json")
  if let json = try? String(contentsOf: routes, encoding: .utf8), json.contains("\"littleArc\"") {
    try json.replacingOccurrences(of: "\"littleArc\"", with: "\"littleSailfish\"").write(
      to: routes, atomically: true, encoding: .utf8)
  }
  let shell = Shell()
  let center = NotificationCenter.default
  center.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { shell.launch() }
  }
  center.addObserver(forName: .ECEngineOpenURLs, object: nil, queue: .main) { notification in
    let urls = notification.object as! [URL]
    MainActor.assumeIsolated { _ = shell.store.send(.openURLs(urls)) }
  }
  center.addObserver(forName: .ECEngineReopen, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { _ = shell.store.send(.reopen) }
  }
  center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { shell.terminate() }
  }
  // Chrome's Google Wallet passes, which Sailfish has no use for, ask macOS whether device sign-in is available as
  // each page is made: a synchronous call that held the main thread for up to 120 ms per page.
  ECEngine.start(
    withArguments: CommandLine.arguments + [
      "--user-data-dir=" + Engine.userDataDir, "--disable-features=AutofillAiWalletPrivatePasses",
    ])
}
