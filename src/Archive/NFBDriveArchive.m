#import "NFBDriveArchive.h"
#import "NFBDriveAuth.h"
#import "Core/BHTManager.h"
#import "Headers/TFNHeaders.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>
#import "Hooks/HookHelpers.h"

static NSString * const Changed = @"NFBDriveArchiveChanged";
static const NSUInteger ChunkSize = 4 * 1024 * 1024;
static UIViewController *ArchiveTaskList(void);

static const char *ReturnType(id object, SEL selector) {
    Method method = object ? class_getInstanceMethod(object_getClass(object), selector) : NULL;
    return method ? method_getTypeEncoding(method) : "";
}

static id ObjectValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return ReturnType(object, selector)[0] == '@' ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static NSNumber *IntegerValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    switch (ReturnType(object, selector)[0]) {
        case 'B': return @(((BOOL (*)(id, SEL))objc_msgSend)(object, selector));
        case 'c': return @(((signed char (*)(id, SEL))objc_msgSend)(object, selector));
        case 'q': return @(((long long (*)(id, SEL))objc_msgSend)(object, selector));
        case 'Q': return @(((unsigned long long (*)(id, SEL))objc_msgSend)(object, selector));
        default: return nil;
    }
}

static NSString *StringValue(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        id value = ObjectValue(object, name);
        if ([value isKindOfClass:NSString.class]) return value;
        if ([value isKindOfClass:NSAttributedString.class]) return [value string];
    }
    return nil;
}

static NSString *SafeName(NSString *value, NSUInteger limit) {
    NSMutableCharacterSet *invalid = [NSMutableCharacterSet controlCharacterSet];
    [invalid addCharactersInString:@"<>:\"/\\|?*"];
    NSString *clean = [[value componentsSeparatedByCharactersInSet:invalid] componentsJoinedByString:@" "];
    clean = [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (clean.length <= limit) return clean;
    NSRange last = [clean rangeOfComposedCharacterSequenceAtIndex:limit];
    return [clean substringToIndex:last.location];
}

static NSString *ArchiveNamePrefix(NSString *value, NSUInteger byteLimit) {
    NSUInteger end = 0, bytes = 0;
    while (end < value.length) {
        NSRange character = [value rangeOfComposedCharacterSequenceAtIndex:end];
        NSUInteger length = [[value substringWithRange:character] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (length > byteLimit - bytes) break;
        bytes += length;
        end = NSMaxRange(character);
    }
    return [[value substringToIndex:end] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSURL *MediaURL(NSString *string) {
    NSURL *url = string.length ? [NSURL URLWithString:string] : nil;
    NSSet *hosts = [NSSet setWithArray:@[@"pbs.twimg.com", @"video.twimg.com"]];
    return [url.scheme isEqualToString:@"https"] && [hosts containsObject:url.host.lowercaseString] ? url : nil;
}

static NSArray *MediaFiles(id status) {
    id entities = ObjectValue(status, @"entities");
    NSArray *media = ObjectValue(entities, @"media");
    if (!entities || ![entities respondsToSelector:@selector(media)] ||
        (media && ![media isKindOfClass:NSArray.class])) return nil;
    NSMutableArray *files = [NSMutableArray array];
    for (TFSTwitterEntityMedia *item in media) {
        if (![item isKindOfClass:objc_getClass("TFSTwitterEntityMedia")]) {
            [files addObject:[@{@"source": @"", @"type": @0} mutableCopy]];
            continue;
        }
        NSURL *url = nil;
        NSURL *playlist = nil;
        NSInteger type = [IntegerValue(item, @"mediaType") integerValue];
        if (type == 1) {
            url = MediaURL(item.mediaURL);
        } else if (type == 2 || type == 3) {
            NSInteger best = -1;
            for (TFSTwitterEntityMediaVideoVariant *variant in item.videoInfo.variants) {
                NSURL *candidate = MediaURL(variant.url);
                if (!candidate) continue;
                if ([candidate.pathExtension.lowercaseString isEqualToString:@"m3u8"] && !playlist) playlist = candidate;
                if (![variant.contentType isEqualToString:@"video/mp4"]) continue;
                NSArray *dimensions = [[BHTManager getVideoQuality:variant.url] componentsSeparatedByString:@"x"];
                NSInteger pixels = dimensions.count == 2 ? [dimensions[0] integerValue] * [dimensions[1] integerValue] : 0;
                if (pixels > best) { best = pixels; url = candidate; }
            }
        }
        if (!playlist && (type == 2 || type == 3)) {
            NSURL *primary = MediaURL(item.videoInfo.primaryUrl);
            if ([primary.pathExtension.lowercaseString isEqualToString:@"m3u8"]) playlist = primary;
        }
        NSString *identity = StringValue(item, @[@"mediaKey"]);
        if (!identity.length) {
            NSNumber *mediaID = IntegerValue(item, @"mediaID");
            if (mediaID.unsignedLongLongValue > 0) identity = mediaID.stringValue;
        }
        [files addObject:[@{@"source": (url ?: playlist).absoluteString ?: @"", @"type": @(type),
                            @"mediaID": identity ?: @"",
                            @"playlist": @(!url && playlist != nil)} mutableCopy]];
    }
    return files;
}

static NSDictionary *Snapshot(id status) {
    if ([IntegerValue(status, @"isRetweet") boolValue]) return nil;
    id author = ObjectValue(status, @"fromUser") ?: ObjectValue(status, @"author");
    NSNumber *protected = IntegerValue(author, @"protectedUser") ?:
                          IntegerValue(status, @"isFromUserProtected") ?: IntegerValue(author, @"isProtected");
    NSNumber *authorID = IntegerValue(author, @"userID") ?: IntegerValue(status, @"fromUserID");
    NSNumber *postID = IntegerValue(status, @"statusID");
    NSString *handle = StringValue(author, @[@"username", @"screenName"]) ?: StringValue(status, @[@"fromUserName"]);
    NSString *name = StringValue(status, @[@"fromUserFullName"]) ?:
                     StringValue(author, @[@"displayFullName", @"fullName", @"name"]) ?: handle;
    id note = ObjectValue(status, @"noteTweet");
    NSString *body = note ? StringValue(note, @[@"text", @"fullText"]) :
                            StringValue(status, @[@"originalText", @"fullText", @"text"]);
    if (!protected || protected.boolValue || authorID.longLongValue <= 0 || postID.longLongValue <= 0 ||
        !handle.length || !body) return nil;
    handle = [handle stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"@"]];
    if ([handle rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"] invertedSet]].location != NSNotFound || !handle.length) return nil;

    NSDate *date = ObjectValue(status, @"date") ?: ObjectValue(status, @"createdAt");
    if (![date isKindOfClass:NSDate.class]) {
        date = [NSDate dateWithTimeIntervalSince1970:((postID.unsignedLongLongValue >> 22) + 1288834974657ULL) / 1000.0];
    }
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSString *timestamp = [formatter stringFromDate:date];
    if (timestamp.length < 20) return nil;
    NSString *link = [NSString stringWithFormat:@"https://x.com/i/status/%@", postID];
    NSArray *assets = MediaFiles(status);
    if (!assets) return nil;
    NSString *fileTime = [[[[timestamp substringToIndex:19] stringByReplacingOccurrencesOfString:@"T" withString:@" "]
                           stringByReplacingOccurrencesOfString:@":" withString:@"-"] stringByAppendingString:@"Z"];
    NSString *authorAndPost = [NSString stringWithFormat:@" (@%@) [%@]", handle, postID];
    NSString *longestExtension = [NSString stringWithFormat:@" - %02lu.avif", (unsigned long)MAX(1, assets.count)];
    NSUInteger overhead = [[NSString stringWithFormat:@"%@ %@%@", fileTime, authorAndPost, longestExtension]
                           lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSUInteger titleBudget = 240 - MIN(240, overhead);
    NSString *safeBody = SafeName(body, body.length);
    BOOL nameFits = [body isEqualToString:safeBody] &&
                    [body lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= titleBudget;
    BOOL hasDownloadableMedia = NO;
    for (NSDictionary *asset in assets) {
        if ([asset[@"source"] length]) {
            hasDownloadableMedia = YES;
            break;
        }
    }
    BOOL needsTextFile = !hasDownloadableMedia || !nameFits;
    NSString *title = nameFits ? body : ArchiveNamePrefix(safeBody, titleBudget);
    if (!title.length) {
        NSArray *types = @[@"媒体", @"照片", @"GIF", @"视频"];
        NSUInteger type = [assets.firstObject[@"type"] unsignedIntegerValue];
        title = !assets.count ? @"帖子" : type < types.count ? types[type] : @"媒体";
    }
    NSString *prefix = [NSString stringWithFormat:@"%@ %@%@", fileTime, title, authorAndPost];
    NSString *content = [NSString stringWithFormat:@"%@ (@%@)\n%@\n%@\n\n%@\n", name, handle, timestamp, link, body];
    NSMutableArray *files = [NSMutableArray array];
    if (needsTextFile) {
        [files addObject:[@{@"name": [prefix stringByAppendingString:@".txt"],
                            @"text": content, @"mime": @"text/plain"} mutableCopy]];
    }
    [files addObjectsFromArray:assets];
    return @{@"post": postID.stringValue, @"author": authorID.stringValue, @"prefix": prefix, @"files": files,
             @"body": body, @"timestamp": timestamp, @"link": link, @"hasTextFile": @(needsTextFile),
             @"folderName": [NSString stringWithFormat:@"%@ (@%@)", SafeName(name, 48), handle]};
}

// Older jobs always had a text file at index zero. Keep the Drive keys and
// attachment numbers stable even when a new job omits that file.
static BOOL HasTextFile(NSDictionary *job) {
    return !job[@"hasTextFile"] || [job[@"hasTextFile"] boolValue];
}

static NSUInteger DriveFileIndex(NSDictionary *job, NSUInteger index) {
    return HasTextFile(job) ? index : index + 1;
}

static NSString *DriveFileKey(NSDictionary *job, NSUInteger index) {
    return [NSString stringWithFormat:@"post-%@-%lu", job[@"post"], (unsigned long)DriveFileIndex(job, index)];
}

static NSString *DriveFileQuery(NSString *key, NSString *parent) {
    return [NSString stringWithFormat:@"trashed = false and '%@' in parents and appProperties has { key='nfbArchiveKey' and value='%@' }", parent, key];
}

static BOOL ValidDriveID(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet];
    return [identifier rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static NSURL *API(NSString *path, NSDictionary *query) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:[@"https://www.googleapis.com" stringByAppendingString:path]];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *key in query) [items addObject:[NSURLQueryItem queryItemWithName:key value:query[key]]];
    parts.queryItems = items.count ? items : nil;
    return parts.URL;
}

static NSDictionary *MediaExtensions(void) {
    return @{@"image/jpeg": @"jpg", @"image/png": @"png", @"image/webp": @"webp",
             @"image/gif": @"gif", @"image/avif": @"avif", @"video/mp4": @"mp4"};
}

// A .data file is only installed after a completed download or FFmpeg export.
// Read its signature to recover downloads installed before queue.json was updated.
static NSString *DownloadedMediaType(NSURL *url) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    NSData *header = [handle readDataUpToLength:32 error:nil];
    [handle closeFile];
    const unsigned char *bytes = header.bytes;
    NSUInteger count = header.length;
    if (count >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) return @"image/jpeg";
    if (count >= 8 && memcmp(bytes, "\x89PNG\r\n\x1a\n", 8) == 0) return @"image/png";
    if (count >= 6 && (!memcmp(bytes, "GIF87a", 6) || !memcmp(bytes, "GIF89a", 6))) return @"image/gif";
    if (count >= 12 && !memcmp(bytes, "RIFF", 4) && !memcmp(bytes + 8, "WEBP", 4)) return @"image/webp";
    if (count >= 12 && !memcmp(bytes + 4, "ftyp", 4)) {
        if (!memcmp(bytes + 8, "avif", 4) || !memcmp(bytes + 8, "avis", 4)) return @"image/avif";
        return @"video/mp4";
    }
    return nil;
}

typedef void (^DriveReply)(NSDictionary *, NSHTTPURLResponse *, NSError *);

@interface NFBArchiveQueue : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *jobs;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *batches;
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary *active;
@property (nonatomic, strong) NSMutableDictionary *removing;
@property (nonatomic, strong) NSURLSessionTask *network;
@property (nonatomic, strong) FFmpegSession *mediaSession;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger retries;
@property (nonatomic) BOOL retriedAuth;
@property (nonatomic) BOOL recoveringExpiredUpload;
+ (instancetype)shared;
- (BOOL)save;
- (void)run;
- (void)pause:(NSMutableDictionary *)job;
- (void)resume:(NSMutableDictionary *)job;
- (NSString *)removalBlocker:(NSMutableDictionary *)job;
- (BOOL)removeRecord:(NSMutableDictionary *)job;
- (void)trashArchive:(NSMutableDictionary *)job completion:(void (^)(NSString *error))completion;
- (NSArray<NSMutableDictionary *> *)recordsForAuthor:(NSDictionary *)author;
- (BOOL)removeAuthor:(NSDictionary *)author;
- (NSString *)authorRemovalBlocker:(NSDictionary *)author;
- (void)trashAuthor:(NSDictionary *)author completion:(void (^)(NSString *error))completion;
@end

@implementation NFBArchiveQueue
+ (instancetype)shared {
    static NFBArchiveQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = [self new]; });
    return queue;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        self.directory = [support URLByAppendingPathComponent:@"NeoFreeBirdDriveArchive" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *cache = self.directory;
        [cache setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        NSData *data = [NSData dataWithContentsOfURL:[self.directory URLByAppendingPathComponent:@"queue.json"]];
        id saved = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
        if ([saved isKindOfClass:NSDictionary.class]) {
            self.jobs = saved[@"jobs"];
            self.batches = saved[@"batches"];
        }
        if (!self.jobs) self.jobs = [saved isKindOfClass:NSMutableArray.class] ? saved : [NSMutableArray array];
        if (!self.batches) self.batches = [NSMutableArray array];
        for (NSMutableDictionary *batch in self.batches) {
            if ([@[@"scanning", @"paused"] containsObject:batch[@"state"] ?: @""]) batch[@"state"] = @"interrupted";
        }
        for (NSMutableDictionary *job in self.jobs) {
            if ([job[@"state"] isEqualToString:@"running"]) job[@"state"] = @"waiting";
        }
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.HTTPCookieStorage = nil;
        config.URLCredentialStorage = nil;
        config.HTTPShouldSetCookies = NO;
        self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    }
    return self;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    BOOL mediaRedirect = MediaURL(task.originalRequest.URL.absoluteString) &&
                         MediaURL(request.URL.absoluteString);
    completionHandler(mediaRedirect ? request : nil);
}

- (BOOL)save {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"jobs": self.jobs, @"batches": self.batches} options:0 error:nil];
    BOOL saved = [data writeToURL:[self.directory URLByAppendingPathComponent:@"queue.json"]
                          options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:Changed object:nil];
    return saved;
}

- (void)stop:(NSString *)state message:(NSString *)message {
    self.active[@"state"] = state;
    self.active[@"message"] = message ?: @"";
    self.active = nil;
    if ([self save]) dispatch_async(dispatch_get_main_queue(), ^{ [self run]; });
}

- (void)pause:(NSMutableDictionary *)job {
    if (![job[@"state"] isEqualToString:@"running"] && ![job[@"state"] isEqualToString:@"waiting"]) return;
    job[@"state"] = @"paused";
    job[@"message"] = @"已暂停";
    if (job == self.active) {
        self.generation++;
        if ([self.network isKindOfClass:NSURLSessionDownloadTask.class]) {
            NSURLSessionDownloadTask *download = (NSURLSessionDownloadTask *)self.network;
            NSUInteger index = [job[@"fileIndex"] unsignedIntegerValue];
            [download cancelByProducingResumeData:^(NSData *data) {
                if (!data.length) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![job[@"state"] isEqualToString:@"paused"] || index >= [job[@"files"] count]) return;
                    job[@"files"][index][@"downloadResume"] = [data base64EncodedStringWithOptions:0];
                    [self save];
                });
            }];
        } else {
            [self.network cancel];
        }
        if (self.mediaSession) {
            [FFmpegKit cancel:[self.mediaSession getSessionId]];
            self.mediaSession = nil;
        }
        self.network = nil;
        self.active = nil;
    }
    [self save];
    [self run];
}

- (void)resume:(NSMutableDictionary *)job {
    if (job == self.active || [job[@"state"] isEqualToString:@"complete"] || [job[@"driveRemovalPending"] boolValue]) return;
    job[@"state"] = @"waiting";
    job[@"message"] = @"等待上传";
    if ([self save]) [self run];
}

- (NSString *)removalBlocker:(NSMutableDictionary *)job {
    if (![self.jobs containsObject:job]) return @"这条收藏记录已删除。";
    if (self.removing) return @"请等待当前的 Drive 删除操作完成。";
    if (job == self.active || [job[@"state"] isEqualToString:@"running"] || [job[@"state"] isEqualToString:@"waiting"]) {
        return @"请先在「任务」里暂停这条收藏，再删除。";
    }
    for (NSDictionary *batch in self.batches) {
        if ([batch[@"state"] isEqualToString:@"scanning"] &&
            [batch[@"account"] isEqual:job[@"account"]] && [batch[@"author"] isEqual:job[@"author"]]) {
            return @"请先结束该博主正在进行的归档扫描。";
        }
    }
    return nil;
}

- (NSArray<NSMutableDictionary *> *)recordsForAuthor:(NSDictionary *)author {
    NSMutableArray *jobs = [NSMutableArray array];
    for (NSMutableDictionary *job in self.jobs) {
        if ([job[@"account"] isEqual:author[@"account"]] && [job[@"author"] isEqual:author[@"author"]]) [jobs addObject:job];
    }
    return jobs;
}

- (NSString *)authorRemovalBlocker:(NSDictionary *)author {
    if (self.removing) return @"请等待当前的 Drive 删除操作完成。";
    for (NSDictionary *batch in self.batches) {
        if ([batch[@"account"] isEqual:author[@"account"]] && [batch[@"author"] isEqual:author[@"author"]] &&
            [@[@"scanning", @"paused"] containsObject:batch[@"state"] ?: @""]) {
            return @"请先结束该博主正在进行的归档扫描。";
        }
    }
    for (NSDictionary *job in [self recordsForAuthor:author]) {
        if (job == self.active || [@[@"running", @"waiting"] containsObject:job[@"state"] ?: @""]) {
            return @"请先在「任务」里暂停该博主的上传，再删除。";
        }
    }
    return nil;
}

- (BOOL)removeAuthor:(NSDictionary *)author {
    NSArray *jobs = [self recordsForAuthor:author];
    NSArray *previousJobs = [self.jobs copy];
    NSArray *previousBatches = [self.batches copy];
    [self.jobs removeObjectsInArray:jobs];
    NSIndexSet *matching = [self.batches indexesOfObjectsPassingTest:^BOOL(NSDictionary *batch, NSUInteger index, BOOL *stop) {
        return [batch[@"account"] isEqual:author[@"account"]] && [batch[@"author"] isEqual:author[@"author"]];
    }];
    [self.batches removeObjectsAtIndexes:matching];
    if (![self save]) {
        [self.jobs setArray:previousJobs];
        [self.batches setArray:previousBatches];
        [NSNotificationCenter.defaultCenter postNotificationName:Changed object:nil];
        return NO;
    }
    for (NSDictionary *job in jobs) {
        for (NSUInteger index = 0; index < [job[@"files"] count]; index++) {
            [NSFileManager.defaultManager removeItemAtURL:[self localFileForJob:job index:index] error:nil];
        }
    }
    return YES;
}

- (BOOL)removeRecord:(NSMutableDictionary *)job {
    NSUInteger index = [self.jobs indexOfObjectIdenticalTo:job];
    if (index == NSNotFound) return YES;
    NSMutableDictionary *affectedBatch = nil;
    for (NSMutableDictionary *batch in self.batches) {
        if ([batch[@"account"] isEqual:job[@"account"]] && [batch[@"author"] isEqual:job[@"author"]]) {
            affectedBatch = batch;
            break;
        }
    }
    NSArray *oldPosts = affectedBatch[@"posts"];
    NSArray *oldUnreadable = affectedBatch[@"unreadable"];
    if (affectedBatch) {
        NSMutableArray *posts = [oldPosts mutableCopy];
        NSMutableArray *unreadable = [oldUnreadable mutableCopy];
        [posts removeObject:job[@"post"]];
        [unreadable removeObject:job[@"post"]];
        affectedBatch[@"posts"] = posts;
        affectedBatch[@"unreadable"] = unreadable;
    }
    [self.jobs removeObjectAtIndex:index];
    if (![self save]) {
        [self.jobs insertObject:job atIndex:index];
        affectedBatch[@"posts"] = oldPosts;
        affectedBatch[@"unreadable"] = oldUnreadable;
        [NSNotificationCenter.defaultCenter postNotificationName:Changed object:nil];
        return NO;
    }
    for (NSUInteger file = 0; file < [job[@"files"] count]; file++) {
        [NSFileManager.defaultManager removeItemAtURL:[self localFileForJob:job index:file] error:nil];
    }
    return YES;
}

- (void)trashRequest:(NSMutableURLRequest *)request account:(NSString *)account retry:(BOOL)retry
          completion:(void (^)(NSDictionary *, NSString *))completion {
    if (![NFBDriveAuth.shared.account isEqualToString:account]) { completion(nil, @"请连接收藏时使用的 Google 账号。"); return; }
    [NFBDriveAuth.shared token:^(NSString *token, NSString *error) {
        if (!token.length || ![NFBDriveAuth.shared.account isEqualToString:account]) {
            completion(nil, error ?: @"Google 账号已切换。");
            return;
        }
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            NSInteger code = [(NSHTTPURLResponse *)response statusCode];
            id decoded = data.length && code == 200 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![NFBDriveAuth.shared.account isEqualToString:account]) { completion(nil, @"Google 账号已切换。"); return; }
                if (code == 401 && retry) {
                    [NFBDriveAuth.shared invalidateAccessToken];
                    [self trashRequest:request account:account retry:NO completion:completion];
                } else if (code == 404 && [request.HTTPMethod isEqualToString:@"GET"] &&
                           ![request.URL.path isEqualToString:@"/drive/v3/files"]) {
                    completion(@{}, nil);
                } else if ([decoded isKindOfClass:NSDictionary.class]) {
                    completion(decoded, nil);
                } else {
                    completion(nil, code ? [NSString stringWithFormat:@"Drive 请求失败（%ld）。", (long)code] : @"无法连接 Google Drive。");
                }
            });
        }] resume];
    }];
}

- (void)collectTrashIDs:(NSMutableOrderedSet<NSString *> *)ids matches:(BOOL (^)(NSString *))matches
                 query:(NSString *)query page:(NSString *)page account:(NSString *)account
            completion:(void (^)(NSString *error))completion {
    NSMutableDictionary *params = [@{@"q": query, @"pageSize": @"100",
        @"fields": @"nextPageToken,incompleteSearch,files(id,ownedByMe,appProperties)"} mutableCopy];
    if (page.length) params[@"pageToken"] = page;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:API(@"/drive/v3/files", params)];
    [self trashRequest:request account:account retry:YES completion:^(NSDictionary *result, NSString *error) {
        if (error || [result[@"incompleteSearch"] boolValue] || ![result[@"files"] isKindOfClass:NSArray.class]) {
            completion(error ?: @"Drive 未返回完整的归档文件列表。");
            return;
        }
        for (NSDictionary *item in result[@"files"]) {
            NSString *fileID = item[@"id"];
            if ([item[@"ownedByMe"] boolValue] && matches(item[@"appProperties"][@"nfbArchiveKey"]) &&
                ValidDriveID(fileID)) [ids addObject:fileID];
        }
        NSString *next = result[@"nextPageToken"];
        if (next.length && ![next isEqualToString:page]) {
            [self collectTrashIDs:ids matches:matches query:query page:next account:account completion:completion];
        } else {
            completion(next.length ? @"Drive 文件列表分页未完成。" : nil);
        }
    }];
}

- (void)includeRecentUploads:(NSDictionary *)job index:(NSUInteger)index found:(NSMutableOrderedSet<NSString *> *)ids
                  completion:(void (^)(NSString *error))completion {
    NSArray *files = job[@"files"];
    while (index < files.count) {
        NSString *fileID = files[index][@"driveID"];
        if (!ValidDriveID(fileID) || [ids containsObject:fileID]) { index++; continue; }
        // Drive search can lag immediately after an upload. Confirm known IDs
        // directly before reporting that all archived files are gone.
        NSURL *url = API([@"/drive/v3/files/" stringByAppendingString:fileID],
                        @{@"fields": @"id,ownedByMe,trashed,mimeType,appProperties"});
        [self trashRequest:[NSMutableURLRequest requestWithURL:url] account:job[@"account"] retry:YES
                completion:^(NSDictionary *result, NSString *error) {
            if (error) { completion(error); return; }
            if ([result[@"id"] isEqualToString:fileID] && [result[@"ownedByMe"] boolValue] &&
                ![result[@"trashed"] boolValue] && ![result[@"mimeType"] isEqualToString:@"application/vnd.google-apps.folder"] &&
                [result[@"appProperties"][@"nfbArchiveKey"] isEqualToString:DriveFileKey(job, index)]) [ids addObject:fileID];
            [self includeRecentUploads:job index:index + 1 found:ids completion:completion];
        }];
        return;
    }
    completion(nil);
}

- (void)trashIDs:(NSArray<NSString *> *)ids index:(NSUInteger)index account:(NSString *)account
      completion:(void (^)(NSString *error))completion {
    if (index == ids.count) { completion(nil); return; }
    NSString *fileID = ids[index];
    NSURL *url = API([@"/drive/v3/files/" stringByAppendingString:fileID], @{@"fields": @"id,trashed"});
    NSMutableURLRequest *request = [self JSONRequest:url method:@"PATCH" body:@{@"trashed": @YES}];
    [self trashRequest:request account:account retry:YES completion:^(NSDictionary *result, NSString *error) {
        if (error || ![result[@"id"] isEqualToString:fileID] || ![result[@"trashed"] boolValue]) {
            completion([NSString stringWithFormat:@"已移到回收站 %lu/%lu 个文件。%@", (unsigned long)index,
                        (unsigned long)ids.count, error ?: @"Drive 未确认其余文件。"]);
            return;
        }
        [self trashIDs:ids index:index + 1 account:account completion:completion];
    }];
}

- (void)trashArchive:(NSMutableDictionary *)job completion:(void (^)(NSString *error))completion {
    NSString *blocked = [self removalBlocker:job];
    if (blocked) { completion(blocked); return; }
    NSString *account = job[@"account"];
    if (![NFBDriveAuth.shared.account isEqualToString:account]) { completion(@"请连接收藏时使用的 Google 账号。"); return; }
    self.removing = job;
    BOOL wasPending = [job[@"driveRemovalPending"] boolValue];
    job[@"driveRemovalPending"] = @YES;
    if (![self save]) {
        if (!wasPending) [job removeObjectForKey:@"driveRemovalPending"];
        self.removing = nil;
        completion(@"无法保存删除状态，本次未对 Drive 发出删除请求。");
        return;
    }
    NSMutableSet *keys = [NSMutableSet set];
    NSMutableArray *terms = [NSMutableArray array];
    // Include slot zero (legacy TXT) plus the media slots from both file layouts.
    NSUInteger lastSlot = MAX((NSUInteger)4, [job[@"files"] count]);
    for (NSUInteger slot = 0; slot <= lastSlot; slot++) {
        NSString *key = [NSString stringWithFormat:@"post-%@-%lu", job[@"post"], (unsigned long)slot];
        [keys addObject:key];
        [terms addObject:[NSString stringWithFormat:@"appProperties has { key='nfbArchiveKey' and value='%@' }", key]];
    }
    NSString *query = [NSString stringWithFormat:@"trashed = false and mimeType != 'application/vnd.google-apps.folder' and (%@)",
        [terms componentsJoinedByString:@" or "]];
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
    void (^finish)(NSString *) = ^(NSString *error) {
        if (!error && ![self removeRecord:job]) error = @"Drive 已处理，但无法移除本机记录。请重试。";
        self.removing = nil;
        if (error) [NSNotificationCenter.defaultCenter postNotificationName:Changed object:nil];
        completion(error);
    };
    [self collectTrashIDs:ids matches:^BOOL(NSString *key) { return key && [keys containsObject:key]; }
                    query:query page:nil account:account completion:^(NSString *error) {
        if (error) { finish(error); return; }
        [self includeRecentUploads:job index:0 found:ids completion:^(NSString *lookupError) {
            if (lookupError) finish(lookupError);
            else [self trashIDs:ids.array index:0 account:account completion:finish];
        }];
    }];
}

- (void)collectAuthorFiles:(NSArray<NSString *> *)folders index:(NSUInteger)index excluding:(NSSet<NSString *> *)otherPosts
                 account:(NSString *)account found:(NSMutableOrderedSet<NSString *> *)ids
              completion:(void (^)(NSString *error))completion {
    if (index == folders.count) { completion(nil); return; }
    NSString *query = [NSString stringWithFormat:@"trashed = false and '%@' in parents and mimeType != 'application/vnd.google-apps.folder'",
                       folders[index]];
    NSRegularExpression *archiveKey = [NSRegularExpression regularExpressionWithPattern:@"^post-[0-9]+-[0-9]+$" options:0 error:nil];
    [self collectTrashIDs:ids matches:^BOOL(NSString *key) {
        if (![key isKindOfClass:NSString.class] ||
            [archiveKey numberOfMatchesInString:key options:0 range:NSMakeRange(0, key.length)] != 1) return NO;
        return ![otherPosts containsObject:[key componentsSeparatedByString:@"-"][1]];
    } query:query page:nil account:account completion:^(NSString *error) {
        if (error) completion(error);
        else [self collectAuthorFiles:folders index:index + 1 excluding:otherPosts account:account found:ids completion:completion];
    }];
}

- (void)includeAuthorUploads:(NSArray<NSDictionary *> *)jobs index:(NSUInteger)index
                       found:(NSMutableOrderedSet<NSString *> *)ids completion:(void (^)(NSString *error))completion {
    // Yield between records so a large gallery with cached IDs cannot grow the stack.
    if (index == jobs.count) { completion(nil); return; }
    [self includeRecentUploads:jobs[index] index:0 found:ids completion:^(NSString *error) {
        if (error) { completion(error); return; }
        dispatch_async(dispatch_get_main_queue(), ^{ [self includeAuthorUploads:jobs index:index + 1 found:ids completion:completion]; });
    }];
}

- (void)trashAuthor:(NSDictionary *)author completion:(void (^)(NSString *error))completion {
    NSString *blocked = [self authorRemovalBlocker:author];
    if (blocked) { completion(blocked); return; }
    NSString *account = author[@"account"], *authorID = author[@"author"];
    if (![NFBDriveAuth.shared.account isEqualToString:account] ||
        ![authorID length] || [authorID rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound) {
        completion(@"无法确认该博主或收藏时使用的 Google 账号。");
        return;
    }
    NSArray<NSMutableDictionary *> *jobs = [self recordsForAuthor:author];
    NSMutableSet *otherPosts = [NSMutableSet set];
    for (NSDictionary *job in self.jobs) {
        if ([job[@"account"] isEqualToString:account] && ![job[@"author"] isEqualToString:authorID]) {
            [otherPosts addObject:job[@"post"]];
        }
    }
    NSMutableArray *newlyPending = [NSMutableArray array];
    for (NSMutableDictionary *job in jobs) {
        if (![job[@"driveRemovalPending"] boolValue]) [newlyPending addObject:job];
        job[@"driveRemovalPending"] = @YES;
    }
    self.removing = [author mutableCopy];
    if (![self save]) {
        for (NSMutableDictionary *job in newlyPending) [job removeObjectForKey:@"driveRemovalPending"];
        self.removing = nil;
        [NSNotificationCenter.defaultCenter postNotificationName:Changed object:nil];
        completion(@"无法保存删除状态，本次未对 Drive 发出删除请求。");
        return;
    }

    void (^finish)(NSString *) = ^(NSString *error) {
        if (!error && ![self removeAuthor:author]) error = @"Drive 已处理，但无法移除本机记录。请重试。";
        self.removing = nil;
        if (error) [NSNotificationCenter.defaultCenter postNotificationName:Changed object:nil];
        completion(error);
    };
    NSString *key = [@"author-" stringByAppendingString:authorID];
    NSString *query = [NSString stringWithFormat:@"trashed = false and mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='nfbArchiveKey' and value='%@' }", key];
    NSMutableOrderedSet *folders = [NSMutableOrderedSet orderedSet];
    [self collectTrashIDs:folders matches:^BOOL(NSString *candidate) { return [key isEqualToString:candidate]; }
                    query:query page:nil account:account completion:^(NSString *error) {
        if (error) { finish(error); return; }
        NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
        [self collectAuthorFiles:folders.array index:0 excluding:otherPosts account:account found:ids completion:^(NSString *listError) {
            if (listError) { finish(listError); return; }
            [self includeAuthorUploads:jobs index:0 found:ids completion:^(NSString *lookupError) {
                if (lookupError) finish(lookupError);
                else [self trashIDs:ids.array index:0 account:account completion:finish];
            }];
        }];
    }];
}

- (void)run {
    if (self.active) return;
    for (NSMutableDictionary *job in self.jobs) {
        if (![job[@"state"] isEqualToString:@"waiting"] || [job[@"driveRemovalPending"] boolValue]) continue;
        self.active = job;
        self.generation++;
        if (![job[@"account"] isEqualToString:NFBDriveAuth.shared.account]) {
            [self stop:@"failed" message:@"请连接添加任务时使用的 Google 账号"]; return;
        }
        self.retries = 0;
        self.retriedAuth = NO;
        self.recoveringExpiredUpload = NO;
        job[@"state"] = @"running";
        job[@"message"] = @"准备归档";
        if (![self save]) { [self stop:@"failed" message:@"无法写入任务进度，请检查本机存储"]; return; }
        [self folders];
        return;
    }
}

- (void)request:(NSMutableURLRequest *)request reply:(DriveReply)reply {
    NSUInteger generation = self.generation;
    [NFBDriveAuth.shared token:^(NSString *token, NSString *error) {
        if (generation != self.generation || !self.active) return;
        if (![self.active[@"account"] isEqualToString:NFBDriveAuth.shared.account] || !token.length) {
            [self stop:@"failed" message:error ?: @"请切回原 Google 账号"]; return;
        }
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        self.network = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            id decoded = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *json = [decoded isKindOfClass:NSDictionary.class] ? decoded : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.generation || !self.active) return;
                self.network = nil;
                NSInteger code = [(NSHTTPURLResponse *)response statusCode];
                if (code == 401 && !self.retriedAuth) {
                    self.retriedAuth = YES;
                    [NFBDriveAuth.shared invalidateAccessToken];
                    [self request:request reply:reply];
                    return;
                }
                reply(json, (NSHTTPURLResponse *)response, networkError);
            });
        }];
        [self.network resume];
    }];
}

- (void)retry:(NSString *)message operation:(dispatch_block_t)operation {
    if (self.retries >= 3) { [self stop:@"failed" message:message]; return; }
    NSUInteger delay = 1UL << self.retries++;
    NSUInteger generation = self.generation;
    self.active[@"message"] = @"网络中断，等待重试";
    [self save];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation == self.generation && self.active) operation();
    });
}

- (void)driveFailure:(NSDictionary *)json response:(NSHTTPURLResponse *)response operation:(dispatch_block_t)operation {
    NSInteger code = response.statusCode;
    id failure = json[@"error"];
    id errors = [failure isKindOfClass:NSDictionary.class] ? failure[@"errors"] : nil;
    id first = [errors isKindOfClass:NSArray.class] ? [errors firstObject] : nil;
    NSString *reason = [first isKindOfClass:NSDictionary.class] ? first[@"reason"] : nil;
    if (!code || code == 429 || code >= 500 || [reason isEqualToString:@"rateLimitExceeded"] ||
        [reason isEqualToString:@"userRateLimitExceeded"]) {
        [self retry:@"Drive 暂时不可用，请重试" operation:operation];
    } else if ([reason isEqualToString:@"storageQuotaExceeded"]) {
        [self stop:@"failed" message:@"Google Drive 空间不足"];
    } else if (code == 401 || code == 403) {
        [self stop:@"failed" message:@"Drive 拒绝访问，请检查 Google 授权"];
    } else {
        [self stop:@"failed" message:[NSString stringWithFormat:@"Drive 请求失败（%ld）", (long)code]];
    }
}

- (NSMutableURLRequest *)JSONRequest:(NSURL *)url method:(NSString *)method body:(NSDictionary *)body {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    return request;
}

- (void)find:(NSString *)key parent:(NSString *)parent completion:(void (^)(NSDictionary *))completion {
    NSString *query = DriveFileQuery(key, parent);
    NSURLRequest *request = [NSURLRequest requestWithURL:API(@"/drive/v3/files", @{@"q": query, @"fields": @"files(id,name,size,mimeType,parents)", @"pageSize": @"100"})];
    [self request:[request mutableCopy] reply:^(NSDictionary *json, NSHTTPURLResponse *response, NSError *error) {
        if (response.statusCode != 200 || ![json[@"files"] isKindOfClass:NSArray.class]) {
            [self driveFailure:json response:response operation:^{ [self find:key parent:parent completion:completion]; }]; return;
        }
        self.retries = 0;
        completion([json[@"files"] firstObject]);
    }];
}

- (void)folder:(NSString *)key name:(NSString *)name parent:(NSString *)parent completion:(void (^)(NSString *))completion {
    [self find:key parent:parent completion:^(NSDictionary *found) {
        NSString *folderID = found[@"id"];
        if (folderID.length && [found[@"name"] isEqualToString:name]) { completion(folderID); return; }
        NSDictionary *body = folderID.length ? @{@"name": name} :
            @{@"name": name, @"parents": @[parent], @"mimeType": @"application/vnd.google-apps.folder",
              @"appProperties": @{@"nfbArchiveKey": key}};
        NSString *path = folderID.length ? [@"/drive/v3/files/" stringByAppendingString:folderID] : @"/drive/v3/files";
        NSMutableURLRequest *request = [self JSONRequest:API(path, @{@"fields": @"id"})
                                                method:folderID.length ? @"PATCH" : @"POST" body:body];
        [self request:request reply:^(NSDictionary *json, NSHTTPURLResponse *response, NSError *error) {
            if (![json[@"id"] length] || response.statusCode < 200 || response.statusCode >= 300) {
                [self driveFailure:json response:response operation:^{ [self folder:key name:name parent:parent completion:completion]; }];
                return;
            }
            self.retries = 0;
            completion(json[@"id"]);
        }];
    }];
}

- (void)folders {
    [self folder:@"root-v1" name:@"X 收藏" parent:@"root" completion:^(NSString *root) {
        [self folder:[@"author-" stringByAppendingString:self.active[@"author"]] name:self.active[@"folderName"] parent:root completion:^(NSString *folder) {
            self.active[@"folder"] = folder;
            [self nextFile];
        }];
    }];
}

- (void)nextFile {
    NSArray *files = self.active[@"files"];
    for (NSUInteger index = 0; index < files.count; index++) {
        NSMutableDictionary *file = files[index];
        if ([file[@"done"] boolValue] || [file[@"error"] length]) continue;
        self.active[@"fileIndex"] = @(index);
        self.recoveringExpiredUpload = NO;
        NSString *key = DriveFileKey(self.active, index);
        [self find:key parent:self.active[@"folder"] completion:^(NSDictionary *found) {
            if ([found[@"id"] length] && [found[@"size"] longLongValue] > 0) {
                [self finishFile:file driveID:found[@"id"]];
            } else {
                [self prepare:file key:key index:index];
            }
        }];
        return;
    }
    NSUInteger missing = 0;
    for (NSDictionary *file in files) if (![file[@"done"] boolValue]) missing++;
    [self stop:missing ? @"failed" : @"complete"
        message:missing ? [NSString stringWithFormat:@"%lu 个文件未保存，点按查看和重试", (unsigned long)missing] : @"已确认全部上传到 Google Drive"];
}

- (NSURL *)localFile:(NSUInteger)index {
    return [self localFileForJob:self.active index:index];
}

- (NSURL *)localFileForJob:(NSDictionary *)job index:(NSUInteger)index {
    NSString *name = [NSString stringWithFormat:@"%@-%lu.data", job[@"id"], (unsigned long)index];
    return [self.directory URLByAppendingPathComponent:name];
}

- (BOOL)saveMediaMetadata:(NSMutableDictionary *)file mime:(NSString *)mime index:(NSUInteger)index {
    file[@"mime"] = mime;
    file[@"name"] = [NSString stringWithFormat:@"%@ - %02lu.%@", self.active[@"prefix"],
                     (unsigned long)DriveFileIndex(self.active, index), MediaExtensions()[mime]];
    [file removeObjectForKey:@"downloadResume"];
    return [self save];
}

- (void)recordFailure:(NSMutableDictionary *)file message:(NSString *)message {
    file[@"error"] = message;
    self.retries = 0;
    if (![self save]) { [self stop:@"failed" message:@"无法保存任务进度"]; return; }
    [self nextFile];
}

- (void)finishFile:(NSMutableDictionary *)file driveID:(NSString *)driveID {
    file[@"done"] = @YES;
    file[@"driveID"] = driveID;
    [file removeObjectForKey:@"session"];
    [file removeObjectForKey:@"downloadResume"];
    self.retries = 0;
    self.recoveringExpiredUpload = NO;
    if (![self save]) { [self stop:@"failed" message:@"无法保存任务进度"]; return; }
    [NSFileManager.defaultManager removeItemAtURL:[self localFile:[self.active[@"fileIndex"] unsignedIntegerValue]] error:nil];
    [self nextFile];
}

- (void)prepare:(NSMutableDictionary *)file key:(NSString *)key index:(NSUInteger)index {
    NSURL *local = [self localFile:index];
    if (file[@"text"] && ![NSFileManager.defaultManager fileExistsAtPath:local.path]) {
        NSData *data = [file[@"text"] dataUsingEncoding:NSUTF8StringEncoding];
        if (![data writeToURL:local options:NSDataWritingAtomic error:nil]) {
            [self recordFailure:file message:@"无法写入正文"]; return;
        }
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:local.path] && [file[@"mime"] length] && [file[@"name"] length]) {
        [self upload:file key:key index:index offset:nil];
        return;
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:local.path]) {
        NSString *mime = DownloadedMediaType(local);
        if (mime) {
            if (![self saveMediaMetadata:file mime:mime index:index]) {
                [self stop:@"failed" message:@"无法恢复下载记录"]; return;
            }
            [self upload:file key:key index:index offset:nil];
            return;
        }
        // Preserve an unreadable file until a complete replacement is available.
    }

    NSURL *source = MediaURL(file[@"source"]);
    if (!source) { [self recordFailure:file message:@"此附件没有可保存的媒体文件地址"]; return; }
    self.active[@"message"] = [NSString stringWithFormat:@"下载附件 %lu", (unsigned long)index];
    if (![self save]) { [self stop:@"failed" message:@"无法保存下载进度"]; return; }
    NSUInteger generation = self.generation;
    if ([file[@"playlist"] boolValue]) {
        NSURL *temporary = [local URLByAppendingPathExtension:[NSUUID.UUID.UUIDString stringByAppendingString:@".mp4"]];
        self.mediaSession = [FFmpegKit executeWithArgumentsAsync:@[
            @"-nostdin", @"-protocol_whitelist", @"https,tls,tcp,crypto", @"-i", source.absoluteString,
            @"-map", @"0:v:0", @"-map", @"0:a:0?", @"-c", @"copy", @"-movflags", @"+faststart", temporary.path
        ] withCompleteCallback:^(FFmpegSession *session) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.generation || !self.active) {
                    [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
                    return;
                }
                self.mediaSession = nil;
                BOOL ok = [ReturnCode isSuccess:[session getReturnCode]] &&
                    [self installDownload:temporary to:local];
                if (!ok) {
                    [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
                    [self retry:@"串流视频保存失败，请重试" operation:^{ [self prepare:file key:key index:index]; }];
                    return;
                }
                self.retries = 0;
                if (![self saveMediaMetadata:file mime:@"video/mp4" index:index]) {
                    [self stop:@"failed" message:@"无法保存下载进度"]; return;
                }
                [self upload:file key:key index:index offset:nil];
            });
        }];
        return;
    }
    NSData *resume = file[@"downloadResume"] ? [[NSData alloc] initWithBase64EncodedString:file[@"downloadResume"] options:0] : nil;
    void (^done)(NSURL *, NSURLResponse *, NSError *) = ^(NSURL *location, NSURLResponse *response, NSError *error) {
        // The download location expires when this callback returns.
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *mime = response.MIMEType.lowercaseString;
        NSString *extension = MediaExtensions()[mime ?: @""];
        NSURL *temporary = nil;
        if (!error && location && extension && http.statusCode >= 200 && http.statusCode < 300 && MediaURL(response.URL.absoluteString)) {
            temporary = [local URLByAppendingPathExtension:NSUUID.UUID.UUIDString];
            if (![NSFileManager.defaultManager moveItemAtURL:location toURL:temporary error:nil]) temporary = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation || !self.active) {
                if (temporary) [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
                return;
            }
            self.network = nil;
            [file removeObjectForKey:@"downloadResume"];
            if (temporary) {
                if (![self installDownload:temporary to:local]) {
                    [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
                    [self recordFailure:file message:@"无法保存下载的文件"]; return;
                }
                self.retries = 0;
                if (![self saveMediaMetadata:file mime:mime index:index]) {
                    [self stop:@"failed" message:@"无法保存下载进度"]; return;
                }
                [self upload:file key:key index:index offset:nil];
            } else if (error || http.statusCode == 429 || http.statusCode >= 500) {
                NSData *checkpoint = error.userInfo[NSURLSessionDownloadTaskResumeData];
                if (checkpoint.length) file[@"downloadResume"] = [checkpoint base64EncodedStringWithOptions:0];
                [self retry:@"媒体下载失败，请重试" operation:^{ [self prepare:file key:key index:index]; }];
            } else {
                [self recordFailure:file message:@"媒体已失效，或返回了无法保存的格式"];
            }
        });
    };
    if (resume.length) self.network = [self.session downloadTaskWithResumeData:resume completionHandler:done];
    else self.network = [self.session downloadTaskWithURL:source completionHandler:done];
    [self.network resume];
}

- (BOOL)installDownload:(NSURL *)temporary to:(NSURL *)local {
    NSFileManager *manager = NSFileManager.defaultManager;
    if ([manager fileExistsAtPath:local.path]) {
        return [manager replaceItemAtURL:local withItemAtURL:temporary backupItemName:nil
                                  options:NSFileManagerItemReplacementUsingNewMetadataOnly
                         resultingItemURL:nil error:nil];
    }
    return [manager moveItemAtURL:temporary toURL:local error:nil];
}

- (void)upload:(NSMutableDictionary *)file key:(NSString *)key index:(NSUInteger)index offset:(NSNumber *)offset {
    NSURL *local = [self localFile:index];
    NSNumber *sizeValue = nil;
    [local getResourceValue:&sizeValue forKey:NSURLFileSizeKey error:nil];
    unsigned long long size = sizeValue.unsignedLongLongValue;
    if (!size) { [self recordFailure:file message:@"本机文件为空或丢失"]; return; }

    if (![file[@"session"] length]) {
        NSMutableDictionary *body = [@{@"name": file[@"name"], @"parents": @[self.active[@"folder"]],
            @"mimeType": file[@"mime"], @"appProperties": @{@"nfbArchiveKey": key}} mutableCopy];
        if (!HasTextFile(self.active) && index == 0) {
            body[@"description"] = [NSString stringWithFormat:@"%@\n%@\n%@", self.active[@"folderName"],
                                    self.active[@"timestamp"], self.active[@"link"]];
        }
        NSMutableURLRequest *request = [self JSONRequest:API(@"/upload/drive/v3/files", @{@"uploadType": @"resumable", @"fields": @"id,size"}) method:@"POST" body:body];
        [request setValue:file[@"mime"] forHTTPHeaderField:@"X-Upload-Content-Type"];
        [request setValue:sizeValue.stringValue forHTTPHeaderField:@"X-Upload-Content-Length"];
        [self request:request reply:^(NSDictionary *json, NSHTTPURLResponse *response, NSError *error) {
            NSString *location = [response valueForHTTPHeaderField:@"Location"];
            NSURL *session = [NSURL URLWithString:location ?: @""];
            if (response.statusCode != 200 || ![session.scheme isEqualToString:@"https"] ||
                ![session.host isEqualToString:@"www.googleapis.com"]) {
                [self driveFailure:json response:response operation:^{ [self upload:file key:key index:index offset:nil]; }]; return;
            }
            file[@"session"] = location;
            if (![self save]) { [self stop:@"failed" message:@"无法写入续传记录"]; return; }
            [self upload:file key:key index:index offset:@0];
        }];
        return;
    }

    NSURL *session = [NSURL URLWithString:file[@"session"]];
    if (![session.scheme isEqualToString:@"https"] || ![session.host isEqualToString:@"www.googleapis.com"]) {
        [self recordFailure:file message:@"无效的 Drive 续传会话"]; return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:session];
    request.HTTPMethod = @"PUT";
    unsigned long long start = offset.unsignedLongLongValue;
    NSData *chunk = nil;
    if (offset && start < size) {
        NSFileHandle *reader = [NSFileHandle fileHandleForReadingFromURL:local error:nil];
        if ([reader seekToOffset:start error:nil]) chunk = [reader readDataUpToLength:(NSUInteger)MIN(ChunkSize, size - start) error:nil];
        [reader closeFile];
        if (!chunk.length) { [self recordFailure:file message:@"无法读取待上传文件"]; return; }
    }
    request.HTTPBody = chunk ?: [NSData data];
    [request setValue:chunk ? file[@"mime"] : @"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    [request setValue:chunk ? [NSString stringWithFormat:@"bytes %llu-%llu/%llu", start, start + chunk.length - 1, size] :
                              [NSString stringWithFormat:@"bytes */%llu", size] forHTTPHeaderField:@"Content-Range"];
    if (offset) {
        self.active[@"message"] = [NSString stringWithFormat:@"上传文件 %lu/%lu · %.0f%%",
            (unsigned long)(index + 1), (unsigned long)[self.active[@"files"] count], 100.0 * start / size];
        [self save];
    }
    [self request:request reply:^(NSDictionary *json, NSHTTPURLResponse *response, NSError *error) {
        NSInteger code = response.statusCode;
        if ((code == 200 || code == 201) && [json[@"id"] length] && [json[@"size"] longLongValue] > 0 &&
            (unsigned long long)[json[@"size"] longLongValue] == size) {
            [self finishFile:file driveID:json[@"id"]];
        } else if (code == 308) {
            NSString *range = [response valueForHTTPHeaderField:@"Range"];
            unsigned long long next = range.length ? [[[range componentsSeparatedByString:@"-"] lastObject] longLongValue] + 1 : 0;
            if (next >= size || (chunk && next <= start)) {
                [self retry:@"Drive 未确认接收分片，请重试" operation:^{ [self upload:file key:key index:index offset:nil]; }];
                return;
            }
            self.retries = 0;
            [self upload:file key:key index:index offset:@(next)];
        } else if (code == 404) {
            if (self.recoveringExpiredUpload) { [self recordFailure:file message:@"Drive 续传会话已失效"]; return; }
            self.recoveringExpiredUpload = YES;
            [file removeObjectForKey:@"session"];
            [self find:key parent:self.active[@"folder"] completion:^(NSDictionary *found) {
                if ([found[@"id"] length] && [found[@"size"] longLongValue] > 0) [self finishFile:file driveID:found[@"id"]];
                else [self upload:file key:key index:index offset:nil];
            }];
        } else {
            [self driveFailure:json response:response operation:^{ [self upload:file key:key index:index offset:nil]; }];
        }
    }];
}
@end

static void Message(UIViewController *presenter, NSString *title, NSString *message) {
    if (!presenter.view.window || presenter.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}


// The scanner owns separate native controllers, so programmatic scrolling
// cannot move the profile the user was reading.
static char ArchiveScannerKey;

@interface NFBArchiveScanner : UIViewController
@property (nonatomic, copy) NSArray<UIViewController *> *sources;
@property (nonatomic, strong) NSMutableDictionary *batch;
@property (nonatomic, strong) NSMutableArray *states;
@property (nonatomic, strong) NSMapTable *raw;
@property (nonatomic, strong) NSHashTable *initialized;
@property (nonatomic, strong) NSMutableSet<NSString *> *processedPosts;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSArray *lastSignature;
@property (nonatomic) NSTimeInterval lastAdvance;
@property (nonatomic) NSTimeInterval lastScroll;
@property (nonatomic) NSUInteger sourceIndex;
@property (nonatomic) BOOL paused;
@end

static NSDictionary *MatchingMedia(NSDictionary *old, NSArray *freshFiles, NSArray *oldFiles) {
    NSString *identity = old[@"mediaID"];
    NSURL *oldURL = MediaURL(old[@"source"]);
    NSDictionary *onlyCandidate = nil;
    NSUInteger candidates = 0, oldCandidates = 0;
    for (NSDictionary *item in freshFiles) {
        NSURL *newURL = MediaURL(item[@"source"]);
        if (!newURL || ![old[@"type"] isEqual:item[@"type"]]) continue;
        if (identity.length && [identity isEqualToString:item[@"mediaID"]]) return item;
        if ((!identity.length || ![item[@"mediaID"] length]) && oldURL &&
            [oldURL.host isEqualToString:newURL.host] && [oldURL.path isEqualToString:newURL.path]) return item;
        onlyCandidate = item;
        candidates++;
    }
    if (identity.length || oldURL || candidates != 1 || freshFiles.count != oldFiles.count) return nil;
    for (NSDictionary *item in oldFiles) if ([old[@"type"] isEqual:item[@"type"]]) oldCandidates++;
    return oldCandidates == 1 ? onlyCandidate : nil;
}

static BOOL RefreshMissingMedia(NFBArchiveQueue *queue, NSMutableDictionary *job, NSArray *freshFiles) {
    if (job == queue.active || [job[@"state"] isEqualToString:@"complete"] || [job[@"driveRemovalPending"] boolValue]) return NO;
    BOOL refreshed = NO;
    NSArray *oldFiles = job[@"files"];
    NSUInteger firstMedia = HasTextFile(job) && oldFiles.count ? 1 : 0;
    NSArray *oldMedia = [oldFiles subarrayWithRange:NSMakeRange(firstMedia, oldFiles.count - firstMedia)];
    if ([freshFiles.firstObject[@"text"] isKindOfClass:NSString.class]) {
        freshFiles = [freshFiles subarrayWithRange:NSMakeRange(1, freshFiles.count - 1)];
    }
    for (NSUInteger index = firstMedia; index < oldFiles.count; index++) {
        NSMutableDictionary *file = oldFiles[index];
        if ([file[@"done"] boolValue]) continue;
        NSURL *local = [queue localFileForJob:job index:index];
        if ([NSFileManager.defaultManager fileExistsAtPath:local.path] &&
            ([file[@"mime"] length] || DownloadedMediaType(local))) continue;
        NSDictionary *fresh = MatchingMedia(file, freshFiles, oldMedia);
        if (!fresh || [fresh[@"source"] isEqualToString:file[@"source"]]) continue;
        file[@"source"] = fresh[@"source"];
        file[@"playlist"] = fresh[@"playlist"] ?: @NO;
        file[@"mediaID"] = fresh[@"mediaID"] ?: @"";
        [file removeObjectForKey:@"downloadResume"];
        [file removeObjectForKey:@"session"];
        [file removeObjectForKey:@"error"];
        refreshed = YES;
    }
    return refreshed;
}

static NSMutableDictionary *ArchiveJob(NFBArchiveQueue *queue, NSDictionary *snapshot, NSString *account) {
    for (NSMutableDictionary *job in queue.jobs) {
        if ([job[@"account"] isEqualToString:account] && [job[@"post"] isEqualToString:snapshot[@"post"]]) return job;
    }
    NSMutableDictionary *job = [snapshot mutableCopy];
    [job addEntriesFromDictionary:@{@"id": NSUUID.UUID.UUIDString, @"account": account,
                                    @"state": @"waiting", @"message": @"等待上传"}];
    [queue.jobs insertObject:job atIndex:0];
    return job;
}

static BOOL IsArchiveTimelineDecoration(id model) {
    NSString *name = NSStringFromClass(object_getClass(model));
    return [@[@"_TtC10TwitterURT24URTModuleHeaderViewModel",
              @"_TtC10TwitterURT24URTModuleFooterViewModel",
              @"_TtC10TwitterURT33URTModuleSeparatorFooterViewModel",
              @"URTTimelineMessageItemViewModel"] containsObject:name ?: @""];
}

static void DisplayScanner(UIViewController *presenter, NFBArchiveScanner *scanner) {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:scanner];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:nav animated:YES completion:nil];
}

void NFBArchiveCaptureSections(id controller, NSArray *sections) {
    NSHashTable *owners = objc_getAssociatedObject(controller, &ArchiveScannerKey);
    NFBArchiveScanner *scanner = owners.anyObject;
    if (!scanner || ![sections isKindOfClass:NSArray.class]) return;
    [scanner.raw setObject:sections forKey:controller];
}

@implementation NFBArchiveScanner

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"主页媒体归档";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.raw = [NSMapTable weakToStrongObjectsMapTable];
    self.initialized = [NSHashTable weakObjectsHashTable];
    self.processedPosts = [NSMutableSet set];
    self.states = [@[@"等待", @"等待"] mutableCopy];
    self.label = [[UILabel alloc] init];
    self.label.numberOfLines = 0;
    self.label.textColor = UIColor.labelColor;
    self.label.backgroundColor = UIColor.systemBackgroundColor;
    self.label.textAlignment = NSTextAlignmentCenter;
    self.label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.label];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.label.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [self.label.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [self.label.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.label.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]
    ]];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
        style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"暂停"
        style:UIBarButtonItemStylePlain target:self action:@selector(togglePause)];
    self.label.text = @"正在准备两路媒体列表…";
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.timer && [self.batch[@"state"] isEqualToString:@"scanning"]) {
        [self mountSource];
        if (![self.batch[@"state"] isEqualToString:@"scanning"]) return;
        __weak NFBArchiveScanner *weakSelf = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
            NFBArchiveScanner *scanner = weakSelf;
            if (!scanner) { [timer invalidate]; return; }
            [scanner tick];
        }];
    }
}

- (void)dealloc { [self.timer invalidate]; }

- (void)mountSource {
    UIViewController *source = self.sources[self.sourceIndex];
    self.lastSignature = nil;
    self.lastAdvance = NSProcessInfo.processInfo.systemUptime;
    self.lastScroll = 0;
    self.states[self.sourceIndex] = @"正在加载";
    SEL setter = @selector(setLoadingDelegate:);
    if (![source respondsToSelector:setter]) {
        [self stop:@"incomplete" message:@"无法观察原生列表的首次加载"];
        return;
    }
    NSHashTable *owners = [NSHashTable weakObjectsHashTable];
    [owners addObject:self];
    objc_setAssociatedObject(source, &ArchiveScannerKey, owners, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(source, setter, self);
    [self addChildViewController:source];
    [source beginAppearanceTransition:YES animated:NO];
    source.view.frame = self.view.bounds;
    source.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    source.view.userInteractionEnabled = NO;
    source.view.accessibilityElementsHidden = YES;
    [self.view insertSubview:source.view belowSubview:self.label];
    [source didMoveToParentViewController:self];
    [source endAppearanceTransition];
    if (![self.raw objectForKey:source]) {
        NSArray *current = ObjectValue(source, @"sections");
        if ([current isKindOfClass:NSArray.class]) [self.raw setObject:current forKey:source];
    }
    self.label.text = [self summary];
}

- (void)unmountSource:(UIViewController *)source {
    if (source.parentViewController != self) return;
    objc_setAssociatedObject(source, &ArchiveScannerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SEL setter = @selector(setLoadingDelegate:);
    if ([source respondsToSelector:setter]) ((void (*)(id, SEL, id))objc_msgSend)(source, setter, nil);
    [source beginAppearanceTransition:NO animated:NO];
    [source willMoveToParentViewController:nil];
    [source.view removeFromSuperview];
    [source endAppearanceTransition];
    [source removeFromParentViewController];
}

- (void)urtViewControllerDidBeginInitialLoading:(UIViewController *)source {
    if (source == self.sources[self.sourceIndex]) self.lastAdvance = NSProcessInfo.processInfo.systemUptime;
}

- (void)urtViewController:(UIViewController *)source didLoadTimelineInitially:(BOOL)hasContent {
    if ([self.sources containsObject:source]) [self.initialized addObject:source];
}

- (NSString *)summary {
    return [NSString stringWithFormat:@"照片 %@ · 视频 %@\n已发现 %lu 条", self.states[0], self.states[1],
            (unsigned long)[self.batch[@"posts"] count]];
}

- (void)togglePause {
    NSDictionary *removing = NFBArchiveQueue.shared.removing;
    if (self.paused && [removing[@"account"] isEqual:self.batch[@"account"]] &&
        [removing[@"author"] isEqual:self.batch[@"author"]]) {
        Message(self, @"暂时无法继续", @"请等待该博主的 Drive 删除操作完成。");
        return;
    }
    if (self.paused) [self.processedPosts intersectSet:[NSSet setWithArray:self.batch[@"posts"]]];
    self.paused = !self.paused;
    self.lastAdvance = NSProcessInfo.processInfo.systemUptime;
    self.batch[@"state"] = self.paused ? @"paused" : @"scanning";
    self.batch[@"message"] = self.paused ? @"已暂停扫描" : [self summary];
    [NFBArchiveQueue.shared save];
    self.navigationItem.rightBarButtonItem.title = self.paused ? @"继续" : @"暂停";
    self.label.text = self.paused ? [@"已暂停\n" stringByAppendingString:[self summary]] : [self summary];
}

- (void)close {
    if (self.timer) [self stop:@"interrupted" message:@"扫描中断。回到该主页重新发起可继续归档，已发现的帖子会去重。"];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)openTasks {
    [self.navigationController pushViewController:ArchiveTaskList() animated:YES];
}

- (void)stop:(NSString *)state message:(NSString *)message {
    [self.timer invalidate];
    self.timer = nil;
    for (UIViewController *source in self.sources) [self unmountSource:source];
    self.batch[@"state"] = state;
    self.batch[@"message"] = message;
    if (![NFBArchiveQueue.shared save]) message = @"无法保存扫描进度";
    self.label.text = [NSString stringWithFormat:@"%@\n\n%@", [self summary], message];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"查看任务"
        style:UIBarButtonItemStylePlain target:self action:@selector(openTasks)];
    [NFBArchiveQueue.shared run];
}

- (void)tick {
    if (self.paused || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (![NFBDriveAuth.shared.account isEqualToString:self.batch[@"account"]]) {
        [self stop:@"incomplete" message:@"Google 账号已切换"]; return;
    }
    UIViewController *source = self.sources[self.sourceIndex];
    NSArray *sections = [self.raw objectForKey:source];
    BOOL initialized = [self.initialized containsObject:source];
    NSMutableArray *signature = [NSMutableArray array];
    NSMutableSet *known = [NSMutableSet setWithArray:self.batch[@"posts"]];
    NSMutableSet *unreadable = [NSMutableSet setWithArray:self.batch[@"unreadable"]];
    BOOL changed = NO, error = NO;
    Class statusClass = objc_getClass("URTTimelineStatusItemViewModel");
    Class statusAdapterClass = objc_getClass("T1TwitterCoreStatusViewModelAdapter");
    Class errorClass = objc_getClass("URTTimelineCursorErrorViewModel");
    Class cursorClass = objc_getClass("URTTimelineCursorViewModel");
    NFBArchiveQueue *queue = NFBArchiveQueue.shared;
    NSUInteger position = 0;
    for (NSArray *section in sections) {
        if (![section isKindOfClass:NSArray.class]) {
            if (initialized) {
                NSString *key = [NSString stringWithFormat:@"row:%lu:section:%lu", (unsigned long)self.sourceIndex, (unsigned long)position++];
                if (![unreadable containsObject:key]) { [unreadable addObject:key]; changed = YES; }
            }
            continue;
        }
        for (id row in section) {
            position++;
            id model = unwrapDataViewItem(row);
            if (errorClass && [model isKindOfClass:errorClass]) { error = YES; continue; }
            if (cursorClass && [model isKindOfClass:cursorClass]) {
                [signature addObject:[model description]];
                continue;
            }
            NSNumber *identifier = IntegerValue(model, @"statusID");
            NSString *postID = identifier.longLongValue > 0 ? identifier.stringValue : nil;
            BOOL status = (statusClass && [model isKindOfClass:statusClass]) ||
                          (statusAdapterClass && [model isKindOfClass:statusAdapterClass]);
            if (!status || !postID.length) {
                if (!initialized || IsArchiveTimelineDecoration(model)) continue;
                NSString *entry = StringValue(model, @[@"entryID"]);
                NSString *key = postID.length ? postID : [NSString stringWithFormat:@"row:%lu:%@:%@",
                    (unsigned long)self.sourceIndex, NSStringFromClass(object_getClass(model)) ?: @"unknown",
                    entry.length ? entry : [@(position) stringValue]];
                if (![known containsObject:key] && ![unreadable containsObject:key]) {
                    [unreadable addObject:key];
                    changed = YES;
                }
                continue;
            }
            [signature addObject:postID];
            if ([self.processedPosts containsObject:postID]) continue;
            if ([IntegerValue(model, @"isRetweet") boolValue]) continue;
            NSString *authorID = [IntegerValue(model, @"fromUserID") stringValue];
            if (authorID.length && ![authorID isEqualToString:self.batch[@"author"]]) continue;
            NSArray *assets = MediaFiles(model);
            NSDictionary *snapshot = Snapshot(model);
            if (![snapshot[@"author"] isEqualToString:self.batch[@"author"]] || !assets.count) {
                if ([known containsObject:postID]) continue;
                if (![unreadable containsObject:postID]) {
                    [unreadable addObject:postID];
                    changed = YES;
                }
                continue;
            }
            NSMutableDictionary *job = ArchiveJob(queue, snapshot, self.batch[@"account"]);
            changed |= RefreshMissingMedia(queue, job, snapshot[@"files"]);
            [self.processedPosts addObject:postID];
            if ([known containsObject:postID]) continue;
            [known addObject:postID];
            [unreadable removeObject:postID];
            changed = YES;
        }
    }
    if (changed) {
        self.batch[@"posts"] = known.allObjects;
        self.batch[@"unreadable"] = unreadable.allObjects;
        if (![queue save]) { [self stop:@"incomplete" message:@"无法保存扫描进度"]; return; }
        [queue run];
    }

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (![self.lastSignature isEqualToArray:signature]) {
        self.lastSignature = [signature copy];
        self.lastAdvance = now;
    }
    SEL tail = @selector(tfn_isContentScrolledToBottom);
    SEL scroll = @selector(scrollViewDidScroll:);
    UITableView *table = ObjectValue(source, @"tableView");
    if (![table isKindOfClass:UITableView.class] || ![source respondsToSelector:tail] ||
        ![source respondsToSelector:scroll]) {
        [self stop:@"incomplete" message:@"当前媒体列表不支持原生分页检查"]; return;
    }
    if (error) { [self stop:@"incomplete" message:@"X 返回了分页错误，请从该主页重试"]; return; }
    if (initialized && sections &&
        ((BOOL (*)(id, SEL))objc_msgSend)(source, tail)) {
        self.states[self.sourceIndex] = @"已到尾";
        self.batch[@"sources"] = [self.states copy];
        if (![queue save]) { [self stop:@"incomplete" message:@"无法保存分页进度"]; return; }
        [self unmountSource:source];
        if (self.sourceIndex == 0) {
            self.sourceIndex = 1;
            [self mountSource];
        } else {
            [self stop:unreadable.count ? @"incomplete" : @"scanned"
                message:unreadable.count ? [NSString stringWithFormat:@"%lu 个媒体条目无法确认，已保留可用项目", (unsigned long)unreadable.count] :
                    @"两路扫描完成。上传结果可在任务中心查看。"];
        }
        return;
    }
    if (now - self.lastAdvance > 45) {
        [self stop:@"incomplete" message:@"X 分页没有继续推进，也未返回到尾信号。请从主页重试。"];
        return;
    }
    if ([self.initialized containsObject:source] && now - self.lastScroll >= 2.0) {
        self.lastScroll = now;
        self.states[self.sourceIndex] = @"扫描中";
        UIEdgeInsets inset = table.adjustedContentInset;
        CGFloat bottom = MAX(-inset.top, table.contentSize.height - table.bounds.size.height + inset.bottom);
        if (fabs(table.contentOffset.y - bottom) > 0.5) {
            [table setContentOffset:CGPointMake(table.contentOffset.x, bottom) animated:NO];
        } else {
            ((void (*)(id, SEL, id))objc_msgSend)(source, scroll, table);
        }
    }
    self.label.text = [self summary];
}
@end

void NFBArchiveProfile(UIViewController *presenter, id author,
                       UIViewController *(^photos)(void), UIViewController *(^videos)(void)) {
    NSNumber *privacy = IntegerValue(author, @"protectedUser");
    NSString *authorID = [IntegerValue(author, @"userID") stringValue];
    NSString *handle = StringValue(author, @[@"username"]);
    if (!privacy || privacy.boolValue || !authorID.length || !handle.length) {
        Message(presenter, @"无法归档", @"仅支持能确认身份的公开主页。");
        return;
    }
    void (^start)(void) = ^{
        if (!presenter.view.window || presenter.presentedViewController) return;
        NSString *account = NFBDriveAuth.shared.account;
        if (!account.length) return;
        UIViewController *photoSource = photos(), *videoSource = videos();
        Class native = objc_getClass("T1URTViewController");
        if (!native || ![photoSource isKindOfClass:native] || ![videoSource isKindOfClass:native] ||
            photoSource == videoSource || photoSource.parentViewController || videoSource.parentViewController) {
            Message(presenter, @"无法归档", @"未能创建两路独立的原生媒体列表。");
            return;
        }
        NFBArchiveQueue *queue = NFBArchiveQueue.shared;
        if ([queue.removing[@"account"] isEqualToString:account] && [queue.removing[@"author"] isEqualToString:authorID]) {
            Message(presenter, @"暂时无法归档", @"请等待该博主的 Drive 删除操作完成。");
            return;
        }
        NSMutableDictionary *batch = nil;
        for (NSMutableDictionary *item in queue.batches) {
            if ([item[@"account"] isEqualToString:account] && [item[@"author"] isEqualToString:authorID]) {
                batch = item;
                break;
            }
        }
        if (!batch) {
            batch = [@{@"account": account, @"author": authorID, @"posts": @[], @"unreadable": @[]} mutableCopy];
            [queue.batches insertObject:batch atIndex:0];
        }
        batch[@"handle"] = handle;
        batch[@"name"] = StringValue(author, @[@"displayFullName", @"fullName", @"name"]) ?: handle;
        batch[@"state"] = @"scanning";
        // Unknown rows without post IDs are specific to the previous scan.
        NSMutableArray *remaining = [NSMutableArray array];
        for (NSString *key in batch[@"unreadable"]) if (![key hasPrefix:@"row:"]) [remaining addObject:key];
        batch[@"unreadable"] = remaining;
        batch[@"message"] = @"扫描中";
        batch[@"sources"] = @[@"等待", @"等待"];
        if (![queue save]) { Message(presenter, @"无法归档", @"无法保存任务，请检查本机空间。"); return; }

        NFBArchiveScanner *scanner = [NFBArchiveScanner new];
        scanner.sources = @[photoSource, videoSource];
        scanner.batch = batch;
        DisplayScanner(presenter, scanner);
    };
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"归档全部媒体到 Google Drive"
        message:[NSString stringWithFormat:@"扫描 @%@ 的公开照片与视频，保存正文和媒体文件。", handle]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"开始归档" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (NFBDriveAuth.shared.account.length) start();
            else [NFBDriveAuth.shared authorizeFrom:presenter completion:^(NSString *error) {
                if (error) Message(presenter, @"连接失败", error);
                else start();
            }];
        });
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void ConfirmRemoval(UIViewController *presenter, NSMutableDictionary *target, BOOL wholeAuthor, dispatch_block_t removed) {
    NFBArchiveQueue *queue = NFBArchiveQueue.shared;
    NSString *(^blocker)(void) = ^{
        return wholeAuthor ? [queue authorRemovalBlocker:target] : [queue removalBlocker:target];
    };
    NSString *blocked = blocker();
    if (blocked) { Message(presenter, @"暂时无法删除", blocked); return; }
    NSString *explanation = wholeAuthor
        ? @"「仅删除本机记录」移除该博主的收藏和任务，保留 Drive 文件。\n「本机和 Drive 一起删除」还会把该博主的 Drive 归档文件移到回收站。"
        : @"「仅删除本机记录」保留 Drive 文件。\n「本机和 Drive 一起删除」会把这条帖子的归档文件移到 Drive 回收站，成功后再移除本机记录。";
    if ([target[@"driveRemovalPending"] boolValue]) {
        explanation = [@"上次 Drive 删除未完成。可以重试剩余文件，或只删除本机记录。\n\n" stringByAppendingString:explanation];
    }
    NSString *title = wholeAuthor ? [NSString stringWithFormat:@"删除 %@ 的全部收藏？", target[@"name"] ?: @"该博主"] : @"删除这条收藏？";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:explanation preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"仅删除本机记录" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *currentBlocker = blocker();
            if (currentBlocker) { Message(presenter, @"暂时无法删除", currentBlocker); return; }
            BOOL success = wholeAuthor ? [queue removeAuthor:target] : [queue removeRecord:target];
            if (success) removed();
            else Message(presenter, @"未删除本机记录", @"无法写入本机收藏记录，请重试。");
        });
    }]];
    UIAlertAction *cloud = [UIAlertAction actionWithTitle:@"本机和 Drive 一起删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIBarButtonItem *button = presenter.navigationItem.rightBarButtonItem;
            UIBarButtonItem *left = presenter.navigationItem.leftBarButtonItem;
            NSString *previousTitle = button.title;
            BOOL leftWasEnabled = left.enabled;
            BOOL viewWasInteractive = presenter.view.userInteractionEnabled;
            button.enabled = NO;
            left.enabled = NO;
            presenter.view.userInteractionEnabled = NO;
            button.title = @"处理中…";
            void (^finish)(NSString *) = ^(NSString *error) {
                button.enabled = YES;
                left.enabled = leftWasEnabled;
                presenter.view.userInteractionEnabled = viewWasInteractive;
                button.title = previousTitle;
                if (error) {
                    if ([presenter isKindOfClass:UITableViewController.class] && ![(UITableViewController *)presenter isEditing]) {
                        [[(UITableViewController *)presenter tableView] reloadData];
                    }
                    Message(presenter, @"Drive 删除未完成", [error stringByAppendingString:@" 本机记录仍保留，可重新打开删除菜单重试。"]);
                } else {
                    removed();
                }
            };
            if (wholeAuthor) [queue trashAuthor:target completion:finish];
            else [queue trashArchive:target completion:finish];
        });
    }];
    cloud.enabled = [target[@"account"] isEqualToString:NFBDriveAuth.shared.account];
    if (!cloud.enabled) alert.message = [explanation stringByAppendingString:@"\n\n登录收藏时使用的 Google 账号后，才能处理 Drive 文件。"];
    [alert addAction:cloud];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void ConfirmArchiveRemoval(UIViewController *presenter, NSMutableDictionary *job, dispatch_block_t removed) {
    ConfirmRemoval(presenter, job, NO, removed);
}

static NSDictionary *ArchiveSelection(NSMutableDictionary *item, BOOL author) {
    return item ? @{@"item": item, @"authorScope": @(author)} : nil;
}

static NSString *SelectionAuthorKey(NSDictionary *item) {
    return [NSString stringWithFormat:@"%@/%@", item[@"account"], item[@"author"]];
}

static NSArray<NSDictionary *> *UniqueArchiveSelections(NSArray<NSDictionary *> *rows) {
    NSMutableSet *authors = [NSMutableSet set];
    for (NSDictionary *row in rows) if ([row[@"authorScope"] boolValue]) [authors addObject:SelectionAuthorKey(row[@"item"])];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSDictionary *item = row[@"item"];
        BOOL wholeAuthor = [row[@"authorScope"] boolValue];
        NSString *authorKey = SelectionAuthorKey(item);
        if (!wholeAuthor && [authors containsObject:authorKey]) continue;
        NSString *key = wholeAuthor ? authorKey : item[@"id"];
        if (key.length && ![seen containsObject:key]) {
            [seen addObject:key];
            [result addObject:row];
        }
    }
    return result;
}

static NSString *SelectionBlocker(NSArray<NSDictionary *> *rows) {
    NFBArchiveQueue *queue = NFBArchiveQueue.shared;
    for (NSDictionary *row in rows) {
        NSString *blocked = [row[@"authorScope"] boolValue] ? [queue authorRemovalBlocker:row[@"item"]] : [queue removalBlocker:row[@"item"]];
        if (blocked) return blocked;
    }
    return nil;
}

static void TrashSelectedArchives(NSArray<NSDictionary *> *rows, NSUInteger index, void (^completion)(NSString *)) {
    if (index == rows.count) { completion(nil); return; }
    NSDictionary *row = rows[index];
    NFBArchiveQueue *queue = NFBArchiveQueue.shared;
    void (^next)(NSString *) = ^(NSString *error) {
        if (error) {
            completion([NSString stringWithFormat:@"已处理 %lu/%lu 项。%@", (unsigned long)index, (unsigned long)rows.count, error]);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ TrashSelectedArchives(rows, index + 1, completion); });
        }
    };
    if ([row[@"authorScope"] boolValue]) [queue trashAuthor:row[@"item"] completion:next];
    else [queue trashArchive:row[@"item"] completion:next];
}

@interface NFBArchiveSelectionController : UITableViewController
@property (nonatomic, strong) UIBarButtonItem *selectionPreviousLeft;
@property (nonatomic, strong) UIBarButtonItem *selectionPreviousRight;
@property (nonatomic) BOOL selectionBusy;
- (NSDictionary *)archiveSelectionAtIndexPath:(NSIndexPath *)path;
- (void)archiveSelectionBegan;
- (void)archiveSelectionEnded;
- (void)updateArchiveSelection;
@end

@implementation NFBArchiveSelectionController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(selectArchiveFromPress:)];
    [self.tableView addGestureRecognizer:press];
}

- (NSDictionary *)archiveSelectionAtIndexPath:(NSIndexPath *)path { return nil; }
- (void)archiveSelectionBegan {}
- (void)archiveSelectionEnded { [self.tableView reloadData]; }

- (void)selectArchiveFromPress:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan || self.isEditing || self.selectionBusy) return;
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:[press locationInView:self.tableView]];
    if (!path || ![self archiveSelectionAtIndexPath:path]) return;
    self.selectionPreviousLeft = self.navigationItem.leftBarButtonItem;
    self.selectionPreviousRight = self.navigationItem.rightBarButtonItem;
    [self archiveSelectionBegan];
    [self setEditing:YES animated:YES];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
        target:self action:@selector(endArchiveSelection)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"删除"
        style:UIBarButtonItemStylePlain target:self action:@selector(removeArchiveSelection)];
    self.navigationItem.rightBarButtonItem.tintColor = UIColor.systemRedColor;
    [self.tableView selectRowAtIndexPath:path animated:NO scrollPosition:UITableViewScrollPositionNone];
    [self updateArchiveSelection];
}

- (NSArray<NSDictionary *> *)selectedArchives {
    NSMutableArray *selected = [NSMutableArray array];
    for (NSIndexPath *path in self.tableView.indexPathsForSelectedRows) {
        NSDictionary *row = [self archiveSelectionAtIndexPath:path];
        if (row) [selected addObject:row];
    }
    return UniqueArchiveSelections(selected);
}

- (void)updateArchiveSelection {
    NSUInteger count = [self selectedArchives].count;
    self.navigationItem.rightBarButtonItem.enabled = count > 0 && !self.selectionBusy;
    self.navigationItem.rightBarButtonItem.title = count ? [NSString stringWithFormat:@"删除 (%lu)", (unsigned long)count] : @"删除";
}

- (void)endArchiveSelection {
    [self setEditing:NO animated:YES];
    self.navigationItem.leftBarButtonItem = self.selectionPreviousLeft;
    self.navigationItem.rightBarButtonItem = self.selectionPreviousRight;
    self.selectionPreviousLeft = nil;
    self.selectionPreviousRight = nil;
    [self archiveSelectionEnded];
}

- (void)tableView:(UITableView *)table didDeselectRowAtIndexPath:(NSIndexPath *)path {
    if (self.isEditing) [self updateArchiveSelection];
}

- (void)removeArchiveSelection {
    if (self.selectionBusy) return;
    NSArray<NSDictionary *> *rows = [self selectedArchives];
    if (!rows.count) return;
    NSString *blocked = SelectionBlocker(rows);
    if (blocked) { Message(self, @"暂时无法删除", blocked); return; }
    if (rows.count == 1) {
        NSDictionary *row = rows.firstObject;
        ConfirmRemoval(self, row[@"item"], [row[@"authorScope"] boolValue], ^{ [self endArchiveSelection]; });
        return;
    }
    NSString *message = @"「仅删除本机记录」保留 Drive 文件。\n「本机和 Drive 一起删除」还会把所选帖子的归档文件，以及所选博主的 Drive 归档文件移到回收站。";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"删除所选 %lu 项？", (unsigned long)rows.count]
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"仅删除本机记录" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = SelectionBlocker(rows);
            if (error) { Message(self, @"暂时无法删除", error); return; }
            NFBArchiveQueue *queue = NFBArchiveQueue.shared;
            NSUInteger index = 0;
            for (NSDictionary *row in rows) {
                BOOL removed = [row[@"authorScope"] boolValue] ? [queue removeAuthor:row[@"item"]] : [queue removeRecord:row[@"item"]];
                if (!removed) break;
                index++;
            }
            [self endArchiveSelection];
            if (index < rows.count) Message(self, @"删除未完成", [NSString stringWithFormat:@"已删除 %lu/%lu 项，其他记录仍保留。",
                (unsigned long)index, (unsigned long)rows.count]);
        });
    }]];
    UIAlertAction *cloud = [UIAlertAction actionWithTitle:@"本机和 Drive 一起删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = SelectionBlocker(rows);
            if (error) { Message(self, @"暂时无法删除", error); return; }
            self.selectionBusy = YES;
            self.tableView.allowsSelection = NO;
            self.navigationItem.leftBarButtonItem.enabled = NO;
            self.navigationItem.rightBarButtonItem.enabled = NO;
            self.navigationItem.rightBarButtonItem.title = @"处理中…";
            TrashSelectedArchives(rows, 0, ^(NSString *failure) {
                self.selectionBusy = NO;
                self.tableView.allowsSelection = YES;
                self.navigationItem.leftBarButtonItem.enabled = YES;
                [self endArchiveSelection];
                if (failure) Message(self, @"Drive 删除未完成", [failure stringByAppendingString:@" 未完成的记录可以重新选择重试。"]);
            });
        });
    }];
    for (NSDictionary *row in rows) {
        if (![row[@"item"][@"account"] isEqual:NFBDriveAuth.shared.account]) {
            cloud.enabled = NO;
            alert.message = [message stringByAppendingString:@"\n\n同时删除 Drive 的文件时，所选项目必须属于当前连接的 Google 账号。"];
            break;
        }
    }
    [alert addAction:cloud];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

@interface NFBArchiveTasksController : NFBArchiveSelectionController
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, copy) NSArray *selectionBatches;
@property (nonatomic, copy) NSArray *selectionJobs;
@end

@implementation NFBArchiveTasksController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"云收藏任务";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"连接 Google" style:UIBarButtonItemStylePlain target:self action:@selector(connect)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh:) name:Changed object:nil];
    [NFBArchiveQueue.shared run];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.isEditing && self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    }
    __weak NFBArchiveTasksController *weakSelf = self;
    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        NFBArchiveTasksController *controller = weakSelf;
        if (!controller) { [timer invalidate]; return; }
        if (!controller.isEditing && [NFBArchiveQueue.shared.network isKindOfClass:NSURLSessionDownloadTask.class]) {
            [controller.tableView reloadData];
        }
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.progressTimer invalidate];
    self.progressTimer = nil;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refresh:(NSNotification *)note { if (!self.isEditing) [self.tableView reloadData]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)connect {
    [NFBDriveAuth.shared authorizeFrom:self completion:^(NSString *error) {
        Message(self, error ? @"连接失败" : @"已连接 Google Drive", error);
    }];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return [self rowsForArchiveSection:section].count;
}

- (NSArray *)rowsForArchiveSection:(NSInteger)section {
    NFBArchiveQueue *queue = NFBArchiveQueue.shared;
    return section == 0 ? (self.selectionBatches ?: queue.batches) : (self.selectionJobs ?: queue.jobs);
}

- (void)archiveSelectionBegan {
    self.selectionBatches = NFBArchiveQueue.shared.batches;
    self.selectionJobs = NFBArchiveQueue.shared.jobs;
}

- (void)archiveSelectionEnded {
    self.selectionBatches = nil;
    self.selectionJobs = nil;
    [super archiveSelectionEnded];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 2; }

- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"主页归档" : @"帖子文件";
}

- (NSArray<NSMutableDictionary *> *)jobsForBatch:(NSDictionary *)batch {
    NSSet *posts = [NSSet setWithArray:batch[@"posts"]];
    NSMutableArray *jobs = [NSMutableArray array];
    for (NSMutableDictionary *job in NFBArchiveQueue.shared.jobs) {
        if ([job[@"account"] isEqualToString:batch[@"account"]] && [posts containsObject:job[@"post"]]) {
            [jobs addObject:job];
        }
    }
    return jobs;
}

- (NSString *)batchDetails:(NSDictionary *)batch {
    NSUInteger complete = 0, failed = 0;
    NSArray *jobs = [self jobsForBatch:batch];
    for (NSDictionary *job in jobs) {
        if ([job[@"driveRemovalPending"] boolValue] || [job[@"state"] isEqualToString:@"failed"]) failed++;
        else if ([job[@"state"] isEqualToString:@"complete"]) complete++;
    }
    BOOL scanned = [batch[@"state"] isEqualToString:@"scanned"];
    NSString *status = scanned && complete == [batch[@"posts"] count] ? @"已确认全部上传" :
                       scanned ? @"扫描完成" : batch[@"message"] ?: @"扫描未完成";
    if ([batch[@"state"] isEqualToString:@"interrupted"]) status = @"扫描中断";
    return [NSString stringWithFormat:@"%@ · 已保存 %lu/%lu 条 · 失败 %lu 条", status,
        (unsigned long)complete, (unsigned long)[batch[@"posts"] count], (unsigned long)failed];
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"task"] ?:
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"task"];
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (indexPath.section == 0) {
        NSDictionary *batch = [self rowsForArchiveSection:indexPath.section][indexPath.row];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ (@%@)", batch[@"name"], batch[@"handle"]];
        cell.detailTextLabel.text = [self batchDetails:batch];
        return cell;
    }
    NSDictionary *job = [self rowsForArchiveSection:indexPath.section][indexPath.row];
    NSUInteger done = 0;
    for (NSDictionary *file in job[@"files"]) if ([file[@"done"] boolValue]) done++;
    cell.textLabel.text = job[@"prefix"];
    NSString *message = job[@"message"] ?: @"";
    if ([job[@"driveRemovalPending"] boolValue]) message = job == NFBArchiveQueue.shared.removing
        ? @"正在移到 Drive 回收站" : @"Drive 删除未完成";
    NSURLSessionTask *network = NFBArchiveQueue.shared.network;
    if (job == NFBArchiveQueue.shared.active && [network isKindOfClass:NSURLSessionDownloadTask.class]) {
        int64_t received = network.countOfBytesReceived;
        int64_t total = network.countOfBytesExpectedToReceive;
        if (received > 0 && total > 0) message = [message stringByAppendingFormat:@" · %.0f%%", MIN(100.0, 100.0 * received / total)];
    }
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu/%lu 个文件 · %@", (unsigned long)done,
                                  (unsigned long)[job[@"files"] count], message];
    return cell;
}

- (void)showBatch:(NSDictionary *)batch {
    NFBArchiveQueue *queue = NFBArchiveQueue.shared;
    NSArray *jobs = [self jobsForBatch:batch];
    NSString *title = [NSString stringWithFormat:@"@%@ 的主页归档", batch[@"handle"]];
    NSString *message = [self batchDetails:batch];
    NSArray *unreadable = batch[@"unreadable"];
    if (unreadable.count) {
        NSArray *sample = [unreadable subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)5, unreadable.count))];
        message = [message stringByAppendingFormat:@"\n\n未确认条目（%lu）：\n%@%@",
                   (unsigned long)unreadable.count, [sample componentsJoinedByString:@"\n"],
                   unreadable.count > sample.count ? @"\n…（其余未显示）" : @""];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    BOOL pending = NO, retryable = NO;
    NSString *folder = nil;
    for (NSDictionary *job in jobs) {
        NSString *state = job[@"state"];
        pending |= [state isEqualToString:@"running"] || [state isEqualToString:@"waiting"];
        retryable |= ![job[@"driveRemovalPending"] boolValue] &&
                     ([state isEqualToString:@"paused"] || [state isEqualToString:@"failed"]);
        folder = folder ?: job[@"folder"];
    }
    if (pending) [alert addAction:[UIAlertAction actionWithTitle:@"暂停上传" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        // Pause waiting jobs first so pausing the current job doesn't start the next one.
        for (NSMutableDictionary *job in jobs) if (job != queue.active) [queue pause:job];
        if ([jobs containsObject:queue.active ?: NSNull.null]) [queue pause:queue.active];
    }]];
    if (retryable) [alert addAction:[UIAlertAction actionWithTitle:@"继续或重试上传" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        for (NSMutableDictionary *job in jobs) {
            if ([job[@"driveRemovalPending"] boolValue]) continue;
            if (![job[@"state"] isEqualToString:@"paused"] && ![job[@"state"] isEqualToString:@"failed"]) continue;
            for (NSMutableDictionary *file in job[@"files"]) [file removeObjectForKey:@"error"];
            [queue resume:job];
        }
    }]];
    if (folder.length) [alert addAction:[UIAlertAction actionWithTitle:@"打开 Drive 文件夹" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:[@"https://drive.google.com/drive/folders/" stringByAppendingString:folder]];
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)table trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isEditing || indexPath.section != 1) return nil;
    NSMutableDictionary *job = NFBArchiveQueue.shared.jobs[indexPath.row];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除…" handler:^(UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
            completion(YES);
            ConfirmArchiveRemoval(self, job, ^{ [self.tableView reloadData]; });
        }];
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

- (NSDictionary *)archiveSelectionAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *rows = [self rowsForArchiveSection:indexPath.section];
    if (indexPath.row >= rows.count) return nil;
    return ArchiveSelection(rows[indexPath.row], indexPath.section == 0);
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isEditing) { [self updateArchiveSelection]; return; }
    [table deselectRowAtIndexPath:indexPath animated:YES];
    NFBArchiveQueue *queue = NFBArchiveQueue.shared;
    if (indexPath.section == 0) {
        [self showBatch:queue.batches[indexPath.row]];
        return;
    }
    NSMutableDictionary *job = queue.jobs[indexPath.row];
    NSMutableArray *details = [NSMutableArray arrayWithObject:job[@"message"] ?: @""];
    [job[@"files"] enumerateObjectsUsingBlock:^(NSDictionary *file, NSUInteger index, BOOL *stop) {
        if ([file[@"error"] length]) [details addObject:[NSString stringWithFormat:@"文件 %lu：%@", (unsigned long)(index + 1), file[@"error"]]];
    }];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:job[@"prefix"]
        message:[details componentsJoinedByString:@"\n"] preferredStyle:UIAlertControllerStyleAlert];
    NSString *state = job[@"state"];
    if ([state isEqualToString:@"running"] || [state isEqualToString:@"waiting"]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"暂停" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [queue pause:job]; }]];
    } else if (![state isEqualToString:@"complete"] && ![job[@"driveRemovalPending"] boolValue]) {
        [alert addAction:[UIAlertAction actionWithTitle:[state isEqualToString:@"failed"] ? @"重试失败项" : @"继续"
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                for (NSMutableDictionary *file in job[@"files"]) [file removeObjectForKey:@"error"];
                [queue resume:job];
            }]];
    }
    if ([job[@"folder"] length]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"打开 Drive 文件夹" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSURL *url = [NSURL URLWithString:[@"https://drive.google.com/drive/folders/" stringByAppendingString:job[@"folder"]]];
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

static UIViewController *ArchiveTaskList(void) {
    return [[NFBArchiveTasksController alloc] initWithStyle:UITableViewStyleInsetGrouped];
}

static NSString *GalleryBody(NSDictionary *job) {
    NSString *body = job[@"body"];
    if (body) return body;
    NSDictionary *textFile = [job[@"files"] firstObject];
    NSString *legacyText = textFile[@"text"];
    if (!legacyText) return @"";
    NSRange separator = [legacyText rangeOfString:@"\n\n"];
    if (separator.location == NSNotFound) return legacyText;
    body = [legacyText substringFromIndex:NSMaxRange(separator)];
    return [body hasSuffix:@"\n"] ? [body substringToIndex:body.length - 1] : body;
}

static NSString *GalleryTimestamp(NSDictionary *job) {
    if ([job[@"timestamp"] length]) return job[@"timestamp"];
    NSArray *lines = [[[job[@"files"] firstObject][@"text"] description] componentsSeparatedByString:@"\n"];
    return lines.count > 1 ? lines[1] : @"";
}

static NSUInteger GalleryCover(NSDictionary *job) {
    NSArray *files = job[@"files"];
    for (NSUInteger index = HasTextFile(job) ? 1 : 0; index < files.count; index++) {
        if ([files[index][@"done"] boolValue]) return index;
    }
    return NSNotFound;
}

static NSString *GalleryMediaName(NSDictionary *file) {
    switch ([file[@"type"] integerValue]) {
        case 1: return @"照片";
        case 2: return @"GIF";
        case 3: return @"视频";
        default: return @"附件";
    }
}

static BOOL GalleryGoogleURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    return [url.scheme isEqualToString:@"https"] &&
        ([host isEqualToString:@"www.googleapis.com"] || [host isEqualToString:@"drive.google.com"] ||
         [host hasSuffix:@".googleusercontent.com"]);
}

typedef void (^GalleryPreviewReply)(NSString *fileID, UIImage *image);

@interface NFBArchivePreviews : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSCache<NSString *, NSArray *> *cache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *pending;
+ (instancetype)shared;
- (void)load:(NSDictionary *)job index:(NSUInteger)index completion:(GalleryPreviewReply)completion;
@end

@implementation NFBArchivePreviews
+ (instancetype)shared {
    static NFBArchivePreviews *previews;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        previews = [self new];
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.HTTPShouldSetCookies = NO;
        config.URLCredentialStorage = nil;
        config.URLCache = nil;
        config.timeoutIntervalForRequest = 20;
        previews.session = [NSURLSession sessionWithConfiguration:config delegate:previews delegateQueue:nil];
        previews.cache = [NSCache new];
        previews.cache.countLimit = 96;
        previews.pending = [NSMutableDictionary dictionary];
    });
    return previews;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    if (!GalleryGoogleURL(request.URL)) { completionHandler(nil); return; }
    NSMutableURLRequest *redirect = [request mutableCopy];
    if (![response.URL.host isEqualToString:request.URL.host]) {
        [redirect setValue:nil forHTTPHeaderField:@"Authorization"];
    }
    completionHandler(redirect);
}

- (void)fetch:(NSURL *)url token:(NSString *)token completion:(void (^)(NSData *, NSInteger))completion {
    if (!GalleryGoogleURL(url)) { completion(nil, 0); return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(code == 200 ? data : nil, code); });
    }] resume];
}

- (void)resolve:(NSDictionary *)job index:(NSUInteger)index retryAuth:(BOOL)retryAuth completion:(GalleryPreviewReply)completion {
    NSString *account = job[@"account"];
    if (![account isEqualToString:NFBDriveAuth.shared.account]) { completion(nil, nil); return; }
    NSDictionary *file = job[@"files"][index];
    NSString *fileID = file[@"driveID"];
    NSDictionary *query = fileID.length ? @{@"fields": @"id,thumbnailLink,trashed"} : @{
        @"q": DriveFileQuery(DriveFileKey(job, index), job[@"folder"]),
        @"fields": @"files(id,thumbnailLink)", @"pageSize": @"1"};
    NSString *path = fileID.length ? [@"/drive/v3/files/" stringByAppendingString:fileID] : @"/drive/v3/files";
    [NFBDriveAuth.shared token:^(NSString *token, NSString *error) {
        if (!token.length || ![account isEqualToString:NFBDriveAuth.shared.account]) { completion(nil, nil); return; }
        [self fetch:API(path, query) token:token completion:^(NSData *data, NSInteger code) {
            if (![account isEqualToString:NFBDriveAuth.shared.account]) { completion(nil, nil); return; }
            if (code == 401 && retryAuth) {
                [NFBDriveAuth.shared invalidateAccessToken];
                [self resolve:job index:index retryAuth:NO completion:completion];
                return;
            }
            id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *json = [object isKindOfClass:NSDictionary.class] ? object : nil;
            NSArray *files = [json[@"files"] isKindOfClass:NSArray.class] ? json[@"files"] : nil;
            NSDictionary *metadata = fileID.length ? json : files.firstObject;
            NSString *identifier = [metadata[@"id"] isKindOfClass:NSString.class] ? metadata[@"id"] : nil;
            if (!identifier.length || [metadata[@"trashed"] boolValue]) { completion(nil, nil); return; }
            NSString *link = [metadata[@"thumbnailLink"] isKindOfClass:NSString.class] ? metadata[@"thumbnailLink"] : nil;
            if (!link.length) { completion(identifier, nil); return; }
            [self fetch:[NSURL URLWithString:link] token:token completion:^(NSData *image, NSInteger status) {
                if (![account isEqualToString:NFBDriveAuth.shared.account]) { completion(nil, nil); return; }
                completion(identifier, image.length ? [UIImage imageWithData:image] : nil);
            }];
        }];
    }];
}

- (void)load:(NSDictionary *)job index:(NSUInteger)index completion:(GalleryPreviewReply)completion {
    NSArray *files = job[@"files"];
    if (index >= files.count || ![files[index][@"done"] boolValue] || ![job[@"folder"] length] ||
        ![job[@"account"] isEqualToString:NFBDriveAuth.shared.account]) { completion(nil, nil); return; }
    NSString *key = [NSString stringWithFormat:@"%@/%@/%lu", job[@"account"], job[@"id"], (unsigned long)index];
    NSArray *cached = [self.cache objectForKey:key];
    if (cached && [cached[2] timeIntervalSinceNow] > 0) {
        completion(cached[0] == NSNull.null ? nil : cached[0], cached[1] == NSNull.null ? nil : cached[1]);
        return;
    }
    if (self.pending[key]) { [self.pending[key] addObject:[completion copy]]; return; }
    self.pending[key] = [NSMutableArray arrayWithObject:[completion copy]];
    [self resolve:job index:index retryAuth:YES completion:^(NSString *fileID, UIImage *image) {
        NSArray *callbacks = self.pending[key];
        [self.pending removeObjectForKey:key];
        [self.cache setObject:@[fileID ?: (id)NSNull.null, image ?: (id)NSNull.null,
            [NSDate dateWithTimeIntervalSinceNow:image ? 600 : 12]] forKey:key];
        for (GalleryPreviewReply callback in callbacks) callback(fileID, image);
    }];
}
@end

@interface NFBArchiveGalleryCell : UITableViewCell
@property (nonatomic, strong) NSUUID *configurationID;
@end

@implementation NFBArchiveGalleryCell
- (void)prepareForReuse {
    [super prepareForReuse];
    self.configurationID = nil;
}
@end

@interface NFBArchiveGalleryController : NFBArchiveSelectionController
@property (nonatomic, copy) NSString *authorID;
@property (nonatomic, copy) NSString *authorAccount;
@property (nonatomic, strong) NSMutableDictionary *post;
@property (nonatomic, copy) NSArray<NSDictionary *> *authors;
@property (nonatomic, copy) NSArray<NSMutableDictionary *> *posts;
@end

@implementation NFBArchiveGalleryController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 84;
    if (self.post) {
        UIBarButtonItem *remove = [[UIBarButtonItem alloc] initWithTitle:@"删除收藏"
            style:UIBarButtonItemStylePlain target:self action:@selector(removePost)];
        remove.tintColor = UIColor.systemRedColor;
        self.navigationItem.rightBarButtonItem = remove;
    } else if (self.authorID) {
        UIBarButtonItem *remove = [[UIBarButtonItem alloc] initWithTitle:@"删除全部"
            style:UIBarButtonItemStylePlain target:self action:@selector(removeAuthor)];
        remove.tintColor = UIColor.systemRedColor;
        self.navigationItem.rightBarButtonItem = remove;
    } else {
        self.title = @"云收藏";
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"任务"
            style:UIBarButtonItemStylePlain target:self action:@selector(showTasks)];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (!self.isEditing) [self refreshContent];
}

- (void)refreshContent {
    NSString *account = NFBDriveAuth.shared.account;
    NSMutableArray *posts = [NSMutableArray array];
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    NSMutableArray *authors = [NSMutableArray array];
    NSArray *sorted = [NFBArchiveQueue.shared.jobs sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"post"] compare:a[@"post"] options:NSNumericSearch];
    }];
    for (NSDictionary *job in sorted) {
        if (![job[@"account"] isEqualToString:account] || ![job[@"state"] isEqualToString:@"complete"]) continue;
        NSString *author = job[@"author"];
        if (self.authorID) {
            if ([author isEqualToString:self.authorID]) [posts addObject:job];
        } else if (!self.post) {
            NSMutableArray *group = groups[author];
            if (!group) {
                group = [NSMutableArray array];
                groups[author] = group;
                [authors addObject:@{@"id": author, @"name": job[@"folderName"], @"posts": group}];
            }
            [group addObject:job];
        }
    }
    self.authors = authors;
    self.posts = posts;
    UILabel *empty = [UILabel new];
    empty.textAlignment = NSTextAlignmentCenter;
    empty.textColor = UIColor.secondaryLabelColor;
    empty.numberOfLines = 0;
    empty.text = account.length ? @"已完成的收藏会显示在这里。\n可以在「任务」查看上传进度。" : @"请在「任务」中连接 Google Drive。";
    self.tableView.backgroundView = !self.post && !(self.authorID ? posts.count : authors.count) ? empty : nil;
    [self.tableView reloadData];
}

- (void)showTasks {
    [self.navigationController pushViewController:ArchiveTaskList() animated:YES];
}

- (void)removePost {
    ConfirmArchiveRemoval(self, self.post, ^{
        if (self.navigationController.topViewController == self) [self.navigationController popViewControllerAnimated:YES];
    });
}

- (void)removeAuthor {
    if (!self.authorAccount.length || !self.authorID.length) return;
    NSMutableDictionary *author = [@{@"account": self.authorAccount, @"author": self.authorID, @"name": self.title ?: @"该博主"} mutableCopy];
    ConfirmRemoval(self, author, YES, ^{
        if (self.navigationController.topViewController == self) [self.navigationController popViewControllerAnimated:YES];
    });
}

- (NSDictionary *)archiveSelectionAtIndexPath:(NSIndexPath *)indexPath {
    if (self.post) return ArchiveSelection(self.post, NO);
    if (self.authorID) {
        if (indexPath.row >= self.posts.count) return nil;
        return ArchiveSelection(self.posts[indexPath.row], NO);
    }
    if (indexPath.row >= self.authors.count || !NFBDriveAuth.shared.account.length) return nil;
    NSDictionary *row = self.authors[indexPath.row];
    NSMutableDictionary *author = [@{@"account": NFBDriveAuth.shared.account, @"author": row[@"id"], @"name": row[@"name"]} mutableCopy];
    return ArchiveSelection(author, YES);
}

- (void)archiveSelectionEnded {
    if (self.post && ![NFBArchiveQueue.shared.jobs containsObject:self.post]) {
        if (self.navigationController.topViewController == self) [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    [self refreshContent];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (self.post) {
        NSUInteger count = [self.post[@"files"] count];
        return section == 0 ? 1 : (HasTextFile(self.post) && count ? count - 1 : count);
    }
    return self.authorID ? self.posts.count : self.authors.count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return self.post ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return self.post && section == 1 && [self tableView:table numberOfRowsInSection:section] ? @"附件" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NFBArchiveGalleryCell *cell = [table dequeueReusableCellWithIdentifier:@"gallery"] ?:
        [[NFBArchiveGalleryCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"gallery"];
    NSUUID *configurationID = [NSUUID UUID];
    cell.configurationID = configurationID;
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.imageProperties.maximumSize = CGSizeMake(80, 80);
    content.imageProperties.reservedLayoutSize = CGSizeMake(80, 80);
    content.imageProperties.cornerRadius = 9;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    NSDictionary *job = self.post;
    NSUInteger index = NSNotFound;
    if (job && indexPath.section == 0) {
        NSString *body = GalleryBody(job);
        content.text = body.length ? body : @"媒体帖";
        content.textProperties.numberOfLines = 0;
        content.secondaryText = [@[job[@"folderName"], GalleryTimestamp(job)] componentsJoinedByString:@"\n"];
        if ([job[@"driveRemovalPending"] boolValue]) {
            content.secondaryText = [content.secondaryText stringByAppendingString:@"\nDrive 删除未完成，可再次选择「删除收藏」"];
        }
        content.secondaryTextProperties.numberOfLines = 0;
        content.imageProperties.reservedLayoutSize = CGSizeZero;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (job) {
        index = indexPath.row + (HasTextFile(job) ? 1 : 0);
        NSDictionary *file = job[@"files"][index];
        content.text = [NSString stringWithFormat:@"%@ %02lu", GalleryMediaName(file), (unsigned long)DriveFileIndex(job, index)];
        content.secondaryText = @"在 Google Drive 打开";
    } else if (self.authorID) {
        job = self.posts[indexPath.row];
        NSString *body = GalleryBody(job);
        content.text = body.length ? body : @"媒体帖";
        content.textProperties.numberOfLines = 2;
        index = GalleryCover(job);
        NSString *timestamp = GalleryTimestamp(job);
        content.secondaryText = timestamp.length ? timestamp : [job[@"prefix"] componentsSeparatedByString:@" "].firstObject;
    } else {
        NSDictionary *group = self.authors[indexPath.row];
        NSArray *posts = group[@"posts"];
        content.text = group[@"name"];
        content.secondaryText = [NSString stringWithFormat:@"%lu 条收藏", (unsigned long)posts.count];
        for (NSDictionary *candidate in posts) {
            index = GalleryCover(candidate);
            if (index != NSNotFound) { job = candidate; break; }
        }
    }
    if (cell.selectionStyle != UITableViewCellSelectionStyleNone) {
        NSNumber *type = index == NSNotFound ? nil : job[@"files"][index][@"type"];
        NSString *icon = index == NSNotFound ? (self.authorID ? @"doc.text" : @"person.crop.square") :
            (type.integerValue > 1 ? @"play.rectangle" : @"photo");
        content.image = [UIImage systemImageNamed:icon];
    }
    cell.contentConfiguration = content;
    if (index != NSNotFound) {
        __weak NFBArchiveGalleryCell *weakCell = cell;
        [NFBArchivePreviews.shared load:job index:index completion:^(NSString *fileID, UIImage *image) {
            NFBArchiveGalleryCell *current = weakCell;
            if (!image || current.configurationID != configurationID) return;
            UIListContentConfiguration *updated = [content copy];
            updated.image = image;
            current.contentConfiguration = updated;
        }];
    }
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isEditing) { [self updateArchiveSelection]; return; }
    [table deselectRowAtIndexPath:indexPath animated:YES];
    if (self.post) {
        if (indexPath.section != 1) return;
        NSUInteger index = indexPath.row + (HasTextFile(self.post) ? 1 : 0);
        __weak typeof(self) weakSelf = self;
        [NFBArchivePreviews.shared load:self.post index:index completion:^(NSString *fileID, UIImage *image) {
            NFBArchiveGalleryController *controller = weakSelf;
            if (controller.navigationController.topViewController != controller || !controller.viewIfLoaded.window) return;
            if (!ValidDriveID(fileID)) {
                Message(controller, @"无法打开附件", @"请检查网络、Google 账号或 Drive 中的文件。");
                return;
            }
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://drive.google.com/file/d/%@/view", fileID]];
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }];
        return;
    }
    NFBArchiveGalleryController *next = [[NFBArchiveGalleryController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    if (self.authorID) {
        next.post = self.posts[indexPath.row];
        next.title = @"帖子详情";
    } else {
        NSDictionary *group = self.authors[indexPath.row];
        next.authorID = group[@"id"];
        next.authorAccount = NFBDriveAuth.shared.account;
        next.title = group[@"name"];
    }
    [self.navigationController pushViewController:next animated:YES];
}
@end

UIViewController *NFBArchiveGallery(void) {
    return [[NFBArchiveGalleryController alloc] initWithStyle:UITableViewStyleInsetGrouped];
}

void NFBArchivePost(UIViewController *presenter, id status) {
    NSDictionary *snapshot = Snapshot(status);
    if (!snapshot) {
        Message(presenter, @"无法保存此帖子", @"请打开原始公开帖再试。当前帖子无法确认作者、可见性或正文。");
        return;
    }
    void (^enqueue)(void) = ^{
        NSString *account = NFBDriveAuth.shared.account;
        if (!account.length) return;
        NFBArchiveQueue *queue = NFBArchiveQueue.shared;
        if ([queue.removing[@"account"] isEqual:account] && [queue.removing[@"author"] isEqual:snapshot[@"author"]]) {
            Message(presenter, @"暂时无法收藏", @"请等待该博主的 Drive 删除操作完成。");
            return;
        }
        NSMutableDictionary *existing = nil;
        for (NSMutableDictionary *job in queue.jobs) {
            if ([job[@"account"] isEqualToString:account] && [job[@"post"] isEqualToString:snapshot[@"post"]]) {
                existing = job; break;
            }
        }
        if (!existing) {
            ArchiveJob(queue, snapshot, account);
            if (![queue save]) {
                [queue.jobs removeObjectAtIndex:0];
                Message(presenter, @"无法创建收藏任务", @"请检查本机可用空间。");
                return;
            }
        } else if ([existing[@"driveRemovalPending"] boolValue]) {
            Message(presenter, @"这条收藏有未完成的删除操作", @"请在云收藏或任务列表处理后再收藏。");
            return;
        } else if (existing != queue.active && ![existing[@"state"] isEqualToString:@"complete"]) {
            BOOL refreshed = RefreshMissingMedia(queue, existing, snapshot[@"files"]);
            if (refreshed && ![queue save]) {
                Message(presenter, @"无法更新收藏任务", @"请检查本机可用空间。");
                return;
            }
            if ([existing[@"state"] isEqualToString:@"failed"]) {
                for (NSMutableDictionary *file in existing[@"files"]) [file removeObjectForKey:@"error"];
                [queue resume:existing];
            }
        }
        [queue run];
        if (presenter.view.window && !presenter.presentedViewController) {
            [presenter presentViewController:[[UINavigationController alloc] initWithRootViewController:ArchiveTaskList()] animated:YES completion:nil];
        }
    };
    if (NFBDriveAuth.shared.account.length) enqueue();
    else [NFBDriveAuth.shared authorizeFrom:presenter completion:^(NSString *error) {
        if (error) Message(presenter, @"连接失败", error);
        else enqueue();
    }];
}
