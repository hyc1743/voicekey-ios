#import "PiPVisibilityAdapter.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

// 目标私有接口（与 Typeless 2.7.0 取证一致，并按 Voxt-ios 已验证实现逐条对齐）：
//   AVPictureInPicturePlatformAdapter:
//     - (NSInteger)pictureInPictureProxyContentType:(id)proxy;   期望 6
//     - (NSInteger)_proxyControlsStyle;                          期望 5
//     - (void)_updateProxyPlaybackState;                         刷新钩子
//     - (void)_updatePlaybackStateContentTypeIfNeeded;           刷新钩子（系统重算内容类型时）
//     - (void)_setStashedOrUnderLock:(BOOL)stashed reason:(NSInteger)reason;   收起/锁定状态
//   播放状态对象: - (void)setContentType:(NSInteger)type;
//
// 设计原则（照搬已验证实现）：只替换**本类自己实现**的方法，记录替换以便完整回滚；
// 任何一步不符合预期就 invalidate 并返回 NO；stash 只观察不改行为，用户主动关闭后不偷偷重启。

@interface PiPVisibilityAdapter ()
@property(nonatomic, weak) id platformAdapter;
@property(nonatomic, weak) id playbackState;
@property(nonatomic, copy, readwrite) NSString *diagnostic;
@property(nonatomic) NSMutableArray<NSDictionary *> *hooks;
@property(nonatomic) BOOL refreshing;
@end

@implementation PiPVisibilityAdapter

- (instancetype)init {
    if ((self = [super init])) {
        _hooks = [NSMutableArray array];
        _diagnostic = @"未启用隐藏适配";
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

#pragma mark - 反射工具

static BOOL VKInteger(const char *type) {
    return type != NULL && strchr("qQ", type[0]) != NULL;
}

static BOOL VKSignature(Method method, unsigned int argumentCount, char returnType, char argumentType) {
    if (method == NULL || method_getNumberOfArguments(method) != argumentCount) { return NO; }
    char *returnEncoding = method_copyReturnType(method);
    BOOL valid = (returnType == 'q') ? VKInteger(returnEncoding)
                                     : (returnEncoding != NULL && returnEncoding[0] == returnType);
    free(returnEncoding);
    if (argumentCount > 2) {
        char *argumentEncoding = method_copyArgumentType(method, 2);
        valid = valid && ((argumentType == 'q') ? VKInteger(argumentEncoding)
                                                : (argumentEncoding != NULL && argumentEncoding[0] == argumentType));
        free(argumentEncoding);
    }
    return valid;
}

/// 优先用 getter；AVKit 有些内部属性只有 ivar、没有 getter，这时按名字直读 ivar。
static id VKReadObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil) { return nil; }
    if (![object respondsToSelector:selector]) {
        Ivar ivar = class_getInstanceVariable(object_getClass(object), name.UTF8String);
        const char *encoding = ivar ? ivar_getTypeEncoding(ivar) : NULL;
        return (encoding != NULL && encoding[0] == '@') ? object_getIvar(object, ivar) : nil;
    }
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!VKSignature(method, 2, '@', 0)) { return nil; }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

/// 只允许替换"该类的自有实现"，避免污染父类（会影响无关的 AVKit 对象）。
- (BOOL)replaceSelector:(SEL)selector
                     on:(id)object
                  block:(id)block
            argumentCount:(unsigned int)argumentCount
             returnType:(char)returnType
           argumentType:(char)argumentType {
    Class cls = object_getClass(object);
    Method method = class_getInstanceMethod(cls, selector);
    if (!VKSignature(method, argumentCount, returnType, argumentType)) { return NO; }

    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    BOOL owned = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(list[index]) == selector) { owned = YES; break; }
    }
    free(list);
    if (!owned) { return NO; }

    IMP previous = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(block);
    method_setImplementation(method, replacement);
    [_hooks addObject:@{ @"method": [NSValue valueWithPointer:method],
                         @"previous": [NSValue valueWithPointer:previous],
                         @"replacement": [NSValue valueWithPointer:replacement] }];
    return YES;
}

#pragma mark - 绑定

- (BOOL)bindToController:(AVPictureInPictureController *)controller {
    NSAssert(NSThread.isMainThread, @"PiPVisibilityAdapter 只能在主线程使用");
    [self invalidate];

    @try {
        id adapter = VKReadObject(controller, @"_platformAdapter");
        if (adapter == nil || ![adapter isKindOfClass:NSClassFromString(@"AVPictureInPicturePlatformAdapter")]) {
            _diagnostic = @"隐藏适配不可用：缺少 _platformAdapter";
            return NO;
        }
        _platformAdapter = adapter;
        __weak PiPVisibilityAdapter *weakSelf = self;

        // 1) 内容类型：让系统把这个代理内容当成"可隐藏画中画"。
        SEL contentType = NSSelectorFromString(@"pictureInPictureProxyContentType:");
        Method contentTypeMethod = class_getInstanceMethod(object_getClass(adapter), contentType);
        if (!VKSignature(contentTypeMethod, 3, 'q', '@')) {
            _diagnostic = @"隐藏适配不可用：contentType 签名变化";
            [self invalidate];
            return NO;
        }
        IMP contentTypeOriginal = method_getImplementation(contentTypeMethod);
        BOOL hooked = [self replaceSelector:contentType
                                         on:adapter
                                      block:^NSInteger(id object, id proxy) {
            if (object == weakSelf.platformAdapter) { return 6; }
            return ((NSInteger (*)(id, SEL, id))contentTypeOriginal)(object, contentType, proxy);
        }
                             argumentCount:3
                              returnType:'q'
                            argumentType:'@'];

        // 2) 控件样式：5 = 隐藏控件。
        SEL style = NSSelectorFromString(@"_proxyControlsStyle");
        Method styleMethod = class_getInstanceMethod(object_getClass(adapter), style);
        if (VKSignature(styleMethod, 2, 'q', 0)) {
            IMP styleOriginal = method_getImplementation(styleMethod);
            hooked = hooked && [self replaceSelector:style
                                                 on:adapter
                                              block:^NSInteger(id object) {
                if (object == weakSelf.platformAdapter) { return 5; }
                return ((NSInteger (*)(id, SEL))styleOriginal)(object, style);
            }
                                     argumentCount:2
                                      returnType:'q'
                                    argumentType:0];
        } else {
            hooked = NO;
        }
        if (!hooked) {
            _diagnostic = @"隐藏适配不可用：AVKit 接口不匹配";
            [self invalidate];
            return NO;
        }

        // 3) 两个刷新钩子：系统重算内容类型时会再次问一次，这里保证答的还是 6。
        for (NSString *name in @[@"_updateProxyPlaybackState", @"_updatePlaybackStateContentTypeIfNeeded"]) {
            SEL refresh = NSSelectorFromString(name);
            Method refreshMethod = class_getInstanceMethod(object_getClass(adapter), refresh);
            if (VKSignature(refreshMethod, 2, 'v', 0)) {
                IMP refreshOriginal = method_getImplementation(refreshMethod);
                [self replaceSelector:refresh
                                   on:adapter
                                block:^(id object) {
                    ((void (*)(id, SEL))refreshOriginal)(object, refresh);
                    if (object == weakSelf.platformAdapter) { [weakSelf refresh]; }
                }
                       argumentCount:2
                        returnType:'v'
                      argumentType:0];
            }
        }

        // 4) 收起/锁定钩子：只观察，不改行为（保留系统 stash，用户主动收起后不做小动作）。
        SEL stash = NSSelectorFromString(@"_setStashedOrUnderLock:reason:");
        Method stashMethod = class_getInstanceMethod(object_getClass(adapter), stash);
        if (VKSignature(stashMethod, 4, 'v', 'B') || VKSignature(stashMethod, 4, 'v', 'c')) {
            char *reasonType = method_copyArgumentType(stashMethod, 3);
            BOOL validReason = VKInteger(reasonType);
            free(reasonType);
            if (validReason) {
                IMP stashOriginal = method_getImplementation(stashMethod);
                char *stashType = method_copyArgumentType(stashMethod, 2);
                char stashEncoding = stashType[0];
                free(stashType);
                [self replaceSelector:stash
                                   on:adapter
                                block:^(id object, BOOL stashed, NSInteger reason) {
                    ((void (*)(id, SEL, BOOL, NSInteger))stashOriginal)(object, stash, stashed, reason);
                    if (object == weakSelf.platformAdapter) {
                        weakSelf.diagnostic = stashed ? @"隐藏适配：系统已收起画中画" : @"隐藏适配：画中画未收起";
                    }
                }
                       argumentCount:4
                        returnType:'v'
                      argumentType:stashEncoding];
            }
        }

        [self refresh];
        _diagnostic = @"隐藏适配已安装（实际隐藏效果需真机确认）";
        return YES;
    } @catch (NSException *exception) {
        [self invalidate];
        _diagnostic = @"隐藏适配不可用：访问 AVKit 对象失败";
        return NO;
    }
}

- (void)refresh {
    if (_refreshing) { return; }          // 防重入：setContentType 可能再次触发刷新钩子
    _refreshing = YES;
    @try {
        id proxy = VKReadObject(self.platformAdapter, @"_pegasusProxy");
        id state = VKReadObject(proxy, @"playbackState");
        if (state == nil) { return; }
        if (state != self.playbackState) {
            self.playbackState = state;
            SEL setter = NSSelectorFromString(@"setContentType:");
            Method setterMethod = class_getInstanceMethod(object_getClass(state), setter);
            if (VKSignature(setterMethod, 3, 'v', 'q')) {
                IMP setterOriginal = method_getImplementation(setterMethod);
                __weak PiPVisibilityAdapter *weakSelf = self;
                BOOL installed = NO;
                for (NSDictionary *hook in _hooks) {
                    if ([hook[@"method"] pointerValue] == setterMethod) { installed = YES; break; }
                }
                if (!installed) {
                    [self replaceSelector:setter
                                       on:state
                                    block:^(id object, NSInteger value) {
                        NSInteger target = (object == weakSelf.playbackState) ? 6 : value;
                        ((void (*)(id, SEL, NSInteger))setterOriginal)(object, setter, target);
                    }
                           argumentCount:3
                            returnType:'v'
                          argumentType:'q'];
                }
            }
        }
        SEL setter = NSSelectorFromString(@"setContentType:");
        Method setterMethod = class_getInstanceMethod(object_getClass(state), setter);
        if (VKSignature(setterMethod, 3, 'v', 'q')) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(state, setter, 6);
        }
    } @catch (NSException *exception) {
        _diagnostic = @"隐藏适配刷新失败，保留普通画中画";
    } @finally {
        _refreshing = NO;
    }
}

- (void)invalidate {
    for (NSDictionary *hook in [_hooks reverseObjectEnumerator]) {
        Method method = [hook[@"method"] pointerValue];
        IMP replacement = [hook[@"replacement"] pointerValue];
        if (method != NULL && method_getImplementation(method) == replacement) {
            method_setImplementation(method, [hook[@"previous"] pointerValue]);
            imp_removeBlock(replacement);
        }
    }
    [_hooks removeAllObjects];
    _platformAdapter = nil;
    _playbackState = nil;
}
@end
