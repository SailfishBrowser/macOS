#import "engine_core/ec_browser_context_private.h"

#include <map>
#include <memory>
#include <set>
#include <string>

#include "base/apple/foundation_util.h"
#include "base/auto_reset.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/extensions/component_loader.h"
#include "chrome/browser/extensions/extension_action_dispatcher.h"
#include "chrome/browser/extensions/extension_action_runner.h"
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/extensions/extension_install_prompt_show_params.h"
#include "chrome/browser/extensions/extension_view.h"
#include "chrome/browser/extensions/extension_view_host.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/extensions/extension_install_ui.h"
#include "chrome/browser/ui/extensions/extension_popup_types.h"
#include "components/sessions/content/session_tab_helper.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#import "engine_core/ec_web_contents_private.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_icon_factory.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/extension_util.h"
#include "extensions/browser/image_loader.h"
#include "extensions/browser/install_prompt_data.h"
#include "extensions/browser/ui_util.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest_handlers/incognito_info.h"
#include "net/base/apple/url_conversions.h"
#include "skia/ext/skia_utils_mac.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/image/image_skia_util_mac.h"

using extensions::Extension;
using extensions::ExtensionAction;

@implementation ECExtension

@synthesize identifier = _identifier;
@synthesize name = _name;
@synthesize icon = _icon;
@synthesize enabled = _enabled;
@synthesize builtIn = _builtIn;

- (instancetype)initWithExtension:(const Extension&)extension
                             icon:(NSImage*)icon
                          enabled:(BOOL)enabled
                          builtIn:(BOOL)builtIn {
  if ((self = [super init])) {
    _identifier = base::SysUTF8ToNSString(extension.id());
    _name = base::SysUTF8ToNSString(extension.name());
    _icon = icon;
    _enabled = enabled;
    _builtIn = builtIn;
  }
  return self;
}

@end

@implementation ECExtensionAction

@synthesize title = _title;
@synthesize icon = _icon;
@synthesize badgeText = _badgeText;
@synthesize badgeBackgroundColor = _badgeBackgroundColor;
@synthesize enabled = _enabled;

- (instancetype)initWithAction:(const ExtensionAction&)action
                          icon:(NSImage*)icon
                         tabId:(int)tabId {
  if ((self = [super init])) {
    _title = base::SysUTF8ToNSString(action.GetTitle(tabId));
    _icon = icon;
    _badgeText = base::SysUTF8ToNSString(action.GetDisplayBadgeText(tabId));
    _badgeBackgroundColor =
        skia::SkColorToSRGBNSColor(action.GetBadgeBackgroundColor(tabId));
    _enabled = action.GetIsVisible(tabId);
  }
  return self;
}

@end

namespace {

// The extensions loadBuiltInExtensionAtPath: loaded, in any profile.
std::set<extensions::ExtensionId>& BuiltInExtensions() {
  static base::NoDestructor<std::set<extensions::ExtensionId>> ids;
  return *ids;
}

class ExtensionsObserver;

// Loads an action's icon and reports when it changes.
class ActionIcon : public extensions::ExtensionActionIconFactory::Observer {
 public:
  ActionIcon(ExtensionsObserver* owner,
             const Extension* extension,
             ExtensionAction* action)
      : owner_(owner), id_(extension->id()), factory_(extension, action, this) {}

  // Converts afresh: the default icon's gfx::Image lives on, and would keep
  // the NSImage of its blank reps from before they loaded.
  NSImage* Get(int tab_id) {
    gfx::Image image = factory_.GetIcon(tab_id);
    return image.IsEmpty() ? nil
                           : gfx::NSImageFromImageSkia(image.AsImageSkia());
  }

  void OnIconUpdated() override;

 private:
  raw_ptr<ExtensionsObserver> owner_;
  const extensions::ExtensionId id_;
  extensions::ExtensionActionIconFactory factory_;
};

// Reports a context's extension changes to its delegate and keeps their
// icons. The profile owns it.
class ExtensionsObserver
    : public base::SupportsUserData::Data,
      public extensions::ExtensionRegistryObserver,
      public extensions::ExtensionActionDispatcher::Observer {
 public:
  static constexpr char kKey[] = "ECExtensionsObserver";

  static ExtensionsObserver* Get(Profile* profile) {
    return static_cast<ExtensionsObserver*>(profile->GetUserData(kKey));
  }

  explicit ExtensionsObserver(ECBrowserContext* owner)
      : owner_(owner), profile_(owner.profile) {
    registry_observation_.Observe(extensions::ExtensionRegistry::Get(profile_));
    action_observation_.Observe(
        extensions::ExtensionActionDispatcher::Get(profile_));
  }

  NSImage* Icon(const Extension* extension) {
    auto it = icons_.find(extension->id());
    if (it != icons_.end()) {
      return it->second;
    }
    icons_[extension->id()] = nil;
    extensions::ImageLoader::Get(profile_)->LoadImageAtEveryScaleFactorAsync(
        extension, gfx::Size(32, 32),
        base::BindOnce(&ExtensionsObserver::IconLoaded,
                       weak_factory_.GetWeakPtr(), extension->id()));
    return nil;
  }

  ECExtensionAction* Action(const Extension& extension,
                            content::WebContents* contents) {
    ExtensionAction* action =
        extensions::ExtensionActionManager::Get(profile_)->GetExtensionAction(
            extension);
    if (!action) {
      return nil;
    }
    std::unique_ptr<ActionIcon>& icon = action_icons_[extension.id()];
    if (!icon) {
      icon = std::make_unique<ActionIcon>(this, &extension, action);
    }
    int tab_id = sessions::SessionTabHelper::IdForTab(contents).id();
    return [[ECExtensionAction alloc] initWithAction:*action
                                                icon:icon->Get(tab_id)
                                               tabId:tab_id];
  }

  void ActionChanged(const extensions::ExtensionId& id, ECWebContents* tab) {
    [owner_.extensionsDelegate browserContext:owner_
                  actionDidChangeForExtension:base::SysUTF8ToNSString(id)
                                  webContents:tab];
  }

  // ExtensionRegistryObserver:
  void OnExtensionLoaded(content::BrowserContext* browser_context,
                         const Extension* extension) override {
    Changed();
  }

  void OnExtensionUnloaded(content::BrowserContext* browser_context,
                           const Extension* extension,
                           extensions::UnloadedExtensionReason reason) override {
    action_icons_.erase(extension->id());
    Changed();
  }

  void OnExtensionInstalled(content::BrowserContext* browser_context,
                            const Extension* extension,
                            bool is_update) override {
    icons_.erase(extension->id());
  }

  void OnExtensionUninstalled(content::BrowserContext* browser_context,
                              const Extension* extension,
                              extensions::UninstallReason reason) override {
    icons_.erase(extension->id());
    Changed();
  }

  void OnShutdown(extensions::ExtensionRegistry* registry) override {
    registry_observation_.Reset();
  }

  // ExtensionActionDispatcher::Observer, shared with the incognito profile:
  void OnExtensionActionUpdated(
      ExtensionAction* action,
      content::WebContents* contents,
      content::BrowserContext* browser_context) override {
    ECWebContents* tab = contents ? [ECWebContents fromContents:contents] : nil;
    if (browser_context == profile_ &&
        (!contents || (tab && !contents->IsBeingDestroyed()))) {
      ActionChanged(action->extension_id(), tab);
    }
  }

  void OnShuttingDown() override { action_observation_.Reset(); }

 private:
  void Changed() {
    [owner_.extensionsDelegate browserContextExtensionsDidChange:owner_];
  }

  void IconLoaded(const extensions::ExtensionId& id, const gfx::Image& image) {
    if (!image.IsEmpty()) {
      icons_[id] = image.ToNSImage();
      Changed();
    }
  }

  __weak ECBrowserContext* owner_;
  raw_ptr<Profile> profile_;
  std::map<extensions::ExtensionId, NSImage*> icons_;
  std::map<extensions::ExtensionId, std::unique_ptr<ActionIcon>> action_icons_;
  base::ScopedObservation<extensions::ExtensionRegistry,
                          extensions::ExtensionRegistryObserver>
      registry_observation_{this};
  base::ScopedObservation<extensions::ExtensionActionDispatcher,
                          extensions::ExtensionActionDispatcher::Observer>
      action_observation_{this};
  base::WeakPtrFactory<ExtensionsObserver> weak_factory_{this};
};

void ActionIcon::OnIconUpdated() {
  owner_->ActionChanged(id_, nil);
}

// Asks the delegate of the web contents that wants to install, instead of
// showing Chrome's install dialog.
void ShowInstallDialog(
    std::unique_ptr<ExtensionInstallPromptShowParams> show_params,
    ExtensionInstallPrompt::DoneCallback done_callback,
    std::unique_ptr<extensions::InstallPromptData> prompt) {
  using Payload = ExtensionInstallPrompt::DoneCallbackPayload;
  using Result = extensions::ExtensionInstallPromptClient::Result;
  content::WebContents* parent = show_params->GetParentWebContents();
  ECWebContents* contents = parent ? [ECWebContents fromContents:parent] : nil;
  if (![contents.delegate
          respondsToSelector:@selector
          (webContents:requestsInstallOfExtensionNamed:icon:permissions:
              completionHandler:)]) {
    std::move(done_callback).Run(Payload(Result::USER_CANCELED));
    return;
  }
  NSMutableArray<NSString*>* permissions = [NSMutableArray array];
  for (size_t i = 0; i < prompt->GetPermissionCount(); ++i) {
    [permissions addObject:base::SysUTF16ToNSString(prompt->GetPermission(i))];
  }
  auto shared =
      std::make_shared<ExtensionInstallPrompt::DoneCallback>(
          std::move(done_callback));
  [contents.delegate webContents:contents
      requestsInstallOfExtensionNamed:base::SysUTF8ToNSString(
                                          prompt->extension()->name())
                                 icon:prompt->icon().IsEmpty()
                                          ? nil
                                          : prompt->icon().ToNSImage()
                          permissions:permissions
                    completionHandler:^(BOOL allow) {
                      if (*shared) {
                        base::SequencedTaskRunner::GetCurrentDefault()
                            ->PostTask(FROM_HERE,
                                       base::BindOnce(
                                           std::move(*shared),
                                           Payload(allow
                                                       ? Result::ACCEPTED
                                                       : Result::
                                                             USER_CANCELED)));
                      }
                    }];
}

// What the popup page asks of its window.
class PopupDelegate : public extensions::ExtensionViewHost::Delegate {
 public:
  explicit PopupDelegate(ECWindow* window) : window_(window) {}

  content::WebContents* OpenURL(
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)>
          navigation_handle_callback) override {
    return [window_.delegate window:window_
                     openTabWithURL:net::NSURLWithGURL(params.url)
                             active:params.disposition !=
                                    WindowOpenDisposition::NEW_BACKGROUND_TAB]
        .contents;
  }

  content::KeyboardEventProcessingResult PreHandleKeyboardEvent(
      content::WebContents* source,
      const input::NativeWebKeyboardEvent& event) override {
    return content::KeyboardEventProcessingResult::NOT_HANDLED;
  }

  std::unique_ptr<content::EyeDropper> OpenEyeDropper(
      content::RenderFrameHost* frame,
      content::EyeDropperListener* listener) override {
    return nullptr;
  }

  extensions::WindowController* GetExtensionWindowController() override {
    return window_.controller;
  }

 private:
  __weak ECWindow* window_;
};

}  // namespace

@interface ECExtensionPopup ()
- (void)setSize:(NSSize)size;
@end

namespace {

// Hosts the popup page and sizes it to its content, as Chrome's popup view
// does. The page lays out once the shell shows the view.
class PopupView : public extensions::ExtensionView {
 public:
  PopupView(ECExtensionPopup* owner,
            const Extension* extension,
            const GURL& url,
            Profile* profile,
            ECWindow* window)
      : owner_(owner),
        host_(extension,
              profile,
              url,
              extensions::mojom::ViewType::kExtensionPopup,
              std::make_unique<PopupDelegate>(window)) {
    host_.set_view(this);
    // window.close() calls this inside the page's delegate.
    __weak ECExtensionPopup* weak_owner = owner;
    host_.SetCloseHandler(base::BindOnce(^(extensions::ExtensionHost*) {
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(^{
            ECExtensionPopup* popup = weak_owner;
            [popup close];
            [popup.delegate extensionPopupDidClose:popup];
          }));
    }));
    host_.CreateRendererSoon();
  }

  gfx::NativeView GetNativeView() override {
    return host_.host_contents()->GetNativeView();
  }

  void ResizeDueToAutoResize(content::WebContents* web_contents,
                             const gfx::Size& new_size) override {
    [owner_ setSize:NSMakeSize(new_size.width(), new_size.height())];
  }

  void RenderFrameCreated(content::RenderFrameHost* frame) override {
    if (!frame->GetParent()) {
      frame->GetView()->EnableAutoResize(extensions::kExtensionPopupMinSize,
                                         extensions::kExtensionPopupMaxSize);
    }
  }

  bool HandleKeyboardEvent(
      content::WebContents* source,
      const input::NativeWebKeyboardEvent& event) override {
    return false;
  }

  void OnLoaded() override {}

 private:
  __weak ECExtensionPopup* owner_;
  extensions::ExtensionViewHost host_;
};

}  // namespace

@implementation ECExtensionPopup {
  std::unique_ptr<PopupView> _view;
}

@synthesize size = _size;
@synthesize delegate = _delegate;

- (instancetype)initWithExtension:(const Extension*)extension
                              url:(const GURL&)url
                          profile:(Profile*)profile
                           window:(ECWindow*)window {
  if ((self = [super init])) {
    _view = std::make_unique<PopupView>(self, extension, url, profile, window);
  }
  return self;
}

- (NSView*)view {
  return _view->GetNativeView().GetNativeNSView();
}

- (void)setSize:(NSSize)size {
  _size = size;
  [_delegate extensionPopupDidResize:self];
}

- (void)close {
  if (!_view) {
    return;
  }
  [self.view removeFromSuperview];
  _view.reset();
}

@end

void SetUpExtensions() {
  // The shell shows what follows an install itself.
  static base::NoDestructor<base::AutoReset<bool>> no_install_ui(
      ExtensionInstallUI::disable_ui_for_tests(true));
  ExtensionInstallPrompt::SetDefaultShowDialogCallback(
      base::BindRepeating(&ShowInstallDialog));
  RegisterWindowFunctions();
}

void ObserveExtensions(ECBrowserContext* context) {
  context.profile->SetUserData(ExtensionsObserver::kKey,
                               std::make_unique<ExtensionsObserver>(context));
}

@implementation ECBrowserContext (Extensions)

- (NSArray<ECExtension*>*)extensions {
  ExtensionsObserver* observer = ExtensionsObserver::Get(self.profile);
  NSMutableArray<ECExtension*>* result = [NSMutableArray array];
  for (BOOL enabled : {YES, NO}) {
    for (const auto& extension :
         enabled ? extensions::ExtensionRegistry::Get(self.profile)->enabled_extensions()
                 : extensions::ExtensionRegistry::Get(self.profile)->disabled_extensions()) {
      bool built_in = BuiltInExtensions().contains(extension->id());
      if ((built_in ||
           extensions::ui_util::ShouldDisplayInExtensionSettings(*extension)) &&
          (!self.profile->IsOffTheRecord() ||
           extensions::util::IsIncognitoEnabled(extension->id(),
                                                self.profile))) {
        [result addObject:[[ECExtension alloc]
                              initWithExtension:*extension
                                           icon:observer->Icon(extension.get())
                                        enabled:enabled
                                        builtIn:built_in]];
      }
    }
  }
  return result;
}

- (void)setEnabled:(BOOL)enabled forExtension:(NSString*)identifier {
  extensions::ExtensionRegistrar* registrar =
      extensions::ExtensionRegistrar::Get(self.profile);
  std::string id = base::SysNSStringToUTF8(identifier);
  if (enabled) {
    registrar->EnableExtension(id);
  } else {
    registrar->DisableExtension(
        id, {extensions::disable_reason::DISABLE_USER_ACTION});
  }
}

- (void)uninstallExtension:(NSString*)identifier {
  std::u16string error;
  extensions::ExtensionRegistrar::Get(self.profile)
      ->UninstallExtension(base::SysNSStringToUTF8(identifier),
                           extensions::UNINSTALL_REASON_USER_INITIATED, &error);
}

- (void)loadBuiltInExtensionAtPath:(NSString*)path {
  BuiltInExtensions().insert(
      extensions::ComponentLoader::Get(self.profile)
          ->AddOrReplace(base::apple::NSStringToFilePath(path)));
}

- (void)unloadBuiltInExtensions {
  for (const extensions::ExtensionId& id : BuiltInExtensions()) {
    extensions::ComponentLoader::Get(self.profile)->Remove(id);
  }
}

- (ECExtensionAction*)actionForExtension:(NSString*)identifier
                           inWebContents:(ECWebContents*)contents {
  const Extension* extension = extensions::ExtensionRegistry::Get(self.profile)->enabled_extensions().GetByID(
      base::SysNSStringToUTF8(identifier));
  return extension ? ExtensionsObserver::Get(self.profile)
                         ->Action(*extension, contents.contents)
                   : nil;
}

- (ECExtensionPopup*)runActionForExtension:(NSString*)identifier
                             inWebContents:(ECWebContents*)contents {
  const Extension* extension = extensions::ExtensionRegistry::Get(self.profile)->enabled_extensions().GetByID(
      base::SysNSStringToUTF8(identifier));
  if (!extension ||
      extensions::ExtensionActionRunner::GetForWebContents(contents.contents)
              ->RunAction(extension, /*grant_tab_permissions=*/true) !=
          ExtensionAction::ShowAction::kShowPopup) {
    return nil;
  }
  int tab_id = sessions::SessionTabHelper::IdForTab(contents.contents).id();
  GURL url = extensions::ExtensionActionManager::Get(self.profile)
                 ->GetExtensionAction(*extension)
                 ->GetPopupUrl(tab_id);
  // A spanning extension runs in the original profile.
  Profile* profile =
      extensions::IncognitoInfo::IsSplitMode(extension)
          ? self.profile
          : self.profile->GetOriginalProfile();
  return [[ECExtensionPopup alloc] initWithExtension:extension
                                                 url:url
                                             profile:profile
                                              window:contents.window];
}

@end
