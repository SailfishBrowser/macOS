#import "engine_core/ec_web_contents_private.h"

#include <algorithm>
#include <memory>
#include <variant>
#include <vector>

#include "base/apple/foundation_util.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/pickle.h"
#include "base/strings/sys_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/task/bind_post_task.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/i18n/rtl.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/chrome_content_browser_client_navigation_throttles.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/devtools/devtools_toggle_action.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/file_select_helper.h"
#include "chrome/browser/history/history_tab_helper.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "chrome/browser/printing/print_view_manager_common.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ssl/chrome_security_state_util.h"
#include "chrome/browser/translate/chrome_translate_client.h"
#include "chrome/browser/ui/tab_helpers.h"
#include "chrome/browser/ui/views/overlay/video_overlay_window_views.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "components/content_settings/core/browser/content_settings_registry.h"
#include "components/content_settings/core/common/content_settings_pattern.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/download/public/common/download_url_parameters.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_types.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/permissions/permission_prompt.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_request_manager.h"
#include "components/permissions/permission_uma_constants.h"
#include "components/permissions/permission_util.h"
#include "components/permissions/request_type.h"
#include "components/security_state/core/security_state.h"
#include "components/sessions/content/content_serialized_navigation_builder.h"
#include "components/sessions/core/serialized_navigation_entry.h"
#include "components/shared_highlighting/core/common/fragment_directives_utils.h"
#include "components/shared_highlighting/core/common/shared_highlighting_metrics.h"
#include "components/translate/core/browser/translate_manager.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "components/zoom/page_zoom.h"
#include "components/zoom/zoom_controller.h"
#include "components/zoom/zoom_observer.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/file_select_listener.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/reload_type.h"
#include "content/public/browser/picture_in_picture_window_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/restore_type.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"
#import "engine_core/ec_browser_context_private.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/apple/url_conversions.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "net/http/http_request_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/data_element.h"
#include "services/network/public/cpp/resource_request_body.h"
#include "services/service_manager/public/cpp/interface_provider.h"
#include "skia/ext/skia_utils_mac.h"
#include "third_party/blink/public/common/context_menu_data/context_menu_data.h"
#include "third_party/blink/public/common/input/web_input_event.h"
#include "third_party/blink/public/mojom/choosers/file_chooser.mojom.h"
#include "third_party/blink/public/mojom/context_menu/context_menu.mojom-shared.h"
#include "third_party/blink/public/mojom/link_to_text/link_to_text.mojom.h"
#include "third_party/blink/public/mojom/loader/referrer.mojom.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"

@interface ECContextMenu ()
- (instancetype)initWithFrame:(content::RenderFrameHost&)frame
                       params:(const content::ContextMenuParams&)params;
@end

@interface ECWebContents ()
// Asks the delegate for a new window, with the modifier keys of the click or
// key press behind the request when it came from one.
- (void)requestNewWindowWithURL:(const GURL&)url
                    disposition:(WindowOpenDisposition)disposition
                    userGesture:(BOOL)userGesture;
@end

// A friend of TabHelpers (patches/0003).
class EngineCoreTabHelpers {
 public:
  static void Attach(content::WebContents* contents) {
    TabHelpers::AttachTabHelpers(contents);
  }
};

namespace {

// The sessionState format, and how much of an entry is kept (Chrome's
// session commands keep less; page state past it is cut).
constexpr int kSessionStateVersion = 1;
constexpr int kSessionEntryMaxSize = 1 << 20;

// The content settings of permissions the user set for the URL's site.
NSDictionary<NSString*, NSNumber*>* SitePermissions(Profile* profile,
                                                     const GURL& url) {
  NSMutableDictionary<NSString*, NSNumber*>* permissions =
      [NSMutableDictionary dictionary];
  HostContentSettingsMap* map =
      HostContentSettingsMapFactory::GetForProfile(profile);
  for (const content_settings::ContentSettingsInfo* info :
       *content_settings::ContentSettingsRegistry::GetInstance()) {
    ContentSettingsType type = info->website_settings_info()->type();
    std::optional<permissions::RequestType> request =
        permissions::ContentSettingsTypeToRequestTypeIfExists(type);
    if (!request || !permissions::PermissionUtil::IsPermission(type)) {
      continue;
    }
    content_settings::SettingInfo setting_info;
    ContentSetting setting =
        map->GetContentSetting(url, url, type, &setting_info);
    bool decided =
        setting == CONTENT_SETTING_ALLOW || setting == CONTENT_SETTING_BLOCK;
    if (setting_info.source != content_settings::SettingSource::kUser ||
        setting_info.primary_pattern == ContentSettingsPattern::Wildcard() ||
        !decided) {
      continue;
    }
    permissions[@(permissions::PermissionKeyForRequestType(*request))] =
        @(setting == CONTENT_SETTING_ALLOW);
  }
  return permissions;
}

void SetSitePermission(Profile* profile,
                       const GURL& url,
                       NSString* permission,
                       BOOL allowed) {
  for (const content_settings::ContentSettingsInfo* info :
       *content_settings::ContentSettingsRegistry::GetInstance()) {
    ContentSettingsType type = info->website_settings_info()->type();
    std::optional<permissions::RequestType> request =
        permissions::ContentSettingsTypeToRequestTypeIfExists(type);
    if (request &&
        std::string_view(permission.UTF8String) ==
            permissions::PermissionKeyForRequestType(*request)) {
      HostContentSettingsMapFactory::GetForProfile(profile)
          ->SetContentSettingDefaultScope(
              url, url, type,
              allowed ? CONTENT_SETTING_ALLOW : CONTENT_SETTING_BLOCK);
      return;
    }
  }
}

// Asks the shell instead of showing Chrome's permission bubble.
class PermissionPromptBridge : public permissions::PermissionPrompt {
 public:
  PermissionPromptBridge(ECWebContents* owner, Delegate* delegate)
      : delegate_(delegate) {
    NSMutableArray<NSString*>* permissions = [NSMutableArray array];
    for (const auto& request : delegate->Requests()) {
      [permissions addObject:@(permissions::PermissionKeyForRequestType(
                                 request->request_type()))];
    }
    base::WeakPtr<PermissionPromptBridge> weak = weak_factory_.GetWeakPtr();
    [owner.delegate webContents:owner
            requestsPermissions:permissions
                      forOrigin:net::NSURLWithGURL(
                                    delegate->GetRequestingOrigin())
              completionHandler:^(BOOL allow) {
                // Deciding destroys the prompt, which may not be shown yet.
                base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
                    FROM_HERE, base::BindOnce(&PermissionPromptBridge::Decide,
                                              weak, allow));
              }];
  }

  bool UpdateAnchor() override { return true; }
  TabSwitchingBehavior GetTabSwitchingBehavior() override {
    return kKeepPromptAlive;
  }
  permissions::PermissionPromptDisposition GetPromptDisposition()
      const override {
    return permissions::PermissionPromptDisposition::CUSTOM_MODAL_DIALOG;
  }
  bool IsAskPrompt() const override { return true; }
  std::optional<gfx::Rect> GetViewBoundsInScreen() const override {
    return std::nullopt;
  }
  std::vector<permissions::ElementAnchoredBubbleVariant> GetPromptVariants()
      const override {
    return {};
  }
  std::optional<permissions::feature_params::PermissionElementPromptPosition>
  GetPromptPosition() const override {
    return std::nullopt;
  }

 private:
  void Decide(bool allow) {
    allow ? delegate_->Accept(std::monostate())
          : delegate_->Deny(std::monostate());
  }

  raw_ptr<Delegate> delegate_;
  base::WeakPtrFactory<PermissionPromptBridge> weak_factory_{this};
};

class WebContentsDelegateBridge : public content::WebContentsDelegate,
                                  public content::JavaScriptDialogManager,
                                  public content::WebContentsObserver,
                                  public zoom::ZoomObserver {
 public:
  explicit WebContentsDelegateBridge(ECWebContents* owner) : owner_(owner) {}

  using content::WebContentsObserver::Observe;

  void OnZoomChanged(
      const zoom::ZoomController::ZoomChangedEventData& data) override {
    if ([owner_.delegate
            respondsToSelector:@selector(webContentsDidChangeZoom:)]) {
      [owner_.delegate webContentsDidChangeZoom:owner_];
    }
  }

  void OnZoomControllerDestroyed(zoom::ZoomController* controller) override {
    controller->RemoveObserver(this);
  }

  void OnTextSelectionChanged(content::RenderFrameHost* render_frame_host,
                              std::u16string_view selected_text) override {
    if ([owner_.delegate respondsToSelector:@selector
                         (webContents:didChangeSelection:)]) {
      [owner_.delegate webContents:owner_
                didChangeSelection:base::SysUTF16ToNSString(selected_text)];
    }
  }

  void UpdateTargetURL(content::WebContents* source, const GURL& url) override {
    if ([owner_.delegate respondsToSelector:@selector
                         (webContents:didUpdateTargetURL:)]) {
      [owner_.delegate webContents:owner_
                didUpdateTargetURL:url.is_empty() ? nil
                                                  : net::NSURLWithGURL(url)];
    }
  }

  std::unique_ptr<permissions::PermissionPrompt> CreatePermissionPrompt(
      content::WebContents* contents,
      permissions::PermissionPrompt::Delegate* delegate) {
    if (![owner_.delegate
            respondsToSelector:@selector
            (webContents:requestsPermissions:forOrigin:completionHandler:)]) {
      return nullptr;
    }
    return std::make_unique<PermissionPromptBridge>(owner_, delegate);
  }

  void NavigationStateChanged(content::WebContents* source,
                              content::InvalidateTypes changed_flags) override {
    [owner_.delegate webContentsDidUpdate:owner_];
    [owner_.window tabDidUpdate:owner_];
  }

  // Reported once the call returns, as the shell closes the web contents.
  void CloseContents(content::WebContents* source) override {
    if (![owner_.delegate
            respondsToSelector:@selector(webContentsDidRequestClose:)]) {
      return;
    }
    __weak ECWebContents* owner = owner_;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(^{
          [owner.delegate webContentsDidRequestClose:owner];
        }));
  }

  void ActivateContents(content::WebContents* contents) override {
    if ([owner_.delegate
            respondsToSelector:@selector(webContentsDidRequestActivation:)]) {
      [owner_.delegate webContentsDidRequestActivation:owner_];
    }
  }

  // As Chrome's browser windows do; without these the page cannot enter it.
  content::PictureInPictureResult EnterPictureInPicture(
      content::WebContents* web_contents) override {
    return PictureInPictureWindowManager::GetInstance()
        ->EnterVideoPictureInPicture(web_contents);
  }

  void ExitPictureInPicture() override {
    PictureInPictureWindowManager::GetInstance()->ExitPictureInPicture();
  }

  void MediaStartedPlaying(const MediaPlayerInfo& video_type,
                           const content::MediaPlayerId& id) override {
    ReportMediaChange();
  }

  void MediaStoppedPlaying(const MediaPlayerInfo& video_type,
                           const content::MediaPlayerId& id,
                           MediaStoppedReason reason) override {
    ReportMediaChange();
  }

  void MediaDestroyed(const content::MediaPlayerId& id) override {
    ReportMediaChange();
  }

  void MediaPictureInPictureChanged(bool is_picture_in_picture) override {
    ReportMediaChange();
  }

  // Reported once the call returns, as the media session updates after
  // these.
  void ReportMediaChange() {
    __weak ECWebContents* owner = owner_;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(^{
          if (owner.contents) {
            [owner.delegate webContentsDidUpdate:owner];
          }
        }));
  }

  void LoadingStateChanged(content::WebContents* source,
                           bool should_show_loading_ui) override {
    [owner_.delegate webContentsDidUpdate:owner_];
    [owner_.window tabDidUpdate:owner_];
  }

  void LoadProgressChanged(double progress) override {
    if ([owner_.delegate respondsToSelector:@selector
                         (webContents:didChangeLoadProgress:)]) {
      [owner_.delegate webContents:owner_ didChangeLoadProgress:progress];
    }
  }

  // The modifier keys held at the last click or key press in the page, which
  // a link it opens follows (kRawKeyDown is the key press; kKeyDown is not
  // reported here).
  void DidGetUserInteraction(const blink::WebInputEvent& event) override {
    using Type = blink::WebInputEvent::Type;
    Type type = event.GetType();
    if (type != Type::kMouseDown && type != Type::kRawKeyDown) {
      return;
    }
    int modifiers = event.GetModifiers();
    last_interaction_ = base::TimeTicks::Now();
    last_modifier_flags_ = 0;
    if (modifiers & blink::WebInputEvent::kShiftKey) {
      last_modifier_flags_ |= NSEventModifierFlagShift;
    }
    if (modifiers & blink::WebInputEvent::kControlKey) {
      last_modifier_flags_ |= NSEventModifierFlagControl;
    }
    if (modifiers & blink::WebInputEvent::kAltKey) {
      last_modifier_flags_ |= NSEventModifierFlagOption;
    }
    if (modifiers & blink::WebInputEvent::kMetaKey) {
      last_modifier_flags_ |= NSEventModifierFlagCommand;
    }
  }

  // The flags of the last click or key press if it was within the last
  // second, so a request long after it (a script's window.open() during the
  // activation window) reports none.
  NSEventModifierFlags recent_modifier_flags() const {
    return base::TimeTicks::Now() - last_interaction_ <= base::Seconds(1)
               ? last_modifier_flags_
               : 0;
  }

  // Gives the shell's main menu the shortcuts the page did not handle.
  bool HandleKeyboardEvent(content::WebContents* source,
                           const input::NativeWebKeyboardEvent& event) override {
    return event.GetType() == blink::WebInputEvent::Type::kRawKeyDown &&
           [NSApp.mainMenu performKeyEquivalent:event.os_event.Get()];
  }

  content::WebContents* OpenURLFromTab(
      content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)>
          navigation_handle_callback) override {
    if (params.disposition != WindowOpenDisposition::CURRENT_TAB) {
      [owner_ requestNewWindowWithURL:params.url
                          disposition:params.disposition
                          userGesture:params.user_gesture];
      return nullptr;
    }
    base::WeakPtr<content::NavigationHandle> handle =
        source->GetController().LoadURLWithParams(
            content::NavigationController::LoadURLParams(params));
    if (handle && navigation_handle_callback) {
      std::move(navigation_handle_callback).Run(*handle);
    }
    return source;
  }

  bool IsWebContentsCreationOverridden(
      content::RenderFrameHost* opener,
      content::SiteInstance* source_site_instance,
      content::mojom::WindowContainerType window_container_type,
      const GURL& opener_url,
      const std::string& frame_name,
      const GURL& target_url) override {
    return true;
  }

  content::WebContents* CreateCustomWebContents(
      content::RenderFrameHost* opener,
      content::SiteInstance* source_site_instance,
      bool is_new_browsing_instance,
      const GURL& opener_url,
      const std::string& frame_name,
      const GURL& target_url,
      WindowOpenDisposition disposition,
      const blink::mojom::WindowFeatures& window_features,
      const content::StoragePartitionConfig& partition_config,
      content::SessionStorageNamespaceHandle* session_storage_namespace)
      override {
    [owner_ requestNewWindowWithURL:target_url
                        disposition:disposition
                        userGesture:opener && opener->HasTransientUserActivation()];
    return nullptr;
  }

  content::JavaScriptDialogManager* GetJavaScriptDialogManager(
      content::WebContents* source) override {
    return [owner_.delegate
               respondsToSelector:@selector
               (webContents:runJavaScriptDialog:message:defaultText:
                   completionHandler:)]
               ? this
               : nullptr;
  }

  // ECJavaScriptDialogType matches content::JavaScriptDialogType.
  void RunJavaScriptDialog(content::WebContents* web_contents,
                           content::RenderFrameHost* render_frame_host,
                           content::JavaScriptDialogType dialog_type,
                           const std::u16string& message_text,
                           const std::u16string& default_prompt_text,
                           DialogClosedCallback callback,
                           bool* did_suppress_message) override {
    RunDialog(static_cast<ECJavaScriptDialogType>(dialog_type), message_text,
              default_prompt_text, std::move(callback));
  }

  void RunBeforeUnloadDialog(content::WebContents* web_contents,
                             content::RenderFrameHost* render_frame_host,
                             bool is_reload,
                             DialogClosedCallback callback) override {
    RunDialog(ECJavaScriptDialogTypeBeforeUnload, std::u16string(),
              std::u16string(), std::move(callback));
  }

  void CancelDialogs(content::WebContents* web_contents,
                     bool reset_state) override {
    if (dialog_callback_ && *dialog_callback_) {
      std::move(*dialog_callback_).Run(false, std::u16string());
    }
  }

  void RunFileChooser(content::RenderFrameHost* render_frame_host,
                      scoped_refptr<content::FileSelectListener> listener,
                      const blink::mojom::FileChooserParams& params) override {
    using Mode = blink::mojom::FileChooserParams::Mode;
    if (![owner_.delegate
            respondsToSelector:@selector
            (webContents:runFileChooserWithAcceptTypes:allowsMultiple:
                directory:completionHandler:)]) {
      listener->FileSelectionCanceled();
      return;
    }
    NSMutableArray<NSString*>* acceptTypes = [NSMutableArray array];
    for (const std::u16string& type : params.accept_types) {
      [acceptTypes addObject:base::SysUTF16ToNSString(type)];
    }
    Mode mode = params.mode;
    base::WeakPtr<content::WebContents> contents =
        content::WebContents::FromRenderFrameHost(render_frame_host)
            ->GetWeakPtr();
    [owner_.delegate webContents:owner_
        runFileChooserWithAcceptTypes:acceptTypes
                       allowsMultiple:mode == Mode::kOpenMultiple
                            directory:mode == Mode::kUploadFolder
                    completionHandler:^(NSArray<NSURL*>* fileURLs) {
                      if (!fileURLs.count || !contents) {
                        listener->FileSelectionCanceled();
                        return;
                      }
                      if (mode == Mode::kUploadFolder) {
                        FileSelectHelper::EnumerateDirectory(
                            contents.get(), listener,
                            base::apple::NSURLToFilePath(fileURLs[0]));
                        return;
                      }
                      std::vector<blink::mojom::FileChooserFileInfoPtr> files;
                      for (NSURL* url in fileURLs) {
                        files.push_back(
                            blink::mojom::FileChooserFileInfo::NewNativeFile(
                                blink::mojom::NativeFileInfo::New(
                                    base::apple::NSURLToFilePath(url),
                                    std::u16string(),
                                    std::vector<std::u16string>())));
                      }
                      listener->FileSelected(std::move(files),
                                             base::FilePath(), mode);
                    }];
  }

  void FindReply(content::WebContents* source,
                 int request_id,
                 int number_of_matches,
                 const gfx::Rect& selection_rect,
                 int active_match_ordinal,
                 bool final_update) override {
    find_in_page::FindTabHelper* helper =
        find_in_page::FindTabHelper::FromWebContents(source);
    helper->HandleFindReply(request_id, number_of_matches, selection_rect,
                            active_match_ordinal, final_update);
    if ([owner_.delegate respondsToSelector:@selector
                         (webContents:didFindMatches:activeMatch:)]) {
      const find_in_page::FindNotificationDetails& result =
          helper->find_result();
      [owner_.delegate webContents:owner_
                    didFindMatches:result.number_of_matches()
                       activeMatch:std::max(0, result.active_match_ordinal())];
    }
  }

  bool HandleContextMenu(content::RenderFrameHost& render_frame_host,
                         const content::ContextMenuParams& params) override {
    if (![owner_.delegate
            respondsToSelector:@selector(webContents:showContextMenu:)]) {
      return false;
    }
    [owner_.delegate
            webContents:owner_
        showContextMenu:[[ECContextMenu alloc] initWithFrame:render_frame_host
                                                      params:params]];
    return true;
  }

 private:
  void RunDialog(ECJavaScriptDialogType type,
                 const std::u16string& message,
                 const std::u16string& default_text,
                 DialogClosedCallback callback) {
    // Shared with the completion handler, which CancelDialogs() may preempt.
    auto shared = std::make_shared<DialogClosedCallback>(std::move(callback));
    dialog_callback_ = shared;
    [owner_.delegate webContents:owner_
             runJavaScriptDialog:type
                         message:base::SysUTF16ToNSString(message)
                     defaultText:base::SysUTF16ToNSString(default_text)
               completionHandler:^(BOOL accepted, NSString* text) {
                 if (*shared) {
                   std::move(*shared).Run(accepted,
                                          base::SysNSStringToUTF16(text));
                 }
               }];
  }

  std::shared_ptr<DialogClosedCallback> dialog_callback_;
  NSEventModifierFlags last_modifier_flags_ = 0;
  base::TimeTicks last_interaction_;
  __weak ECWebContents* owner_;
};

// Finds the ECWebContents of a web contents.
class Owner : public base::SupportsUserData::Data {
 public:
  static constexpr char kKey[] = "ECWebContents";
  explicit Owner(ECWebContents* owner) : owner_(owner) {}
  __weak ECWebContents* owner_;
};

// Asks for a new window instead of following a link to another site, for
// tabs with opensLinksToOtherSitesInNewWindow.
class OtherSiteLinkThrottle : public content::NavigationThrottle {
 public:
  using content::NavigationThrottle::NavigationThrottle;

  static void MaybeCreateAndAdd(content::NavigationThrottleRegistry& registry) {
    content::NavigationHandle& handle = registry.GetNavigationHandle();
    ECWebContents* owner = [ECWebContents fromContents:handle.GetWebContents()];
    const GURL& from = handle.GetWebContents()->GetLastCommittedURL();
    if (owner.opensLinksToOtherSitesInNewWindow &&
        handle.IsInPrimaryMainFrame() && handle.IsRendererInitiated() &&
        handle.HasUserGesture() &&
        ui::PageTransitionCoreTypeIs(handle.GetPageTransition(),
                                     ui::PAGE_TRANSITION_LINK) &&
        from.SchemeIsHTTPOrHTTPS() && handle.GetURL().SchemeIsHTTPOrHTTPS() &&
        !net::registry_controlled_domains::SameDomainOrHost(
            from, handle.GetURL(),
            net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES)) {
      registry.AddThrottle(std::make_unique<OtherSiteLinkThrottle>(registry));
    }
  }

  ThrottleCheckResult WillStartRequest() override {
    ECWebContents* owner =
        [ECWebContents fromContents:navigation_handle()->GetWebContents()];
    [owner requestNewWindowWithURL:navigation_handle()->GetURL()
                       disposition:WindowOpenDisposition::NEW_WINDOW
                       userGesture:navigation_handle()->HasUserGesture()];
    return CANCEL_AND_IGNORE;
  }

  const char* GetNameForLogging() override { return "OtherSiteLinkThrottle"; }
};

// Asks the shell whether a navigation the user started should be made
// elsewhere, before its request leaves, and cancels it if so. Redirects are
// not asked about.
class HandoffThrottle : public content::NavigationThrottle {
 public:
  using content::NavigationThrottle::NavigationThrottle;

  static void MaybeCreateAndAdd(content::NavigationThrottleRegistry& registry) {
    content::NavigationHandle& handle = registry.GetNavigationHandle();
    ECWebContents* owner = [ECWebContents fromContents:handle.GetWebContents()];
    bool user_started =
        (!handle.IsRendererInitiated() || handle.HasUserGesture()) &&
        handle.GetReloadType() == content::ReloadType::NONE &&
        !handle.IsHistory() &&
        handle.GetRestoreType() == content::RestoreType::kNotRestored;
    if ([owner.delegate respondsToSelector:@selector
                        (webContents:shouldHandOffNavigation:)] &&
        handle.IsInPrimaryMainFrame() && !handle.IsSameDocument() &&
        handle.GetURL().SchemeIsHTTPOrHTTPS() && user_started) {
      registry.AddThrottle(std::make_unique<HandoffThrottle>(registry));
    }
  }

  ThrottleCheckResult WillStartRequest() override {
    content::NavigationHandle* handle = navigation_handle();
    ECWebContents* owner = [ECWebContents fromContents:handle->GetWebContents()];
    NSMutableURLRequest* request =
        [NSMutableURLRequest requestWithURL:net::NSURLWithGURL(handle->GetURL())];
    if (handle->IsPost()) {
      request.HTTPMethod = @"POST";
      NSMutableData* body = [NSMutableData data];
      if (scoped_refptr<network::ResourceRequestBody> post =
              handle->GetPostData()) {
        for (const network::DataElement& element : *post->elements()) {
          if (const auto* bytes =
                  element.TryAs<network::DataElementBytes>()) {
            [body appendBytes:bytes->bytes().data()
                       length:bytes->bytes().size()];
          }
        }
      }
      request.HTTPBody = body;
      if (std::optional<std::string> type =
              handle->GetRequestHeaders().GetHeader(
                  net::HttpRequestHeaders::kContentType)) {
        [request setValue:base::SysUTF8ToNSString(*type)
            forHTTPHeaderField:@"Content-Type"];
      }
    }
    const GURL& referrer = handle->GetReferrer().url;
    if (referrer.is_valid()) {
      [request setValue:base::SysUTF8ToNSString(referrer.spec())
          forHTTPHeaderField:@"Referer"];
    }
    return [owner.delegate webContents:owner shouldHandOffNavigation:request]
               ? CANCEL_AND_IGNORE
               : PROCEED;
  }

  const char* GetNameForLogging() override { return "HandoffThrottle"; }
};

// The other-site throttle comes first, so Peek keeps priority.
void AddNavigationThrottles(content::NavigationThrottleRegistry& registry) {
  OtherSiteLinkThrottle::MaybeCreateAndAdd(registry);
  HandoffThrottle::MaybeCreateAndAdd(registry);
}

}  // namespace

@implementation ECContextMenu {
  content::GlobalRenderFrameHostId _frame;
  std::unique_ptr<content::ContextMenuParams> _menuParams;
}

- (instancetype)initWithFrame:(content::RenderFrameHost&)frame
                       params:(const content::ContextMenuParams&)params {
  if ((self = [super init])) {
    _frame = frame.GetGlobalId();
    _menuParams = std::make_unique<content::ContextMenuParams>(params);
  }
  return self;
}

- (NSURL*)linkURL {
  return _menuParams->link_url.is_empty()
             ? nil
             : net::NSURLWithGURL(_menuParams->link_url);
}

- (NSString*)linkText {
  return base::SysUTF16ToNSString(_menuParams->link_text);
}

- (NSURL*)imageURL {
  bool image =
      _menuParams->media_type == blink::mojom::ContextMenuDataMediaType::kImage;
  return image ? net::NSURLWithGURL(_menuParams->src_url) : nil;
}

- (NSString*)selectionText {
  return base::SysUTF16ToNSString(_menuParams->selection_text);
}

- (BOOL)isEditable {
  return _menuParams->is_editable;
}

- (ECEditFlags)editFlags {
  return _menuParams->edit_flags;
}

- (NSWritingDirection)writingDirection {
  int checked = blink::ContextMenuData::kCheckableMenuItemChecked;
  if (_menuParams->writing_direction_left_to_right & checked) {
    return NSWritingDirectionLeftToRight;
  }
  if (_menuParams->writing_direction_right_to_left & checked) {
    return NSWritingDirectionRightToLeft;
  }
  return NSWritingDirectionNatural;
}

- (content::Referrer)referrerFor:(const GURL&)url {
  return content::Referrer::SanitizeForRequest(
      url,
      content::Referrer(_menuParams->frame_url, _menuParams->referrer_policy));
}

// As Chrome's "Save link as...".
- (void)saveLink {
  content::RenderFrameHost* frame = content::RenderFrameHost::FromID(_frame);
  if (!frame) {
    return;
  }
  auto download = frame->CreateDownloadUrlParameters(
      _menuParams->link_url,
      net::DefineNetworkTrafficAnnotation("engine_core_save_link", R"(
        semantics {
          sender: "Save Link As"
          description: "Saving a link's target to a local file."
          trigger: "The user chose Save Link As in the context menu."
          data: "None."
          destination: WEBSITE
        }
        policy {
          cookies_allowed: YES
          cookies_store: "user"
          setting: "This feature cannot be disabled by settings."
          policy_exception_justification: "Not implemented."
        })"));
  content::Referrer referrer = [self referrerFor:_menuParams->link_url];
  download->set_referrer(referrer.url);
  download->set_referrer_policy(
      content::Referrer::ReferrerPolicyForUrlRequest(referrer.policy));
  download->set_referrer_encoding(_menuParams->frame_charset);
  download->set_suggested_name(_menuParams->suggested_filename);
  download->set_prompt(true);
  download->set_download_source(download::DownloadSource::CONTEXT_MENU);
  frame->GetBrowserContext()->GetDownloadManager()->DownloadUrl(
      std::move(download));
}

// As Chrome's "Save image as...".
- (void)saveImage {
  content::RenderFrameHost* frame = content::RenderFrameHost::FromID(_frame);
  if (!frame) {
    return;
  }
  if (_menuParams->src_url.is_empty()) {
    frame->SaveImageAt(_menuParams->x, _menuParams->y);
    return;
  }
  content::WebContents::FromRenderFrameHost(frame)->SaveFrameWithHeaders(
      _menuParams->src_url, [self referrerFor:_menuParams->src_url],
      std::string(), _menuParams->suggested_filename, frame,
      /*is_subresource=*/true);
}

- (void)copyImage {
  if (content::RenderFrameHost* frame =
          content::RenderFrameHost::FromID(_frame)) {
    frame->CopyImageAt(_menuParams->x, _menuParams->y);
  }
}

- (void)inspect {
  if (content::RenderFrameHost* frame =
          content::RenderFrameHost::FromID(_frame)) {
    DevToolsWindow::InspectElement(frame, _menuParams->x, _menuParams->y);
  }
}

- (void)lookUp {
  content::RenderFrameHost* frame = content::RenderFrameHost::FromID(_frame);
  if (frame && frame->GetRenderWidgetHost()->GetView()) {
    frame->GetRenderWidgetHost()->GetView()->ShowDefinitionForSelection();
  }
}

- (void)setWritingDirection:(NSWritingDirection)direction {
  content::RenderFrameHost* frame = content::RenderFrameHost::FromID(_frame);
  if (!frame) {
    return;
  }
  frame->GetRenderWidgetHost()->UpdateTextDirection(
      direction == NSWritingDirectionRightToLeft ? base::i18n::RIGHT_TO_LEFT
                                                 : base::i18n::LEFT_TO_RIGHT);
  frame->GetRenderWidgetHost()->NotifyTextDirection();
}

@end

@implementation ECNavigationEntry

@synthesize URL = _URL;
@synthesize title = _title;
@synthesize index = _index;
@synthesize offset = _offset;

// nil for an entry whose URL has no NSURL form.
- (instancetype)initWithEntry:(content::NavigationEntry*)entry
                        index:(NSInteger)index
                       offset:(NSInteger)offset {
  if ((self = [super init])) {
    _URL = net::NSURLWithGURL(entry->GetVirtualURL());
    if (!_URL) {
      return nil;
    }
    _title = base::SysUTF16ToNSString(entry->GetTitleForDisplay());
    _index = index;
    _offset = offset;
  }
  return self;
}

@end

@implementation ECWebContents {
  ECBrowserContext* _context;
  std::unique_ptr<WebContentsDelegateBridge> _bridge;
  std::unique_ptr<content::WebContents> _contents;
  // Kept past close, so the view outlives the web contents, detached and
  // empty.
  NSView* _view;
}

@synthesize delegate = _delegate;
@synthesize window = _window;
@synthesize opensLinksToOtherSitesInNewWindow =
    _opensLinksToOtherSitesInNewWindow;

+ (void)initialize {
  if (self == [ECWebContents class]) {
    SetEngineCoreNavigationThrottles(&AddNavigationThrottles);
  }
}

+ (ECWebContents*)fromContents:(content::WebContents*)contents {
  Owner* owner = static_cast<Owner*>(contents->GetUserData(Owner::kKey));
  return owner ? owner->owner_ : nil;
}

- (content::WebContents*)contents {
  return _contents.get();
}

- (instancetype)initWithBrowserContext:(ECBrowserContext*)context {
  if ((self = [super init])) {
    _context = context;
    _bridge = std::make_unique<WebContentsDelegateBridge>(self);
    _contents = content::WebContents::Create(
        content::WebContents::CreateParams(context.profile));
    _contents->SetUserData(Owner::kKey, std::make_unique<Owner>(self));
    EngineCoreTabHelpers::Attach(_contents.get());
    // The manager's only seam for a prompt other than Chrome's bubble.
    permissions::PermissionRequestManager::FromWebContents(_contents.get())
        ->set_view_factory_for_testing(base::BindRepeating(
            &WebContentsDelegateBridge::CreatePermissionPrompt,
            base::Unretained(_bridge.get())));
    // History records only tabs of Chrome's browser windows otherwise.
    HistoryTabHelper::FromWebContents(_contents.get())
        ->SetForceEligibleTabForTesting(true);
    [context.webContents addObject:self];
    _view = _contents->GetNativeView().GetNativeNSView();
    _contents->SetDelegate(_bridge.get());
    _bridge->Observe(_contents.get());
    zoom::ZoomController::FromWebContents(_contents.get())
        ->AddObserver(_bridge.get());
  }
  return self;
}

// A web contents the shell let go of without closing it closes here, so
// that its destruction reports nothing to a delegate.
- (void)dealloc {
  [self close];
}

- (NSView*)view {
  return _view;
}

- (NSURL*)URL {
  return _contents ? net::NSURLWithGURL(_contents->GetLastCommittedURL())
                   : nil;
}

- (NSString*)title {
  return _contents ? base::SysUTF16ToNSString(_contents->GetTitle()) : @"";
}

- (NSImage*)favicon {
  if (!_contents) {
    return nil;
  }
  favicon::ContentFaviconDriver* driver =
      favicon::ContentFaviconDriver::FromWebContents(_contents.get());
  return driver->FaviconIsValid() ? driver->GetFavicon().ToNSImage() : nil;
}

- (BOOL)isLoading {
  return _contents && _contents->IsLoading();
}

- (double)loadProgress {
  return _contents ? _contents->GetLoadProgress() : 0;
}

- (BOOL)canGoBack {
  return _contents && _contents->GetController().CanGoBack();
}

- (BOOL)canGoForward {
  return _contents && _contents->GetController().CanGoForward();
}

// The entries from the current one (the pending one during a history
// navigation, as Chrome's BackForwardMenuModel) in `step`'s direction,
// nearest first.
- (NSArray<ECNavigationEntry*>*)entriesStepping:(int)step {
  NSMutableArray<ECNavigationEntry*>* entries = [NSMutableArray array];
  if (!_contents) {
    return entries;
  }
  content::NavigationController& controller = _contents->GetController();
  int current = controller.GetCurrentEntryIndex();
  for (int index = current + step; index >= 0 &&
                                   index < controller.GetEntryCount();
       index += step) {
    content::NavigationEntry* entry = controller.GetEntryAtIndex(index);
    if (entry->IsInitialEntry()) {
      continue;
    }
    ECNavigationEntry* item =
        [[ECNavigationEntry alloc] initWithEntry:entry
                                           index:index
                                          offset:index - current];
    if (item) {
      [entries addObject:item];
    }
  }
  return entries;
}

- (NSArray<ECNavigationEntry*>*)backEntries {
  return [self entriesStepping:-1];
}

- (NSArray<ECNavigationEntry*>*)forwardEntries {
  return [self entriesStepping:1];
}

- (void)goToOffset:(NSInteger)offset {
  if (_contents && _contents->GetController().CanGoToOffset(offset)) {
    _contents->GetController().GoToOffset(offset);
  }
}

- (void)goToEntry:(ECNavigationEntry*)entry {
  if (_contents && entry.index >= 0 &&
      entry.index < _contents->GetController().GetEntryCount()) {
    _contents->GetController().GoToIndex(entry.index);
  }
}

- (BOOL)isAudible {
  return _contents && _contents->IsCurrentlyAudible();
}

- (BOOL)isMuted {
  return _contents && _contents->IsAudioMuted();
}

- (void)setMuted:(BOOL)muted {
  if (_contents) {
    _contents->SetAudioMuted(muted);
  }
}

- (media_session::mojom::MediaSessionInfoPtr)mediaSessionInfo {
  return _contents ? content::MediaSession::Get(_contents.get())
                         ->GetMediaSessionInfoSync()
                   : nullptr;
}

- (BOOL)hasMediaSessionAction:(media_session::mojom::MediaSessionAction)action {
  if (!_contents) {
    return NO;
  }
  auto actions = content::MediaSession::Get(_contents.get())
                     ->GetMediaSessionActionsSync();
  return std::ranges::find(actions, action) != actions.end();
}

- (BOOL)hasMedia {
  auto info = [self mediaSessionInfo];
  return info && info->state !=
                     media_session::mojom::MediaSessionInfo::SessionState::kInactive;
}

- (BOOL)isPlayingMedia {
  auto info = [self mediaSessionInfo];
  return info && info->playback_state ==
                     media_session::mojom::MediaPlaybackState::kPlaying;
}

- (BOOL)mediaHasVideo {
  using media_session::mojom::MediaAudioVideoState;
  auto info = [self mediaSessionInfo];
  return info && info->audio_video_states &&
         std::ranges::any_of(*info->audio_video_states, [](auto state) {
           return state == MediaAudioVideoState::kVideoOnly ||
                  state == MediaAudioVideoState::kAudioVideo;
         });
}

- (BOOL)canGoToPreviousTrack {
  return [self hasMediaSessionAction:media_session::mojom::MediaSessionAction::
                                         kPreviousTrack];
}

- (BOOL)canGoToNextTrack {
  return [self
      hasMediaSessionAction:media_session::mojom::MediaSessionAction::kNextTrack];
}

- (void)playMedia {
  if (_contents) {
    content::MediaSession::Get(_contents.get())
        ->Resume(content::MediaSession::SuspendType::kUI);
  }
}

- (void)pauseMedia {
  if (_contents) {
    content::MediaSession::Get(_contents.get())
        ->Suspend(content::MediaSession::SuspendType::kUI);
  }
}

- (void)previousTrack {
  if (_contents) {
    content::MediaSession::Get(_contents.get())->PreviousTrack();
  }
}

- (void)nextTrack {
  if (_contents) {
    content::MediaSession::Get(_contents.get())->NextTrack();
  }
}

// The media session asks the page's one player to enter, as Chrome's media
// controls do, which needs no user gesture.
- (void)enterPictureInPicture {
  if (_contents && !_contents->HasPictureInPictureVideo()) {
    content::MediaSession::Get(_contents.get())->EnterPictureInPicture();
  }
}

- (void)exitPictureInPicture {
  if (_contents && _contents->HasPictureInPictureVideo()) {
    PictureInPictureWindowManager::GetInstance()->ExitPictureInPicture();
  }
}

- (NSWindow*)pictureInPictureWindow {
  if (!_contents || !_contents->HasPictureInPictureVideo()) {
    return nil;
  }
  auto* window = static_cast<VideoOverlayWindowViews*>(
      content::PictureInPictureWindowController::
          GetOrCreateVideoPictureInPictureController(_contents.get())
              ->GetWindowForTesting());
  return window ? window->GetNativeWindow().GetNativeNSWindow() : nil;
}

- (BOOL)isSecure {
  return _contents && chrome_security_state::GetSecurityLevel(
                          _contents.get()) == security_state::SECURE;
}

- (NSString*)translationLanguage {
  if (!_contents) {
    return nil;
  }
  ChromeTranslateClient* client =
      ChromeTranslateClient::FromWebContents(_contents.get());
  if (!client->GetTranslateManager()->CanManuallyTranslate()) {
    return nil;
  }
  std::string source;
  std::string target;
  client->GetTranslateLanguages(_contents.get(), &source, &target);
  return base::SysUTF16ToNSString(l10n_util::GetDisplayNameForLocale(
      target, g_browser_process->GetApplicationLocale(), true));
}

// As Chrome's "Translate to" menu item.
- (void)translate {
  if (!_contents) {
    return;
  }
  ChromeTranslateClient::FromWebContents(_contents.get())
      ->GetTranslateManager()
      ->ShowTranslateUI(/*auto_translate=*/true, /*triggered_from_menu=*/true);
}

- (NSDictionary<NSString*, NSNumber*>*)sitePermissions {
  return _contents ? SitePermissions(_context.profile,
                                     _contents->GetLastCommittedURL())
                   : @{};
}

- (void)setSitePermission:(NSString*)permission allowed:(BOOL)allowed {
  if (_contents) {
    SetSitePermission(_context.profile, _contents->GetLastCommittedURL(),
                      permission, allowed);
  }
}

- (void)snapshot:(void (^)(NSImage*))completion {
  content::RenderWidgetHostView* view =
      _contents ? _contents->GetPrimaryMainFrame()->GetView() : nullptr;
  if (!view) {
    completion(nil);
    return;
  }
  view->CopyFromSurface(
      gfx::Rect(), gfx::Size(), base::Seconds(5),
      base::BindPostTaskToCurrentDefault(base::BindOnce(
          [](void (^completion)(NSImage*),
             const content::CopyFromSurfaceResult& result) {
            completion(result.has_value() && !result->bitmap.drawsNothing()
                           ? skia::SkBitmapToNSImage(result->bitmap)
                           : nil);
          },
          completion)));
}

- (void)evaluateJavaScript:(NSString*)script
                completion:(void (^)(NSString*))completion {
  content::RenderFrameHost* frame =
      _contents ? _contents->GetPrimaryMainFrame() : nullptr;
  if (!frame || !frame->IsRenderFrameLive()) {
    completion(nil);
    return;
  }
  frame->ExecuteJavaScriptInIsolatedWorld(
      base::SysNSStringToUTF16(script),
      base::BindOnce(
          [](void (^completion)(NSString*), base::Value value) {
            completion(value.is_string()
                           ? base::SysUTF8ToNSString(value.GetString())
                           : nil);
          },
          completion),
      ISOLATED_WORLD_ID_CHROME_INTERNAL);
}

// As Chrome's "Copy link to highlight", for the focused frame.
- (void)linkToHighlight:(void (^)(NSURL*))completion {
  content::RenderFrameHost* frame =
      _contents ? _contents->GetFocusedFrame() : nullptr;
  if (!frame) {
    completion(nil);
    return;
  }
  auto receiver =
      std::make_unique<mojo::Remote<blink::mojom::TextFragmentReceiver>>();
  frame->GetRemoteInterfaces()->GetInterface(
      receiver->BindNewPipeAndPassReceiver());
  auto* remote = receiver.get();
  GURL url = shared_highlighting::RemoveFragmentSelectorDirectives(
      _contents->GetLastCommittedURL());
  (*remote)->RequestSelectorForSelection(base::BindOnce(
      [](std::unique_ptr<mojo::Remote<blink::mojom::TextFragmentReceiver>>,
         const GURL& url, void (^completion)(NSURL*),
         const std::string& selector, shared_highlighting::LinkGenerationError,
         shared_highlighting::LinkGenerationReadyStatus) {
        completion(selector.empty() ? nil
                                    : net::NSURLWithGURL(
                                          shared_highlighting::AppendSelectors(
                                              url, {selector})));
      },
      std::move(receiver), url, completion));
}

- (void)savePage {
  if (_contents) {
    _contents->OnSavePage();
  }
}

- (void)print {
  if (_contents) {
    printing::StartBasicPrint(_contents.get());
  }
}

// The entries as Chrome's session service writes them: a format version,
// the count, the current index, then each entry's pickle.
- (NSData*)sessionState {
  if (!_contents) {
    return nil;
  }
  content::NavigationController& controller = _contents->GetController();
  if (controller.GetLastCommittedEntry()->IsInitialEntry()) {
    return nil;
  }
  base::Pickle pickle;
  pickle.WriteInt(kSessionStateVersion);
  pickle.WriteInt(controller.GetEntryCount());
  pickle.WriteInt(controller.GetLastCommittedEntryIndex());
  for (int index = 0; index < controller.GetEntryCount(); ++index) {
    sessions::ContentSerializedNavigationBuilder::FromNavigationEntry(
        index, controller.GetEntryAtIndex(index))
        .WriteToPickle(kSessionEntryMaxSize, &pickle);
  }
  return [NSData dataWithBytes:pickle.data() length:pickle.size()];
}

- (BOOL)restoreSessionState:(NSData*)state {
  if (!_contents) {
    return NO;
  }
  content::NavigationController& controller = _contents->GetController();
  if (!controller.GetLastCommittedEntry()->IsInitialEntry() ||
      controller.GetPendingEntry()) {
    return NO;
  }
  base::Pickle pickle =
      base::Pickle::WithUnownedBuffer(base::apple::NSDataToSpan(state));
  base::PickleIterator iterator(pickle);
  int version = 0;
  int count = 0;
  int selected = 0;
  if (!iterator.ReadInt(&version) || version != kSessionStateVersion ||
      !iterator.ReadInt(&count) || !iterator.ReadInt(&selected) ||
      count <= 0 || selected < 0 || selected >= count) {
    return NO;
  }
  std::vector<sessions::SerializedNavigationEntry> serialized;
  for (int i = 0; i < count; ++i) {
    serialized.emplace_back();
    if (!serialized.back().ReadFromPickle(&iterator)) {
      return NO;
    }
  }
  std::vector<std::unique_ptr<content::NavigationEntry>> entries =
      sessions::ContentSerializedNavigationBuilder::ToNavigationEntries(
          serialized, _context.profile);
  controller.Restore(selected, content::RestoreType::kRestored, &entries);
  return YES;
}

- (void)loadIfNeeded {
  if (_contents) {
    _contents->GetController().LoadIfNecessary();
  }
}

- (void)requestNewWindowWithURL:(const GURL&)url
                    disposition:(WindowOpenDisposition)disposition
                    userGesture:(BOOL)userGesture {
  ECWindowOpenDisposition kind = ECWindowOpenDispositionNewForegroundTab;
  if (disposition == WindowOpenDisposition::NEW_BACKGROUND_TAB) {
    kind = ECWindowOpenDispositionNewBackgroundTab;
  } else if (disposition == WindowOpenDisposition::NEW_WINDOW) {
    kind = ECWindowOpenDispositionNewWindow;
  } else if (disposition == WindowOpenDisposition::NEW_POPUP) {
    kind = ECWindowOpenDispositionNewPopup;
  }
  NSURL* URL = net::NSURLWithGURL(url);
  if ([_delegate respondsToSelector:@selector
                 (webContents:requestsNewWindowWithURL:disposition:
                     modifierFlags:)]) {
    [_delegate webContents:self
        requestsNewWindowWithURL:URL
                     disposition:kind
                   modifierFlags:userGesture && _bridge
                                     ? _bridge->recent_modifier_flags()
                                     : 0];
    return;
  }
  [_delegate webContents:self requestsNewWindowWithURL:URL disposition:kind];
}

- (void)loadURL:(NSURL*)url {
  if (!_contents) {
    return;
  }
  _contents->GetController().LoadURL(net::GURLWithNSURL(url),
                                     content::Referrer(),
                                     ui::PAGE_TRANSITION_TYPED, std::string());
}

// A link the user followed (a browser-initiated link transition), so the
// handoff throttle asks about it.
- (void)loadRequest:(NSURLRequest*)request {
  if (!_contents) {
    return;
  }
  content::NavigationController::LoadURLParams params(
      net::GURLWithNSURL(request.URL));
  params.transition_type = ui::PAGE_TRANSITION_LINK;
  if (NSString* referrer = [request valueForHTTPHeaderField:@"Referer"]) {
    params.referrer =
        content::Referrer(GURL(base::SysNSStringToUTF8(referrer)),
                          network::mojom::ReferrerPolicy::kDefault);
  }
  if ([request.HTTPMethod isEqualToString:@"POST"]) {
    params.load_type = content::NavigationController::LOAD_TYPE_HTTP_POST;
    params.post_data = network::ResourceRequestBody::CreateFromCopyOfBytes(
        base::apple::NSDataToSpan(request.HTTPBody ?: [NSData data]));
    if (NSString* type = [request valueForHTTPHeaderField:@"Content-Type"]) {
      params.extra_headers = std::string(net::HttpRequestHeaders::kContentType) +
                             ": " + base::SysNSStringToUTF8(type);
    }
  }
  _contents->GetController().LoadURLWithParams(params);
}

- (void)goBack {
  if (self.canGoBack) {
    _contents->GetController().GoBack();
  }
}

- (void)goForward {
  if (self.canGoForward) {
    _contents->GetController().GoForward();
  }
}

- (void)reload {
  if (_contents) {
    _contents->GetController().Reload(content::ReloadType::NORMAL, true);
  }
}

- (void)reloadBypassingCache {
  if (_contents) {
    _contents->GetController().Reload(content::ReloadType::BYPASSING_CACHE,
                                      true);
  }
}

- (void)stop {
  if (_contents) {
    _contents->Stop();
  }
}

- (NSInteger)zoomPercent {
  return _contents ? zoom::ZoomController::FromWebContents(_contents.get())
                         ->GetZoomPercent()
                   : 100;
}

- (void)zoomIn {
  if (_contents) {
    zoom::PageZoom::Zoom(_contents.get(), content::PAGE_ZOOM_IN);
  }
}

- (void)zoomOut {
  if (_contents) {
    zoom::PageZoom::Zoom(_contents.get(), content::PAGE_ZOOM_OUT);
  }
}

- (void)resetZoom {
  if (_contents) {
    zoom::PageZoom::Zoom(_contents.get(), content::PAGE_ZOOM_RESET);
  }
}

// Detaches the bridge before destroying the web contents: destruction
// reports navigation state changes and observer callbacks, which must reach
// neither the shell nor a window.
- (void)close {
  // Closing the context may have closed it already.
  if (!_contents) {
    return;
  }
  [_window tabWillClose:self];
  [_view removeFromSuperview];
  _contents->SetDelegate(nullptr);
  _bridge->Observe(nullptr);
  zoom::ZoomController::FromWebContents(_contents.get())
      ->RemoveObserver(_bridge.get());
  _contents.reset();
  _bridge.reset();
}

- (void)findString:(NSString*)string forward:(BOOL)forward {
  if (!_contents) {
    return;
  }
  find_in_page::FindTabHelper::FromWebContents(_contents.get())
      ->StartFinding(base::SysNSStringToUTF16(string), forward,
                     /*case_sensitive=*/false, /*find_match=*/true);
}

// An unchanged string would find the next match (FindTabHelper's find-next
// path); this keeps the active match and reports the results again.
- (void)findString:(NSString*)string {
  if (!_contents) {
    return;
  }
  find_in_page::FindTabHelper* helper =
      find_in_page::FindTabHelper::FromWebContents(_contents.get());
  std::u16string text = base::SysNSStringToUTF16(string);
  bool reports = [_delegate respondsToSelector:@selector
                            (webContents:didFindMatches:activeMatch:)];
  // FindTabHelper takes an empty string as a find-next of the old one.
  if (text.empty()) {
    helper->StopFinding(find_in_page::SelectionAction::kClear);
    if (reports) {
      [_delegate webContents:self didFindMatches:0 activeMatch:0];
    }
    return;
  }
  if (text != helper->find_text() || !helper->is_find_session_active()) {
    helper->StartFinding(text, /*forward_direction=*/true,
                         /*case_sensitive=*/false, /*find_match=*/true);
    return;
  }
  if (reports) {
    const find_in_page::FindNotificationDetails& result =
        helper->find_result();
    [_delegate webContents:self
            didFindMatches:result.number_of_matches()
               activeMatch:std::max(0, result.active_match_ordinal())];
  }
}

// Blink has no browser-side call to reveal the selection, so this scrolls to
// it in the focused frame from an isolated world, as content scripts run.
- (void)scrollSelectionIntoView {
  content::RenderFrameHost* frame =
      _contents ? _contents->GetFocusedFrame() : nullptr;
  if (!frame) {
    return;
  }
  frame->ExecuteJavaScriptInIsolatedWorld(
      uR"((() => {
        const selection = getSelection();
        if (!selection || !selection.rangeCount) return;
        const range = selection.getRangeAt(0);
        let node = range.startContainer;
        if (node.nodeType !== Node.ELEMENT_NODE) node = node.parentElement;
        if (!node) return;
        const rect = range.getBoundingClientRect();
        if (rect.width || rect.height) {
          node.scrollIntoView({block: 'nearest', inline: 'nearest'});
          const after = range.getBoundingClientRect();
          if (after.top < 0 || after.bottom > innerHeight) {
            scrollBy(0, after.top - innerHeight / 2);
          }
        } else {
          node.scrollIntoView({block: 'center', inline: 'nearest'});
        }
      })())",
      base::NullCallback(), ISOLATED_WORLD_ID_CHROME_INTERNAL);
}

- (void)stopFinding {
  if (!_contents) {
    return;
  }
  find_in_page::FindTabHelper::FromWebContents(_contents.get())
      ->StopFinding(find_in_page::SelectionAction::kKeep);
}

- (void)showConsole {
  if (!_contents) {
    return;
  }
  DevToolsWindow::OpenDevToolsWindow(_contents.get(),
                                     DevToolsToggleAction::ShowConsolePanel(),
                                     DevToolsOpenedByAction::kConsoleShortcut);
}

- (void)inspectElement {
  if (!_contents) {
    return;
  }
  DevToolsWindow::OpenDevToolsWindow(
      _contents.get(), DevToolsToggleAction::Inspect(),
      DevToolsOpenedByAction::kInspectorModeShortcut);
}

- (void)cut:(id)sender {
  if (_contents) {
    _contents->Cut();
  }
}

- (void)copy:(id)sender {
  if (_contents) {
    _contents->Copy();
  }
}

- (void)paste:(id)sender {
  if (_contents) {
    _contents->Paste();
  }
}

- (void)selectAll:(id)sender {
  if (_contents) {
    _contents->SelectAll();
  }
}

- (void)undo:(id)sender {
  if (_contents) {
    _contents->Undo();
  }
}

- (void)redo:(id)sender {
  if (_contents) {
    _contents->Redo();
  }
}

- (void)pasteAndMatchStyle:(id)sender {
  if (_contents) {
    _contents->PasteAndMatchStyle();
  }
}

@end
