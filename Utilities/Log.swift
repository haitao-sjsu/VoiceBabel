// Log.swift
// WhisperUtil - macOS 菜单栏语音转文字工具
//
// 统一日志工具 —— 同时输出到控制台（Xcode Console）和日志文件。
//
// 职责：
//   提供全局日志接口 Log.i/w/e/d()，每条日志包含时间戳、级别、源文件:行号和消息内容。
//   日志同时写入控制台和沙盒内的文件，便于开发调试和生产环境排查。
//
// 日志级别：
//   - Log.i()：INFO，正常运行信息（状态变更、操作完成等）
//   - Log.w()：WARN，警告信息（可恢复的异常、回退操作等）
//   - Log.e()：ERROR，错误信息（API 失败、编码失败等）
//   - Log.d()：DEBUG，调试信息（仅 #if DEBUG 模式输出，Release 自动移除）
//
// 日志文件：
//   路径：~/Library/Containers/Personal.WhisperUtil/Data/Library/Logs/whisperutil.log
//   条数限制：累积到 1000 条时截断保留最新 500 条
//   格式：[MM-dd HH:mm:ss] [LEVEL] [FileName:Line] Message
//
// 设计：
//   使用 caseless enum 作为纯命名空间。FileHandle 延迟初始化并保持打开（避免频繁开关文件）。
//   每次应用启动时写入分隔线标记。
//
// 依赖：无
//
// 架构角色：
//   被所有组件引用，提供统一的日志输出。

import Foundation

enum Log {

    // MARK: - 日志文件路径

    /// 日志文件路径（沙盒容器内）
    static let logFilePath: String = {
        // NSHomeDirectory() 在沙盒应用中返回容器路径
        let logDir = NSHomeDirectory() + "/Library/Logs"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        return logDir + "/whisperutil.log"
    }()

    /// 触发截断的行数上限
    private static let maxLineCount = 1000
    /// 截断后保留的行数
    private static let keepLineCount = 500

    /// 当前日志文件行数计数器
    private static var lineCount: Int = 0

    /// 日志文件句柄（延迟初始化，保持打开）
    private static let fileHandle: FileHandle? = {
        let fm = FileManager.default

        if !fm.fileExists(atPath: logFilePath) {
            fm.createFile(atPath: logFilePath, contents: nil)
        }

        // 统计现有日志行数，初始化计数器
        if let data = fm.contents(atPath: logFilePath) {
            lineCount = data.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
        }

        let handle = FileHandle(forWritingAtPath: logFilePath)
        handle?.seekToEndOfFile()

        // 写入启动分隔线
        let separator = "\n========== WhisperUtil 启动 (\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium))) ==========\n"
        if let data = separator.data(using: .utf8) {
            handle?.write(data)
        }
        lineCount += 2  // 分隔线占 2 行（前后各一个换行）

        return handle
    }()

    /// 截断日志文件，保留最新的 keepLineCount 条
    private static func trimIfNeeded() {
        guard lineCount >= maxLineCount else { return }

        guard let data = FileManager.default.contents(atPath: logFilePath) else { return }

        // 从头开始跳过 (lineCount - keepLineCount) 个换行符
        let linesToSkip = lineCount - keepLineCount
        var skipped = 0
        var cutIndex = data.startIndex
        for i in data.indices {
            if data[i] == UInt8(ascii: "\n") {
                skipped += 1
                if skipped == linesToSkip {
                    cutIndex = data.index(after: i)
                    break
                }
            }
        }

        let trimmed = data[cutIndex...]
        try? trimmed.write(to: URL(fileURLWithPath: logFilePath))
        lineCount = keepLineCount

        // 重新定位文件句柄到末尾
        fileHandle?.seekToEndOfFile()
    }

    // MARK: - 公共方法

    /// 信息日志
    static func i(_ message: String, file: String = #file, line: Int = #line) {
        log(level: "INFO", message: message, file: file, line: line)
    }

    /// 警告日志
    static func w(_ message: String, file: String = #file, line: Int = #line) {
        log(level: "WARN", message: message, file: file, line: line)
    }

    /// 错误日志
    static func e(_ message: String, file: String = #file, line: Int = #line) {
        log(level: "ERROR", message: message, file: file, line: line)
    }

    /// 调试日志（仅 Debug 模式）
    static func d(_ message: String, file: String = #file, line: Int = #line) {
        #if DEBUG
        log(level: "DEBUG", message: message, file: file, line: line)
        #endif
    }

    // MARK: - 私有方法

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    private static func log(level: String, message: String, file: String, line: Int) {
        let fileName = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let timestamp = dateFormatter.string(from: Date())
        let formatted = "[\(timestamp)] [\(level)] [\(fileName):\(line)] \(message)\n"

        // 输出到控制台
        print(formatted, terminator: "")

        // 写入文件
        if let data = formatted.data(using: .utf8) {
            fileHandle?.seekToEndOfFile()
            fileHandle?.write(data)
            lineCount += 1
            trimIfNeeded()
        }
    }
}
