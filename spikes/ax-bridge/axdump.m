// 技術驗證：不經 Simulator.app，直接透過 CoreSimulator 向模擬器要無障礙樹（idb／AXe 用的同一條路）。
// ⚠️ 私有框架：CoreSimulator（SimServiceContext／SimDevice）、AccessibilityPlatformTranslation（AXPTranslator）。
// 用法：axdump <UDID> [displayId] [--press <label>] > out.json   輸出 elements JSON（--press 時是按完之後的畫面）
// build：clang -fobjc-arc -framework Foundation -framework AppKit axdump.m -o axdump
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

@interface NSObject (Priv)
+ (id)sharedServiceContextForDeveloperDir:(NSString *)d error:(NSError **)e;
- (id)defaultDeviceSetWithError:(NSError **)e;
- (NSArray *)devices;
- (NSUUID *)UDID;
- (void)sendAccessibilityRequestAsync:(id)req completionQueue:(dispatch_queue_t)q completionHandler:(void (^)(id))h;
+ (id)sharedInstance;
- (void)setBridgeTokenDelegate:(id)d;
- (void)setSupportsDelegateTokens:(BOOL)b;
- (void)setAccessibilityEnabled:(BOOL)b;
- (id)frontmostApplicationWithDisplayId:(unsigned)d bridgeDelegateToken:(NSString *)t;
- (id)macPlatformElementFromTranslation:(id)t;
- (void)setBridgeDelegateToken:(NSString *)t;
- (id)translation;
- (BOOL)accessibilityPerformPress;
@end

typedef id (^AXPCallback)(id request);

@interface Delegate : NSObject
@property (strong) id device;
@end
@implementation Delegate
- (AXPCallback)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
  id dev = self.device;
  return ^id(id request) {
    __block id response = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [dev sendAccessibilityRequestAsync:request
                       completionQueue:dispatch_get_global_queue(0, 0)
                     completionHandler:^(id r) { response = r; dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return response;
  };
}
- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)r withToken:(NSString *)t { return r; }
- (id)accessibilityTranslationRootParentWithToken:(NSString *)t { return nil; }
@end

static NSString *roleName(NSString *axRole) {  // AXButton → button
  if (![axRole hasPrefix:@"AX"]) return axRole ?: @"";
  NSString *s = [axRole substringFromIndex:2];
  return [[[s substringToIndex:1] lowercaseString] stringByAppendingString:[s substringFromIndex:1]];
}

static NSString *str(id v) { return [v isKindOfClass:NSString.class] ? v : ([v respondsToSelector:@selector(stringValue)] ? [v stringValue] : nil); }

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: axdump <UDID> [displayId]\n"); return 2; }
    NSString *udid = @(argv[1]);
    unsigned displayId = argc > 2 ? (unsigned)atoi(argv[2]) : 0;
    NSDate *t0 = NSDate.date;
    if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) ||
        !dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_NOW)) {
      fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1;
    }
    NSString *devDir = [[[NSTask alloc] init] launchPath] ? nil : nil;  // placeholder
    FILE *p = popen("xcode-select -p", "r"); char buf[1024] = {0}; fgets(buf, sizeof buf, p); pclose(p);
    devDir = [@(buf) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSError *err = nil;
    id ctx = [NSClassFromString(@"SimServiceContext") sharedServiceContextForDeveloperDir:devDir error:&err];
    id set = [ctx defaultDeviceSetWithError:&err];
    id device = nil;
    for (id d in [set devices]) if ([[[d UDID] UUIDString] isEqualToString:udid]) device = d;
    if (!device) { fprintf(stderr, "device not found %s\n", err.description.UTF8String); return 1; }

    Delegate *del = [Delegate new]; del.device = device;
    id tr = [NSClassFromString(@"AXPTranslator") sharedInstance];
    [tr setBridgeTokenDelegate:del];
    [tr setSupportsDelegateTokens:YES];
    [tr setAccessibilityEnabled:YES];
    NSString *token = NSUUID.UUID.UUIDString;
    id translation = [tr frontmostApplicationWithDisplayId:displayId bridgeDelegateToken:token];
    if (!translation) { fprintf(stderr, "no frontmost app on display %u\n", displayId); return 1; }
    [translation setBridgeDelegateToken:token];
    id root = [tr macPlatformElementFromTranslation:translation];
    [[root translation] setBridgeDelegateToken:token];

    NSMutableArray *els = [NSMutableArray array];
    __block int nextId = 1;
    __block CGRect rootFrame = [root accessibilityFrame];
    void (^__block walk)(id, NSNumber *, int);
    void (^walkRef)(id, NSNumber *, int);
    walk = walkRef = ^(id e, NSNumber *parent, int depth) {
      if (depth > 60) return;
      [[e translation] setBridgeDelegateToken:token];
      NSString *role = roleName([e accessibilityRole]);
      NSString *label = str([e accessibilityLabel]) ?: @"";
      NSString *ident = str([e accessibilityIdentifier]) ?: @"";
      CGRect f = [e accessibilityFrame];
      NSNumber *me = parent;
      BOOL container = [role isEqualToString:@"group"] || [role isEqualToString:@"application"];
      if (!(container && label.length == 0 && ident.length == 0) && depth > 0) {
        NSMutableDictionary *o = [@{@"id": @(nextId), @"role": role, @"label": label,
          @"frame": @[@[@(f.origin.x), @(f.origin.y)], @[@(f.size.width), @(f.size.height)]],
          @"stableKey": ident.length ? [NSString stringWithFormat:@"%@|%@||%@", role, label, ident]
                                     : [NSString stringWithFormat:@"%@|%@|", role, label],
          @"traits": @[]} mutableCopy];
        if (ident.length) o[@"identifier"] = ident;
        if (parent) o[@"parentId"] = parent;
        NSString *v = str([e accessibilityValue]); if (v.length) o[@"value"] = v;
        [els addObject:o];
        me = @(nextId++);
      }
      for (id c in [e accessibilityChildren] ?: @[]) walk(c, me, depth + 1);
    };
    // --press <label>：找 label 包含文字的第一個元素（button 優先），送 AXPress（等同 VoiceOver 點兩下＝accessibilityActivate）
    NSString *press = argc > 4 && !strcmp(argv[3], "--press") ? @(argv[4]) : nil;
    __block id hitButton = nil, hitAny = nil;
    void (^find)(id, int);
    void (^__block findRef)(id, int);
    find = findRef = ^(id e, int depth) {
      if (depth > 60 || hitButton) return;
      [[e translation] setBridgeDelegateToken:token];
      NSString *l = str([e accessibilityLabel]) ?: @"";
      if (depth > 0 && [l containsString:press]) {
        if ([[e accessibilityRole] isEqualToString:@"AXButton"]) { hitButton = e; return; }
        if (!hitAny) hitAny = e;
      }
      for (id c in [e accessibilityChildren] ?: @[]) findRef(c, depth + 1);
    };
    if (press) {
      find(root, 0);
      id hit = hitButton ?: hitAny;
      if (!hit) { printf("{\"ok\":false,\"error\":\"not_found\"}\n"); return 1; }
      BOOL ok = [hit accessibilityPerformPress];
      CGRect f = [hit accessibilityFrame];
      fprintf(stderr, "pressed '%s' role=%s frame=%s ok=%d\n", [[hit accessibilityLabel] UTF8String],
              [[hit accessibilityRole] UTF8String], NSStringFromRect(f).UTF8String, ok);
      [NSThread sleepForTimeInterval:0.8];
      translation = [tr frontmostApplicationWithDisplayId:displayId bridgeDelegateToken:token];
      [translation setBridgeDelegateToken:token];
      root = [tr macPlatformElementFromTranslation:translation];
      [[root translation] setBridgeDelegateToken:token];
    }
    walk(root, nil, 0);
    NSDictionary *out = @{@"ok": @YES, @"data": @{
      @"canvasSize": @[@(rootFrame.size.width), @(rootFrame.size.height)],
      @"elements": els, @"source": @"simpilot-spike/ax-bridge",
      @"debug": @{@"rootFrame": NSStringFromRect(rootFrame), @"seconds": @(-[t0 timeIntervalSinceNow]),
                  @"displayId": @(displayId)}}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:&err];
    fwrite(data.bytes, 1, data.length, stdout);
    fprintf(stderr, "axdump: %lu elements in %.2fs\n", (unsigned long)els.count, -[t0 timeIntervalSinceNow]);
  }
  return 0;
}
