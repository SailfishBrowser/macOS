#import "engine_core/ec_browser_context_private.h"

#include "chrome/browser/profiles/profile.h"
#include "components/download/public/common/download_item.h"
#include "content/public/browser/download_manager.h"

@implementation ECBrowserContext (Downloads)

- (NSArray<ECDownload*>*)downloads {
  content::DownloadManager::DownloadVector items;
  self.profile->GetDownloadManager()->GetAllDownloads(&items);
  NSMutableArray<ECDownload*>* downloads = [NSMutableArray array];
  for (download::DownloadItem* item : items) {
    [downloads addObject:[[ECDownload alloc] initWithItem:item]];
  }
  return downloads;
}

- (void)cancelDownload:(uint32_t)identifier {
  download::DownloadItem* item =
      self.profile->GetDownloadManager()->GetDownload(identifier);
  if (item && item->GetState() == download::DownloadItem::IN_PROGRESS) {
    item->Cancel(/*user_cancel=*/true);
  }
}

@end
