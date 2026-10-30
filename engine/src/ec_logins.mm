#import "engine_core/ec_browser_context_private.h"

#include <algorithm>
#include <tuple>
#include <utility>
#include <vector>

#include "base/barrier_callback.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#include "base/types/expected.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/affiliations/core/browser/match_type.h"
#include "components/keyed_service/core/service_access_type.h"
#include "components/password_manager/core/browser/import/csv_password_sequence.h"
#include "components/password_manager/core/browser/password_form_digest.h"
#include "components/password_manager/core/browser/password_manager_util.h"
#include "components/password_manager/core/browser/password_store/password_store_backend_error.h"
#include "components/password_manager/core/browser/password_store/password_store_consumer.h"
#include "components/password_manager/core/browser/password_store/password_store_interface.h"
#include "components/password_manager/core/browser/password_store/stored_credential.h"
#include "content/public/browser/storage_partition.h"
#include "net/base/apple/url_conversions.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_access_result.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_util.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "url/gurl.h"

namespace {

using StoredCredential = password_manager::StoredCredential;

// Reads the logins of one form digest from a password store and hands them
// to `callback`, then deletes itself.
class LoginsRequest : public password_manager::PasswordStoreConsumer {
 public:
  using Callback = base::OnceCallback<void(std::vector<StoredCredential>)>;

  static void Start(Profile* profile,
                    const password_manager::PasswordFormDigest& digest,
                    Callback callback) {
    LoginsRequest* request = new LoginsRequest(std::move(callback));
    ProfilePasswordStoreFactory::GetForProfile(
        profile, ServiceAccessType::EXPLICIT_ACCESS)
        ->GetLogins(digest, request->weak_factory_.GetWeakPtr());
  }

  void OnGetPasswordStoreResultsOrErrorFrom(
      password_manager::PasswordStoreInterface* store,
      base::expected<std::vector<StoredCredential>,
                     password_manager::PasswordStoreBackendError>
          results_or_error) override {
    std::move(callback_).Run(results_or_error.has_value()
                                 ? std::move(*results_or_error)
                                 : std::vector<StoredCredential>());
    delete this;
  }

 private:
  explicit LoginsRequest(Callback callback) : callback_(std::move(callback)) {}

  Callback callback_;
  base::WeakPtrFactory<LoginsRequest> weak_factory_{this};
};

// The digest of the page's form, as Chrome's password manager makes it for
// an HTML form on the page.
password_manager::PasswordFormDigest DigestForURL(const GURL& url) {
  return password_manager::PasswordFormDigest(
      password_manager::PasswordForm::Scheme::kHtml,
      password_manager_util::GetSignonRealm(url), url.GetWithEmptyPath());
}

}  // namespace

@interface ECPassword ()
- (instancetype)initWithURLString:(NSString*)URLString
                         username:(NSString*)username
                         password:(NSString*)password
                       exactMatch:(BOOL)exactMatch;
@end

@implementation ECPassword

@synthesize URLString = _URLString;
@synthesize username = _username;
@synthesize password = _password;
@synthesize exactMatch = _exactMatch;

- (instancetype)initWithURLString:(NSString*)URLString
                         username:(NSString*)username
                         password:(NSString*)password {
  return [self initWithURLString:URLString
                        username:username
                        password:password
                      exactMatch:YES];
}

- (instancetype)initWithURLString:(NSString*)URLString
                         username:(NSString*)username
                         password:(NSString*)password
                       exactMatch:(BOOL)exactMatch {
  if ((self = [super init])) {
    _URLString = [URLString copy];
    _username = [username copy];
    _password = [password copy];
    _exactMatch = exactMatch;
  }
  return self;
}

+ (NSArray<ECPassword*>*)passwordsFromCSV:(NSString*)CSV {
  password_manager::CSVPasswordSequence sequence(base::SysNSStringToUTF8(CSV));
  NSMutableArray<ECPassword*>* passwords = [NSMutableArray array];
  for (const password_manager::CSVPassword& row : sequence) {
    if (row.GetParseStatus() != password_manager::CSVPassword::Status::kOK ||
        !row.GetURL().has_value()) {
      continue;
    }
    [passwords
        addObject:[[ECPassword alloc]
                      initWithURLString:base::SysUTF8ToNSString(
                                            row.GetURL()->spec())
                               username:base::SysUTF8ToNSString(
                                            row.GetUsername())
                               password:base::SysUTF8ToNSString(
                                            row.GetPassword())]];
  }
  return passwords;
}

@end

@implementation ECCookie

@synthesize name = _name;
@synthesize value = _value;
@synthesize domain = _domain;
@synthesize path = _path;
@synthesize creation = _creation;
@synthesize expiry = _expiry;
@synthesize lastAccess = _lastAccess;
@synthesize secure = _secure;
@synthesize HTTPOnly = _HTTPOnly;
@synthesize sameSite = _sameSite;

- (instancetype)initWithName:(NSString*)name
                       value:(NSString*)value
                      domain:(NSString*)domain
                        path:(NSString*)path
                    creation:(NSDate*)creation
                      expiry:(NSDate*)expiry
                  lastAccess:(NSDate*)lastAccess
                      secure:(BOOL)secure
                    HTTPOnly:(BOOL)HTTPOnly
                    sameSite:(NSInteger)sameSite {
  if ((self = [super init])) {
    _name = [name copy];
    _value = [value copy];
    _domain = [domain copy];
    _path = [path copy];
    _creation = creation;
    _expiry = expiry;
    _lastAccess = lastAccess;
    _secure = secure;
    _HTTPOnly = HTTPOnly;
    _sameSite = sameSite;
  }
  return self;
}

// net::CookieSameSite has the values of the sameSite property.
- (instancetype)initWithCanonicalCookie:(const net::CanonicalCookie&)cookie {
  return [self
      initWithName:base::SysUTF8ToNSString(cookie.Name())
             value:base::SysUTF8ToNSString(cookie.Value())
            domain:base::SysUTF8ToNSString(cookie.Domain())
              path:base::SysUTF8ToNSString(cookie.Path())
          creation:cookie.CreationDate().ToNSDate()
            expiry:cookie.IsPersistent() ? cookie.ExpiryDate().ToNSDate() : nil
        lastAccess:cookie.LastAccessDate().ToNSDate()
            secure:cookie.SecureAttribute()
          HTTPOnly:cookie.IsHttpOnly()
          sameSite:static_cast<NSInteger>(cookie.SameSite())];
}

@end

bool CookieIsUnderDomains(const net::CanonicalCookie& cookie,
                          NSArray<NSString*>* domains) {
  std::string host = cookie.DomainWithoutDot();
  for (NSString* domain in domains) {
    std::string name = base::SysNSStringToUTF8(domain);
    if (host == name || host.ends_with("." + name)) {
      return true;
    }
  }
  return false;
}

@implementation ECBrowserContext (Logins)

// As Chrome adds the passwords of a CSV file it imports.
- (void)importPasswords:(NSArray<ECPassword*>*)passwords
             completion:(void (^)(NSInteger))completion {
  std::vector<password_manager::StoredCredential> forms;
  base::Time now = base::Time::Now();
  for (ECPassword* password in passwords) {
    GURL url(base::SysNSStringToUTF8(password.URLString));
    if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() ||
        password.password.length == 0) {
      continue;
    }
    password_manager::StoredCredential& form = forms.emplace_back();
    form.url = url;
    form.signon_realm = password_manager_util::GetSignonRealm(url);
    form.username_value = base::SysNSStringToUTF16(password.username);
    form.password_value = password_manager::PasswordString(
        base::SysNSStringToUTF16(password.password));
    form.type = password_manager::PasswordForm::Type::kImported;
    form.date_created = now;
    form.date_password_modified = now;
    form.in_store = password_manager::PasswordForm::Store::kProfileStore;
  }
  NSInteger count = forms.size();
  ProfilePasswordStoreFactory::GetForProfile(self.profile,
                                             ServiceAccessType::EXPLICIT_ACCESS)
      ->AddLogins(std::move(forms), base::BindOnce(^{
                    completion(count);
                  }));
}

// As chrome.cookies.set sets a cookie.
- (void)importCookies:(NSArray<ECCookie*>*)cookies
           completion:(void (^)(NSInteger))completion {
  network::mojom::CookieManager* manager =
      self.profile->GetDefaultStoragePartition()
          ->GetCookieManagerForBrowserProcess();
  std::vector<std::pair<std::unique_ptr<net::CanonicalCookie>, GURL>> valid;
  for (ECCookie* cookie in cookies) {
    std::string domain = base::SysNSStringToUTF8(cookie.domain);
    std::string path = base::SysNSStringToUTF8(cookie.path);
    GURL url = net::cookie_util::CookieDomainAndPathToURL(domain, path,
                                                          cookie.secure);
    if (cookie.sameSite < -1 || cookie.sameSite > 2) {
      continue;
    }
    net::CookieInclusionStatus status;
    // A host-only cookie's domain is its URL's host.
    std::unique_ptr<net::CanonicalCookie> canonical =
        net::CanonicalCookie::CreateSanitizedCookie(
            url, base::SysNSStringToUTF8(cookie.name),
            base::SysNSStringToUTF8(cookie.value),
            domain.starts_with(".") ? domain : std::string(), path,
            base::Time::FromNSDate(cookie.creation),
            cookie.expiry ? base::Time::FromNSDate(cookie.expiry)
                          : base::Time(),
            base::Time::FromNSDate(cookie.lastAccess), cookie.secure,
            cookie.HTTPOnly, static_cast<net::CookieSameSite>(cookie.sameSite),
            net::COOKIE_PRIORITY_DEFAULT, std::nullopt, &status);
    if (canonical) {
      valid.emplace_back(std::move(canonical), url);
    }
  }
  if (valid.empty()) {
    completion(0);
    return;
  }
  auto done = base::BarrierCallback<bool>(
      valid.size(), base::BindOnce(^(std::vector<bool> results) {
        completion(std::ranges::count(results, true));
      }));
  for (auto& [cookie, url] : valid) {
    manager->SetCanonicalCookie(
        *cookie, url, net::CookieOptions::MakeAllInclusive(),
        base::BindOnce(
            [](base::RepeatingCallback<void(bool)> done,
               net::CookieAccessResult result) {
              done.Run(result.status.IsInclude());
            },
            done));
  }
}

// As Chrome's password manager fetches the logins for a form: exact
// matches, then the public suffix matches it offers, without blocklisted
// and federated entries, which have no password.
- (void)loginsForURL:(NSURL*)url
          completion:(void (^)(NSArray<ECPassword*>*))completion {
  password_manager::PasswordFormDigest digest =
      DigestForURL(net::GURLWithNSURL(url));
  std::string realm = digest.signon_realm;
  LoginsRequest::Start(
      self.profile, digest,
      base::BindOnce(^(std::vector<StoredCredential> forms) {
        std::erase_if(forms, [&](const StoredCredential& form) {
          bool psl = form.match_type &&
                     (*form.match_type & affiliations::MatchType::kPSL) ==
                         affiliations::MatchType::kPSL;
          return form.blocked_by_user || form.federation_origin.IsValid() ||
                 (form.signon_realm != realm && !psl);
        });
        std::ranges::stable_sort(
            forms, [&](const StoredCredential& a, const StoredCredential& b) {
              bool a_exact = a.signon_realm == realm;
              bool b_exact = b.signon_realm == realm;
              return a_exact != b_exact ? a_exact
                                        : a.date_last_used > b.date_last_used;
            });
        NSMutableArray<ECPassword*>* logins = [NSMutableArray array];
        for (const StoredCredential& form : forms) {
          [logins
              addObject:[[ECPassword alloc]
                            initWithURLString:base::SysUTF8ToNSString(
                                                  form.url.spec())
                                     username:base::SysUTF16ToNSString(
                                                  form.username_value)
                                     password:base::SysUTF16ToNSString(
                                                  form.password_value.value())
                                   exactMatch:form.signon_realm == realm]];
        }
        completion(logins);
      }));
}

// As Chrome's save prompt saves a login: a new password for a username the
// realm has updates that login, and anything else is added.
- (void)addLoginForURL:(NSURL*)url
              username:(NSString*)username
              password:(NSString*)password {
  GURL page = net::GURLWithNSURL(url);
  GURL::Replacements strip;
  strip.ClearUsername();
  strip.ClearPassword();
  strip.ClearQuery();
  strip.ClearRef();
  page = page.ReplaceComponents(strip);
  password_manager::PasswordFormDigest digest = DigestForURL(page);
  std::u16string name = base::SysNSStringToUTF16(username);
  std::u16string value = base::SysNSStringToUTF16(password);
  scoped_refptr<password_manager::PasswordStoreInterface> store =
      ProfilePasswordStoreFactory::GetForProfile(
          self.profile, ServiceAccessType::EXPLICIT_ACCESS);
  LoginsRequest::Start(
      self.profile, digest,
      base::BindOnce(
          [](scoped_refptr<password_manager::PasswordStoreInterface> store,
             GURL page, std::string realm, std::u16string name,
             std::u16string value, std::vector<StoredCredential> forms) {
            base::Time now = base::Time::Now();
            for (StoredCredential& form : forms) {
              if (form.signon_realm == realm && !form.blocked_by_user &&
                  form.username_value == name) {
                form.password_value =
                    password_manager::PasswordString(std::move(value));
                form.date_password_modified = now;
                form.date_last_used = now;
                store->UpdateLogin(std::move(form));
                return;
              }
            }
            StoredCredential form;
            form.url = page;
            form.signon_realm = realm;
            form.username_value = name;
            form.password_value =
                password_manager::PasswordString(std::move(value));
            form.type = password_manager::PasswordForm::Type::kFormSubmission;
            form.date_created = now;
            form.date_password_modified = now;
            form.date_last_used = now;
            form.in_store = password_manager::PasswordForm::Store::kProfileStore;
            store->AddLogin(std::move(form));
          },
          store, page, digest.signon_realm, name, value));
}

@end

@implementation ECBrowserContext (Cookies)

- (void)cookiesForDomains:(NSArray<NSString*>*)domains
               completion:(void (^)(NSArray<ECCookie*>*))completion {
  NSArray<NSString*>* scope = [domains copy];
  self.profile->GetDefaultStoragePartition()
      ->GetCookieManagerForBrowserProcess()
      ->GetAllCookies(base::BindOnce(
          ^(const std::vector<net::CanonicalCookie>& all) {
            base::Time now = base::Time::Now();
            NSMutableArray<ECCookie*>* cookies = [NSMutableArray array];
            for (const net::CanonicalCookie& cookie : all) {
              if (!cookie.IsPartitioned() && !cookie.IsExpired(now) &&
                  CookieIsUnderDomains(cookie, scope)) {
                [cookies addObject:[[ECCookie alloc]
                                       initWithCanonicalCookie:cookie]];
              }
            }
            completion(cookies);
          }));
}

// DeleteCanonicalCookie deletes only a cookie whose value is unchanged, so
// this deletes the stored cookies with the given keys.
- (void)deleteCookies:(NSArray<ECCookie*>*)cookies
           completion:(void (^)(NSInteger))completion {
  std::vector<std::tuple<std::string, std::string, std::string>> keys;
  for (ECCookie* cookie in cookies) {
    keys.emplace_back(base::SysNSStringToUTF8(cookie.name),
                      base::SysNSStringToUTF8(cookie.domain),
                      base::SysNSStringToUTF8(cookie.path));
  }
  network::mojom::CookieManager* manager =
      self.profile->GetDefaultStoragePartition()
          ->GetCookieManagerForBrowserProcess();
  manager->GetAllCookies(base::BindOnce(
      [](network::mojom::CookieManager* manager,
         std::vector<std::tuple<std::string, std::string, std::string>> keys,
         void (^completion)(NSInteger),
         const std::vector<net::CanonicalCookie>& all) {
        std::vector<const net::CanonicalCookie*> matches;
        for (const net::CanonicalCookie& cookie : all) {
          if (!cookie.IsPartitioned() &&
              std::ranges::find(keys, std::make_tuple(cookie.Name(),
                                                      cookie.Domain(),
                                                      cookie.Path())) !=
                  keys.end()) {
            matches.push_back(&cookie);
          }
        }
        if (matches.empty()) {
          completion(0);
          return;
        }
        auto done = base::BarrierCallback<bool>(
            matches.size(), base::BindOnce(^(std::vector<bool> results) {
              completion(std::ranges::count(results, true));
            }));
        for (const net::CanonicalCookie* cookie : matches) {
          manager->DeleteCanonicalCookie(*cookie, done);
        }
      },
      base::Unretained(manager), std::move(keys), completion));
}

@end
