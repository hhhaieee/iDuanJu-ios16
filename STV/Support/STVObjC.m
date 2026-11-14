#import "STVObjC.h"

BOOL STVFinishLoading(AVAssetResourceLoadingRequest *request, NSError *error) {
    if (request == nil) {
        return NO;
    }
    if (request.isCancelled || request.isFinished) {
        return NO;
    }
    @try {
        // iOS 16 上 finishLoadingWithError: 对已取消/已完成请求会直接 abort（SIGABRT），
        // 且该 abort 无法被 @try/@catch 捕获。失败场景也统一走 finishLoading：AVPlayer
        // 收到空数据后自行进入失败状态，行为等价但不会崩溃。error 仅留作上层日志语义。
        (void)error;
        [request finishLoading];
        return YES;
    } @catch (NSException *exception) {
        // 请求在检查与 finish 之间被 AVPlayer 取消/完成，忽略即可。
        return NO;
    }
}
