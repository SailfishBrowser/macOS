#ifndef ENGINE_CORE_EC_BROWSER_CONTEXT_PRIVATE_H_
#define ENGINE_CORE_EC_BROWSER_CONTEXT_PRIVATE_H_

#import "engine_core/EngineCore.h"

class Profile;

namespace download {
class DownloadItem;
}

@interface ECDownload ()
- (instancetype)initWithItem:(download::DownloadItem*)item;
@end

@interface ECBrowserContext ()
@property(readonly) Profile* profile;
// The open web contents, closed with the context.
@property(readonly) NSHashTable<ECWebContents*>* webContents;
// The open autocompletes, closed with the context.
@property(readonly) NSHashTable<ECAutocomplete*>* autocompletes;
@end

@interface ECAutocomplete ()
- (void)close;
@end

// Reports the context's extension changes to its extensionsDelegate.
void ObserveExtensions(ECBrowserContext* context);

// Has extension installs ask the shell and chrome.tabs read its windows.
void SetUpExtensions();

#endif  // ENGINE_CORE_EC_BROWSER_CONTEXT_PRIVATE_H_
