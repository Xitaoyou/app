#import <UIKit/UIKit.h>

@interface NFBDriveAuth : NSObject
@property (nonatomic, readonly) NSString *account;
+ (instancetype)shared;
- (void)authorizeFrom:(UIViewController *)presenter completion:(void (^)(NSString *error))completion;
- (void)token:(void (^)(NSString *token, NSString *error))completion;
- (void)invalidateAccessToken;
@end
