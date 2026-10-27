#import "engine_core/ec_browser_context_private.h"

#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/cancelable_task_tracker.h"
#include "base/time/time.h"
#include "chrome/browser/favicon/favicon_service_factory.h"
#include "chrome/browser/history/history_service_factory.h"
#include "components/favicon/core/favicon_service.h"
#include "components/favicon_base/favicon_types.h"
#include "components/history/core/browser/history_backend.h"
#include "components/history/core/browser/history_service.h"
#include "components/keyed_service/core/service_access_type.h"
#include "net/base/apple/url_conversions.h"
#include "url/gurl.h"

@implementation ECHistoryEntry

@synthesize URLString = _URLString;
@synthesize title = _title;
@synthesize visitCount = _visitCount;
@synthesize typedCount = _typedCount;
@synthesize lastVisit = _lastVisit;

- (instancetype)initWithURLString:(NSString*)URLString
                            title:(NSString*)title
                       visitCount:(NSInteger)visitCount
                       typedCount:(NSInteger)typedCount
                        lastVisit:(NSDate*)lastVisit {
  if ((self = [super init])) {
    _URLString = [URLString copy];
    _title = [title copy];
    _visitCount = visitCount;
    _typedCount = typedCount;
    _lastVisit = lastVisit;
  }
  return self;
}

@end

@implementation ECBrowserContext (History)

- (NSInteger)importHistory:(NSArray<ECHistoryEntry*>*)entries {
  // HistoryBackend drops visits older than it keeps.
  base::Time cutoff = base::Time::Now() -
                      base::Days(history::HistoryBackend::kExpireDaysThreshold);
  history::URLRows rows;
  for (ECHistoryEntry* entry in entries) {
    GURL url(base::SysNSStringToUTF8(entry.URLString));
    base::Time lastVisit = base::Time::FromNSDate(entry.lastVisit);
    if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || lastVisit < cutoff) {
      continue;
    }
    history::URLRow& row = rows.emplace_back(url);
    row.set_title(base::SysNSStringToUTF16(entry.title));
    row.set_visit_count(entry.visitCount);
    row.set_typed_count(entry.typedCount);
    row.set_last_visit(lastVisit);
  }
  // The source Chrome gives history imported from another browser.
  HistoryServiceFactory::GetForProfile(self.profile,
                                       ServiceAccessType::EXPLICIT_ACCESS)
      ->AddPagesWithDetails(rows, history::SOURCE_OS_MIGRATION_IMPORTED);
  return rows.size();
}

// As Chrome's omnibox gets its matches' favicons. The requests are never
// cancelled.
- (void)faviconForPageURL:(NSURL*)URL
               completion:(void (^)(NSImage*))completion {
  static base::NoDestructor<base::CancelableTaskTracker> tracker;
  FaviconServiceFactory::GetForProfile(self.profile,
                                       ServiceAccessType::EXPLICIT_ACCESS)
      ->GetFaviconImageForPageURL(
          net::GURLWithNSURL(URL),
          base::BindOnce(^(const favicon_base::FaviconImageResult& result) {
            completion(result.image.IsEmpty() ? nil : result.image.ToNSImage());
          }),
          tracker.get());
}

@end
