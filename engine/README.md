# EngineCore

`EngineCore.framework` is Chromium's browser process, built from our fork of
Chromium `156.0.8078.48` (`CHROMIUM_VERSION`), with a small Objective-C bridge
(`src/EngineCore.h`) that the Swift shell calls.

## The cut: a `//chrome` embedder without browser windows

We build Chrome's own framework target (`//chrome:chrome_framework`), renamed to
`EngineCore`, with the bridge (`//engine_core`) linked in. The browser process
runs Chrome's full startup (`ChromeMain`, `ChromeMainDelegate`,
`ChromeBrowserMainParts`, `ProfileManager`, prefs, the extension system) and is
started with `--no-startup-window`, so Chrome never creates a `Browser`, a tab
strip or a Views browser window. The shell creates web contents directly with
`content::WebContents::Create` against a Chrome `Profile`.

The alternative was a `content/`-based embedder in the style of `content_shell`
plus `//extensions` (as in `extensions/shell`). That means writing our own
`ContentMainDelegate`, `ContentBrowserClient`, `BrowserMainParts`,
`BrowserContext`, `ExtensionsBrowserClient` and renderer clients, and it still
leaves out what lives in `//chrome`: Chrome Web Store installs
(`WebstoreInstaller`, `CrxInstaller`), most `chrome.*` extension APIs, history,
password manager, omnibox autocomplete and downloads UI services. Phase 5 needs
those, so the `//chrome` cut is both less code now (a few hundred lines plus
small patches) and the only one that keeps Chrome extensions in reach.

The cost: Chrome's UI code is still linked (it is never instantiated), so the
framework is the size of Chrome's. Removing it from the link would need deep
patching of `//chrome/browser` and is not worth it.

Upstream changes (`patches/`):
1. Rename `Chromium Framework.framework` to `EngineCore.framework` (GN name,
   `kFrameworkName`, the helper and app loader paths, and the install names
   of `libaperitif.dylib` and the web app shortcut copier).
2. Link `//engine_core` into the framework and publish `Headers/` and
   `Modules/` so Swift can `import EngineCore`.
3. Make the bridge a friend of `TabHelpers`, whose `AttachTabHelpers` is
   private to Chrome's own tab owners.
4. Return no permission prompt for a web contents without a browser window
   (Chrome's Views bubble crashes without one). `ECWebContents` replace the
   prompt factory, so this covers only web contents Chrome creates itself.
5. Make the default extension install dialog replaceable, so installs ask
   the shell instead of showing Chrome's Views dialog.
6. Let `ExtensionTabUtil::GetTabById()` and a function's current window
   accept a `WindowController` without a `BrowserWindowInterface`, which
   the shell's windows are (see Extensions).
7. Let the bridge add navigation throttles after Chrome's, for links to
   other sites (see Page UI).
8. Start the macOS notification service when a page first shows a
   notification, not at launch, so macOS asks for notification permission
   then. Chrome's `NotificationDispatcherMojo` constructor forces the service
   on at startup (crbug.com/40149365): a hook on the Mac caught
   `MacNotificationProviderImpl::BindNotificationService` at launch in the app
   and in "Chromium Helper (Alerts)", and usernoted asked for permission at
   that first connection, once for every new bundle id.

## Tabs

Every `ECWebContents` gets Chrome's tab helpers (`TabHelpers::AttachTabHelpers`,
as `tabs::TabModel` does): session and favicon drivers, autofill and password
manager clients, extension tab helpers (content scripts, `webNavigation`),
find, permissions, translate, history, site engagement and the rest.
`TabFeatures` is not created: it needs a `tabs::TabInterface` in a
`BrowserWindowInterface` and is almost entirely Chrome UI (page actions, side
panels, tab dialogs).

`HistoryTabHelper` records only web contents in Chrome's browser windows, so
the bridge marks each `ECWebContents` as a tab (`SetForceEligibleTabForTesting`,
its only seam) and their visits reach History.

The helpers' UI looks up a browser window and shows nothing without one.
The bridge hands the page UI below to the shell instead; the password save
and translate bubbles still do not appear.

## Page UI

Chrome keeps the logic and the bridge replaces only the presentation. The
`ECWebContentsDelegate` methods are optional; without one the request is
denied or cancelled (permissions stay pending, Chrome's context menu shows).

- Permissions: the `PermissionRequestManager` tab helper queues, groups and
  decides requests; the bridge swaps its prompt factory
  (`set_view_factory_for_testing`, its only seam) for one that asks the
  shell. Allow and deny persist as content settings, as Chrome's bubble does.
- JavaScript dialogs and leave-page confirmations: the bridge is the web
  contents' `JavaScriptDialogManager`.
- File chooser: the shell picks files; a folder upload is enumerated by
  Chrome's `FileSelectHelper`.
- Lifecycle: `close` detaches the delegate, the observer and the zoom
  observer before destroying the web contents (destruction reports
  navigation state changes), a web contents released without `close`
  closes in `dealloc`, the accessors of a closed one return nil, empty or
  NO, and its view stays, detached.
- Closing: `window.close()` asks the shell to close the web contents, as
  does a download from a web contents that has committed nothing (a new tab
  that only downloaded), which the context closes as Chrome's
  `DownloadUIController` closes such tabs of its tab strips.
- Find in page: `FindTabHelper` runs the find session and the bridge reports
  its results. `findString:` is the find field's path: a changed string
  starts a new search from the current match, an unchanged one keeps the
  active match (`FindTabHelper` would find the next) and an empty one
  clears the search; `findString:forward:` moves between matches.
  `scrollSelectionIntoView` reveals the selection from an isolated world in
  the focused frame, as Blink has no browser-side call for it.
- Context menu: the shell builds its own menu from an `ECContextMenu`, the
  click's link, image, selection and edit state. Its commands are Chrome's
  context menu commands on the frame clicked: save link or image (Chrome's
  download prompt), copy image, inspect (`DevToolsWindow`, in its own
  window), look up, writing direction and copy link to highlight (Blink's
  text fragment generator). Page commands are on `ECWebContents`: save page,
  print (the system dialog, as with print preview disabled), translate
  (`TranslateManager`, as the menu item does), undo, redo and paste and
  match style. Opening a link in a new tab is the shell's own new tab.
- New windows: a link with a target, a modified click or `window.open()`
  asks the shell with Chrome's disposition (foreground or background tab,
  window for a ⇧-click, popup). With `opensLinksToOtherSitesInNewWindow`, a
  throttle (patches/0007) cancels a link click to another registrable
  domain and asks for a new window instead, so the shell can open such links
  in Peek from a pinned tab. `webContents:requestsNewWindowWithURL:disposition:modifierFlags:`
  adds the modifier keys of the last click or key press in the page when it
  was within the past second (from `DidGetUserInteraction`), 0 otherwise.
- Navigation: `backEntries` and `forwardEntries` list the entries around
  the current one (the pending one during a history navigation, as
  Chrome's `BackForwardMenuModel`), nearest first, each with its index for
  `goToEntry:` (`GoToIndex`) and its offset for display; `loadProgress` and
  `webContents:didChangeLoadProgress:` are `WebContents::GetLoadProgress`.
- Element full screen: the bridge implements the delegate calls Chrome's
  `FullscreenController` answers for a tab (`CanEnterFullscreenModeForTab`,
  `EnterFullscreenModeForTab`, `ExitFullscreenModeForTab`,
  `IsFullscreenForTabOrPending`, `GetFullscreenState`) and keeps the state
  per web contents. It changes inside the request, as content reads it back
  there to grant the page full screen; the shell hears of the enter, with
  the requesting frame's origin, and of the exit once the call returns, and
  fills the screen with the view meanwhile. `exitFullscreenResizingView:`
  is `WebContents::ExitFullscreen`: a shown page leaves with the resize the
  shell makes as it restores its layout, as Chrome's windows do, so it lays
  out once; a hidden one is told at once. Content also exits on a
  navigation, and drops
  full screen for security (`ForSecurityDropFullscreen`) through
  `GetFullscreenState`. Without the delegate method requests are refused,
  as before.
- Shortcuts: a key press goes to the page first and to `NSApp.mainMenu` if
  the page leaves it, unless the delegate reserves it
  (`webContents:reservesKeyEquivalent:`, `PreHandleKeyboardEvent`), in
  which case the menu performs it before the renderer sees it, as Chrome's
  tab and window shortcuts, so a busy page cannot hold it.
- Zoom: `zoomPercent` and `webContentsDidChangeZoom:` read Chrome's
  `ZoomController`, so a tab's zoom follows the site's as in Chrome.
- Session restore: `sessionState` serializes the navigation entries with
  `ContentSerializedNavigationBuilder` and `SerializedNavigationEntry`
  pickles, as Chrome's session service does; `restoreSessionState:` feeds
  them to `NavigationController::Restore` on a fresh web contents, which
  loads on `loadIfNeeded`.
- Developer tools: `reloadBypassingCache`, and `showConsole` and
  `inspectElement`, which open Chrome's `DevToolsWindow` as ⌥⌘J and ⇧⌘C do.
- Site info: the security level (`chrome_security_state`), the permissions
  the user allowed or blocked for the site (content settings, which the
  shell can change), a snapshot of the visible page, audio state and mute,
  the selected text and the hovered link (`UpdateTargetURL`).
- Downloads: Chrome's `DownloadManager` and its delegate choose the path
  (`~/Downloads`) and the context reports every download to its
  `downloadDelegate`. Chrome's download bubble sets incognito profiles to
  ask where to save; the bridge turns that back off.
- Extension installs: the Chrome Web Store's `webstorePrivate` flow runs
  as in Chrome. Its install dialog asks the web contents' delegate with the
  extension's name, icon and permission warnings (patches/0005), and
  Chrome's post-install UI is off (`ExtensionInstallUI`'s only switch).
- Built-in extensions: `loadBuiltInExtensionAtPath:` registers an unpacked
  extension with the profile's `ComponentLoader` (`AddOrReplace`, the one
  entry that skips the component allowlist), so it loads for the session, in
  incognito too, and is spared by `ManifestV2Handler`, which disables every
  Manifest V2 extension but component ones. The shell bundles uBlock Origin
  this way. Its manifest needs a "key", which gives a stable ID.

The engine starts Chrome with `--disable-field-trial-config`. Non-official
builds otherwise enable the experiments in
`testing/variations/fieldtrial_testing_config.json`, including
OmniboxEverywhere, which adds a menu bar status item.
That config also migrated existing profiles' search engines
(PrepopulatedEnginesMigration), which cannot be undone, so the engine keeps
that migration enabled; Chrome fails on such a profile without it. Chrome
honors only the last `--enable-features`, so add features to that switch.

## Autocomplete

`ECAutocomplete` runs Chrome's omnibox `AutocompleteController` with
`ChromeAutocompleteProviderClient` and the providers of Chrome's desktop
omnibox (`AutocompleteClassifier::DefaultOmniboxProviders()`): the input as
a URL or search, history, bookmarks, shortcuts, search suggestions and the
rest. It reports each update of the ranked matches with the match's text,
description, destination URL, a coarse type and whether it may be the
default, leaving out matches without a valid destination. The shell loads
the destination URL with `loadURL:` (a typed visit, which history ranks) and
calls `didSelectMatch:`, which adds the text to the shortcuts database as
Chrome's omnibox does; incognito keeps none. There are no open-tab matches: Chrome finds those in its tab strips (`TabMatcherDesktop`).
An autocomplete closes with its context.

A match also carries its inline completion (the default match's rest of the
URL, e.g. "ipedia.org" for "wik") and its `associated_keyword`, Chrome's Tab
to search hint, with the engine's name. Only engines Chrome may use as
keywords get one: the prepopulated ones (Bing, DuckDuckGo, ...), those the
user activated and the site searches Chrome found on visited
pages (Wikipedia, from its OpenSearch description or a search there).
Chrome keeps those inactive until the user activates them; a regular
context activates them as Chrome adds them, for the session only, so they
stay replaceable: activating them for good would stop a page's OpenSearch
description from replacing the engine Chrome made from its search form.
`startWithText:keyword:` is Chrome's keyword mode:
it queries "<keyword> <text>" with the input in keyword mode, so the matches
search that site. `faviconForPageURL:` gets a page's 16 pt favicon from
`FaviconService`, as Chrome's omnibox does for its matches.

## History import

Chrome 156 has no importer for other Chromium browsers or Safari's
History.db on the Mac (`chrome/utility/importer` keeps Firefox and Windows
browsers; `user_data_importer` reads Safari's export archive). The shell
reads the other browser's database (SQLite3 in Swift, testable without the
engine) and `importHistory:` writes the pages through `HistoryService`'s
`AddPagesWithDetails`, as Chrome's importers do, with the source Chrome
gives imports from another browser (`SOURCE_OS_MIGRATION_IMPORTED`). Each
page keeps its title and visit and typed counts and gets one visit at its
last visit time; history drops pages older than 90 days, so the bridge
skips and does not count them.

## Search engine

Every regular context makes Google its default search engine once its
`TemplateURLService` has loaded: the profile's own entry from Chrome's
prepopulated engines, or one added from the built-in data if its region's
list leaves Google out. This also replaces DuckDuckGo, which earlier builds
made the default. Google's search and suggest URLs need no API keys.
Incognito contexts use their profile's engines.

## Extensions

Chrome's extension system runs unchanged: installs, updates, content
scripts, service workers, `webNavigation` and the rest. The bridge adds:

- Management on `ECBrowserContext`: `extensions` (an incognito context
  lists those allowed in incognito), enable, disable and uninstall through
  `ExtensionRegistrar`, and change reports to `extensionsDelegate`.
- Toolbar actions: `actionForExtension:inWebContents:` reads the
  `ExtensionAction` for the tab, with its icon from
  `ExtensionActionIconFactory` (converted on every call, as the default
  icon is blank until its images load); `ExtensionActionDispatcher` and the
  factory report changes. `runActionForExtension:inWebContents:` runs it through the tab's
  `ExtensionActionRunner` as a toolbar click does (granting activeTab). A
  popup is an `ExtensionViewHost` of type popup, as Chrome's, with the
  bridge as its `ExtensionView`: it enables auto-resize and reports sizes,
  and `window.close()` closes it. The shell shows its view in a popover.
  Side panel actions do nothing.
- Windows and tabs. `chrome.tabs` and `chrome.windows` read Chrome's tab
  strips (`BrowserWindowInterface`, `TabListInterface`, `tabs::TabInterface`)
  and their events come from `TabsEventRouter` observing those. Making the
  shell's tabs look like those means implementing about 110 methods of
  browser UI, and Chrome code would then treat them as Chrome tabs. Instead
  the shell describes each window as an `ECWindow` (its tabs in order, the
  active one, and whether it is focused). Each is a `WindowController` in
  `WindowControllerList`, the list extension code searches for tabs and
  windows by id, so `sendMessage`, `executeScript`, `scripting`, action
  APIs with a tab id and `windows.get` find the shell's tabs (patches/0006).
  Its `ui::BaseWindow` is the tabs' `NSWindow`. The functions that walk tab
  strips are replaced (`ExtensionFunctionRegistry` keeps the last
  registration): `tabs.query`, `get`, `getCurrent`, `create`, `update`
  (URL, active) and `remove`, and `windows.getCurrent`, `getLastFocused`
  and `getAll`. `create` and `remove`, and activating a tab, ask the
  window's delegate. The window sends `tabs.onCreated`, `onRemoved`,
  `onActivated` and `onUpdated` (status, URL, title, favicon) as the shell
  changes it, scrubbed per extension as Chrome does, and focus changes
  reach `windows.onFocusChanged`. Not supported: pinning, groups, moving,
  `tabs.onMoved`, `onAttached`, `onDetached`, `onHighlighted`, and
  `windows.create`, `remove` and `onCreated`.

## WebKit tabs

The shell can show some pages in a `WKWebView` instead of Chromium. These
calls let it move a user's navigation between the engines and share the
profile's data with WebKit pages. None needs an upstream patch, and none
changes what an existing call does.

- Handoff: a second throttle beside the other-site one (patches/0007),
  registered after it so Peek keeps priority, asks the delegate's
  `webContents:shouldHandOffNavigation:` in `WillStartRequest` and returns
  `CANCEL_AND_IGNORE` on YES. It attaches only when the delegate implements
  the method, to a primary main frame, cross-document http or https
  navigation the user started: one without a reload type, history step or
  restore type that is browser-initiated or carries a user gesture. It does
  not override `WillRedirectRequest`, so redirects stay. The request carries
  the URL, the method, a POST's bytes from `GetPostData()` (file and data
  pipe elements dropped) with its `Content-Type`, and `GetReferrer()` as
  `Referer`.
- `loadRequest:` loads through `LoadURLParams` as a browser-initiated
  `PAGE_TRANSITION_LINK`, with the `Referer` header as the referrer and, for
  a POST, the body as `post_data` with `LOAD_TYPE_HTTP_POST` and its
  `Content-Type` in `extra_headers`, as Chrome's own POST loads pass it.
- `webContents:didCommitNavigationIsHistory:` is sent from
  `DidFinishNavigation` for a committed primary main frame, cross-document
  navigation, with `NavigationHandle::IsHistory()`.
- `ECEngine.registrableDomainForHost:` is
  `registry_controlled_domains::GetDomainAndRegistry` with private
  registries, or the host when it has none.
- Cookies use the default storage partition's
  `network::mojom::CookieManager`. `cookiesForDomains:` filters
  `GetAllCookies` to unpartitioned, unexpired cookies at or under the
  domains. `deleteCookies:` deletes the stored cookies with each name,
  domain and path through `DeleteCanonicalCookie`, which deletes only a
  cookie whose value is unchanged, so it passes the stored cookie rather
  than the shell's. While `observedCookieDomains` is non-empty, an
  `AddGlobalChangeListener` listener, bound again if the network service
  restarts, reports changes under those domains to `cookieDelegate`: the
  three insert causes as set, the removal causes as removed, and neither the
  `OVERWRITE` half of an overwrite nor a partitioned cookie.
- Logins: `loginsForURL:` reads `PasswordStoreInterface::GetLogins` with
  the `PasswordFormDigest` of an HTML form at the URL's origin and keeps the
  exact signon-realm matches, most recently used first, then the
  `MatchType::kPSL` matches with `exactMatch` NO; blocklisted and federated
  entries are dropped. `addLoginForURL:username:password:` reads the same
  logins and calls `UpdateLogin` with the new password for a login of that
  realm and username, or `AddLogin` with a form-submission login for the
  page's URL without query, fragment or credentials.
- History: `addVisitToURL:title:` calls `HistoryService::AddPage` with
  `SOURCE_BROWSED` and then `SetPageTitle`, and
  `setFavicon:iconURL:forPageURL:` writes the image's PNG bytes with
  `FaviconService::MergeFavicon` as `kFavicon` at its pixel size, which
  replaces the bitmap of that size and keeps the others. An incognito
  context does neither.
- Site settings: `permissionsForOrigin:` and
  `setPermission:allowed:forOrigin:` share the content-settings code of
  `sitePermissions` and `setSitePermission:allowed:`, for an origin instead
  of the page's URL. `zoomPercentForHost:` and `setZoomPercent:forHost:`
  read and write the profile's `HostZoomMap` level for the host, converted
  as `ZoomController::GetZoomPercent` converts it; the default percentage
  clears the host's level.
- `webContentsDidPresentFirstFrame:` lets the shell keep the page it
  replaces on screen until a Chromium page has drawn. It is sent from
  `DidFirstVisuallyNonEmptyPaint`, which Blink reports from the presentation
  feedback of the primary page's first frame with content, and, when
  `OnVisibilityChanged` turns `VISIBLE` after that paint, once a one-pixel
  `CopyFromSurface` has completed. Showing the view gives it a new
  compositor and a new surface id; the copy request marks the page's surface
  damaged and is taken only when the display draws that id or a newer one,
  so it completes on the first frame that draws the page.

## Main-world scripts

`addDocumentStartScript:` runs a script in the main world of every frame
before the page's own scripts, and `addMessageObjectNamed:` adds an object
whose `postMessage(string)` reaches the delegate's
`webContents:didReceiveMessage:fromObject:origin:mainFrame:`. Both use
`components/js_injection`, as Android WebView does, and apply from the next
navigation on.

- Browser side: each `ECWebContents` makes one
  `js_injection::JsCommunicationHost` on first use and destroys it before
  its web contents. Scripts go to `AddPersistentJavaScript` at
  `kDocumentStart` and objects to `AddWebMessageHostFactory`, both in world
  `ISOLATED_WORLD_ID_GLOBAL` for the origin rule `*`. The host reaches each
  frame through its remote associated interfaces and hands the renderer the
  message remotes itself, so no binder is registered.
- Renderer side (patches/0012): `ChromeContentRendererClient` makes a
  `js_injection::JsCommunication` in `RenderFrameCreated` and runs its
  document-start scripts first in `RunScriptsAtDocumentStart`, before the
  extension scripts, which run only if the frame outlived ours. Every
  Chromium renderer frame carries the observer, but without a host it holds
  no scripts or objects.
- Messages: a frame's host is made on its first message, with the frame's
  origin and whether it is the main frame. js_injection names opaque and
  local origins `null`, which reaches the delegate as a nil origin. String
  messages are posted to the main queue and dropped if the web contents
  closed meanwhile; other payloads are dropped.

## How the host app hands control to Chromium

- On macOS the browser process owns the main thread, which is Chromium's UI
  thread. Its `NSApplication` must be `BrowserCrApplication`
  (`chrome/browser/chrome_browser_application_mac.h`), a subclass of
  `CrApplication` that implements `CrAppProtocol` and `CrAppControlProtocol`
  (`base/message_loop/message_pump_apple.h`, `base/mac/scoped_sending_event.h`).
  `ChromeMainDelegate::PreBrowserMain` creates it and `CHECK`s that nothing
  created `NSApp` earlier.
- So the host's `main` must not use `NSApplicationMain`, `@main` / SwiftUI
  `App`, or touch `NSApp`. It calls
  `ECEngine.start(withArguments: CommandLine.arguments)`, which runs
  `ChromeMain` and never returns. Chromium runs the event loop through
  `MessagePumpNSApplication`, which calls `[NSApp run]`.
- Chrome's `AppController` is the `NSApp` delegate and Chrome's main menu is
  installed. The shell observes notifications instead of being the app
  delegate, and may replace `NSApp.mainMenu` once launching has finished.
  The engine keeps Chrome's bookmark and history menu bridges unbound (they
  `CHECK` for Chrome's menu items) and sends the shortcuts a page leaves
  unhandled, and those the delegate reserves, to `NSApp.mainMenu`; the web
  view otherwise takes every ⌘ key.
- Chrome never opens a browser window. On
  `NSApplicationWillFinishLaunchingNotification` the engine changes the
  delegate's class to `ECAppController`, an `AppController` subclass
  (`src/ec_engine.mm`; no upstream patch). It posts
  `ECEngineOpenURLsNotification` for URLs from other apps or Handoff and
  `ECEngineReopenNotification` for Dock icon clicks, and shows
  `ECEngine.dockMenu` (nil by default) instead of Chrome's Dock menu. URLs opened at launch arrive before
  `NSApplicationDidFinishLaunchingNotification`, so register first and queue
  them until a context has loaded. A second launch with the same user data
  dir is silent because of `--no-startup-window`.
- The engine is ready when `NSApplicationDidFinishLaunchingNotification` is
  posted (after `ProfileManager` and the rest of browser startup). Register
  for it before calling `start`, then create contexts and web contents.
- Every bridge call happens on the main thread. Delegate callbacks arrive on it.

## Host app requirements

- Embed the framework at
  `Contents/Frameworks/EngineCore.framework/Versions/156.0.8078.48/` (the
  versioned layout Chrome resolves paths against). Helpers, resources and
  libraries stay inside the framework.
- `Info.plist`: a `CFBundleIdentifier`, `CFBundleDevelopmentRegion` `en`, and
  `LSEnvironment` `MallocNanoZone=0` (PartitionAlloc). See `host/Info.plist`.
- Pass `--user-data-dir=<dir>`. `ECBrowserContext.load(withPath:completion:)`
  takes a profile directory inside it (for example `<dir>/Default`). It is
  asynchronous because Chrome forbids blocking file IO on the UI thread, which
  synchronous profile creation needs.
- `offTheRecordContext` is the profile's primary incognito profile, the one
  Chrome's incognito windows and extensions' incognito mode use.
  `ECBrowserContext.close()` closes the context's web contents first.

`host/main.swift` is the minimal host used to verify the framework. It
replaces the main menu (⌘R reloads, ⌘Q quits), opens Wikipedia in the
profile and GitHub in its incognito context, each in a window titled with the
page's title and favicon, and opens URLs from other apps and Dock reopens in
new windows. A third window opens example.com and drives the page UI:
it runs script as `javascript:` URLs (as bookmarklets do) and right-clicks
with posted events, answers every request itself (allow, accept, a temporary
file, copy the selection, stay on the page) and prints what the delegates
saw, while the page logs what it got. With `--snapshot=<dir>` it writes each
window to `<dir>/regular.png` and `<dir>/incognito.png` once its page and
favicon have loaded and the third to `<dir>/content-ui.png` after the run,
then closes the windows and contexts and quits. The incognito window
downloads too, which must not ask where to save.

With `--extensions` (and its own user data dir) the host keeps one shell
window as an `ECWindow` and installs Dark Reader and OneTab by pressing Add
to Chrome on their Web Store pages, allowing the install prompts. It
checks Dark Reader's content script on example.com (the page reports it
in its title), opens Dark Reader's popup in a window sized to it, runs
OneTab's action (which queries the window's tabs, opens its own tab and
closes the others), then disables and enables Dark Reader and uninstalls
OneTab. It writes `darkreader.png`, `popup.png` and `onetab.png`.

With `--autocomplete` (and its own user data dir) the host visits
www.wikipedia.org, searches "Rust" there, visits example.com and
rust-lang.org without a window, prints the matches for "wik" (Wikipedia
from history first, inline "ipedia.org", with the "Wikipedia (en)" keyword
hint), "bing.com" (with the Bing keyword hint), "rust" in Bing's and in
Wikipedia's keyword mode (Bing and Wikipedia searches) and "rust language"
(the Google search and its suggestions),
opening the first one of each as the shell would and saving its favicon,
when history has one, to `<dir>/favicon-<text>.png` (`--snapshot=<dir>`, else `/tmp`), then quits.

## Verifying on a remote Mac

When a remote Mac's GUI session sits behind a locked screen, macOS reports every window
as occluded (Chrome then never paints, including the new renderer view after a
cross-site navigation), the login keychain prompts for the
shared `Chromium Safe Storage` item, and `screencapture` from SSH lacks Screen
Recording permission. The app cannot become active either, so a left click
only tries to activate it; the host right-clicks instead. Run the host with
test-only switches and let it capture its own window:

```
defaults write dev.harunkkhan.EngineHost ApplePersistenceIgnoreState -bool YES
open -n out/Engine/EngineHost.app --stdout /tmp/enginehost/out.log \
  --args --snapshot=/tmp/enginehost \
  --use-mock-keychain --disable-backgrounding-occluded-windows
```

## Scripts

Run from the laptop against a remote Mac build host (set `ENGINE_HOST`, e.g.
`user@host`): a Mac with ~150 GB free disk and the Chromium toolchain.

- `scripts/sync.sh`: rsync `engine/` to `~/engine`, copy `src/` to
  `~/chromium/src/engine_core`, apply `patches/` (skips applied ones).
- `scripts/build.sh`: in tmux session `engine`, `gn gen out/Engine` and
  `autoninja -C out/Engine chrome_framework`, then assemble
  `out/Engine/EngineHost.app`. Log: `~/chromium/engine-build.log`, ends with
  `ENGINE_BUILD_DONE`.
- `scripts/fetch.sh`: rsync `EngineCore.framework` and `EngineHost.app` to
  `engine/out/` (gitignored).
- `scripts/package-engine.sh`: on the build Mac, zip `EngineCore.framework`
  as `EngineCore-<version>-arm64.zip` and print its SHA-256. The zip is the
  asset of release `engine-<version>` on github.com/SailfishBrowser/macOS and
  the checksum goes in `ENGINE_SHA256`; `macOS/scripts/fetch-engine.sh`
  downloads and checks it (or, with `ENGINE_HOST` set, copies the build
  host's framework).
