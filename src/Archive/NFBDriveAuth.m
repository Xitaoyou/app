#import "NFBDriveAuth.h"
#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <objc/runtime.h>

static NSString * const Service = @"com.neofreebird.archive.google";
static NSString * const Scope = @"https://www.googleapis.com/auth/drive.file openid";

static NSString *Base64URL(NSData *data) {
    NSString *value = [data base64EncodedStringWithOptions:0];
    value = [value stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    value = [value stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [value stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static NSURLComponents *Fields(NSString *url, NSDictionary *fields) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:url];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *key in fields) [items addObject:[NSURLQueryItem queryItemWithName:key value:fields[key]]];
    parts.queryItems = items;
    return parts;
}

static void Request(NSURLRequest *request, void (^done)(NSDictionary *)) {
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id object = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        dispatch_async(dispatch_get_main_queue(), ^{
            done(!error && code >= 200 && code < 300 && [object isKindOfClass:NSDictionary.class] ? object : nil);
        });
    }] resume];
}

@interface NFBDriveAuth () <ASWebAuthenticationPresentationContextProviding>
@property (nonatomic, copy) NSString *account;
@property (nonatomic, copy) NSString *refreshToken;
@property (nonatomic, copy) NSString *accessToken;
@property (nonatomic, strong) NSDate *expiry;
@property (nonatomic, strong) ASWebAuthenticationSession *session;
@property (nonatomic, weak) UIWindow *window;
@end

@implementation NFBDriveAuth

+ (instancetype)shared {
    static NFBDriveAuth *auth;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ auth = [self new]; });
    return auth;
}

- (NSDictionary *)keychainQuery {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: Service,
             (__bridge id)kSecAttrAccount: @"session"};
}

- (instancetype)init {
    if ((self = [super init])) {
        NSMutableDictionary *query = [[self keychainQuery] mutableCopy];
        query[(__bridge id)kSecReturnData] = @YES;
        CFTypeRef result = NULL;
        if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess) {
            NSData *data = CFBridgingRelease(result);
            NSDictionary *saved = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            self.account = saved[@"sub"];
            self.refreshToken = saved[@"refresh"];
        }
    }
    return self;
}

- (NSString *)clientID {
    id value = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NFBDriveClientID"];
    NSString *registered = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NFBDriveBundleID"];
    if (![registered isEqualToString:NSBundle.mainBundle.bundleIdentifier]) return @"";
    return [value isKindOfClass:NSString.class] ? value : @"";
}

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return self.window;
}

- (void)exchange:(NSDictionary *)fields completion:(void (^)(NSDictionary *))completion {
    NSURLComponents *form = Fields(@"https://oauth2.googleapis.com/token", fields);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://oauth2.googleapis.com/token"]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSString *body = [form.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    Request(request, completion);
}

- (void)authorizeFrom:(UIViewController *)presenter completion:(void (^)(NSString *))completion {
    if (self.session) { completion(@"Google 登录已打开"); return; }
    NSString *client = self.clientID;
    if (!client.length) { completion(@"此安装包缺少匹配的 Google iOS OAuth 配置，请检查构建配置和实际安装的 Bundle ID"); return; }
    NSString *scheme = [[[client componentsSeparatedByString:@"."] reverseObjectEnumerator].allObjects componentsJoinedByString:@"."];
    NSString *redirect = [scheme stringByAppendingString:@":/oauthredirect"];
    unsigned char bytes[64], digest[CC_SHA256_DIGEST_LENGTH];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) {
        completion(@"无法启动安全登录"); return;
    }
    NSString *verifier = Base64URL([NSData dataWithBytes:bytes length:32]);
    NSString *state = Base64URL([NSData dataWithBytes:bytes + 32 length:32]);
    NSData *encoded = [verifier dataUsingEncoding:NSASCIIStringEncoding];
    CC_SHA256(encoded.bytes, (CC_LONG)encoded.length, digest);
    NSURL *url = Fields(@"https://accounts.google.com/o/oauth2/v2/auth", @{
        @"client_id": client, @"redirect_uri": redirect, @"response_type": @"code",
        @"scope": Scope, @"state": state, @"code_challenge_method": @"S256",
        @"code_challenge": Base64URL([NSData dataWithBytes:digest length:sizeof(digest)]),
        @"access_type": @"offline", @"prompt": @"consent select_account"
    }).URL;
    self.window = presenter.view.window;
    self.session = [[ASWebAuthenticationSession alloc] initWithURL:url callbackURLScheme:scheme completionHandler:^(NSURL *callback, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.session = nil;
            NSURLComponents *parts = callback ? [NSURLComponents componentsWithURL:callback resolvingAgainstBaseURL:NO] : nil;
            NSMutableDictionary *values = [NSMutableDictionary dictionary];
            for (NSURLQueryItem *item in parts.queryItems) if (item.value) values[item.name] = item.value;
            if (error || ![parts.scheme isEqualToString:scheme] || ![parts.path isEqualToString:@"/oauthredirect"] ||
                ![values[@"state"] isEqualToString:state] || ![values[@"code"] length]) {
                completion(@"Google 授权未完成"); return;
            }
            [self exchange:@{@"grant_type": @"authorization_code", @"client_id": client, @"redirect_uri": redirect,
                             @"code_verifier": verifier, @"code": values[@"code"]} completion:^(NSDictionary *tokens) {
                NSString *access = tokens[@"access_token"];
                NSString *refresh = tokens[@"refresh_token"];
                if (!access.length || !refresh.length) { completion(@"Google 未返回可续期的授权"); return; }
                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://openidconnect.googleapis.com/v1/userinfo"]];
                [request setValue:[@"Bearer " stringByAppendingString:access] forHTTPHeaderField:@"Authorization"];
                Request(request, ^(NSDictionary *user) {
                    NSString *sub = user[@"sub"];
                    if (!sub.length) { completion(@"无法确认 Google 账号"); return; }
                    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"sub": sub, @"refresh": refresh} options:0 error:nil];
                    NSDictionary *query = [self keychainQuery];
                    NSDictionary *update = @{(__bridge id)kSecValueData: data};
                    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
                    if (status == errSecItemNotFound) {
                        NSMutableDictionary *record = [query mutableCopy];
                        [record addEntriesFromDictionary:update];
                        record[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
                        status = SecItemAdd((__bridge CFDictionaryRef)record, NULL);
                    }
                    if (status != errSecSuccess) { completion(@"无法保存 Google 授权"); return; }
                    self.account = sub;
                    self.refreshToken = refresh;
                    self.accessToken = access;
                    self.expiry = [NSDate dateWithTimeIntervalSinceNow:MAX(0, [tokens[@"expires_in"] doubleValue] - 60)];
                    completion(nil);
                });
            }];
        });
    }];
    self.session.presentationContextProvider = self;
    if (![self.session start]) { self.session = nil; completion(@"无法打开 Google 登录"); }
}

- (void)token:(void (^)(NSString *, NSString *))completion {
    if (self.accessToken.length && self.expiry.timeIntervalSinceNow > 0) { completion(self.accessToken, nil); return; }
    if (!self.refreshToken.length || !self.clientID.length) { completion(nil, @"请先连接 Google Drive"); return; }
    NSString *account = self.account;
    [self exchange:@{@"client_id": self.clientID, @"grant_type": @"refresh_token", @"refresh_token": self.refreshToken}
         completion:^(NSDictionary *tokens) {
        if (![self.account isEqualToString:account] || ![tokens[@"access_token"] length]) {
            completion(nil, @"无法更新 Google 授权，请检查网络或重新登录"); return;
        }
        self.accessToken = tokens[@"access_token"];
        self.expiry = [NSDate dateWithTimeIntervalSinceNow:MAX(0, [tokens[@"expires_in"] doubleValue] - 60)];
        completion(self.accessToken, nil);
    }];
}

- (void)invalidateAccessToken { self.expiry = nil; }
@end
