import AppKit
import ComposableArchitecture
import EngineCore

if isTesting {
  NSApplication.shared.run()
} else {
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
