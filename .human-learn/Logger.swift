//这个是为了方便文件操作
import Foundation

enum Logger {
    //所有的变量和方法均为static

    //filePath通过closure方式来实现
    private let filePath: String ={
        //内容是生成合适的filePath
    }()

    //fileHandle也通过closure方式来实现
    private let fileHandle: ? = {
        //内容是生成文件句柄
    }()

    public func i() {

    }
    public func w() {}
    public func e() {}
    public func d() {}

    private func log(
        //parameter includes: time, level, filename, linenumber, message
    ) {
        //把信息追加至文件结尾
    }
    //保留最近的信息，删除过于古老的信息
    private func trimifNeeded() {}
}