// AudioEncoderTests.swift
// VoiceBabelTests
//
// AudioEncoder 是纯函数模块（static 方法，无副作用），测试价值最高。
// 重点测试 WAV 编码的二进制头正确性和 PCM16 转换精度——
// 这些手工构造的二进制格式，一个字节错位就会导致 API 拒绝音频。
//
// 【给你的讲解】
// XCTestCase 是 Apple 测试框架的基础类。每个 test 方法必须以 "test" 开头。
// setUp() 在每个测试方法前调用，tearDown() 在之后调用。
// XCTAssert 系列函数用来验证结果：
//   - XCTAssertEqual(a, b)：a 必须等于 b
//   - XCTAssertNil(x)：x 必须为 nil
//   - XCTAssertNotNil(x)：x 不能为 nil
//   - XCTAssertGreaterThan(a, b)：a > b
//   - XCTAssertLessThan(a, b)：a < b
// 测试失败时，Xcode 会显示哪一行断言失败以及实际值 vs 期望值。

import XCTest
@testable import VoiceBabel

// MARK: - WAV 编码测试

final class WAVEncodingTests: XCTestCase {

    // ========== 基本行为 ==========

    func testEncodeToWAV_emptyInput_returnsNil() {
        let result = AudioEncoder.encodeToWAV(samples: [])
        XCTAssertNil(result, "空输入应返回 nil")
    }

    func testEncodeToWAV_normalInput_returnsWAVFormat() {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0]
        let result = AudioEncoder.encodeToWAV(samples: samples)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.format, .wav)
    }

    // ========== WAV 文件头验证 ==========
    //
    // 【讲解】这是最有价值的测试。WAV 头是手工逐字节构造的，
    // 44 个字节里每个位置都有固定含义。如果任何一个字段写错了
    // （比如 SampleRate 写到了 ByteRate 的位置），Whisper API
    // 会返回 400 错误或者诡异的识别结果，但错误信息不会告诉你是
    // WAV 头的问题。这类 bug 只能靠测试预防。

    func testEncodeToWAV_riffHeader() {
        let samples: [Float] = Array(repeating: 0.1, count: 100)
        guard let result = AudioEncoder.encodeToWAV(samples: samples) else {
            XCTFail("encodeToWAV returned nil"); return
        }
        let data = result.data

        XCTAssertGreaterThanOrEqual(data.count, 44, "WAV 文件至少 44 字节")

        // RIFF 标识（offset 0-3）
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        // WAVE 标识（offset 8-11）
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        // fmt 子块（offset 12-15）
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")
        // data 子块（offset 36-39）
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
    }

    func testEncodeToWAV_fmtChunkFields() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        guard let result = AudioEncoder.encodeToWAV(samples: samples) else {
            XCTFail("encodeToWAV returned nil"); return
        }
        let data = result.data

        // AudioFormat = 1 (PCM)
        let audioFormat = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt16.self) }
        XCTAssertEqual(audioFormat, 1, "AudioFormat 应为 1 (PCM)")

        // NumChannels = 1 (mono)
        let channels = data.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }
        XCTAssertEqual(channels, 1, "应为单声道")

        // SampleRate = 16000
        let sampleRate = data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }
        XCTAssertEqual(sampleRate, UInt32(EngineeringOptions.sampleRate))

        // BitsPerSample = 16
        let bitsPerSample = data.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self) }
        XCTAssertEqual(bitsPerSample, 16)
    }

    func testEncodeToWAV_fileSizeField() {
        let samples: [Float] = Array(repeating: 0.5, count: 200)
        guard let result = AudioEncoder.encodeToWAV(samples: samples) else {
            XCTFail("encodeToWAV returned nil"); return
        }
        let data = result.data

        let expectedDataSize = samples.count * 2
        let expectedFileSize = 36 + expectedDataSize

        // ChunkSize 字段（offset 4）
        let fileSize = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        XCTAssertEqual(Int(fileSize), expectedFileSize)

        // data 子块大小字段（offset 40）
        let dataSize = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
        XCTAssertEqual(Int(dataSize), expectedDataSize)

        // 总文件大小 = 44 字节头 + PCM 数据
        XCTAssertEqual(data.count, 44 + expectedDataSize)
    }

    // ========== PCM16 转换精度 ==========
    //
    // 【讲解】Float32 (-1.0~1.0) → Int16 (-32767~32767) 的转换精度很重要。
    // 如果转换公式有 off-by-one 错误，音频会有轻微失真，Whisper 识别率下降。

    func testEncodeToWAV_pcm16_zero() {
        guard let result = AudioEncoder.encodeToWAV(samples: [0.0]) else {
            XCTFail("nil"); return
        }
        let sample = result.data.withUnsafeBytes { $0.load(fromByteOffset: 44, as: Int16.self) }
        XCTAssertEqual(sample, 0)
    }

    func testEncodeToWAV_pcm16_maxPositive() {
        guard let result = AudioEncoder.encodeToWAV(samples: [1.0]) else {
            XCTFail("nil"); return
        }
        let sample = result.data.withUnsafeBytes { $0.load(fromByteOffset: 44, as: Int16.self) }
        XCTAssertEqual(sample, Int16.max)  // 32767
    }

    func testEncodeToWAV_pcm16_maxNegative() {
        guard let result = AudioEncoder.encodeToWAV(samples: [-1.0]) else {
            XCTFail("nil"); return
        }
        let sample = result.data.withUnsafeBytes { $0.load(fromByteOffset: 44, as: Int16.self) }
        XCTAssertEqual(sample, -Int16.max)  // -32767（不是 Int16.min = -32768）
    }

    func testEncodeToWAV_pcm16_halfValues() {
        guard let result = AudioEncoder.encodeToWAV(samples: [0.5, -0.5]) else {
            XCTFail("nil"); return
        }
        let data = result.data
        let pos = data.withUnsafeBytes { $0.load(fromByteOffset: 44, as: Int16.self) }
        let neg = data.withUnsafeBytes { $0.load(fromByteOffset: 46, as: Int16.self) }
        XCTAssertEqual(pos, 16383)   // 0.5 * 32767 ≈ 16383
        XCTAssertEqual(neg, -16383)
    }

    func testEncodeToWAV_clamping_outOfRange() {
        // 超出 [-1, 1] 范围的值应被钳制
        guard let result = AudioEncoder.encodeToWAV(samples: [2.0, -2.0]) else {
            XCTFail("nil"); return
        }
        let data = result.data
        let over = data.withUnsafeBytes { $0.load(fromByteOffset: 44, as: Int16.self) }
        let under = data.withUnsafeBytes { $0.load(fromByteOffset: 46, as: Int16.self) }
        XCTAssertEqual(over, Int16.max, "超出上限应钳制到 max")
        XCTAssertEqual(under, -Int16.max, "超出下限应钳制到 -max")
    }
}

// MARK: - M4A 编码测试

final class M4AEncodingTests: XCTestCase {

    func testEncodeToM4A_emptyInput_returnsNil() {
        XCTAssertNil(AudioEncoder.encodeToM4A(samples: []))
    }

    func testEncodeToM4A_normalInput_returnsM4AFormat() {
        // AAC 编码器需要足够的采样才能工作
        let samples = Array(repeating: Float(0.01), count: 16000)  // 1秒
        let result = AudioEncoder.encodeToM4A(samples: samples)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.format, .m4a)
    }

    func testEncodeToM4A_compressionRatio() {
        let samples = Array(repeating: Float(0.1), count: 32000)  // 2秒
        guard let result = AudioEncoder.encodeToM4A(samples: samples) else {
            XCTFail("encodeToM4A returned nil"); return
        }
        let originalSize = samples.count * MemoryLayout<Float>.size
        XCTAssertLessThan(result.data.count, originalSize, "M4A 应比原始数据小")
    }
}

// MARK: - AudioFormat 枚举测试

final class AudioFormatTests: XCTestCase {

    func testFilename() {
        XCTAssertEqual(AudioEncoder.AudioFormat.m4a.filename, "audio.m4a")
        XCTAssertEqual(AudioEncoder.AudioFormat.wav.filename, "audio.wav")
    }

    func testContentType() {
        XCTAssertEqual(AudioEncoder.AudioFormat.m4a.contentType, "audio/mp4")
        XCTAssertEqual(AudioEncoder.AudioFormat.wav.contentType, "audio/wav")
    }
}
