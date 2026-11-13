import Foundation
import UIKit

/// 极简崩溃记录器：把未捕获异常和致命信号的调用堆栈写到 Documents/crash.log。
/// 配合 Info.plist 里的 UIFileSharingEnabled，用户可以在「文件」App → 我的 iPhone → i短剧 里
/// 找到 crash.log 并导出，方便远程定位闪退原因。
enum CrashReporter {
    static func install() {
        NSSetUncaughtExceptionHandler(stvExceptionHandler)
        signal(SIGSEGV, stvCrashSignalHandler)
        signal(SIGABRT, stvCrashSignalHandler)
        signal(SIGBUS, stvCrashSignalHandler)
        signal(SIGILL, stvCrashSignalHandler)
        signal(SIGFPE, stvCrashSignalHandler)
        signal(SIGTRAP, stvCrashSignalHandler)
    }

    fileprivate static func write(_ text: String) {
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("crash.log")
        let line = "\n===== \(Date()) =====\n\(text)\n"
        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8) ?? Data())
                try? h.close()
                return
            }
        }
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// 未捕获 NSException 处理器（无捕获的顶层函数，可安全作为 C 函数指针）。
private func stvExceptionHandler(_ ex: NSException) {
    let stack = Thread.callStackSymbols.joined(separator: "\n")
    CrashReporter.write("NSException \(ex.name.rawValue): \(ex.reason ?? "")\n\(stack)")
}

/// 信号处理器（无捕获的顶层函数，可安全传给 signal）。
private func stvCrashSignalHandler(_ sig: Int32) {
    CrashReporter.write("Signal \(sig)\n" + Thread.callStackSymbols.joined(separator: "\n"))
    signal(sig, SIG_DFL)
    raise(sig)
}
