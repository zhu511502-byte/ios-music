import Foundation

enum GzipError: LocalizedError {
    case initFailed(Int32)
    case processFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .initFailed(let code): return "gzip 初始化失败：\(code)"
        case .processFailed(let code): return "gzip 处理失败：\(code)"
        }
    }
}

enum Gzip {
    static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initResult = deflateInit2_(
            &stream,
            Int32(Z_DEFAULT_COMPRESSION),
            Int32(Z_DEFLATED),
            31, // gzip wrapper
            8,
            Int32(Z_DEFAULT_STRATEGY),
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { throw GzipError.initFailed(initResult) }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var failure: Int32?

        data.withUnsafeBytes { inputBuffer in
            if let base = inputBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) {
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base)
            } else {
                stream.next_in = nil
            }
            stream.avail_in = uInt(data.count)
            repeat {
                let result: Int32 = outputBuffer.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                    let status = deflate(&stream, Int32(Z_FINISH))
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 { output.append(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: produced) }
                    return status
                }
                if result != Z_OK && result != Z_STREAM_END {
                    failure = result
                    break
                }
                if result == Z_STREAM_END { break }
            } while stream.avail_out == 0
        }
        if let failure { throw GzipError.processFailed(failure) }
        return output
    }

    static func decompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initResult = inflateInit2_(
            &stream,
            47, // auto-detect gzip/zlib
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { throw GzipError.initFailed(initResult) }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var failure: Int32?

        data.withUnsafeBytes { inputBuffer in
            if let base = inputBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) {
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base)
            } else {
                stream.next_in = nil
            }
            stream.avail_in = uInt(data.count)
            repeat {
                let result: Int32 = outputBuffer.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                    let status = inflate(&stream, Int32(Z_NO_FLUSH))
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 { output.append(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: produced) }
                    return status
                }
                if result == Z_STREAM_END { break }
                if result != Z_OK {
                    failure = result
                    break
                }
            } while stream.avail_out == 0
        }
        if let failure { throw GzipError.processFailed(failure) }
        return output
    }
}
