#import "engine_core/ec_browser_context_private.h"

#include <memory>

#include "base/apple/foundation_util.h"
#include "base/callback_list.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/raw_ptr.h"
#include "base/scoped_observation.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/download/download_prefs.h"
#include "chrome/browser/profiles/delete_profile_helper.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile_destroyer.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_metrics.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "chrome/common/pref_names.h"
#include "components/download/content/public/all_download_item_notifier.h"
#include "components/download/public/common/download_item.h"
#include "components/prefs/pref_service.h"
#include "components/search_engines/default_search_manager.h"
#include "components/search_engines/template_url.h"
#include "components/search_engines/template_url_data_util.h"
#include "components/search_engines/template_url_prepopulate_data.h"
#include "components/search_engines/template_url_service.h"
#include "components/search_engines/template_url_service_observer.h"
#include "content/public/browser/download_item_utils.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#import "engine_core/ec_web_contents_private.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "net/base/apple/url_conversions.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_change_dispatcher.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"

@implementation ECDownload

@synthesize identifier = _identifier;
@synthesize URL = _URL;
@synthesize fileURL = _fileURL;
@synthesize receivedBytes = _receivedBytes;
@synthesize totalBytes = _totalBytes;
@synthesize state = _state;
@synthesize startTime = _startTime;

- (instancetype)initWithItem:(download::DownloadItem*)item {
  if ((self = [super init])) {
    _identifier = item->GetId();
    _URL = net::NSURLWithGURL(item->GetURL());
    if (!item->GetTargetFilePath().empty()) {
      _fileURL = base::apple::FilePathToNSURL(item->GetTargetFilePath());
    }
    _receivedBytes = item->GetReceivedBytes();
    _totalBytes = item->GetTotalBytes();
    _state = static_cast<ECDownloadState>(item->GetState());
    _startTime = item->GetStartTime().ToNSDate();
  }
  return self;
}

@end

namespace {

class DownloadObserver : public download::AllDownloadItemNotifier::Observer {
 public:
  explicit DownloadObserver(ECBrowserContext* owner)
      : owner_(owner), notifier_(owner.profile->GetDownloadManager(), this) {}

  // Closes a new tab that only downloaded, as DownloadUIController does.
  void OnDownloadCreated(content::DownloadManager* manager,
                         download::DownloadItem* item) override {
    content::WebContents* contents =
        content::DownloadItemUtils::GetWebContents(item);
    if (contents && [ECWebContents fromContents:contents] &&
        contents->GetController().IsInitialNavigation() &&
        !item->IsSavePackageDownload()) {
      contents->Close();
    }
    OnDownloadUpdated(manager, item);
  }

  void OnDownloadUpdated(content::DownloadManager* manager,
                         download::DownloadItem* item) override {
    [owner_.downloadDelegate browserContext:owner_
                          downloadDidUpdate:[[ECDownload alloc]
                                                initWithItem:item]];
  }

 private:
  __weak ECBrowserContext* owner_;
  download::AllDownloadItemNotifier notifier_;
};

// Reports changes to cookies under the context's observedCookieDomains, as
// chrome.cookies.onChanged hears them.
class CookieObserver : public network::mojom::CookieChangeListener {
 public:
  explicit CookieObserver(ECBrowserContext* owner) : owner_(owner) { Listen(); }

  void OnCookieChange(const net::CookieChangeInfo& change) override {
    if (change.cookie.IsPartitioned() ||
        change.cause == net::CookieChangeCause::OVERWRITE ||
        !CookieIsUnderDomains(change.cookie, owner_.observedCookieDomains)) {
      return;
    }
    [owner_.cookieDelegate
        browserContext:owner_
       cookieDidChange:[[ECCookie alloc] initWithCanonicalCookie:change.cookie]
               removed:net::CookieChangeCauseIsDeletion(change.cause)];
  }

 private:
  // Listens again when the network service restarts.
  void Listen() {
    receiver_.reset();
    owner_.profile->GetDefaultStoragePartition()
        ->GetCookieManagerForBrowserProcess()
        ->AddGlobalChangeListener(receiver_.BindNewPipeAndPassRemote());
    receiver_.set_disconnect_handler(
        base::BindOnce(&CookieObserver::Listen, base::Unretained(this)));
  }

  __weak ECBrowserContext* owner_;
  mojo::Receiver<network::mojom::CookieChangeListener> receiver_{this};
};

// Makes Google, from Chrome's prepopulated engines, the default search of a
// profile that still has its region's default, so a default chosen later in
// settings stays. The profile lists Google unless its region's engines leave
// it out.
void UseGoogle(TemplateURLService* service) {
  if (service->default_search_provider_source() !=
      DefaultSearchManager::FROM_FALLBACK) {
    return;
  }
  constexpr char16_t kKeyword[] = u"google.com";
  TemplateURL* engine = service->GetTemplateURLForKeyword(kKeyword);
  if (!engine) {
    engine = service->Add(
        std::make_unique<TemplateURL>(*TemplateURLDataFromPrepopulatedEngine(
            *TemplateURLPrepopulateData::GetPrepopulatedEngineFromBuiltInData(
                kKeyword, {}, {}))));
  }
  service->SetUserSelectedDefaultSearchProvider(engine);
}

// Lets the site searches Chrome finds on visited pages (Wikipedia) be used
// as keywords. Chrome keeps them inactive until the user
// activates them in its settings, which also stops a page's OpenSearch
// description from replacing the one Chrome made from its search form. This
// activates them for the session only, so they stay replaceable.
class SiteSearchActivator : public TemplateURLServiceObserver {
 public:
  explicit SiteSearchActivator(TemplateURLService* service)
      : service_(service) {
    observation_.Observe(service);
    if (service->loaded()) {
      OnTemplateURLServiceChanged();
    }
  }

  void OnTemplateURLServiceChanged() override {
    for (TemplateURL* engine : service_->GetTemplateURLs()) {
      if (engine->safe_for_autoreplace() && engine->prepopulate_id() == 0 &&
          engine->type() == TemplateURL::NORMAL &&
          engine->is_active() == TemplateURLData::ActiveStatus::kUnspecified) {
        engine->set_is_active(TemplateURLData::ActiveStatus::kTrue);
      }
    }
  }

  void OnTemplateURLServiceShuttingDown() override { observation_.Reset(); }

 private:
  raw_ptr<TemplateURLService> service_;
  base::ScopedObservation<TemplateURLService, TemplateURLServiceObserver>
      observation_{this};
};

}  // namespace

@implementation ECBrowserContext {
  std::unique_ptr<ScopedProfileKeepAlive> _keepAlive;
  std::unique_ptr<DownloadObserver> _downloadObserver;
  ECBrowserContext* _offTheRecordContext;
  base::CallbackListSubscription _searchEnginesLoaded;
  std::unique_ptr<SiteSearchActivator> _siteSearchActivator;
  std::unique_ptr<CookieObserver> _cookieObserver;
}

@synthesize profile = _profile;
@synthesize webContents = _webContents;
@synthesize autocompletes = _autocompletes;
@synthesize downloadDelegate = _downloadDelegate;
@synthesize extensionsDelegate = _extensionsDelegate;
@synthesize cookieDelegate = _cookieDelegate;
@synthesize observedCookieDomains = _observedCookieDomains;

+ (void)loadWithPath:(NSString*)path
          completion:(void (^)(ECBrowserContext*))completion {
  g_browser_process->profile_manager()->CreateProfileAsync(
      base::apple::NSStringToFilePath(path),
      base::BindOnce(^(Profile* profile) {
        completion(profile ? [[ECBrowserContext alloc] initWithProfile:profile]
                           : nil);
      }));
}

+ (void)deleteProfileAtPath:(NSString*)path {
  g_browser_process->profile_manager()
      ->GetDeleteProfileHelper()
      .MaybeScheduleProfileForDeletion(
          base::apple::NSStringToFilePath(path), base::DoNothing(),
          ProfileMetrics::DELETE_PROFILE_SETTINGS);
}

- (instancetype)initWithProfile:(Profile*)profile {
  if ((self = [super init])) {
    _profile = profile;
    _observedCookieDomains = @[];
    _webContents = [NSHashTable weakObjectsHashTable];
    _autocompletes = [NSHashTable weakObjectsHashTable];
    // Chrome destroys its profiles when it quits.
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(closeAll)
               name:NSApplicationWillTerminateNotification
             object:nil];
    // An off-the-record profile keeps its original profile alive and uses
    // its search engines.
    if (!profile->IsOffTheRecord()) {
      _keepAlive = std::make_unique<ScopedProfileKeepAlive>(
          profile, ProfileKeepAliveOrigin::kBrowserWindow);
      TemplateURLService* service =
          TemplateURLServiceFactory::GetForProfile(profile);
      _siteSearchActivator = std::make_unique<SiteSearchActivator>(service);
      if (service->loaded()) {
        UseGoogle(service);
      } else {
        _searchEnginesLoaded = service->RegisterOnLoadedCallback(
            base::BindOnce(&UseGoogle, base::Unretained(service)));
        service->Load();
      }
    }
    _downloadObserver = std::make_unique<DownloadObserver>(self);
    // Creating the download manager made Chrome's download bubble set an
    // incognito profile to ask where to save each download.
    if (profile->IsOffTheRecord()) {
      profile->GetPrefs()->SetBoolean(prefs::kPromptForDownload, false);
    }
    ObserveExtensions(self);
  }
  return self;
}

- (NSURL*)downloadDirectory {
  return base::apple::FilePathToNSURL(
      DownloadPrefs::FromBrowserContext(_profile)->DownloadPath());
}

- (void)setDownloadDirectory:(NSURL*)url {
  DownloadPrefs::FromBrowserContext(_profile)->SetDownloadPath(
      base::apple::NSURLToFilePath(url));
}

- (NSArray<NSString*>*)observedCookieDomains {
  return _observedCookieDomains;
}

- (void)setObservedCookieDomains:(NSArray<NSString*>*)domains {
  _observedCookieDomains = [domains copy];
  if (!domains.count) {
    _cookieObserver.reset();
  } else if (!_cookieObserver) {
    _cookieObserver = std::make_unique<CookieObserver>(self);
  }
}

- (BOOL)searchSuggestEnabled {
  return _profile->GetPrefs()->GetBoolean(prefs::kSearchSuggestEnabled);
}

- (void)setSearchSuggestEnabled:(BOOL)enabled {
  _profile->GetPrefs()->SetBoolean(prefs::kSearchSuggestEnabled, enabled);
}

- (ECBrowserContext*)offTheRecordContext {
  if (!_offTheRecordContext.profile) {
    _offTheRecordContext = [[ECBrowserContext alloc]
        initWithProfile:_profile->GetPrimaryOTRProfile(
                            /*create_if_needed=*/true)];
  }
  return _offTheRecordContext;
}

- (void)closeAll {
  [_webContents.allObjects makeObjectsPerformSelector:@selector(close)];
  [_autocompletes.allObjects makeObjectsPerformSelector:@selector(close)];
}

- (void)close {
  [self closeAll];
  if (_profile->IsOffTheRecord()) {
    ProfileDestroyer::DestroyOTRProfileWhenAppropriate(_profile);
  }
  _downloadObserver.reset();
  _siteSearchActivator.reset();
  _cookieObserver.reset();
  _keepAlive.reset();
  _profile = nullptr;
}

@end
