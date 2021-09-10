//
//  SYVideoEncoder.swift
//  AudioVideoEncode
//

import VideoToolbox

protocol SYVideoEncoderDelegate {
    /// h264数据编码完成回调
    func videoEncodeCallback(h264Data: NSData) -> Void
    /// sps pps数据编码完成回调
    func videoEncodeCallback(sps: NSData, pps: NSData) -> Void
}

class SYVideoEncoder {
    /// 代理方法
    var delegate: SYVideoEncoderDelegate?
    /// config
    var config: SYVideoConfig!
    /// 编码session
    private var encodeSession: VTCompressionSession!
    /// 编码完成回调方法
    private var compressionOutputCallback: VTCompressionOutputCallback?
    /// 帧ID
    private var frameID: Int64 = 0
    /// 是否已经获取过sps pps
    private var hasSpsPps = false
    /// 编码异步队列
    lazy private var encodeQueue: dispatch_queue_global_t = {
        let queue = dispatch_queue_global_t.init(label: "encode_queue")
        return queue
    }()
    /// 编码完成回调异步队列
    lazy private var callbackQueue: dispatch_queue_global_t = {
        let queue = dispatch_queue_global_t.init(label: "callback_queue")
        return queue
    }()
    
    required init(config: SYVideoConfig) {
        self.config = config
        /// 注意：compressionOutputCallback初始化要放在setupSession之前
        didCompressH264()
        initEncoder()
    }
    
    deinit {
        if encodeSession != nil {
            VTCompressionSessionCompleteFrames(encodeSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(encodeSession)
            encodeSession = nil
        }
    }
}
// MARK: -初始化编码器
extension SYVideoEncoder {
    /// 配置编码参数
    private func initEncoder() {
        /// 创建编码会话
        var status = VTCompressionSessionCreate(allocator: nil,
                                                width: Int32(config.width),
                                                height: Int32(config.height),
                                                codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: nil,
                                                imageBufferAttributes: nil,
                                                compressedDataAllocator: nil,
                                                outputCallback: compressionOutputCallback,
                                                refcon: unsafeBitCast(self, to: UnsafeMutablePointer.self),
                                                compressionSessionOut: &encodeSession)
        if status != noErr {
            fatalError("VTCompressionSessionCreate field, statu=\(status)")
        }
        /// 设置编码属性
        /// 1.是否实时执行
        status = VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        debugPrint("VTSessionSetProperty: set RealTime return:\(status)")
        
        /// 2.指定编码比特流的配置文件和级别 直播一般使用baseline 可减少由B帧带来的延时
        status = VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        debugPrint("VTSessionSetProperty: set ProfileLevel return:\(status)")
        
        /// 3.是否产生B帧
        status = VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        debugPrint("VTSessionSetProperty: set AllowFrameReordering return:\(status)")
        
        /// 4.设置码率均值(比特率可以高于此。默认比特率为零，表示视频编码器。应该确定压缩数据的大小。注意，比特率设置只在定时时有效）
        let bitRateRef = CFNumberCreate(kCFAllocatorDefault, CFNumberType.intType, &config.bitRate)
        status = VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRateRef)
        debugPrint("VTSessionSetProperty: set AverageBitRate return:\(status)")
        
        /// 5.码率限制
        let limits = [config.bitRate * 4, config.bitRate / 4] as CFArray
        status = VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        debugPrint("VTSessionSetProperty: set DataRateLimits return:\(status)")
        
        /// 6.设置关键帧间隔（GOP）
        var keyFrameInterval = config.fps * 2
        let keyFrameIntervalRef = CFNumberCreate(kCFAllocatorDefault, CFNumberType.intType, &keyFrameInterval)
        status = VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyFrameIntervalRef)
        debugPrint("VTSessionSetProperty: set MaxKeyFrameInterval return:\(status)")
        
        /// 7.设置fps
        let expectedFrameRate = CFNumberCreate(kCFAllocatorDefault, CFNumberType.intType, &config.fps)
        status = VTSessionSetProperty(encodeSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: expectedFrameRate)
        debugPrint("VTSessionSetProperty: set ExpectedFrameRate return:\(status)")
        
        /// 8.准备编码
        status = VTCompressionSessionPrepareToEncodeFrames(encodeSession)
        debugPrint("PrepareToEncodeFrames: return:\(status)")
    }
}

// MARK: -获取到编码数据->开始编码
extension SYVideoEncoder {
    /// 获取到数据 编码
    func encodeVideo(sampleBuffer: CMSampleBuffer) -> Void {
        encodeQueue.async { [self] in
            /// 1.获取帧数据
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            /// 2.该帧的时间戳
            frameID += 1
            let timeStamp = CMTimeMake(value: frameID, timescale: 1000)
            /// 3.持续时间
            let duration = CMTime.invalid
            /// 4.编码
            let status = VTCompressionSessionEncodeFrame(encodeSession,
                                                         imageBuffer: imageBuffer!,
                                                         presentationTimeStamp: timeStamp,
                                                         duration: duration,
                                                         frameProperties: nil,
                                                         sourceFrameRefcon: nil,
                                                         infoFlagsOut: nil)
            if status != noErr {
                fatalError("VTCompressionSessionEncodeFrame: failed: status=\(status)")
            }
        }
    }
}
// MARK: -编码完成回调
extension SYVideoEncoder {
    /// 编码完成的回调
    private func didCompressH264() {
        compressionOutputCallback = {(outputCallbackRefCon,
                                      sourceFrameRefCon,
                                      status,
                                      flag,
                                      sampleBuffer) in
            if status != noErr {
                fatalError("compressionOutputCallback: failed: status=\(status)")
            }
            if !CMSampleBufferDataIsReady(sampleBuffer!) {
                fatalError("compressionOutputCallback: data is not ready")
            }
            /// 头部信息
            let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x01]
            /// 在C语言函数中获取swift对象
            let encoder = unsafeBitCast(outputCallbackRefCon, to: SYVideoEncoder.self)
            /// 判断是否为关键帧
            let cfDic = unsafeBitCast(CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true), 0), to: CFDictionary.self)
            let key = unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self)
            let keyFrame = !CFDictionaryContainsKey(cfDic, key)
            /// 获取sps pps 数据 只需获取一次，保存在h264文件开头即可
            if keyFrame && !encoder.hasSpsPps {
                /// 获取图像源格式
                let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer!)
                /// sps
                var spsData: UnsafePointer<UInt8>? = UnsafePointer(bitPattern: 0)
                var spsSize = 0
                var spsCount = 0
                var spsHeaderLength: Int32 = 0
                let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc!,
                                                                                   parameterSetIndex: 0,
                                                                                   parameterSetPointerOut: &spsData,
                                                                                   parameterSetSizeOut: &spsSize,
                                                                                   parameterSetCountOut: &spsCount,
                                                                                   nalUnitHeaderLengthOut: &spsHeaderLength)
                /// pps
                var ppsData: UnsafePointer<UInt8>? = UnsafePointer(bitPattern: 0)
                var ppsSize = 0
                var ppsCount = 0
                var ppsHeaderLength: Int32 = 0
                let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc!,
                                                                                   parameterSetIndex: 1,
                                                                                   parameterSetPointerOut: &ppsData,
                                                                                   parameterSetSizeOut: &ppsSize,
                                                                                   parameterSetCountOut: &ppsCount,
                                                                                   nalUnitHeaderLengthOut: &ppsHeaderLength)
                /// 获取sps pps 成功
                if spsStatus == noErr && ppsStatus == noErr {
                    encoder.hasSpsPps = true
                    /// sps data
                    let sps = NSMutableData(capacity: spsSize + bytes.count)
                    sps?.append(bytes, length: bytes.count)
                    sps?.append(spsData!, length: spsSize)
                    let pps = NSMutableData(capacity: ppsSize + bytes.count)
                    pps?.append(bytes, length: bytes.count)
                    pps?.append(ppsData!, length: ppsSize)
                    encoder.callbackQueue.async {
                        encoder.delegate?.videoEncodeCallback(sps: sps!, pps: pps!)
                    }
                } else {
                    debugPrint("compressionOutputCallback: get sps/pps failed spsStatus=\(spsStatus) ppsStatus=\(ppsStatus)")
                }
            }
            /// 获取NALU数据
            /// 编码完成后 数据在blockBuffer中
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer!)
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>? = nil
            let status = CMBlockBufferGetDataPointer(blockBuffer!,
                                                     atOffset: 0,
                                                     lengthAtOffsetOut: &lengthAtOffset,
                                                     totalLengthOut: &totalLength,
                                                     dataPointerOut: &dataPointer)
            if status != noErr {
                fatalError("compressionOutputCallback: get datapoint failed, statu=\(status)")
            }
            /// 偏移量
            var offset: UInt32 = 0
            /// 返回的nalu数据前四个字节不是0001的startcode(不是系统端的0001)，而是大端模式的帧长度length
            let headerLength = 4
            while offset < totalLength - headerLength {
                /// NALU数据长度
                var naluDataLength: UInt32 = 0
                memcpy(&naluDataLength, dataPointer! + UnsafeMutablePointer<Int8>.Stride(offset), headerLength)
                /// 大端转系统端
                naluDataLength = CFSwapInt32BigToHost(naluDataLength)
                /// 获取编码好的视频数据
                let data = NSMutableData(capacity: bytes.count + Int(naluDataLength))
                data?.append(bytes, length: bytes.count)
                data?.append(dataPointer! + UnsafeMutablePointer<Int8>.Stride(offset) + headerLength, length: Int(naluDataLength))
                encoder.callbackQueue.async {
                    encoder.delegate?.videoEncodeCallback(h264Data: data!)
                }
                /// 移动偏移量 读取下一个数据
                offset += UInt32(headerLength) + naluDataLength
            }
        }
    }
}
