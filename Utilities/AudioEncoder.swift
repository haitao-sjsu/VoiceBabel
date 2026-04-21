// AudioEncoder.swift
// VoiceBabel - macOS 菜单栏语音转文字工具
//
// 音频编码模块 —— 将内存中的 Float32 PCM 采样数据编码为可上传的音频文件格式。
//
// 职责：
//   1. encodeToM4A()：Float32 → 临时 AVAudioFile（AAC 16kHz 24kbps）→ 读回压缩数据
//      压缩比约 20:1，显著减少上传时间和 API 调用费用
//   2. encodeToWAV()：手动构造 WAV 文件（44 字节头 + PCM16 数据）
//      作为 M4A 编码失败时的后备方案，不依赖任何系统编码器
//
// 编码策略：
//   优先 M4A（AAC 压缩） → 失败自动回退 WAV（无压缩）
//   由 EngineeringOptions.enableAudioCompression 控制是否启用压缩
//
// 设计：
//   使用 caseless enum 作为纯命名空间，所有方法均为 static。
//   同时定义了 AudioFormat 枚举和 EncodingResult 结构体，
//   被 AudioRecorder.RecordingResult 和 CloudOpenAIService 共用。
//
// 依赖：
//   - AVFoundation：AVAudioFile, AVAudioPCMBuffer, AVAudioFormat
//   - EngineeringOptions：sampleRate（16kHz）、aacBitRate（24kbps）
//
// 架构角色：
//   由 AudioRecorder.stopRecording() 调用，产出的数据传递给 CloudOpenAIService。

import AVFoundation

/// 音频编码器（使用 enum 作为命名空间，不可实例化）
/// 将 Float32 PCM 采样数据编码为压缩的音频文件格式
enum AudioEncoder {

    // MARK: - 公共方法

    /// 将浮点音频数据编码为 M4A 格式（AAC 压缩）
    ///
    /// 编码流程：
    /// 1. 将 Float32 采样数据写入 AVAudioPCMBuffer
    /// 2. 通过 AVAudioFile 写入临时 M4A 文件（系统自动完成 AAC 编码）
    /// 3. 读取临时文件内容到 Data
    /// 4. 清理临时文件
    ///
    /// - Parameter samples: Float32 PCM 采样数据（值域 -1.0 ~ 1.0）
    /// - Returns: 编码结果，失败时自动回退到 WAV 格式；数据为空时返回 nil
    static func encodeToM4A(samples: [Float]) -> EncodingResult? {
        guard !samples.isEmpty else {
            Log.w("AudioEncoder: encodeToM4A skipped, empty samples")
            return nil
        }

        // 创建临时文件路径（AVAudioFile 需要写入磁盘文件，不支持纯内存操作）
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")

        defer {
            // 无论编码成功与否，都清理临时文件
            try? FileManager.default.removeItem(at: tempURL)
        }

        // 创建输入格式描述：32位浮点、单声道、16kHz
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: EngineeringOptions.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            Log.e("AudioEncoder: 无法创建输入格式")
            return encodeToWAV(samples: samples)
        }

        // 创建 AAC 输出格式描述
        // 注意：AAC 是可变比特率编码，mBytesPerPacket/mBytesPerFrame 设为 0（由编码器决定）
        // mFramesPerPacket = 1024 是 AAC 标准帧大小
        var outputDescription = AudioStreamBasicDescription(
            mSampleRate: EngineeringOptions.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,        // 可变比特率，编码器自行决定
            mFramesPerPacket: 1024,    // AAC 标准：每个包含 1024 个采样帧
            mBytesPerFrame: 0,         // 压缩格式无固定帧大小
            mChannelsPerFrame: 1,      // 单声道
            mBitsPerChannel: 0,        // 压缩格式不指定位深度
            mReserved: 0
        )

        // 验证系统是否支持该 AAC 格式
        guard AVAudioFormat(streamDescription: &outputDescription) != nil else {
            Log.e("AudioEncoder: 无法创建 AAC 输出格式")
            return encodeToWAV(samples: samples)
        }

        // 创建 PCM 输入缓冲区，容量为采样点总数
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            Log.e("AudioEncoder: 无法创建输入缓冲区")
            return encodeToWAV(samples: samples)
        }

        // 将 Float32 采样数据逐个复制到缓冲区的通道数据指针中
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = inputBuffer.floatChannelData?[0] {
            for (index, sample) in samples.enumerated() {
                channelData[index] = sample
            }
        }

        // 创建 M4A 输出文件并写入编码后的数据
        // AVAudioFile 会根据 settings 自动选择 AAC 编码器进行压缩
        do {
            let outputFile = try AVAudioFile(
                forWriting: tempURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: EngineeringOptions.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: EngineeringOptions.aacBitRate   // 24kbps，针对语音优化的低比特率
                ]
            )
            try outputFile.write(from: inputBuffer)
            // outputFile 在此 do 作用域结束时自动关闭，确保数据刷新到磁盘
        } catch {
            Log.e("AudioEncoder: M4A 编码失败 - \(error)")
            return encodeToWAV(samples: samples)
        }

        // 从磁盘读取编码后的 M4A 数据（文件已关闭，数据完整）
        guard let compressedData = try? Data(contentsOf: tempURL) else {
            Log.e("AudioEncoder: 读取压缩文件失败")
            return encodeToWAV(samples: samples)
        }

        // 打印压缩效果信息
        let originalSize = samples.count * 4  // Float32 = 4 字节/采样
        let compressionRatio = Double(originalSize) / Double(compressedData.count)
        Log.i("音频压缩完成: \(originalSize / 1024) KB → \(compressedData.count / 1024) KB (压缩比 \(String(format: "%.1f", compressionRatio)):1)")

        return EncodingResult(data: compressedData, format: .m4a)
    }

    /// 将浮点音频数据编码为 WAV 格式（无损、无压缩）
    ///
    /// 作为 M4A 编码失败时的后备方案。WAV 是最简单的音频格式，
    /// 手动构建文件头 + 原始 PCM 数据即可，不依赖任何系统编码器。
    ///
    /// WAV 文件结构：
    /// ┌──────────────────────┐
    /// │ RIFF 头（12 字节）    │  标识文件类型为 WAVE
    /// ├──────────────────────┤
    /// │ fmt 子块（24 字节）   │  描述音频格式参数
    /// ├──────────────────────┤
    /// │ data 子块头（8 字节） │  标识数据块开始
    /// ├──────────────────────┤
    /// │ PCM 音频数据          │  16-bit 有符号整数，小端序
    /// └──────────────────────┘
    ///
    /// - Parameter samples: Float32 PCM 采样数据（值域 -1.0 ~ 1.0）
    /// - Returns: 编码结果
    static func encodeToWAV(samples: [Float]) -> EncodingResult? {
        Log.i("AudioEncoder: 使用 WAV 格式")
        guard !samples.isEmpty else {
            Log.w("AudioEncoder: encodeToWAV skipped, empty samples")
            return nil
        }

        // 将 Float32（-1.0 ~ 1.0）转换为 Int16（-32768 ~ 32767）
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))           // 防止溢出
            return Int16(clamped * Float(Int16.max))             // 缩放到 Int16 范围
        }

        var data = Data()

        let dataSize = int16Samples.count * 2   // 每个 Int16 占 2 字节
        let fileSize = 36 + dataSize            // 文件头固定 44 字节，减去 RIFF 标识和大小字段的 8 字节 = 36

        // ===== RIFF 头（12 字节）=====
        data.append("RIFF".data(using: .ascii)!)                                                    // ChunkID：固定 "RIFF"
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })    // ChunkSize：文件总大小 - 8
        data.append("WAVE".data(using: .ascii)!)                                                    // Format：固定 "WAVE"

        // ===== fmt 子块（24 字节）=====
        data.append("fmt ".data(using: .ascii)!)                                                                    // SubchunkID：固定 "fmt "
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })                         // SubchunkSize：PCM 格式固定 16 字节
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })                          // AudioFormat：1 = PCM（无压缩）
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })                          // NumChannels：1 = 单声道
        data.append(contentsOf: withUnsafeBytes(of: UInt32(EngineeringOptions.sampleRate).littleEndian) { Array($0) })       // SampleRate：16000 Hz
        data.append(contentsOf: withUnsafeBytes(of: UInt32(EngineeringOptions.sampleRate * 2).littleEndian) { Array($0) })   // ByteRate：采样率 x 声道数 x 每采样字节数
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })                          // BlockAlign：声道数 x 每采样字节数
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })                         // BitsPerSample：16 位

        // ===== data 子块 =====
        data.append("data".data(using: .ascii)!)                                                    // SubchunkID：固定 "data"
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })    // SubchunkSize：音频数据大小

        // 逐个写入 Int16 采样值（小端序）
        for sample in int16Samples {
            data.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) })
        }

        Log.i("WAV encoding complete: \(data.count / 1024) KB")
        return EncodingResult(data: data, format: .wav)
    }

    // MARK: - 类型定义

    /// 音频文件格式
    enum AudioFormat {
        case m4a    // AAC 压缩格式，体积小
        case wav    // PCM 无压缩格式，兼容性好

        /// 上传到 API 时使用的文件名
        var filename: String {
            switch self {
            case .m4a: return "audio.m4a"
            case .wav: return "audio.wav"
            }
        }

        /// HTTP multipart 上传时使用的 MIME 类型
        var contentType: String {
            switch self {
            case .m4a: return "audio/mp4"  // M4A 属于 MPEG-4 容器，MIME 类型为 audio/mp4
            case .wav: return "audio/wav"
            }
        }
    }

    /// 编码结果，包含编码后的二进制数据和对应的格式信息
    struct EncodingResult {
        let data: Data
        let format: AudioFormat
    }
}
