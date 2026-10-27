#ifndef ENGINE_CORE_EC_WEB_CONTENTS_PRIVATE_H_
#define ENGINE_CORE_EC_WEB_CONTENTS_PRIVATE_H_

#import "engine_core/EngineCore.h"

namespace content {
class WebContents;
}

namespace extensions {
class WindowController;
}

NS_ASSUME_NONNULL_BEGIN

@interface ECWebContents ()
// The ECWebContents of `contents`, nil if the shell did not create it.
+ (nullable ECWebContents*)fromContents:(content::WebContents*)contents;
// Null once closed.
@property(readonly, nullable) content::WebContents* contents;
// Set by the window that holds the tab.
@property(weak, nullable) ECWindow* window;
@end

@interface ECWindow ()
// Null once closed.
@property(readonly, nullable) extensions::WindowController* controller;
// The tab's status, URL, title or favicon may have changed.
- (void)tabDidUpdate:(ECWebContents*)tab;
// The tab is closing.
- (void)tabWillClose:(ECWebContents*)tab;
@end

// Replaces Chrome's chrome.tabs and chrome.windows functions that read its
// tab strips with ones that read the shell's windows.
void RegisterWindowFunctions();

NS_ASSUME_NONNULL_END

#endif  // ENGINE_CORE_EC_WEB_CONTENTS_PRIVATE_H_
