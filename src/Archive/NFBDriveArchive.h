#import <UIKit/UIKit.h>

void NFBArchivePost(UIViewController *presenter, id status);
UIViewController *NFBArchiveTasks(void);
void NFBArchiveProfile(UIViewController *presenter, id author,
                       UIViewController *(^photos)(void), UIViewController *(^videos)(void));
void NFBArchiveCaptureSections(id controller, NSArray *sections);
