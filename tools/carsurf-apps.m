// carsurf-apps — dumps what LaunchServices knows about every installed app, so the
// preference picker's filter can be chosen from real data rather than from
// guesses about which names look internal.
//
//   carsurf-apps            every app, with the properties the filter can use
//   carsurf-apps -k         only the ones the current filter keeps
//   carsurf-apps -d         only the ones it drops

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "CSAppFilter.h"

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;
@property (nonatomic, readonly) NSURL *bundleURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        BOOL onlyKept = (argc > 1 && strcmp(argv[1], "-k") == 0);
        BOOL onlyDropped = (argc > 1 && strcmp(argv[1], "-d") == 0);

        Class workspaceClass = objc_getClass("LSApplicationWorkspace");
        id workspace = ((id (*)(Class, SEL))objc_msgSend)(workspaceClass,
                                                         sel_getUid("defaultWorkspace"));
        NSArray<LSApplicationProxy *> *all =
            ((id (*)(id, SEL))objc_msgSend)(workspace, sel_getUid("allApplications"));

        NSUInteger kept = 0, dropped = 0;
        NSMutableArray<NSString *> *lines = [NSMutableArray new];

        for (LSApplicationProxy *proxy in all) {
            NSString *reason = nil;
            BOOL keep = CSAppIsUserVisible(proxy, &reason);
            keep ? kept++ : dropped++;

            if (onlyKept && !keep) continue;
            if (onlyDropped && keep) continue;

            [lines addObject:[NSString stringWithFormat:@"%@ %-46s %-8s %-22s %@",
                keep ? @"KEEP" : @"drop",
                proxy.applicationIdentifier.UTF8String,
                proxy.applicationType.UTF8String ?: "?",
                keep ? "" : (reason.UTF8String ?: "?"),
                proxy.localizedName ?: @""]];
        }

        [lines sortUsingSelector:@selector(caseInsensitiveCompare:)];
        for (NSString *line in lines) printf("%s\n", line.UTF8String);

        printf("\n%lu total: %lu kept, %lu dropped\n",
               (unsigned long)all.count, (unsigned long)kept, (unsigned long)dropped);
        return 0;
    }
}
