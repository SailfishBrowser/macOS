#import <AppKit/AppKit.h>

#define EC_EXPORT __attribute__((visibility("default")))

NS_ASSUME_NONNULL_BEGIN

@class ECWebContents;

// Chrome never opens its own browser windows. These are posted on the main
// thread instead. The URLs another app or Handoff asks to open, as the
// notification's object (NSArray<NSURL*>*):
EC_EXPORT extern NSNotificationName const ECEngineOpenURLsNotification;
// A click on the Dock icon. AppKit unminimizes a window if none is visible;
// the shell opens one if it has none.
EC_EXPORT extern NSNotificationName const ECEngineReopenNotification;

EC_EXPORT
@interface ECEngine : NSObject
// Runs Chromium's browser process on the calling (main) thread and never
// returns. `args` is the full argv, e.g. CommandLine.arguments. Call it from
// main() before anything touches NSApp. The engine is ready for
// ECBrowserContext and ECWebContents once
// NSApplicationDidFinishLaunchingNotification is posted.
+ (void)startWithArguments:(NSArray<NSString*>*)args
    __attribute__((noreturn));
// The Dock icon's menu (Chrome's own is dropped), nil for none. The shell
// sets it once launching has finished, as it replaces the main menu.
@property(class, nullable) NSMenu* dockMenu;
@end

// Matches download::DownloadItem::DownloadState.
typedef NS_ENUM(NSInteger, ECDownloadState) {
  ECDownloadStateInProgress,
  ECDownloadStateComplete,
  ECDownloadStateCancelled,
  ECDownloadStateInterrupted,
};

// A download's state at the time it was reported.
EC_EXPORT
@interface ECDownload : NSObject
- (instancetype)init NS_UNAVAILABLE;
// Unique within its context.
@property(readonly) uint32_t identifier;
@property(readonly) NSURL* URL;
// The file's final path, nil until Chrome has chosen it.
@property(readonly, nullable) NSURL* fileURL;
@property(readonly) int64_t receivedBytes;
// 0 when unknown.
@property(readonly) int64_t totalBytes;
@property(readonly) ECDownloadState state;
@property(readonly) NSDate* startTime;
@end

@class ECBrowserContext;
@class ECExtensionPopup;

// An installed extension, as of when it was read.
EC_EXPORT
@interface ECExtension : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(readonly) NSString* identifier;
@property(readonly) NSString* name;
// nil until it has loaded, which the context reports as a change.
@property(readonly, nullable) NSImage* icon;
@property(readonly, getter=isEnabled) BOOL enabled;
// Loaded with loadBuiltInExtensionAtPath:, which the user cannot turn off or
// remove.
@property(readonly, getter=isBuiltIn) BOOL builtIn;
@end

// An extension's toolbar action as it shows for one tab, as of when it was
// read.
EC_EXPORT
@interface ECExtensionAction : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(readonly) NSString* title;
// nil until it has loaded, which the context reports as a change.
@property(readonly, nullable) NSImage* icon;
@property(readonly) NSString* badgeText;
// Clear when the extension set none.
@property(readonly) NSColor* badgeBackgroundColor;
// Running a disabled action does nothing.
@property(readonly, getter=isEnabled) BOOL enabled;
@end

@protocol ECExtensionsDelegate <NSObject>
// An extension was installed, uninstalled, enabled or disabled, or its icon
// loaded.
- (void)browserContextExtensionsDidChange:(ECBrowserContext*)context;
// The action of the extension changed for `contents`, or for every tab when
// nil.
- (void)browserContext:(ECBrowserContext*)context
    actionDidChangeForExtension:(NSString*)identifier
                    webContents:(nullable ECWebContents*)contents;
@end

@protocol ECDownloadDelegate <NSObject>
// A download of the context was created, restored from history or changed.
- (void)browserContext:(ECBrowserContext*)context
     downloadDidUpdate:(ECDownload*)download;
@end

EC_EXPORT
@interface ECBrowserContext : NSObject
// Loads, or creates, the profile at `path`, a directory inside the user data
// dir. Profiles load off the main thread, so the context arrives in
// `completion` (nil on failure).
+ (void)loadWithPath:(NSString*)path
          completion:(void (^)(ECBrowserContext* _Nullable context))completion;
- (instancetype)init NS_UNAVAILABLE;
// The incognito context of this profile: the same object until it is closed,
// then a fresh one. It keeps this profile loaded while it is open.
@property(readonly) ECBrowserContext* offTheRecordContext;
// Chrome's download manager saves downloads to ~/Downloads (an incognito
// context asks where first) and reports them here.
@property(weak, nullable) id<ECDownloadDelegate> downloadDelegate;
// The profile's download folder and whether the address bar asks its search
// engine for suggestions, saved in its preferences.
@property(copy) NSURL* downloadDirectory;
@property BOOL searchSuggestEnabled;
@property(weak, nullable) id<ECExtensionsDelegate> extensionsDelegate;
// Closes the context's web contents, then releases the profile. Closing an
// incognito context discards its data.
- (void)close;
// Has Chrome delete the profile at `path` and its data: at once if it is
// not loaded, otherwise when Chrome next starts. Close its context first.
+ (void)deleteProfileAtPath:(NSString*)path;
@end

@interface ECBrowserContext (Extensions)
// The installed extensions; for an incognito context, those allowed in
// incognito. The Chrome Web Store installs them (see ECWebContentsDelegate).
@property(readonly) NSArray<ECExtension*>* extensions;
- (void)setEnabled:(BOOL)enabled forExtension:(NSString*)identifier;
- (void)uninstallExtension:(NSString*)identifier;
// Loads the unpacked extension at `path`, whose manifest has a "key", with
// the browser for this session, as Chrome loads its component extensions:
// in the incognito context too and spared by the Manifest V2 deprecation.
// Call it on a regular context.
- (void)loadBuiltInExtensionAtPath:(NSString*)path;
- (void)unloadBuiltInExtensions;
// nil for an extension without a toolbar action.
- (nullable ECExtensionAction*)actionForExtension:(NSString*)identifier
                                    inWebContents:(ECWebContents*)contents;
// Runs the action as a click on its toolbar button does, granting the
// extension access to the tab. Returns the action's popup, if it has one,
// which the shell shows until it closes.
- (nullable ECExtensionPopup*)runActionForExtension:(NSString*)identifier
                                      inWebContents:(ECWebContents*)contents;
@end

// A page from another browser's history, as importHistory: takes it.
EC_EXPORT
@interface ECHistoryEntry : NSObject
- (instancetype)initWithURLString:(NSString*)URLString
                            title:(NSString*)title
                       visitCount:(NSInteger)visitCount
                       typedCount:(NSInteger)typedCount
                        lastVisit:(NSDate*)lastVisit;
- (instancetype)init NS_UNAVAILABLE;
@property(readonly) NSString* URLString;
@property(readonly) NSString* title;
@property(readonly) NSInteger visitCount;
// How many of the visits were typed in the address bar.
@property(readonly) NSInteger typedCount;
@property(readonly) NSDate* lastVisit;
@end

// A password saved in another browser, as importPasswords: takes it.
EC_EXPORT
@interface ECPassword : NSObject
- (instancetype)initWithURLString:(NSString*)URLString
                         username:(NSString*)username
                         password:(NSString*)password;
- (instancetype)init NS_UNAVAILABLE;
// The rows of a passwords CSV file, as Chrome, Safari and the Passwords app
// export them, read by Chrome's parser; rows without a URL are left out.
+ (NSArray<ECPassword*>*)passwordsFromCSV:(NSString*)CSV;
@property(readonly) NSString* URLString;
@property(readonly) NSString* username;
@property(readonly) NSString* password;
@end

// A cookie from another browser, as importCookies: takes it.
EC_EXPORT
@interface ECCookie : NSObject
// `expiry` is nil for a session cookie. `sameSite` is as Chromium's Cookies
// database stores it: -1 unspecified, 0 none, 1 lax, 2 strict.
- (instancetype)initWithName:(NSString*)name
                       value:(NSString*)value
                      domain:(NSString*)domain
                        path:(NSString*)path
                    creation:(NSDate*)creation
                      expiry:(nullable NSDate*)expiry
                  lastAccess:(NSDate*)lastAccess
                      secure:(BOOL)secure
                    HTTPOnly:(BOOL)HTTPOnly
                    sameSite:(NSInteger)sameSite;
- (instancetype)init NS_UNAVAILABLE;
@property(readonly) NSString* name;
@property(readonly) NSString* value;
@property(readonly) NSString* domain;
@property(readonly) NSString* path;
@property(readonly) NSDate* creation;
@property(readonly, nullable) NSDate* expiry;
@property(readonly) NSDate* lastAccess;
@property(readonly) BOOL secure;
@property(readonly) BOOL HTTPOnly;
@property(readonly) NSInteger sameSite;
@end

@interface ECBrowserContext (Logins)
// Adds the http and https passwords to the profile's password store as
// imported, which encrypts them with this browser's key. `completion` gets
// how many it added, on the main thread.
- (void)importPasswords:(NSArray<ECPassword*>*)passwords
             completion:(void (^)(NSInteger count))completion;
// Sets the cookies in the profile's cookie store, as another browser's sites
// set them. `completion` gets how many it took, on the main thread.
- (void)importCookies:(NSArray<ECCookie*>*)cookies
           completion:(void (^)(NSInteger count))completion;
@end

@interface ECBrowserContext (Downloads)
// The downloads the context has, including those restored from history, as
// reported so far; later ones arrive in the downloadDelegate.
@property(readonly) NSArray<ECDownload*>* downloads;
// Cancels the download if it is in progress.
- (void)cancelDownload:(uint32_t)identifier;
@end

@interface ECBrowserContext (History)
// Adds the http and https pages last visited in the past 90 days (the history
// Chrome keeps) to the context's history as imported, with one visit at their
// last visit, so autocomplete finds them. Returns how many it added.
- (NSInteger)importHistory:(NSArray<ECHistoryEntry*>*)entries;
// The 16 pt favicon history keeps for the page, e.g. an autocomplete match's
// destinationURL, in `completion` on the main thread (nil for none).
- (void)faviconForPageURL:(NSURL*)URL
               completion:(void (^)(NSImage* _Nullable favicon))completion;
@end

@protocol ECExtensionPopupDelegate <NSObject>
// The page laid out at a new size, between 25x25 and 800x600 points.
- (void)extensionPopupDidResize:(ECExtensionPopup*)popup;
// The page closed itself.
- (void)extensionPopupDidClose:(ECExtensionPopup*)popup;
@end

// An extension action's popup page. The shell shows the view in a popover
// right away, at any size, and resizes it as the page lays out.
EC_EXPORT
@interface ECExtensionPopup : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(readonly) NSView* view;
@property(readonly) NSSize size;
@property(weak, nullable) id<ECExtensionPopupDelegate> delegate;
// Closes the page, e.g. when the popover closed.
- (void)close;
@end

// Matches content::JavaScriptDialogType, plus the leave-page confirmation.
typedef NS_ENUM(NSInteger, ECJavaScriptDialogType) {
  ECJavaScriptDialogTypeAlert,
  ECJavaScriptDialogTypeConfirm,
  ECJavaScriptDialogTypePrompt,
  // Leave the page? Accepting leaves it. The message is empty.
  ECJavaScriptDialogTypeBeforeUnload,
};

// Where the page asked to open a URL, as Chrome's WindowOpenDisposition.
typedef NS_ENUM(NSInteger, ECWindowOpenDisposition) {
  // A link with a target, a script's window.open() or a ⇧⌘-click.
  ECWindowOpenDispositionNewForegroundTab,
  // A ⌘-click or middle click.
  ECWindowOpenDispositionNewBackgroundTab,
  // A ⇧-click, or a link to another site (see
  // opensLinksToOtherSitesInNewWindow).
  ECWindowOpenDispositionNewWindow,
  // A script's window.open() with window features (a popup).
  ECWindowOpenDispositionNewPopup,
};

// Matches blink::ContextMenuDataEditFlags.
typedef NS_OPTIONS(NSUInteger, ECEditFlags) {
  ECEditFlagCanUndo = 1 << 0,
  ECEditFlagCanRedo = 1 << 1,
  ECEditFlagCanCut = 1 << 2,
  ECEditFlagCanCopy = 1 << 3,
  ECEditFlagCanPaste = 1 << 4,
  ECEditFlagCanSelectAll = 1 << 6,
};

// What a right click was on, as of the click. Its commands act on the frame
// clicked and do nothing once it has gone.
EC_EXPORT
@interface ECContextMenu : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(readonly, nullable) NSURL* linkURL;
@property(readonly) NSString* linkText;
// The image's source, nil unless the click was on an image.
@property(readonly, nullable) NSURL* imageURL;
@property(readonly) NSString* selectionText;
@property(readonly, getter=isEditable) BOOL editable;
@property(readonly) ECEditFlags editFlags;
// The writing direction checked for the editable text, natural for none.
@property(readonly) NSWritingDirection writingDirection;
// Ask where to save the link's or the image's target, then download it.
- (void)saveLink;
- (void)saveImage;
- (void)copyImage;
// Opens DevTools on the element clicked.
- (void)inspect;
// Shows the dictionary's definition of the selection.
- (void)lookUp;
- (void)setWritingDirection:(NSWritingDirection)direction;
@end

@protocol ECWebContentsDelegate <NSObject>
- (void)webContentsDidUpdate:(ECWebContents*)contents;
- (void)webContents:(ECWebContents*)contents
    requestsNewWindowWithURL:(NSURL*)url
                 disposition:(ECWindowOpenDisposition)disposition;

// UI the shell presents for the page. Call each completion handler once, on
// the main thread. A call after the engine withdrew the request (navigation,
// close) is ignored.
@optional
// As webContents:requestsNewWindowWithURL:disposition:, which it replaces
// when implemented, with the modifier keys (⌘, ⇧, ⌥, ⌃) of the last click or
// key press in the page, when it was within the past second; 0 otherwise.
// For a window a script opens, that press may predate the request.
- (void)webContents:(ECWebContents*)contents
    requestsNewWindowWithURL:(NSURL*)url
                 disposition:(ECWindowOpenDisposition)disposition
               modifierFlags:(NSEventModifierFlags)modifierFlags;
// `permissions` are Chrome's permission keys, e.g. "notifications",
// "geolocation", "media_stream_camera". Chrome's content settings remember
// the decision for the origin. Without this method requests stay pending.
- (void)webContents:(ECWebContents*)contents
    requestsPermissions:(NSArray<NSString*>*)permissions
              forOrigin:(NSURL*)origin
      completionHandler:(void (^)(BOOL allow))completionHandler;
// `text` is the prompt's answer. Without this method alerts return at once,
// confirms and prompts return false and pages are left without asking.
- (void)webContents:(ECWebContents*)contents
    runJavaScriptDialog:(ECJavaScriptDialogType)type
                message:(NSString*)message
            defaultText:(NSString*)defaultText
      completionHandler:(void (^)(BOOL accepted, NSString* text))completionHandler;
// `acceptTypes` are the input's accept values (".png", "image/*"), empty for
// any file. With `directory`, the user picks one directory, whose files are
// uploaded. Nil or no URLs cancels, as does not implementing this method.
- (void)webContents:(ECWebContents*)contents
    runFileChooserWithAcceptTypes:(NSArray<NSString*>*)acceptTypes
                   allowsMultiple:(BOOL)allowsMultiple
                        directory:(BOOL)directory
                completionHandler:
                    (void (^)(NSArray<NSURL*>* _Nullable fileURLs))
                        completionHandler;
// The page's load progress changed, 0 to 1; 1 once the load finished.
- (void)webContents:(ECWebContents*)contents
    didChangeLoadProgress:(double)progress;
// The page's zoomPercent changed.
- (void)webContentsDidChangeZoom:(ECWebContents*)contents;
// The results of -findString:forward:, updated as the page reports them.
// `activeMatch` counts from 1 and is 0 while unknown.
- (void)webContents:(ECWebContents*)contents
     didFindMatches:(NSInteger)matches
        activeMatch:(NSInteger)activeMatch;
// A right click. Without this method Chrome's own menu shows.
- (void)webContents:(ECWebContents*)contents
    showContextMenu:(ECContextMenu*)menu
    NS_SWIFT_NAME(webContents(_:showContextMenu:));
// The page's selected text changed, empty for none.
- (void)webContents:(ECWebContents*)contents
    didChangeSelection:(NSString*)selectionText;
// The pointer moved onto a link (its URL) or off it (nil).
- (void)webContents:(ECWebContents*)contents
    didUpdateTargetURL:(nullable NSURL*)URL;
// The page closed itself (window.close()), or a new tab only downloaded
// (it started a download before committing anything). The shell closes the
// web contents.
- (void)webContentsDidRequestClose:(ECWebContents*)contents;
// The page asked to be shown, e.g. by its Picture in Picture window's back to
// tab button. The shell selects its tab.
- (void)webContentsDidRequestActivation:(ECWebContents*)contents;
// The Chrome Web Store asks to install an extension. `permissions` are the
// warnings Chrome lists for it. Without this method installs are refused.
- (void)webContents:(ECWebContents*)contents
    requestsInstallOfExtensionNamed:(NSString*)name
                               icon:(nullable NSImage*)icon
                        permissions:(NSArray<NSString*>*)permissions
                  completionHandler:(void (^)(BOOL allow))completionHandler;
@end

// A page in a web contents' history, as of when it was read.
EC_EXPORT
@interface ECNavigationEntry : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(readonly) NSURL* URL;
@property(readonly) NSString* title;
// Its position in the history, for goToEntry:.
@property(readonly) NSInteger index;
// Its distance from the current page as of the read: negative for back
// entries, positive for forward ones (for display; the page may have moved
// since).
@property(readonly) NSInteger offset;
@end

EC_EXPORT
@interface ECWebContents : NSObject
- (instancetype)initWithBrowserContext:(ECBrowserContext*)context;
- (instancetype)init NS_UNAVAILABLE;

// The page's view. Once the web contents is closed it is detached and empty;
// URL and favicon are then nil, the title empty, the flags NO, loadProgress
// 0 and zoomPercent 100.
@property(readonly) NSView* view;
// The URL of the page shown, nil until one has committed. A navigation that
// ends in a download commits nothing.
@property(readonly, nullable) NSURL* URL;
@property(readonly) NSString* title;
// The page's favicon, nil until one has loaded.
@property(readonly, nullable) NSImage* favicon;
@property(readonly) BOOL isLoading;
// How far the page has loaded, 0 to 1 (Chrome's load progress bar). Changes
// are reported to webContents:didChangeLoadProgress:.
@property(readonly) double loadProgress;
@property(readonly) BOOL canGoBack;
@property(readonly) BOOL canGoForward;
// The pages behind and ahead of the current one (the one being navigated
// to, during a history navigation), nearest first, as Chrome's back and
// forward menus list them. Changes are reported to webContentsDidUpdate:.
@property(readonly) NSArray<ECNavigationEntry*>* backEntries;
@property(readonly) NSArray<ECNavigationEntry*>* forwardEntries;
// Whether the page is playing sound, and whether its sound is muted. Changes
// are reported to webContentsDidUpdate:.
@property(readonly, getter=isAudible) BOOL audible;
@property(getter=isMuted) BOOL muted;
// The page's media as Chrome's media session sees it: whether it has any
// (playing or paused), whether it plays, whether what plays has video, and
// whether the page handles previous and next track. Changes are reported to
// webContentsDidUpdate:.
@property(readonly) BOOL hasMedia;
@property(readonly, getter=isPlayingMedia) BOOL playingMedia;
@property(readonly) BOOL mediaHasVideo;
@property(readonly) BOOL canGoToPreviousTrack;
@property(readonly) BOOL canGoToNextTrack;
- (void)playMedia;
- (void)pauseMedia;
- (void)previousTrack;
- (void)nextTrack;
// Shows the page's video in Chrome's Picture in Picture window, which has
// its own controls, and closes it. The window, nil while there is none, is
// reported to webContentsDidUpdate: as it opens and closes; the shell may
// move it.
- (void)enterPictureInPicture;
- (void)exitPictureInPicture;
@property(readonly, nullable) NSWindow* pictureInPictureWindow;
// Whether the page has Chrome's secure (lock) security level.
@property(readonly, getter=isSecure) BOOL secure;
// The name of the language "Translate to" would translate the page into,
// nil if it cannot be translated.
@property(readonly, nullable) NSString* translationLanguage;
// The permissions the user allowed (YES) or blocked (NO) for the page's
// site, by Chrome's permission key (see requestsPermissions:).
@property(readonly) NSDictionary<NSString*, NSNumber*>* sitePermissions;
// Whether a click on a link to another site (registrable domain) asks for a
// new window (ECWindowOpenDispositionNewWindow) instead of leaving the page.
@property BOOL opensLinksToOtherSitesInNewWindow;
@property(weak, nullable) id<ECWebContentsDelegate> delegate;

- (void)loadURL:(NSURL*)url;
- (void)goBack;
- (void)goForward;
// Goes to the entry at `offset` from the current page, as ⌘[ and ⌘] with a
// count. A menu pick goes to the entry itself, by its index, as Chrome's
// back and forward menus do.
- (void)goToOffset:(NSInteger)offset;
- (void)goToEntry:(ECNavigationEntry*)entry;
- (void)reload;
// Reloads without the cache, as ⇧⌘R.
- (void)reloadBypassingCache;
- (void)stop;
// Destroys the web contents. Nothing reaches the delegate afterwards; a web
// contents released without close closes itself.
- (void)close;
// Chrome's page zoom steps, remembered per site.
- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;
// The page's zoom as a percentage, 100 at the default. It changes with the
// steps above and with the site's remembered zoom when the page navigates;
// changes are reported to webContentsDidChangeZoom:.
@property(readonly) NSInteger zoomPercent;

// The page's history (its navigation entries, with their page state) as
// Chrome's session restore keeps it, nil while nothing has committed. Save
// it when the tab is archived or the app quits.
@property(readonly, nullable) NSData* sessionState;
// Restores a saved sessionState into a new web contents that has loaded
// nothing yet: it gets the entries, with the saved one current, and shows
// it once it loads (loadIfNeeded, reload or a navigation). Returns NO if
// the state cannot be read or the web contents has already navigated.
- (BOOL)restoreSessionState:(NSData*)state;
// Loads the current entry if the page has not been loaded, as showing a
// restored tab does.
- (void)loadIfNeeded;

// Asks where to save the page, then saves it.
- (void)savePage;
// Prints the page with the system print dialog.
- (void)print;
- (void)translate;
- (void)setSitePermission:(NSString*)permission allowed:(BOOL)allowed;
// The URL with a text fragment that scrolls to and highlights the selection
// in the focused frame, in `completion` (nil if none could be made).
- (void)linkToHighlight:(void (^)(NSURL* _Nullable URL))completion
    NS_SWIFT_NAME(linkToHighlight(_:));
// The visible page as an image, in `completion` (nil on failure).
- (void)snapshot:(void (^)(NSImage* _Nullable image))completion;
// Runs `script` in the main frame, in an isolated world as content scripts
// run, and gives its result in `completion` if it is a string, nil
// otherwise. Promises are not awaited.
- (void)evaluateJavaScript:(NSString*)script
                completion:(void (^)(NSString* _Nullable result))completion
    NS_SWIFT_NAME(evaluateJavaScript(_:completion:));

// Finds `string` (case-insensitively), or the next match if it is unchanged.
- (void)findString:(NSString*)string forward:(BOOL)forward;
// Finds `string` as typed in the find field: a changed string starts a new
// search from the current match; an unchanged one keeps the active match
// and reports the results again instead of moving to the next match; an
// empty one clears the search and its highlights (reported as 0 matches).
- (void)findString:(NSString*)string;
// Scrolls the selection (the active match) into view, as Jump to Selection.
- (void)scrollSelectionIntoView;
// Ends finding and keeps the active match selected.
- (void)stopFinding;

// Opens DevTools in its own window on the Console, as ⌥⌘J.
- (void)showConsole;
// Opens DevTools with its element picker on, as ⇧⌘C.
- (void)inspectElement;

// Edit commands on the focused frame, usable as menu item actions.
- (void)cut:(nullable id)sender;
- (void)copy:(nullable id)sender;
- (void)paste:(nullable id)sender;
- (void)selectAll:(nullable id)sender;
- (void)undo:(nullable id)sender;
- (void)redo:(nullable id)sender;
- (void)pasteAndMatchStyle:(nullable id)sender;
@end

// What a match leads to, from Chrome's AutocompleteMatchType.
typedef NS_ENUM(NSInteger, ECAutocompleteMatchType) {
  ECAutocompleteMatchTypeURL,
  // A search with the default engine (Google) or another one.
  ECAutocompleteMatchTypeSearch,
  ECAutocompleteMatchTypeHistory,
  ECAutocompleteMatchTypeBookmark,
};

// One of Chrome's address bar suggestions, as of when it was reported.
EC_EXPORT
@interface ECAutocompleteMatch : NSObject
- (instancetype)init NS_UNAVAILABLE;
// The URL or search terms, and the page title or engine name, as the address
// bar shows them.
@property(readonly) NSString* contents;
@property(readonly) NSString* matchDescription;
// Where choosing the match goes: loadURL: it.
@property(readonly) NSURL* destinationURL;
@property(readonly) ECAutocompleteMatchType type;
// Whether the match may be chosen by pressing Return, as the first one.
@property(readonly) BOOL allowedToBeDefault;
// For the first match, the rest of its text the address bar shows selected
// after the typed text, e.g. "ipedia.org" for "wik". Empty for none.
@property(readonly) NSString* inlineAutocompletion;
// The keyword of the site search the match offers, e.g. "bing.com" (Chrome's
// "Search Bing" Tab hint), and the engine's name, e.g. "Bing". nil for none.
@property(readonly, nullable) NSString* associatedKeyword;
@property(readonly, nullable) NSString* associatedKeywordName;
@end

@class ECAutocomplete;

@protocol ECAutocompleteDelegate <NSObject>
// The matches for the text, best first. More arrive until `done`.
- (void)autocomplete:(ECAutocomplete*)autocomplete
    didUpdateMatches:(NSArray<ECAutocompleteMatch*>*)matches
                done:(BOOL)done;
@end

// Chrome's address bar autocomplete for a context: history, bookmarks,
// shortcuts, and searches and suggestions from the default engine.
EC_EXPORT
@interface ECAutocomplete : NSObject
- (instancetype)initWithBrowserContext:(ECBrowserContext*)context;
- (instancetype)init NS_UNAVAILABLE;
@property(weak, nullable) id<ECAutocompleteDelegate> delegate;
// Replaces any query running. Matches arrive in the delegate, the first ones
// before this returns.
- (void)startWithText:(NSString*)text;
// As startWithText:, in keyword mode for a match's associatedKeyword: the
// matches search that site for `text`.
- (void)startWithText:(NSString*)text keyword:(nullable NSString*)keyword;
- (void)stop;
// The user chose `match` for the last text; Chrome ranks it higher for that
// text next time. The shell loads its destinationURL.
- (void)didSelectMatch:(ECAutocompleteMatch*)match;
@end

@class ECWindow;

// What extensions ask of a window's tabs (chrome.tabs).
@protocol ECWindowDelegate <NSObject>
// Opens a tab loading `url`: the shell creates the web contents, adds it to
// the window's tabs and returns it, or returns nil if it opened none.
- (nullable ECWebContents*)window:(ECWindow*)window
                   openTabWithURL:(NSURL*)url
                           active:(BOOL)active;
- (void)window:(ECWindow*)window activateTab:(ECWebContents*)contents;
- (void)window:(ECWindow*)window closeTab:(ECWebContents*)contents;
@end

// A shell window as extensions see it (chrome.windows), holding tabs
// (chrome.tabs). Extensions are told of the changes the shell makes.
EC_EXPORT
@interface ECWindow : NSObject
- (instancetype)initWithBrowserContext:(ECBrowserContext*)context;
- (instancetype)init NS_UNAVAILABLE;
@property(weak, nullable) id<ECWindowDelegate> delegate;
// The window's tabs in order; a web contents is in at most one window. A
// closed web contents leaves its window.
@property(nonatomic, copy) NSArray<ECWebContents*>* tabs;
// One of `tabs`.
@property(nonatomic, weak, nullable) ECWebContents* activeTab;
// Set when the window becomes and stops being key. Extensions' current
// window is the focused one, else the one focused last.
@property(nonatomic, getter=isFocused) BOOL focused;
- (void)close;
@end

NS_ASSUME_NONNULL_END
