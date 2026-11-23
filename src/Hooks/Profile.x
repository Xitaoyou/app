//
//  Profile.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Hide premium offer

%hook T1ProfileSummaryView

- (BOOL)shouldShowGetVerifiedButton {
    return [BHTSettings boolForKey:@"hide_premium_offer"] ? NO : %orig;
}

%end

// MARK: - Show unrounded follower/following counts

%hook T1ProfileFriendsFollowingViewModel

- (id)_t1_followCountTextWithLabel:(__unsafe_unretained id)label
                     singularLabel:(__unsafe_unretained id)singularLabel
                             count:(NSNumber*)count
                       highlighted:(BOOL)highlighted {
    id original = %orig;
    if (![BHTSettings boolForKey:@"show_unrounded_counts"]) {
        return original;
    }

    if (![count isKindOfClass:[NSNumber class]] ||
        ![original isKindOfClass:[NSAttributedString class]]) {
        return original;
    }

    NSString* abbreviated = [count tfs_twitterAbbreviated];
    NSNumberFormatter* formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSString* fullCount = [formatter stringFromNumber:count];

    if (!abbreviated.length || !fullCount.length || [abbreviated isEqualToString:fullCount]) {
        return original;
    }

    NSRange range = [[original string] rangeOfString:abbreviated];
    if (range.location == NSNotFound) {
        return original;
    }

    NSMutableAttributedString* expanded = [original mutableCopy];
    [expanded replaceCharactersInRange:range withString:fullCount];
    return [expanded copy];
}

%end

// MARK: - Show unrounded tweet/post count

%hook T1ProfileDisplayNormalMainContentProvider

- (id)_tweetsSubtitle {
    id original = %orig;

    if (![BHTSettings boolForKey:@"show_unrounded_counts"]) {
        return original;
    }

    NSNumber* count = self.viewModel.tweetCount;
    if (![count isKindOfClass:[NSNumber class]] || ![original isKindOfClass:[NSString class]]) {
        return original;
    }

    NSString* abbreviated = [count tfs_twitterAbbreviated];
    NSNumberFormatter* formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSString* fullCount = [formatter stringFromNumber:count];

    if (!abbreviated.length || !fullCount.length || [abbreviated isEqualToString:fullCount]) {
        return original;
    }

    NSRange range = [(NSString*)original rangeOfString:abbreviated];
    if (range.location == NSNotFound) {
        return original;
    }

    return [(NSString*)original stringByReplacingCharactersInRange:range withString:fullCount];
}

%end
