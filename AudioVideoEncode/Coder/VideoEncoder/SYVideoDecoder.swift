//
//  SYVideoDecoder.swift
//  AudioVideoEncode
//

import AVFoundation
import VideoToolbox

protocol SYVideoDecoderDelegate {
    /// 解码完成回调
    func videoDecodeCallback(imageBuffer: CVPixelBuffer) -> Void
}

class SYVideoDecoder {
    /// 代理
    var delegate: SYVideoDecoderDelegate?
    /// config
    private var config: SYVideoConfig!
    /// 解码session
    private var decodeSession: VTDecompressionSession!
    /// 解码描述信息
    private var decodeDesc: CMVideoFormatDescription!
    /// 解码异步队列
    lazy private var decodeQueue: dispatch_queue_global_t = {
        let queue = dispatch_queue_global_t.init(label: "decode_queue")
        return queue
    }()
    /// 解码完成回调异步队列
    lazy private var callbackQueue: dispatch_queue_global_t = {
        let queue = dispatch_queue_global_t.init(label: "callback_queue")
        return queue
    }()
    /// 存放sps数据
    private var sps: [UInt8] = []
    /// 存放pps数据
    private var pps: [UInt8] = []
    /// 解码完成回调函数
    private var decompressionOutputCallback: VTDecompressionOutputCallback!
    
    required init(config: SYVideoConfig) {
        self.config = config
        didDeCompressH264()
    }
    
    deinit {
        if decodeSession != nil {
            VTDecompressionSessionInvalidate(decodeSession)
            decodeSession = nil
        }
    }
}

/// MARK: -初始化解码器
extension SYVideoDecoder {
    private func initDecoder() -> Bool {
        if decodeSession != nil {
            return true
        }
        /**
         根据sps pps设置解码参数
         param kCFAllocatorDefault 分配器
         param 2 参数个数
         param parameterSetPointers 参数集指针
         param parameterSetSizes 参数集大小
         param naluHeaderLen nalu nalu start code 的长度 4
         param _decodeDesc 解码器描述
         return 状态
         */
        var parameterSetPointers = [sps.withUnsafeBufferPointer{$0}.baseAddress!, pps.withUnsafeBufferPointer{$0}.baseAddress!]
        var parameterSetSizes = [sps.count, pps.count]
        let nalUnitHeaderLength: Int32 = 4
        var status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                                                                         parameterSetCount: 2,
                                                                         parameterSetPointers: &parameterSetPointers,
                                                                         parameterSetSizes: &parameterSetSizes,
                                                                         nalUnitHeaderLength: nalUnitHeaderLength,
                                                                         formatDescriptionOut: &decodeDesc)
        debugPrint("CMVideoFormatDescriptionCreateFromH264ParameterSets: result=\(status)")
        if status != noErr { return false }
        
        /**
         解码参数:
        * kCVPixelBufferPixelFormatTypeKey:摄像头的输出数据格式
         kCVPixelBufferPixelFormatTypeKey，已测可用值为
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange，即420v
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange，即420f
            kCVPixelFormatType_32BGRA，iOS在内部进行YUV至BGRA格式转换
         YUV420一般用于标清视频，YUV422用于高清视频，这里的限制让人感到意外。但是，在相同条件下，YUV420计算耗时和传输压力比YUV422都小。
         
         kCVPixelBufferWidthKey/kCVPixelBufferHeightKey: 视频源的分辨率 width*height
         * kCVPixelBufferOpenGLCompatibilityKey : 它允许在 OpenGL 的上下文中直接绘制解码后的图像，而不是从总线和 CPU 之间复制数据。这有时候被称为零拷贝通道，因为在绘制过程中没有解码的图像被拷贝.
         */
        let imageBufferAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: Int32(config.width),
            kCVPixelBufferHeightKey: Int32(config.height),
            kCVPixelBufferOpenGLCompatibilityKey: true] as [CFString : Any] as CFDictionary
        
        /** 创建session
         @function    VTDecompressionSessionCreate
         @abstract    创建用于解压缩视频帧的会话。
         @discussion  解压后的帧将通过调用OutputCallback发出
         @param    allocator  内存的会话。通过使用默认的kCFAllocatorDefault的分配器。
         @param    videoFormatDescription 描述源视频帧
         @param    videoDecoderSpecification 指定必须使用的特定视频解码器.NULL
         @param    destinationImageBufferAttributes 描述源像素缓冲区的要求 NULL
         @param    outputCallback 使用已解压缩的帧调用的回调
         @param    decompressionSessionOut 指向一个变量以接收新的解压会话
         */
        var decompressionOutputCallbackRecord: VTDecompressionOutputCallbackRecord = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: decompressionOutputCallback, decompressionOutputRefCon: unsafeBitCast(self, to: UnsafeMutablePointer.self))
        status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                              formatDescription: decodeDesc,
                                              decoderSpecification: nil,
                                              imageBufferAttributes: imageBufferAttributes,
                                              outputCallback: &decompressionOutputCallbackRecord,
                                              decompressionSessionOut: &decodeSession)
        debugPrint("VTDecompressionSessionCreate: result=\(status)")
        if status != noErr { return false }
        
        /// 设置解码会话属性
        status = VTSessionSetProperty(decodeSession,
                                      key: kVTDecompressionPropertyKey_RealTime,
                                      value: kCFBooleanTrue)
        debugPrint("VTSessionSetProperty: RealTime result=\(status)")
        if status != noErr { return false }
        return true
    }
}

// MARK: -解码前的sps pps获取以及type判断
extension SYVideoDecoder {
    func decodeVideo(data: NSData) {
        decodeQueue.async { [self] in
            let size: UInt32 = UInt32(data.count)
            /// 前4个字节是NALU数据的开始码，也就是00 00 00 01，
            let naluSize = size - 4
            /// 将NALU长度转为4字节大端NALU的长度信息
            let length : [UInt8] = [
                UInt8(truncatingIfNeeded: naluSize >> 24),
                UInt8(truncatingIfNeeded: naluSize >> 16),
                UInt8(truncatingIfNeeded: naluSize >> 8),
                UInt8(truncatingIfNeeded: naluSize)
                ]
            var frameByte :[UInt8] = length
            [UInt8](data).suffix(from: 4).forEach { byte in
                frameByte.append(byte)
            }
            /// 转换后的NALU数据
            let bytes = frameByte
            /// 第5个字节是表示数据类型，转为10进制后，7是sps, 8是pps, 5是IDR（I帧）信息
            let type: Int = Int(bytes[4] & 0x1f)
            switch type {
            case 0x05:/// 关键帧
                if initDecoder() {
                    decodeVideo(bytes: bytes, size: size)
                }
                break
            case 0x07:/// sps
                bytes.suffix(from: 4).forEach { byte in
                    sps.append(byte)
                }
                break
            case 0x08:/// pps
                bytes.suffix(from: 4).forEach { byte in
                    pps.append(byte)
                }
                break
            default:/// other
                if initDecoder() {
                    decodeVideo(bytes: bytes, size: size)
                }
            }
        }
    }
}

// MARK: -解码
extension SYVideoDecoder {
    private func decodeVideo(bytes: [UInt8], size: UInt32) {
        /**创建blockBuffer
         参数1: structureAllocator kCFAllocatorDefault
         参数2: memoryBlock  frame
         参数3: frame size
         参数4: blockAllocator: Pass NULL
         参数5: customBlockSource Pass NULL
         参数6: offsetToData  数据偏移
         参数7: dataLength 数据长度
         参数8: flags 功能和控制标志
         参数9: newBBufOut blockBuffer地址,不能为空
         */
        var memoryBlock = bytes
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: &memoryBlock,
                                                        blockLength: Int(size),
                                                        blockAllocator: kCFAllocatorNull,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: Int(size),
                                                        flags: 0,
                                                        blockBufferOut: &blockBuffer)
        debugPrint("CMBlockBufferCreateWithMemoryBlock: result=\(status)")
        if status != noErr { return }
        
        /**创建sampleBuffer
         参数1: allocator 分配器,使用默认内存分配, kCFAllocatorDefault
         参数2: blockBuffer.需要编码的数据blockBuffer.不能为NULL
         参数3: formatDescription,视频输出格式
         参数4: numSamples.CMSampleBuffer 个数.
         参数5: numSampleTimingEntries 必须为0,1,numSamples
         参数6: sampleTimingArray.  数组.为空
         参数7: numSampleSizeEntries 默认为1
         参数8: sampleSizeArray
         参数9: sampleBuffer对象
         */
        var sampleBuffer: CMSampleBuffer!
        var sampleSizeArray: [Int] = [Int(size)]
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                           dataBuffer: blockBuffer,
                                           formatDescription: decodeDesc,
                                           sampleCount: 1,
                                           sampleTimingEntryCount: 0,
                                           sampleTimingArray: nil,
                                           sampleSizeEntryCount: 1,
                                           sampleSizeArray: &sampleSizeArray,
                                           sampleBufferOut: &sampleBuffer)
        debugPrint("CMSampleBufferCreateReady: result=\(status)")
        if status != noErr { return }
        /**解码数据
         参数1: 解码session
         参数2: 源数据 包含一个或多个视频帧的CMsampleBuffer
         参数3: 解码标志
         参数4: 解码后数据outputPixelBuffer
         参数5: 同步/异步解码标识
         */
        /// 向视频解码器提示使用低功耗模式是可以的
        let flags = VTDecodeFrameFlags._1xRealTimePlayback
        /// 异步解码
        var infoFlagsOut = VTDecodeInfoFlags.asynchronous
        status = VTDecompressionSessionDecodeFrame(decodeSession,
                                                   sampleBuffer: sampleBuffer,
                                                   flags: flags,
                                                   frameRefcon: nil,
                                                   infoFlagsOut: &infoFlagsOut)
        debugPrint("VTDecompressionSessionDecodeFrame: result=\(status)")
        if status != noErr { return }
    }
}

// MARK: -解码完成回调
extension SYVideoDecoder {
    private func didDeCompressH264() {
        decompressionOutputCallback = { decompressionOutputRefCon,
                                        sourceFrameRefCon,
                                        status,
                                        inforFlags,
                                        imageBuffer,
                                        presentationTimeStamp,
                                        presentationDuration in
            let decoder = unsafeBitCast(decompressionOutputRefCon, to: SYVideoDecoder.self)
            if imageBuffer != nil {
                decoder.callbackQueue.async {
                    decoder.delegate?.videoDecodeCallback(imageBuffer: imageBuffer!)
                }
            } else {
                debugPrint("decompressionOutputCallback: imageBuffer = nil")
            }
        }
    }
}
