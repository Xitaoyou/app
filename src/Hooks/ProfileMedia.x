//
// ProfileMedia.x
// Merge the native Photos and Videos timelines. Each native controller keeps
// its own query, cursor objects, adapters and loading lifecycle.
//

#import "HookHelpers.h"
#include <limits.h>

static const void* NativeMediaPairKey = &NativeMediaPairKey;
static const void* NativeMediaFactoryKey = &NativeMediaFactoryKey;
static const void* NativeMediaOptionsKey = &NativeMediaOptionsKey;
static const void* NativeMediaConfiguredKey = &NativeMediaConfiguredKey;

static id MediaValue(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void MediaSetValue(id object, SEL selector, id value) {
    if (object && [object respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
    }
}

static unsigned long long NativeMediaStatusID(id item) {
    id model = unwrapDataViewItem(item);
    if (![model respondsToSelector:@selector(statusID)]) return 0;
    return ((unsigned long long (*)(id, SEL))objc_msgSend)(model, @selector(statusID));
}

@interface NFBProfileMediaRow : NSObject
@property (nonatomic, strong) id item;
@property (nonatomic) unsigned long long order;
@property (nonatomic) NSUInteger source;
@property (nonatomic) NSUInteger position;
@end
@implementation NFBProfileMediaRow
@end

@interface NFBProfileMediaPair : NSObject
@property (nonatomic, weak) UIViewController* photos;
@property (nonatomic, weak) UIViewController* videos;
@property (nonatomic, copy) NSArray* photoSections;
@property (nonatomic, copy) NSArray* videoSections;
@property (nonatomic) BOOL publishing;
@property (nonatomic) BOOL publishPending;
@property (nonatomic) NSUInteger displayDepth;
@property (nonatomic) NSTimeInterval lastRefresh;
- (NSArray*)mergedSections;
- (void)schedulePublish;
- (void)refreshVideos:(id)sender;
@end

// Use the source's native adapter, especially for cursor rows: its
// adapterWasUsedByURTViewController: binding must continue to target that
// source's loader, not the other media query.
static id NativeMediaWrappedItem(id item, UIViewController* source,
                                 NSUInteger sourceIndex, NSUInteger position,
                                 UIViewController* presentation) {
    id model = unwrapDataViewItem(item);
    Class wrapperClass = objc_getClass("TFNDataViewItem");
    if (!wrapperClass) return item;
    id wrapper = ((id (*)(id, SEL, id))objc_msgSend)(
        [wrapperClass alloc], @selector(initWithItem:), model);
    if (!wrapper) return item;

    BOOL nativeWrapper = [item isKindOfClass:wrapperClass];
    id adapter = nativeWrapper ? MediaValue(item, @selector(dataViewAdapter)) : nil;
    SEL adapterSelector = @selector(registeredDataViewAdapterForItem:);
    if (!adapter && [source respondsToSelector:adapterSelector]) {
        adapter = ((id (*)(id, SEL, id))objc_msgSend)(source, adapterSelector, model);
    }
    // Both native queries produce URTTimelineStatusItemViewModel. The Videos
    // controller registers ProfileVideoTableAdapter for that same model, which
    // renders the compact video list. Resolve the Photos controller's standard
    // tweet adapter for video posts; cursors keep their source-bound adapter.
    Class statusClass = objc_getClass("URTTimelineStatusItemViewModel");
    Class postAdapterClass = objc_getClass("T1StatusTableRowAdapter");
    if (sourceIndex == 1 && statusClass && [model isKindOfClass:statusClass] &&
        postAdapterClass && [presentation respondsToSelector:adapterSelector]) {
        id postAdapter = ((id (*)(id, SEL, id))objc_msgSend)(
            presentation, adapterSelector, model);
        if ([postAdapter isKindOfClass:postAdapterClass]) adapter = postAdapter;
    }
    MediaSetValue(wrapper, @selector(setDataViewAdapter:), adapter);
    if (nativeWrapper) {
        MediaSetValue(wrapper, @selector(setSectionController:),
                      MediaValue(item, @selector(sectionController)));
    }

    id options = nativeWrapper ? MediaValue(item, @selector(options)) : nil;
    if (options) objc_setAssociatedObject(wrapper, NativeMediaOptionsKey, options,
                                          OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    unsigned long long statusID = NativeMediaStatusID(item);
    id nativeID = (nativeWrapper ? MediaValue(item, @selector(objectIdentifier)) : nil) ?:
                  MediaValue(model, @selector(entryID));
    NSString* identifier = statusID
        ? [NSString stringWithFormat:@"nfb.media.post.%llu", statusID]
        : [NSString stringWithFormat:@"nfb.media.row.%lu.%@", (unsigned long)sourceIndex,
              nativeID ?: [NSString stringWithFormat:@"%p.%lu", model, (unsigned long)position]];
    MediaSetValue(wrapper, @selector(setObjectIdentifier:), identifier);
    return wrapper;
}

@implementation NFBProfileMediaPair

- (NSArray*)mergedSections {
    NSMutableArray<NFBProfileMediaRow*>* rows = [NSMutableArray array];
    NSMutableSet<NSNumber*>* seenPosts = [NSMutableSet set];
    NSArray* sources = @[self.photoSections ?: @[], self.videoSections ?: @[]];
    NSArray* controllers = @[self.photos ?: (id)[NSNull null],
                             self.videos ?: (id)[NSNull null]];

    for (NSUInteger sourceIndex = 0; sourceIndex < sources.count; sourceIndex++) {
        UIViewController* controller = controllers[sourceIndex];
        if ((id)controller == [NSNull null]) continue;
        NSArray* sections = sources[sourceIndex];
        NSMutableArray* sourceItems = [NSMutableArray array];
        for (id section in sections) {
            if ([section isKindOfClass:[NSArray class]]) [sourceItems addObjectsFromArray:section];
        }
        unsigned long long previousPost = ULLONG_MAX;
        for (NSUInteger position = 0; position < sourceItems.count; position++) {
            id item = sourceItems[position];
            unsigned long long statusID = NativeMediaStatusID(item);
            // Preserve every native row, including source-specific media and
            // pagination models. Only a known duplicate post ID is removed.
            if (statusID) {
                previousPost = statusID;
                NSNumber* key = @(statusID);
                if ([seenPosts containsObject:key]) continue;
                [seenPosts addObject:key];
            }
            NFBProfileMediaRow* row = [NFBProfileMediaRow new];
            row.item = NativeMediaWrappedItem(item, controller, sourceIndex, position, self.photos);
            row.order = statusID ? statusID :
                (previousPost == ULLONG_MAX ? ULLONG_MAX : previousPost - 1);
            row.source = sourceIndex;
            row.position = position;
            [rows addObject:row];
        }
    }
    if (rows.count == 0) return self.photoSections ?: @[];
    [rows sortUsingComparator:^NSComparisonResult(id left, id right) {
        NFBProfileMediaRow* a = left;
        NFBProfileMediaRow* b = right;
        if (a.order != b.order) return a.order > b.order ? NSOrderedAscending : NSOrderedDescending;
        if (a.source != b.source) return a.source < b.source ? NSOrderedAscending : NSOrderedDescending;
        if (a.position == b.position) return NSOrderedSame;
        return a.position < b.position ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSMutableArray* items = [NSMutableArray arrayWithCapacity:rows.count];
    for (NFBProfileMediaRow* row in rows) [items addObject:row.item];
    return @[[items copy]];
}

- (void)schedulePublish {
    if (self.publishPending) return;
    self.publishPending = YES;
    __weak NFBProfileMediaPair* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NFBProfileMediaPair* pair = weakSelf;
        if (!pair) return;
        pair.publishPending = NO;
        UIViewController* photos = pair.photos;
        SEL setter = @selector(setSections:restoreScrollPosition:);
        if (!photos || ![photos respondsToSelector:setter]) return;
        pair.publishing = YES;
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(photos, setter, [pair mergedSections], YES);
        pair.publishing = NO;
    });
}

- (void)refreshVideos:(id)sender {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastRefresh < 0.25) return;
    self.lastRefresh = now;
    id videos = self.videos;
    SEL loadingSelector = @selector(isLoadingTop);
    if ([videos respondsToSelector:loadingSelector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(videos, loadingSelector)) return;
    SEL loadSelector = @selector(loadTop:);
    if ([videos respondsToSelector:loadSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(videos, loadSelector, sender);
    }
}
@end

// nil means this is not one of the two native Media sources. Native input
// sections are retained separately from the visible merged presentation.
NSArray* BHProfileMediaNativeSections(id controller, NSArray* sections) {
    NFBProfileMediaPair* pair = objc_getAssociatedObject(controller, NativeMediaPairKey);
    if (!pair) return nil;
    if (pair.publishing || pair.displayDepth > 0) return sections ?: @[];
    if (controller == pair.photos) {
        pair.photoSections = sections ?: @[];
        return [pair mergedSections];
    }
    pair.videoSections = sections ?: @[];
    [pair schedulePublish];
    return sections ?: @[];
}

void BHProfileMediaWillApplySections(id controller) {
    NFBProfileMediaPair* pair = objc_getAssociatedObject(controller, NativeMediaPairKey);
    if (pair) pair.displayDepth++;
}

void BHProfileMediaDidApplySections(id controller) {
    NFBProfileMediaPair* pair = objc_getAssociatedObject(controller, NativeMediaPairKey);
    if (pair.displayDepth > 0) pair.displayDepth--;
}

id BHProfileMediaReconfigureIdentifiers(NSArray* sections, id nativeIdentifiers) {
    if (!nativeIdentifiers) return nil;
    NSMutableArray* identifiers = [NSMutableArray array];
    for (NSArray* section in sections) {
        for (id item in section) {
            id identifier = MediaValue(item, @selector(objectIdentifier));
            if (identifier) [identifiers addObject:identifier];
        }
    }
    return [nativeIdentifiers isKindOfClass:[NSSet class]]
               ? (id)[NSSet setWithArray:identifiers] : (id)[identifiers copy];
}

static UIViewController* NativeMediaViewController(id (^photosFactory)(void),
                                                  id (^videosFactory)(void)) {
    UIViewController* photos = photosFactory();
    UIViewController* videos = videosFactory();
    Class dataClass = objc_getClass("TFNItemsDataViewController");
    if (!dataClass || ![photos isKindOfClass:dataClass] || ![videos isKindOfClass:dataClass] ||
        photos == videos) return photos;

    NFBProfileMediaPair* pair = [NFBProfileMediaPair new];
    pair.photos = photos;
    pair.videos = videos;
    pair.photoSections = MediaValue(photos, @selector(sections)) ?: @[];
    pair.videoSections = MediaValue(videos, @selector(sections)) ?: @[];
    objc_setAssociatedObject(photos, NativeMediaPairKey, pair, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(videos, NativeMediaPairKey, pair, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SEL scrollEventsSelector = @selector(setTfn_sendContentScrollEventsToParentViewController:);
    if ([videos respondsToSelector:scrollEventsSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(videos, scrollEventsSelector, NO);
    }
    [photos addChildViewController:videos];
    [photos loadViewIfNeeded];
    [videos loadViewIfNeeded];
    videos.view.frame = photos.view.bounds;
    videos.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    videos.view.hidden = YES;
    videos.view.userInteractionEnabled = NO;
    videos.view.accessibilityElementsHidden = YES;
    [photos.view addSubview:videos.view];
    [videos didMoveToParentViewController:photos];
    [pair schedulePublish];
    return photos;
}

static NSString* ProfileMediaEntryTitle(id entry) {
    id title = MediaValue(entry, @selector(title));
    if (![title isKindOfClass:[NSString class]]) title = MediaValue(entry, @selector(menuTitle));
    return [title isKindOfClass:[NSString class]] ? title : nil;
}

static BOOL ProfileMediaEntryIsSplitMedia(id entry, id photoEntry, id videoEntry) {
    if (entry == photoEntry || entry == videoEntry) return YES;
    NSString* title = [ProfileMediaEntryTitle(entry) lowercaseString];
    return [title isEqualToString:@"photos"] || [title isEqualToString:@"photo"] ||
           [title isEqualToString:@"videos"] || [title isEqualToString:@"video"] ||
           [title isEqualToString:@"media"];
}

static id NativeMediaEntryFactory(id entry) {
    id factory = objc_getAssociatedObject(entry, NativeMediaFactoryKey);
    if (!factory) {
        factory = MediaValue(entry, @selector(viewControllerCreateBlock));
        if (factory) objc_setAssociatedObject(entry, NativeMediaFactoryKey, factory,
                                              OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return factory;
}

static T1ProfileContentMainEntry* ProfileMediaEntryForProvider(
    T1ProfileDisplayNormalMainContentProvider* provider) {
    id photoEntry = MediaValue(provider, @selector(photoEntry));
    id videoEntry = MediaValue(provider, @selector(videoEntry));
    if (!photoEntry || !videoEntry ||
        ![photoEntry respondsToSelector:@selector(setViewControllerCreateBlock:)]) return nil;
    if (objc_getAssociatedObject(photoEntry, NativeMediaConfiguredKey)) return photoEntry;
    id (^photosFactory)(void) = NativeMediaEntryFactory(photoEntry);
    id (^videosFactory)(void) = NativeMediaEntryFactory(videoEntry);
    if (!photosFactory || !videosFactory) return nil;
    id (^mediaFactory)(void) = ^{
        return NativeMediaViewController(photosFactory, videosFactory);
    };
    NSString* (^mediaTitle)(void) = ^NSString*{ return @"Media"; };
    MediaSetValue(photoEntry, @selector(setTitle:), @"Media");
    MediaSetValue(photoEntry, @selector(setTitleReturnBlock:), mediaTitle);
    MediaSetValue(photoEntry, @selector(setMenuTitle:), @"Media");
    MediaSetValue(photoEntry, @selector(setViewControllerCreateBlock:), mediaFactory);
    id cached = MediaValue(photoEntry, @selector(cachedViewControllerInstance));
    if (cached && !objc_getAssociatedObject(cached, NativeMediaPairKey) &&
        [photoEntry respondsToSelector:@selector(removeCachedViewControllerIfNeeded)]) {
        ((void (*)(id, SEL))objc_msgSend)(photoEntry, @selector(removeCachedViewControllerIfNeeded));
    }
    objc_setAssociatedObject(photoEntry, NativeMediaConfiguredKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return photoEntry;
}

// The profile controller requires an array of entry groups, not a flat array.
static NSArray* ProfileMediaMergedMainEntries(
    T1ProfileDisplayNormalMainContentProvider* provider, id originalEntries) {
    if (![originalEntries isKindOfClass:[NSArray class]]) return originalEntries;
    for (id group in originalEntries) {
        if (![group isKindOfClass:[NSArray class]]) return originalEntries;
    }
    id mediaEntry = ProfileMediaEntryForProvider(provider);
    if (!mediaEntry) return originalEntries;
    id photoEntry = MediaValue(provider, @selector(photoEntry));
    id videoEntry = MediaValue(provider, @selector(videoEntry));
    NSMutableArray* groups = [NSMutableArray array];
    BOOL insertedMedia = NO;
    for (NSArray* group in originalEntries) {
        NSMutableArray* entries = [NSMutableArray array];
        for (id entry in group) {
            if (ProfileMediaEntryIsSplitMedia(entry, photoEntry, videoEntry)) {
                if (!insertedMedia) { [entries addObject:mediaEntry]; insertedMedia = YES; }
            } else {
                [entries addObject:entry];
            }
        }
        if (entries.count) [groups addObject:[entries copy]];
    }
    if (!insertedMedia) [groups addObject:@[mediaEntry]];
    return [groups copy];
}

%hook T1ProfileDisplayNormalMainContentProvider
- (id)contentMainEntries {
    return ProfileMediaMergedMainEntries(self, %orig);
}
%end

%hook TFNDataViewItem
- (id)options {
    id options = objc_getAssociatedObject(self, NativeMediaOptionsKey);
    return options ?: %orig;
}
%end

%hook TFNDataViewController
- (void)_tfn_dynamic_didPullToLoadTop:(id)sender {
    NFBProfileMediaPair* pair = objc_getAssociatedObject(self, NativeMediaPairKey);
    if (self == pair.photos) [pair refreshVideos:sender];
    %orig;
}
- (void)loadTop:(id)sender {
    NFBProfileMediaPair* pair = objc_getAssociatedObject(self, NativeMediaPairKey);
    if (self == pair.photos) [pair refreshVideos:sender];
    %orig;
}
%end
