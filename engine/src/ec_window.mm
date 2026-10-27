#import "engine_core/ec_web_contents_private.h"

#include <map>
#include <optional>
#include <string>
#include <vector>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/pattern.h"
#include "base/strings/string_number_conversions.h"
#include "chrome/browser/extensions/api/tabs/tabs_constants.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/extensions/window_controller.h"
#include "chrome/browser/extensions/window_controller_list.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/extensions/api/tabs.h"
#include "chrome/common/extensions/api/windows.h"
#include "chrome/common/webui_url_constants.h"
#include "components/sessions/content/session_tab_helper.h"
#include "components/sessions/core/session_id.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/web_contents.h"
#import "engine_core/ec_browser_context_private.h"
#include "extensions/browser/api/constants.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_function.h"
#include "extensions/browser/extension_function_dispatcher.h"
#include "extensions/browser/extension_function_registry.h"
#include "extensions/common/constants.h"
#include "extensions/common/error_utils.h"
#include "extensions/common/url_pattern_set.h"
#include "net/base/apple/url_conversions.h"
#include "ui/base/base_window.h"
#include "ui/base/mojom/window_show_state.mojom.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/mac/coordinate_conversion.h"

namespace {

using extensions::ExtensionTabUtil;
using extensions::WindowController;
namespace tabs = extensions::api::tabs;
namespace windows = extensions::api::windows;

class WindowBridge;

// The shell's windows, the one focused last first.
std::vector<WindowBridge*>& Windows() {
  static base::NoDestructor<std::vector<WindowBridge*>> windows;
  return *windows;
}

// The tab as `extension` may see it.
tabs::Tab TabObject(content::WebContents* contents,
                    const extensions::Extension* extension,
                    extensions::mojom::ContextType context) {
  tabs::Tab tab = ExtensionTabUtil::CreateTabObject(
      contents,
      ExtensionTabUtil::GetScrubTabBehavior(extension, context, contents),
      extension);
  ECWebContents* owner = [ECWebContents fromContents:contents];
  if (ECWindow* window = owner.window) {
    tab.index = static_cast<int>([window.tabs indexOfObject:owner]);
    tab.active = tab.selected = tab.highlighted = window.activeTab == owner;
  }
  return tab;
}

// A window as Chrome's extension code sees it: in the WindowControllerList,
// so ExtensionTabUtil::GetTabById() finds its tabs (patches/0006), and with
// the shell's NSWindow behind ui::BaseWindow.
class WindowBridge : public ui::BaseWindow, public WindowController {
 public:
  WindowBridge(ECWindow* owner, Profile* profile)
      : WindowController(this, profile), owner_(owner) {
    Windows().push_back(this);
    extensions::WindowControllerList::GetInstance()->AddExtensionWindow(this);
  }

  ~WindowBridge() override {
    extensions::WindowControllerList::GetInstance()->RemoveExtensionWindow(
        this);
    std::erase(Windows(), this);
  }

  ECWindow* owner() const { return owner_; }
  SessionID session_id() const { return session_id_; }

  bool Contains(content::WebContents* contents) const {
    return [ECWebContents fromContents:contents].window == owner_;
  }

  // WindowController:
  int GetWindowId() const override { return session_id_.id(); }

  std::string GetWindowTypeText() const override {
    return tabs::ToString(tabs::WindowType::kNormal);
  }

  void SetFullscreenMode(bool is_fullscreen,
                         const GURL& extension_url) const override {
    if (IsFullscreen() != is_fullscreen) {
      [Window() toggleFullScreen:nil];
    }
  }

  content::WebContents* GetActiveTab() const override {
    return owner_.activeTab.contents;
  }

  int GetTabCount() const override {
    return static_cast<int>(owner_.tabs.count);
  }

  content::WebContents* GetWebContentsAt(int i) const override {
    return i >= 0 && i < GetTabCount() ? owner_.tabs[i].contents : nullptr;
  }

  bool IsVisibleToTabsAPIForExtension(
      const extensions::Extension* extension,
      bool include_dev_tools_windows) const override {
    return true;
  }

  base::DictValue CreateWindowValueForExtension(
      const extensions::Extension* extension,
      PopulateTabBehavior populate_tab_behavior,
      extensions::mojom::ContextType context) const override {
    windows::Window window;
    window.id = GetWindowId();
    window.focused = IsActive();
    window.incognito = profile()->IsOffTheRecord();
    window.type = windows::WindowType::kNormal;
    window.state = IsMinimized()    ? windows::WindowState::kMinimized
                   : IsFullscreen() ? windows::WindowState::kFullscreen
                   : IsMaximized()  ? windows::WindowState::kMaximized
                                    : windows::WindowState::kNormal;
    gfx::Rect bounds = GetBounds();
    window.left = bounds.x();
    window.top = bounds.y();
    window.width = bounds.width();
    window.height = bounds.height();
    base::DictValue value = window.ToValue();
    if (populate_tab_behavior == kPopulateTabs) {
      value.Set(ExtensionTabUtil::kTabsKey, CreateTabList(extension, context));
    }
    return value;
  }

  base::ListValue CreateTabList(
      const extensions::Extension* extension,
      extensions::mojom::ContextType context) const override {
    base::ListValue tabs;
    for (ECWebContents* tab in owner_.tabs) {
      tabs.Append(TabObject(tab.contents, extension, context).ToValue());
    }
    return tabs;
  }

  bool OpenOptionsPage(const extensions::Extension* extension,
                       const GURL& url,
                       bool open_in_tab) override {
    return [owner_.delegate window:owner_
                    openTabWithURL:net::NSURLWithGURL(url)
                            active:YES] != nil;
  }

  // ui::BaseWindow:
  bool IsActive() const override { return owner_.focused; }
  bool IsMaximized() const override { return Window().zoomed; }
  bool IsMinimized() const override { return Window().miniaturized; }
  bool IsFullscreen() const override {
    return Window().styleMask & NSWindowStyleMaskFullScreen;
  }
  gfx::NativeWindow GetNativeWindow() const override {
    return gfx::NativeWindow(Window());
  }
  gfx::Rect GetRestoredBounds() const override { return GetBounds(); }
  ui::mojom::WindowShowState GetRestoredState() const override {
    return ui::mojom::WindowShowState::kNormal;
  }
  gfx::Rect GetBounds() const override {
    return gfx::ScreenRectFromNSRect(Window().frame);
  }
  void Show() override { [Window() makeKeyAndOrderFront:nil]; }
  void Hide() override { [Window() orderOut:nil]; }
  bool IsVisible() const override { return Window().visible; }
  void ShowInactive() override { [Window() orderFront:nil]; }
  void Close() override { [Window() performClose:nil]; }
  void Activate() override { [Window() makeKeyAndOrderFront:nil]; }
  void Deactivate() override { [Window() orderBack:nil]; }
  void Maximize() override {
    if (!IsMaximized()) {
      [Window() zoom:nil];
    }
  }
  void Minimize() override { [Window() miniaturize:nil]; }
  void Restore() override { [Window() deminiaturize:nil]; }
  void SetBounds(const gfx::Rect& bounds) override {
    [Window() setFrame:gfx::ScreenRectToNSRect(bounds) display:YES];
  }
  void FlashFrame(bool flash) override {
    if (flash) {
      [NSApp requestUserAttention:NSInformationalRequest];
    }
  }
  ui::ZOrderLevel GetZOrderLevel() const override {
    return Window().level > NSNormalWindowLevel
               ? ui::ZOrderLevel::kFloatingWindow
               : ui::ZOrderLevel::kNormal;
  }
  void SetZOrderLevel(ui::ZOrderLevel order) override {
    Window().level = order == ui::ZOrderLevel::kNormal ? NSNormalWindowLevel
                                                       : NSFloatingWindowLevel;
  }

 private:
  NSWindow* Window() const {
    return (owner_.activeTab ?: owner_.tabs.firstObject).view.window;
  }

  __weak ECWindow* owner_;
  const SessionID session_id_ = SessionID::NewUnique();
};

void DispatchEvent(Profile* profile,
                   extensions::events::HistogramValue histogram_value,
                   const std::string& event_name,
                   base::ListValue args,
                   extensions::Event::WillDispatchCallback will_dispatch =
                       extensions::Event::WillDispatchCallback()) {
  auto event = std::make_unique<extensions::Event>(
      histogram_value, event_name, std::move(args), profile);
  event->will_dispatch_callback = std::move(will_dispatch);
  extensions::EventRouter::Get(profile)->BroadcastEvent(std::move(event));
}

// Fills in the tab of tabs.onCreated, or of tabs.onUpdated with the
// `changed` properties, as each extension may see it.
bool WillDispatchTabEvent(base::WeakPtr<content::WebContents> contents,
                          std::optional<std::vector<std::string>> changed,
                          content::BrowserContext* browser_context,
                          extensions::mojom::ContextType context,
                          const extensions::Extension* extension,
                          const base::DictValue* listener_filter,
                          std::optional<base::ListValue>& args,
                          extensions::mojom::EventFilteringInfoPtr& info,
                          bool* dispatch_separate_event) {
  if (!contents) {
    return false;
  }
  base::DictValue tab = TabObject(contents.get(), extension, context).ToValue();
  args.emplace();
  if (!changed) {
    args->Append(std::move(tab));
    return true;
  }
  base::DictValue change_info;
  for (const std::string& key : *changed) {
    if (const base::Value* value = tab.Find(key)) {
      change_info.Set(key, value->Clone());
    }
  }
  args->Append(ExtensionTabUtil::GetTabId(contents.get()));
  args->Append(std::move(change_info));
  args->Append(std::move(tab));
  return true;
}

Profile* ProfileOf(content::WebContents* contents) {
  return Profile::FromBrowserContext(contents->GetBrowserContext());
}

// The tab properties tabs.onUpdated reports.
base::DictValue TabState(content::WebContents* contents) {
  base::DictValue tab =
      ExtensionTabUtil::CreateTabObject(
          contents,
          {ExtensionTabUtil::kDontScrubTab, ExtensionTabUtil::kDontScrubTab},
          nullptr)
          .ToValue();
  base::DictValue state;
  for (const char* key : {"status", "url", "title", "favIconUrl"}) {
    if (const base::Value* value = tab.Find(key)) {
      state.Set(key, value->Clone());
    }
  }
  return state;
}

bool CanSee(ExtensionFunction* function, WindowBridge* window) {
  Profile* profile = Profile::FromBrowserContext(function->browser_context());
  return window->profile() == profile ||
         (function->include_incognito_information() &&
          profile->IsSameOrParent(window->profile()));
}

// The window of the calling tab or popup, else the focused or last focused
// window.
WindowBridge* CurrentWindow(ExtensionFunction* function) {
  WindowController* controller =
      function->dispatcher()
          ? function->dispatcher()->GetExtensionWindowController()
          : nullptr;
  content::WebContents* sender = function->GetSenderWebContents();
  for (WindowBridge* window : Windows()) {
    if (window == controller || (sender && window->Contains(sender))) {
      return window;
    }
  }
  for (WindowBridge* window : Windows()) {
    if (CanSee(function, window)) {
      return window;
    }
  }
  return nullptr;
}

WindowBridge* LastFocusedWindow(ExtensionFunction* function) {
  for (WindowBridge* window : Windows()) {
    if (CanSee(function, window)) {
      return window;
    }
  }
  return nullptr;
}

WindowBridge* WindowWithId(ExtensionFunction* function,
                           int window_id,
                           std::string* error) {
  if (window_id == extension_misc::kCurrentWindowId) {
    WindowBridge* window = CurrentWindow(function);
    if (!window) {
      *error = ExtensionTabUtil::kNoCurrentWindowError;
    }
    return window;
  }
  for (WindowBridge* window : Windows()) {
    if (window->GetWindowId() == window_id && CanSee(function, window)) {
      return window;
    }
  }
  *error = extensions::ErrorUtils::FormatErrorMessage(
      ExtensionTabUtil::kWindowNotFoundError, base::NumberToString(window_id));
  return nullptr;
}

content::WebContents* TabWithId(ExtensionFunction* function,
                                int tab_id,
                                std::string* error) {
  content::WebContents* contents = nullptr;
  if (!ExtensionTabUtil::GetTabById(tab_id, function->browser_context(),
                                    function->include_incognito_information(),
                                    &contents)) {
    *error = extensions::ErrorUtils::FormatErrorMessage(
        extensions::kTabNotFoundError, base::NumberToString(tab_id));
  }
  return contents;
}

constexpr char kNoTabOpenedError[] = "The window opened no tab.";

bool Matches(const std::optional<bool>& wanted, bool value) {
  return !wanted || *wanted == value;
}

class EngineTabsQueryFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.query", TABS_QUERY)

 private:
  ~EngineTabsQueryFunction() override = default;

  ResponseAction Run() override {
    std::optional<tabs::Query::Params> params =
        tabs::Query::Params::Create(args());
    EXTENSION_FUNCTION_VALIDATE(params);
    const tabs::Query::Params::QueryInfo& query = params->query_info;
    extensions::URLPatternSet patterns;
    if (query.url) {
      std::string error;
      if (!patterns.Populate(query.url->as_string
                                 ? std::vector{*query.url->as_string}
                                 : *query.url->as_strings,
                             URLPattern::SCHEME_ALL, true, &error)) {
        return RespondNow(Error(std::move(error)));
      }
    }
    WindowBridge* current = CurrentWindow(this);
    WindowBridge* last_focused = LastFocusedWindow(this);
    int window_id = query.window_id.value_or(extension_misc::kUnknownWindowId);
    base::ListValue result;
    for (WindowBridge* window : Windows()) {
      if (!CanSee(this, window) ||
          (window_id >= 0 && window_id != window->GetWindowId()) ||
          (window_id == extension_misc::kCurrentWindowId &&
           window != current) ||
          !Matches(query.current_window, window == current) ||
          !Matches(query.last_focused_window, window == last_focused) ||
          (query.window_type != tabs::WindowType::kNone &&
           query.window_type != tabs::WindowType::kNormal)) {
        continue;
      }
      for (int i = 0; i < window->GetTabCount(); ++i) {
        tabs::Tab tab = TabObject(window->GetWebContentsAt(i), extension(),
                                  source_context_type());
        auto url_matches = [&patterns](const std::optional<std::string>& url) {
          return url && patterns.MatchesURL(GURL(*url));
        };
        if ((query.index && *query.index != i) ||
            !Matches(query.active, tab.active) ||
            !Matches(query.highlighted, tab.highlighted) ||
            !Matches(query.pinned, tab.pinned) ||
            !Matches(query.audible, tab.audible.value_or(false)) ||
            !Matches(query.muted, tab.muted_info && tab.muted_info->muted) ||
            !Matches(query.discarded, tab.discarded) ||
            (query.group_id && *query.group_id != tab.group_id) ||
            (query.status != tabs::TabStatus::kNone &&
             query.status != tab.status) ||
            (query.title && !query.title->empty() &&
             !(tab.title && base::MatchPattern(*tab.title, *query.title))) ||
            (!patterns.is_empty() && !url_matches(tab.url) &&
             !url_matches(tab.pending_url))) {
          continue;
        }
        result.Append(tab.ToValue());
      }
    }
    return RespondNow(WithArguments(std::move(result)));
  }
};

class EngineTabsGetFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.get", TABS_GET)

 private:
  ~EngineTabsGetFunction() override = default;

  ResponseAction Run() override {
    std::optional<tabs::Get::Params> params = tabs::Get::Params::Create(args());
    EXTENSION_FUNCTION_VALIDATE(params);
    std::string error;
    content::WebContents* contents = TabWithId(this, params->tab_id, &error);
    if (!contents) {
      return RespondNow(Error(std::move(error)));
    }
    return RespondNow(WithArguments(
        TabObject(contents, extension(), source_context_type()).ToValue()));
  }
};

class EngineTabsGetCurrentFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.getCurrent", TABS_GETCURRENT)

 private:
  ~EngineTabsGetCurrentFunction() override = default;

  // Nothing unless called from a tab.
  ResponseAction Run() override {
    content::WebContents* sender = GetSenderWebContents();
    if (!sender || ![ECWebContents fromContents:sender].window) {
      return RespondNow(NoArguments());
    }
    return RespondNow(WithArguments(
        TabObject(sender, extension(), source_context_type()).ToValue()));
  }
};

class EngineTabsCreateFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.create", TABS_CREATE)

 private:
  ~EngineTabsCreateFunction() override = default;

  ResponseAction Run() override {
    std::optional<tabs::Create::Params> params =
        tabs::Create::Params::Create(args());
    EXTENSION_FUNCTION_VALIDATE(params);
    const tabs::Create::Params::CreateProperties& properties =
        params->create_properties;
    std::string error;
    WindowBridge* window = WindowWithId(
        this, properties.window_id.value_or(extension_misc::kCurrentWindowId),
        &error);
    if (!window) {
      return RespondNow(Error(std::move(error)));
    }
    GURL url(chrome::kChromeUINewTabURL);
    if (properties.url) {
      base::expected<GURL, std::string> prepared =
          ExtensionTabUtil::PrepareURLForNavigation(
              *properties.url, extension(), browser_context());
      if (!prepared.has_value()) {
        return RespondNow(Error(prepared.error()));
      }
      url = *prepared;
    }
    ECWebContents* tab = [window->owner().delegate
                window:window->owner()
        openTabWithURL:net::NSURLWithGURL(url)
                active:properties.active.value_or(
                           properties.selected.value_or(true))];
    if (!tab) {
      return RespondNow(Error(kNoTabOpenedError));
    }
    return RespondNow(WithArguments(
        TabObject(tab.contents, extension(), source_context_type())
            .ToValue()));
  }
};

class EngineTabsUpdateFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.update", TABS_UPDATE)

 private:
  ~EngineTabsUpdateFunction() override = default;

  // Navigates and activates the tab, by default the current window's active
  // one.
  ResponseAction Run() override {
    std::optional<tabs::Update::Params> params =
        tabs::Update::Params::Create(args());
    EXTENSION_FUNCTION_VALIDATE(params);
    std::string error = extensions::tabs_constants::kNoSelectedTabError;
    content::WebContents* contents = nullptr;
    if (params->tab_id) {
      contents = TabWithId(this, *params->tab_id, &error);
    } else if (WindowBridge* window = CurrentWindow(this)) {
      contents = window->GetActiveTab();
    }
    if (!contents) {
      return RespondNow(Error(std::move(error)));
    }
    const tabs::Update::Params::UpdateProperties& properties =
        params->update_properties;
    if (properties.url) {
      base::expected<GURL, std::string> url =
          ExtensionTabUtil::PrepareURLForNavigation(
              *properties.url, extension(), browser_context());
      if (!url.has_value()) {
        return RespondNow(Error(url.error()));
      }
      contents->GetController().LoadURL(*url, content::Referrer(),
                                        ui::PAGE_TRANSITION_FROM_API,
                                        std::string());
    }
    ECWebContents* tab = [ECWebContents fromContents:contents];
    if (properties.active.value_or(false) ||
        properties.highlighted.value_or(false)) {
      [tab.window.delegate window:tab.window activateTab:tab];
    }
    return RespondNow(WithArguments(
        TabObject(contents, extension(), source_context_type()).ToValue()));
  }
};

class EngineTabsRemoveFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.remove", TABS_REMOVE)

 private:
  ~EngineTabsRemoveFunction() override = default;

  ResponseAction Run() override {
    std::optional<tabs::Remove::Params> params =
        tabs::Remove::Params::Create(args());
    EXTENSION_FUNCTION_VALIDATE(params);
    std::vector<int> tab_ids = params->tab_ids.as_integer
                                   ? std::vector{*params->tab_ids.as_integer}
                                   : *params->tab_ids.as_integers;
    for (int tab_id : tab_ids) {
      std::string error;
      content::WebContents* contents = TabWithId(this, tab_id, &error);
      if (!contents) {
        return RespondNow(Error(std::move(error)));
      }
      ECWebContents* tab = [ECWebContents fromContents:contents];
      [tab.window.delegate window:tab.window closeTab:tab];
    }
    return RespondNow(NoArguments());
  }
};

template <typename Params>
WindowController::PopulateTabBehavior Populate(const Params& params) {
  return params.query_options && params.query_options->populate.value_or(false)
             ? WindowController::kPopulateTabs
             : WindowController::kDontPopulateTabs;
}

class EngineWindowsGetCurrentFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("windows.getCurrent", WINDOWS_GETCURRENT)

 private:
  ~EngineWindowsGetCurrentFunction() override = default;

  ResponseAction Run() override {
    std::optional<windows::GetCurrent::Params> params =
        windows::GetCurrent::Params::Create(args());
    EXTENSION_FUNCTION_VALIDATE(params);
    WindowBridge* window = CurrentWindow(this);
    if (!window) {
      return RespondNow(Error(ExtensionTabUtil::kNoCurrentWindowError));
    }
    return RespondNow(WithArguments(window->CreateWindowValueForExtension(
        extension(), Populate(*params), source_context_type())));
  }
};

class EngineWindowsGetLastFocusedFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("windows.getLastFocused", WINDOWS_GETLASTFOCUSED)

 private:
  ~EngineWindowsGetLastFocusedFunction() override = default;

  ResponseAction Run() override {
    std::optional<windows::GetLastFocused::Params> params =
        windows::GetLastFocused::Params::Create(args());
    EXTENSION_FUNCTION_VALIDATE(params);
    WindowBridge* window = LastFocusedWindow(this);
    if (!window) {
      return RespondNow(
          Error(extensions::tabs_constants::kNoLastFocusedWindowError));
    }
    return RespondNow(WithArguments(window->CreateWindowValueForExtension(
        extension(), Populate(*params), source_context_type())));
  }
};

class EngineWindowsGetAllFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("windows.getAll", WINDOWS_GETALL)

 private:
  ~EngineWindowsGetAllFunction() override = default;

  ResponseAction Run() override {
    std::optional<windows::GetAll::Params> params =
        windows::GetAll::Params::Create(args());
    EXTENSION_FUNCTION_VALIDATE(params);
    base::ListValue result;
    for (WindowBridge* window : Windows()) {
      if (CanSee(this, window)) {
        result.Append(window->CreateWindowValueForExtension(
            extension(), Populate(*params), source_context_type()));
      }
    }
    return RespondNow(WithArguments(std::move(result)));
  }
};

}  // namespace

void RegisterWindowFunctions() {
  ExtensionFunctionRegistry& registry = ExtensionFunctionRegistry::GetInstance();
  registry.RegisterFunction<EngineTabsQueryFunction>();
  registry.RegisterFunction<EngineTabsGetFunction>();
  registry.RegisterFunction<EngineTabsGetCurrentFunction>();
  registry.RegisterFunction<EngineTabsCreateFunction>();
  registry.RegisterFunction<EngineTabsUpdateFunction>();
  registry.RegisterFunction<EngineTabsRemoveFunction>();
  registry.RegisterFunction<EngineWindowsGetCurrentFunction>();
  registry.RegisterFunction<EngineWindowsGetLastFocusedFunction>();
  registry.RegisterFunction<EngineWindowsGetAllFunction>();
}

@implementation ECWindow {
  std::unique_ptr<WindowBridge> _bridge;
  NSArray<ECWebContents*>* _tabs;
  // What tabs.onUpdated last reported of each tab.
  std::map<content::WebContents*, base::DictValue> _states;
}

@synthesize delegate = _delegate;
@synthesize activeTab = _activeTab;
@synthesize focused = _focused;

- (instancetype)initWithBrowserContext:(ECBrowserContext*)context {
  if ((self = [super init])) {
    _tabs = @[];
    _bridge = std::make_unique<WindowBridge>(self, context.profile);
  }
  return self;
}

- (WindowController*)controller {
  return _bridge.get();
}

- (NSArray<ECWebContents*>*)tabs {
  return _tabs;
}

// A closed web contents is left out.
- (void)setTabs:(NSArray<ECWebContents*>*)tabs {
  NSArray<ECWebContents*>* old = _tabs;
  _tabs = [tabs filteredArrayUsingPredicate:
                    [NSPredicate predicateWithBlock:^BOOL(ECWebContents* tab,
                                                          NSDictionary*) {
                      return tab.contents != nullptr;
                    }]];
  for (ECWebContents* tab in old) {
    if (![_tabs containsObject:tab]) {
      [self removeTab:tab windowClosing:NO];
    }
  }
  for (ECWebContents* tab in _tabs) {
    if (![old containsObject:tab]) {
      [self addTab:tab];
    }
  }
}

// A tab moved from another window keeps its tab id and is not reported as
// created.
- (void)addTab:(ECWebContents*)tab {
  BOOL moved = tab.window != nil;
  tab.window = self;
  content::WebContents* contents = tab.contents;
  sessions::SessionTabHelper::FromWebContents(contents)->SetWindowID(
      _bridge->session_id());
  _states[contents] = TabState(contents);
  if (!moved) {
    DispatchEvent(ProfileOf(contents), extensions::events::TABS_ON_CREATED,
                  tabs::OnCreated::kEventName, base::ListValue(),
                  base::BindRepeating(&WillDispatchTabEvent,
                                      contents->GetWeakPtr(), std::nullopt));
  }
}

- (void)removeTab:(ECWebContents*)tab windowClosing:(BOOL)windowClosing {
  if (tab.window != self) {
    return;
  }
  tab.window = nil;
  if (_activeTab == tab) {
    _activeTab = nil;
  }
  content::WebContents* contents = tab.contents;
  _states.erase(contents);
  tabs::OnRemoved::RemoveInfo info;
  info.window_id = _bridge->GetWindowId();
  info.is_window_closing = windowClosing;
  DispatchEvent(ProfileOf(contents), extensions::events::TABS_ON_REMOVED,
                tabs::OnRemoved::kEventName,
                tabs::OnRemoved::Create(ExtensionTabUtil::GetTabId(contents),
                                        info));
}

- (void)setActiveTab:(ECWebContents*)tab {
  if (_activeTab == tab) {
    return;
  }
  _activeTab = tab;
  if (!tab.contents) {
    return;
  }
  tabs::OnActivated::ActiveInfo info;
  info.tab_id = ExtensionTabUtil::GetTabId(tab.contents);
  info.window_id = _bridge->GetWindowId();
  DispatchEvent(ProfileOf(tab.contents), extensions::events::TABS_ON_ACTIVATED,
                tabs::OnActivated::kEventName,
                tabs::OnActivated::Create(info));
}

- (void)setFocused:(BOOL)focused {
  _focused = focused;
  if (focused) {
    std::erase(Windows(), _bridge.get());
    Windows().insert(Windows().begin(), _bridge.get());
  }
  _bridge->NotifyWindowFocusChanged(focused);
}

- (void)tabDidUpdate:(ECWebContents*)tab {
  content::WebContents* contents = tab.contents;
  base::DictValue state = TabState(contents);
  base::DictValue& last = _states[contents];
  std::vector<std::string> changed;
  for (const auto [key, value] : state) {
    if (const base::Value* old = last.Find(key); !old || *old != value) {
      changed.push_back(key);
    }
  }
  last = std::move(state);
  if (!changed.empty()) {
    DispatchEvent(ProfileOf(contents), extensions::events::TABS_ON_UPDATED,
                  tabs::OnUpdated::kEventName, base::ListValue(),
                  base::BindRepeating(&WillDispatchTabEvent,
                                      contents->GetWeakPtr(),
                                      std::move(changed)));
  }
}

- (void)tabWillClose:(ECWebContents*)tab {
  NSMutableArray<ECWebContents*>* tabs = [_tabs mutableCopy];
  [tabs removeObject:tab];
  _tabs = tabs;
  [self removeTab:tab windowClosing:NO];
}

- (void)close {
  for (ECWebContents* tab in _tabs) {
    [self removeTab:tab windowClosing:YES];
  }
  _tabs = @[];
  _bridge.reset();
}

@end
