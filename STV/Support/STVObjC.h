#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 安全地结束一个 AVAssetResourceLoadingRequest。
///
/// iOS 16 上，若请求已被取消（AVPlayer 返回/切源时 cancel）或已经完成，再次调用
/// `finishLoading` / `finishLoadingWithError:` 会抛 NSException（SIGABRT，崩溃日志为
/// `-[AVAssetResourceLoadingRequest finishLoadingWithError:]`）。此外 isCancelled/isFinished
/// 的检查与 finish 之间存在 TOCTOU 竞态窗口，Swift 侧无法捕获 NSException，
/// 因此在这里用 @try/@catch 兜底。
///
/// @return YES 表示已成功结束；NO 表示请求已作废或结束失败，调用方应跳过后续处理。
BOOL STVFinishLoading(AVAssetResourceLoadingRequest *request, NSError * _Nullable error);

NS_ASSUME_NONNULL_END
