#import <AVKit/AVKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 尽量把系统画中画的浮窗做成"不显示内容、不显示控件"的静默窗口。
///
/// 这是 Typeless 2.7.0 同类做法的独立实现（分析结论见项目文档）：
/// 它对 AVKit 的私有实现做**作用域限定**的替换，任何签名/类型不符都会放弃并回滚，
/// 绝不会把普通画中画搞坏——失败时只是"没隐藏"，画中画本身照常用。
///
/// ⚠️ 使用私有 API：上架审核前请移除该文件与调用点。
@interface PiPVisibilityAdapter : NSObject

/// 最近一次绑定结果的人话描述，可直接展示给用户。
@property (nonatomic, copy, readonly) NSString *diagnostic;

- (BOOL)bindToController:(AVPictureInPictureController *)controller NS_SWIFT_NAME(bind(to:));
- (void)refresh;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
