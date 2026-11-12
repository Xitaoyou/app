//
//  ProfileMedia.x
//  NeoFreeBird
//
//  Replace the split Photos and Videos profile entries with one Posts-backed
//  Media timeline. Timeline.x filters its original cards by status media and
//  advances short pages through the existing URT scroll delegate.
//

#import "HookHelpers.h"

static const void* ProfileMediaEntryKey = &ProfileMediaEntryKey;

static id ProfileMediaObjectValue(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void ProfileMediaSetObjectValue(id object, SEL selector, id value) {
    if (object && [object respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
    }
}

static NSString* ProfileMediaEntryTitle(id entry) {
    id title = ProfileMediaObjectValue(entry, @selector(title));
    if (![title isKindOfClass:[NSString class]]) {
        title = ProfileMediaObjectValue(entry, @selector(menuTitle));
    }
    return [title isKindOfClass:[NSString class]] ? title : nil;
}

static BOOL ProfileMediaEntryIsSplitMedia(id entry, id photoEntry, id videoEntry) {
    if (entry == photoEntry || entry == videoEntry) {
        return YES;
    }

    NSString* title = [ProfileMediaEntryTitle(entry) lowercaseString];
    return [title isEqualToString:@"photos"] || [title isEqualToString:@"photo"] ||
           [title isEqualToString:@"videos"] || [title isEqualToString:@"video"] ||
           [title isEqualToString:@"media"];
}

static T1ProfileContentMainEntry* ProfileMediaEntryForProvider(
    T1ProfileDisplayNormalMainContentProvider* provider) {
    T1ProfileContentMainEntry* mediaEntry =
        objc_getAssociatedObject(provider, ProfileMediaEntryKey);
    Class entryClass = objc_getClass("T1ProfileContentMainEntry");
    if (!entryClass || ![entryClass instancesRespondToSelector:@selector(setTitle:)] ||
        ![entryClass instancesRespondToSelector:@selector(setViewControllerCreateBlock:)]) {
        return nil;
    }

    id postsEntry = ProfileMediaObjectValue(provider, @selector(allPostsEntry));
    id originalFactory =
        ProfileMediaObjectValue(postsEntry, @selector(viewControllerCreateBlock));
    if (!postsEntry || !originalFactory ||
        ![postsEntry respondsToSelector:@selector(viewControllerCreateBlock)]) {
        return nil;
    }

    if (!mediaEntry) {
        mediaEntry = [[entryClass alloc] init];
        if (!mediaEntry) {
            return nil;
        }
        objc_setAssociatedObject(provider, ProfileMediaEntryKey, mediaEntry,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    id (^postsFactory)(void) = originalFactory;
    id (^mediaFactory)(void) = ^{
        UIViewController* timeline = postsFactory();
        BHTagProfileMediaTimeline(timeline);
        return timeline;
    };
    NSString* (^mediaTitle)(void) = ^NSString*{
        return @"Media";
    };

    ProfileMediaSetObjectValue(mediaEntry, @selector(setTitle:), @"Media");
    ProfileMediaSetObjectValue(mediaEntry, @selector(setTitleReturnBlock:), mediaTitle);
    ProfileMediaSetObjectValue(mediaEntry, @selector(setMenuTitle:), @"Media");
    ProfileMediaSetObjectValue(mediaEntry, @selector(setViewControllerCreateBlock:), mediaFactory);
    return mediaEntry;
}

static NSArray* ProfileMediaMergedMainEntries(
    T1ProfileDisplayNormalMainContentProvider* provider, id originalEntries) {
    if (![originalEntries isKindOfClass:[NSArray class]]) {
        return originalEntries;
    }

    T1ProfileContentMainEntry* mediaEntry = ProfileMediaEntryForProvider(provider);
    if (!mediaEntry) {
        return originalEntries;
    }

    id photoEntry = ProfileMediaObjectValue(provider, @selector(photoEntry));
    id videoEntry = ProfileMediaObjectValue(provider, @selector(videoEntry));
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:[originalEntries count]];
    NSUInteger insertionIndex = NSNotFound;
    NSUInteger fallbackIndex = 0;
    NSArray<NSString*>* anchorSelectors =
        @[@"allPostsEntry", @"tweetsOnlyEntry", @"tweetsAndRepliesEntry"];

    for (NSUInteger index = 0; index < [originalEntries count]; index++) {
        id entry = originalEntries[index];
        if (ProfileMediaEntryIsSplitMedia(entry, photoEntry, videoEntry)) {
            if (insertionIndex == NSNotFound) {
                insertionIndex = result.count;
            }
            continue;
        }

        [result addObject:entry];
        for (NSString* selectorName in anchorSelectors) {
            id anchor = ProfileMediaObjectValue(provider, NSSelectorFromString(selectorName));
            if (anchor && entry == anchor) {
                fallbackIndex = result.count;
            }
        }
    }

    if (insertionIndex == NSNotFound) {
        insertionIndex = fallbackIndex;
    }
    insertionIndex = MIN(insertionIndex, result.count);
    [result insertObject:mediaEntry atIndex:insertionIndex];
    return [result copy];
}

%hook T1ProfileDisplayNormalMainContentProvider

- (id)contentMainEntries {
    return ProfileMediaMergedMainEntries(self, %orig);
}

%end
