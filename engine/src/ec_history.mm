#import "engine_core/ec_browser_context_private.h"

#include "base/apple/foundation_util.h"
#include "base/functional/bind.h"
#include "base/memory/ref_counted_memory.h"
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
#include "chrome/browser/profiles/profile.h"
#include "components/keyed_service/core/service_access_type.h"
#include "net/base/apple/url_conversions.h"
#include "ui/gfx/geometry/size.h"
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

- (void)addVisitToURL:(NSURL*)url title:(NSString*)title {
  if (self.profile->IsOffTheRecord()) {
    return;
  }
  GURL page = net::GURLWithNSURL(url);
  history::HistoryService* history = HistoryServiceFactory::GetForProfile(
      self.profile, ServiceAccessType::EXPLICIT_ACCESS);
  history->AddPage(page, base::Time::Now(), history::SOURCE_BROWSED);
  history->SetPageTitle(page, base::SysNSStringToUTF16(title));
}

// MergeFavicon replaces the bitmap of the image's pixel size and keeps the
// page's others.
- (void)setFavicon:(NSImage*)image
           iconURL:(NSURL*)iconURL
        forPageURL:(NSURL*)pageURL {
  if (self.profile->IsOffTheRecord()) {
    return;
  }
  CGImageRef bitmap = [image CGImageForProposedRect:nullptr
                                            context:nil
                                              hints:nil];
  if (!bitmap) {
    return;
  }
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:bitmap];
  NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG
                                  properties:@{}];
  FaviconServiceFactory::GetForProfile(self.profile,
                                       ServiceAccessType::EXPLICIT_ACCESS)
      ->MergeFavicon(net::GURLWithNSURL(pageURL), net::GURLWithNSURL(iconURL),
                     favicon_base::IconType::kFavicon,
                     base::MakeRefCounted<base::RefCountedBytes>(
                         base::apple::NSDataToSpan(png)),
                     gfx::Size(rep.pixelsWide, rep.pixelsHigh));
}

@end
