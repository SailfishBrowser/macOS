#import "engine_core/EngineCore.h"

#include <memory>

#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_provider_client.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_scheme_classifier.h"
#include "chrome/browser/autocomplete/shortcuts_backend_factory.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "components/omnibox/browser/autocomplete_classifier.h"
#include "components/omnibox/browser/autocomplete_controller.h"
#include "components/omnibox/browser/autocomplete_controller_config.h"
#include "components/omnibox/browser/autocomplete_enums.h"
#include "components/omnibox/browser/autocomplete_input.h"
#include "components/omnibox/browser/autocomplete_match.h"
#include "components/omnibox/browser/shortcuts_backend.h"
#include "components/search_engines/template_url.h"
#include "components/search_engines/template_url_service.h"
#import "engine_core/ec_browser_context_private.h"
#include "net/base/apple/url_conversions.h"
#include "third_party/metrics_proto/omnibox_event.pb.h"

@interface ECAutocompleteMatch ()
@property(readonly) const AutocompleteMatch& match;
@end

@implementation ECAutocompleteMatch {
  AutocompleteMatch _match;
}

@synthesize associatedKeywordName = _associatedKeywordName;

- (instancetype)initWithMatch:(const AutocompleteMatch&)match
                      engines:(TemplateURLService*)engines {
  if ((self = [super init])) {
    _match = match;
    if (const TemplateURL* engine =
            engines->GetTemplateURLForKeyword(match.associated_keyword)) {
      _associatedKeywordName = base::SysUTF16ToNSString(engine->short_name());
    }
  }
  return self;
}

- (const AutocompleteMatch&)match {
  return _match;
}

- (NSString*)contents {
  return base::SysUTF16ToNSString(_match.contents);
}

- (NSString*)matchDescription {
  return base::SysUTF16ToNSString(_match.description);
}

- (NSURL*)destinationURL {
  return net::NSURLWithGURL(_match.destination_url);
}

- (ECAutocompleteMatchType)type {
  using Type = omnibox::AutocompleteMatchType;
  if (AutocompleteMatch::IsSearchType(_match.type)) {
    return ECAutocompleteMatchTypeSearch;
  }
  switch (_match.type) {
    case Type::kBookmarkTitle:
      return ECAutocompleteMatchTypeBookmark;
    case Type::kHistoryUrl:
    case Type::kHistoryTitle:
    case Type::kHistoryBody:
    case Type::kHistoryKeyword:
    case Type::kHistoryEmbeddings:
      return ECAutocompleteMatchTypeHistory;
    default:
      return ECAutocompleteMatchTypeURL;
  }
}

- (BOOL)allowedToBeDefault {
  return _match.allowed_to_be_default_match;
}

- (NSString*)inlineAutocompletion {
  return base::SysUTF16ToNSString(_match.inline_autocompletion);
}

- (NSString*)associatedKeyword {
  return _associatedKeywordName
             ? base::SysUTF16ToNSString(_match.associated_keyword)
             : nil;
}

@end

@interface ECAutocomplete ()
- (void)resultChanged;
@end

namespace {

class Observer : public AutocompleteController::Observer {
 public:
  explicit Observer(ECAutocomplete* owner) : owner_(owner) {}

  void OnResultChanged(AutocompleteController* controller,
                       bool default_match_changed) override {
    [owner_ resultChanged];
  }

 private:
  __weak ECAutocomplete* owner_;
};

}  // namespace

@implementation ECAutocomplete {
  ECBrowserContext* _context;
  std::unique_ptr<Observer> _observer;
  std::unique_ptr<AutocompleteController> _controller;
}

@synthesize delegate = _delegate;

- (instancetype)initWithBrowserContext:(ECBrowserContext*)context {
  if ((self = [super init])) {
    _context = context;
    _observer = std::make_unique<Observer>(self);
    // The providers of Chrome's omnibox.
    _controller = std::make_unique<AutocompleteController>(
        std::make_unique<ChromeAutocompleteProviderClient>(_context.profile),
        AutocompleteControllerConfig{
            .provider_types =
                AutocompleteClassifier::DefaultOmniboxProviders()});
    _controller->AddObserver(_observer.get());
    [context.autocompletes addObject:self];
  }
  return self;
}

- (void)startWithText:(NSString*)text {
  [self startWithText:text keyword:nil];
}

// Chrome's omnibox in keyword mode queries "<keyword> <text>".
- (void)startWithText:(NSString*)text keyword:(NSString*)keyword {
  AutocompleteInput input(
      base::SysNSStringToUTF16(
          keyword ? [NSString stringWithFormat:@"%@ %@", keyword, text] : text),
      metrics::OmniboxEventProto::OTHER,
      ChromeAutocompleteSchemeClassifier(_context.profile));
  input.set_in_keyword_mode(keyword != nil);
  _controller->Start(input);
}

- (void)stop {
  _controller->Stop(AutocompleteStopReason::kClobbered);
}

- (void)didSelectMatch:(ECAutocompleteMatch*)match {
  // As Chrome's omnibox does on a navigation it started. None in incognito.
  if (scoped_refptr<ShortcutsBackend> shortcuts =
          ShortcutsBackendFactory::GetForProfile(_context.profile)) {
    shortcuts->AddOrUpdateShortcut(_controller->input().text(), match.match);
  }
}

- (void)resultChanged {
  NSMutableArray<ECAutocompleteMatch*>* matches = [NSMutableArray array];
  TemplateURLService* engines =
      TemplateURLServiceFactory::GetForProfile(_context.profile);
  for (const AutocompleteMatch& match : _controller->result()) {
    // Some matches, such as on a new profile, lead nowhere.
    if (!match.destination_url.is_valid()) {
      continue;
    }
    [matches addObject:[[ECAutocompleteMatch alloc] initWithMatch:match
                                                          engines:engines]];
  }
  [_delegate autocomplete:self
         didUpdateMatches:matches
                     done:_controller->done()];
}

// The providers use the profile's services, which go with it.
- (void)close {
  _controller.reset();
}

@end
