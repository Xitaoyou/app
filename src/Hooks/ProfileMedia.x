//
//  ProfileMedia.x
//  NeoFreeBird
//
//  Replace the split Photos and Videos profile entries with one Posts-backed
//  Media timeline. Timeline.x filters its original cards by status media and
//  advances short pages through the existing URT scroll delegate.
//

#import "HookHelpers.h"

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

// Reuse an entry initialized by the native provider.
static T1ProfileContentMainEntry* ProfileMediaEntryForProvider(
    T1ProfileDisplayNormalMainContentProvider* provider) {
    Class entryClass = objc_getClass("T1ProfileContentMainEntry");
    if (!entryClass ||
        ![entryClass instancesRespondToSelector:@selector(setTitle:)] ||
        ![entryClass instancesRespondToSelector:@selector(setViewControllerCreateBlock:)]) {
        return nil;
    }

    id photoEntry = ProfileMediaObjectValue(provider, @selector(photoEntry));
    id videoEntry = ProfileMediaObjectValue(provider, @selector(videoEntry));
    id mediaEntry = [photoEntry isKindOfClass:entryClass] ? photoEntry :
                    ([videoEntry isKindOfClass:entryClass] ? videoEntry : nil);
    if (!mediaEntry) {
        return nil;
    }

    // The native Tweets & replies entry covers media the profile owner
    // posted in replies as well as standalone posts.
    SEL repliesEntrySelector = NSSelectorFromString(@"tweetsAndRepliesEntry");
    id postsEntry = ProfileMediaObjectValue(provider, repliesEntrySelector);
    if (!postsEntry) {
        postsEntry = ProfileMediaObjectValue(provider, @selector(allPostsEntry));
    }
    id originalFactory =
        ProfileMediaObjectValue(postsEntry, @selector(viewControllerCreateBlock));
    if (!postsEntry || !originalFactory ||
        ![postsEntry respondsToSelector:@selector(viewControllerCreateBlock)]) {
        return nil;
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

// contentMainEntries is an array of entry groups. The profile controller
// indexes the outer array, then sends -indexOfObject: to the selected group.
// Keep that two-level shape while replacing the split media entries.
static NSArray* ProfileMediaMergedMainEntries(
    T1ProfileDisplayNormalMainContentProvider* provider, id originalEntries) {
    if (![originalEntries isKindOfClass:[NSArray class]]) {
        return originalEntries;
    }
    for (id group in originalEntries) {
        if (![group isKindOfClass:[NSArray class]]) {
            return originalEntries;
        }
    }

    T1ProfileContentMainEntry* mediaEntry = ProfileMediaEntryForProvider(provider);
    if (!mediaEntry) {
        return originalEntries;
    }

    id photoEntry = ProfileMediaObjectValue(provider, @selector(photoEntry));
    id videoEntry = ProfileMediaObjectValue(provider, @selector(videoEntry));
    id postsEntry = ProfileMediaObjectValue(provider, @selector(allPostsEntry));
    NSMutableArray* groups = [NSMutableArray arrayWithCapacity:[originalEntries count]];
    BOOL insertedMedia = NO;
    NSUInteger fallbackOuterIndex = NSNotFound;

    for (NSArray* group in originalEntries) {
        NSMutableArray* filteredGroup = [NSMutableArray arrayWithCapacity:[group count]];
        BOOL containsPosts = NO;
        for (id entry in group) {
            if (entry == postsEntry) {
                containsPosts = YES;
            }
            if (ProfileMediaEntryIsSplitMedia(entry, photoEntry, videoEntry)) {
                if (!insertedMedia) {
                    [filteredGroup addObject:mediaEntry];
                    insertedMedia = YES;
                }
                continue;
            }
            [filteredGroup addObject:entry];
        }
        if ([filteredGroup count] > 0) {
            [groups addObject:[filteredGroup copy]];
            if (containsPosts) {
                fallbackOuterIndex = [groups count];
            }
        }
    }

    if (!insertedMedia) {
        // Profiles without native media entries still get their own Media tab.
        NSUInteger index = fallbackOuterIndex == NSNotFound
                              ? [groups count] : fallbackOuterIndex;
        [groups insertObject:@[mediaEntry] atIndex:index];
    }
    return [groups copy];
}

%hook T1ProfileDisplayNormalMainContentProvider

- (id)contentMainEntries {
    return ProfileMediaMergedMainEntries(self, %orig);
}

%end
