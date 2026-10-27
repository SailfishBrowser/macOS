#import "engine_core/ec_browser_context_private.h"

#include <algorithm>

#include "base/barrier_callback.h"
#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/keyed_service/core/service_access_type.h"
#include "components/password_manager/core/browser/import/csv_password_sequence.h"
#include "components/password_manager/core/browser/password_manager_util.h"
#include "components/password_manager/core/browser/password_store/password_store_interface.h"
#include "components/password_manager/core/browser/password_store/stored_credential.h"
#include "content/public/browser/storage_partition.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_access_result.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_util.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "url/gurl.h"

@implementation ECPassword

@synthesize URLString = _URLString;
@synthesize username = _username;
@synthesize password = _password;

- (instancetype)initWithURLString:(NSString*)URLString
                         username:(NSString*)username
                         password:(NSString*)password {
  if ((self = [super init])) {
    _URLString = [URLString copy];
    _username = [username copy];
    _password = [password copy];
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

@end

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

@end
