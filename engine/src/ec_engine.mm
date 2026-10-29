#import "engine_core/EngineCore.h"

#import <objc/runtime.h>

#include <cstdlib>
#include <string>
#include <vector>

#include "base/strings/sys_string_conversions.h"
#import "chrome/browser/app_controller_mac.h"
#import "engine_core/ec_browser_context_private.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"

extern "C" int ChromeMain(int argc, const char** argv);

NSNotificationName const ECEngineOpenURLsNotification =
    @"ECEngineOpenURLsNotification";
NSNotificationName const ECEngineReopenNotification =
    @"ECEngineReopenNotification";

NSMenu* g_dock_menu;

// Chrome's app delegate, with the events that would open a Chrome browser
// window posted to the shell instead.
@interface ECAppController : AppController
@end

@implementation ECAppController

- (BOOL)applicationShouldHandleReopen:(NSApplication*)app
                    hasVisibleWindows:(BOOL)hasVisibleWindows {
  [NSNotificationCenter.defaultCenter
      postNotificationName:ECEngineReopenNotification
                    object:nil];
  return YES;
}

- (void)application:(NSApplication*)app openURLs:(NSArray<NSURL*>*)urls {
  [NSNotificationCenter.defaultCenter
      postNotificationName:ECEngineOpenURLsNotification
                    object:urls];
}

- (BOOL)application:(NSApplication*)app
    continueUserActivity:(NSUserActivity*)activity
      restorationHandler:
          (void (^)(NSArray<id<NSUserActivityRestoring>>*))restorationHandler {
  if (!activity.webpageURL) {
    return NO;
  }
  [self application:app openURLs:@[ activity.webpageURL ]];
  return YES;
}

- (NSMenu*)applicationDockMenu:(NSApplication*)app {
  return g_dock_menu;
}

// Binds the bookmark and history menus of Chrome's main menu, which the shell
// may replace, to the last used profile.
- (void)setLastProfile:(Profile*)profile {
}

@end

@implementation ECEngine

+ (NSMenu*)dockMenu {
  return g_dock_menu;
}

+ (void)setDockMenu:(NSMenu*)menu {
  g_dock_menu = menu;
}

+ (NSString*)registrableDomainForHost:(NSString*)host {
  std::string domain = net::registry_controlled_domains::GetDomainAndRegistry(
      base::SysNSStringToUTF8(host),
      net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  return domain.empty() ? host : base::SysUTF8ToNSString(domain);
}

+ (void)startWithArguments:(NSArray<NSString*>*)args {
  // AppController is NSApp's delegate by now and AppKit has not yet delivered
  // any open or reopen events.
  [NSNotificationCenter.defaultCenter
      addObserverForName:NSApplicationWillFinishLaunchingNotification
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification*) {
                object_setClass(NSApp.delegate, ECAppController.class);
              }];
  [NSNotificationCenter.defaultCenter
      addObserverForName:NSApplicationDidFinishLaunchingNotification
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification*) {
                SetUpExtensions();
              }];
  std::vector<std::string> strings;
  for (NSString* arg in args) {
    strings.push_back(arg.UTF8String);
  }
  strings.push_back("--no-startup-window");
  strings.push_back("--no-first-run");
  strings.push_back("--no-default-browser-check");
  // Non-official builds turn on the experiments in
  // testing/variations/fieldtrial_testing_config.json, among them
  // OmniboxEverywhere and its menu bar status item.
  strings.push_back("--disable-field-trial-config");
  // Profiles that ran with that config have migrated their search engines,
  // which cannot be undone, and Chrome expects the migration to stay on.
  strings.push_back(
      "--enable-features=PrepopulatedEnginesMigration,"
      "ApplySearchEngineTypeMigration");
  std::vector<const char*> argv;
  for (const std::string& s : strings) {
    argv.push_back(s.c_str());
  }
  exit(ChromeMain(static_cast<int>(argv.size()), argv.data()));
}

@end
