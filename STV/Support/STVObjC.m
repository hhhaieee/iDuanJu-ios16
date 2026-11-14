#import "STVObjC.h"

BOOL STVFinishLoading(AVAssetResourceLoadingRequest *request, NSError *error) {
    if (request == nil) {
        return NO;
    }
    if (request.isCancelled || request.isFinished) {
        return NO;
    }
    @try {
        if (error != nil) {
            [request finishLoadingWithError:error];
        } else {
            [request finishLoading];
        }
        return YES;
    } @catch (NSException *exception) {
        // 请求在检查与 finish 之间被 AVPlayer 取消/完成，忽略即可。
        return NO;
    }
}
