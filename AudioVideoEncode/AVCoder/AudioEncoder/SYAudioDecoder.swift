//
//  SYAudioDecoder.swift
//  AudioVideoEncode
//

import AudioToolbox

protocol SYAudioDecoderDelegate {
    func audioDecodeCallback(pcmData: NSData) -> Void
}

class SYAudioDecoder {
    
    var delegate: SYAudioDecoderDelegate?
    
    private var config: SYAudioConfig!
    /// 解码器
    private var audioConverter: AudioConverterRef!
    /// 编码回调函数
    private var audioConverterComplexInputDataProc: AudioConverterComplexInputDataProc!
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
    /// pcm数据
    private var aacBuffer: UnsafeRawPointer? = nil
    /// pcm数据大小
    private var aacBufferSize: Int = 0
    
    required init(config: SYAudioConfig) {
        self.config = config
        audioConverterInputData()
    }
}

extension SYAudioDecoder {
    private func initConverter() {
        if audioConverter != nil { return }
        /// 输入参数描述
        var inDescriptionFormat = AudioStreamBasicDescription.init()
        inDescriptionFormat.mSampleRate = Float64(config.sampleRate)
        inDescriptionFormat.mFormatID = kAudioFormatMPEG4AAC
        inDescriptionFormat.mFormatFlags = 2
        inDescriptionFormat.mFramesPerPacket = 1024
        inDescriptionFormat.mChannelsPerFrame = config.channelCount
        /// 填充输入相关信息
        var inDescriptionFormatSize: UInt32 = UInt32(MemoryLayout.size(ofValue: inDescriptionFormat))
        var status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &inDescriptionFormatSize, &inDescriptionFormat)
        debugPrint("AudioFormatGetProperty: FormatInfo result=\(status)")
        if status != noErr { return }
        /// 输出参数描述
        var outDescriptionFormat = AudioStreamBasicDescription.init()
        outDescriptionFormat.mSampleRate = Float64(config.sampleRate)
        outDescriptionFormat.mChannelsPerFrame = config.channelCount
        outDescriptionFormat.mFormatID = kAudioFormatLinearPCM
        outDescriptionFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        outDescriptionFormat.mFramesPerPacket = 1
        outDescriptionFormat.mBitsPerChannel = 16
        outDescriptionFormat.mBytesPerFrame = outDescriptionFormat.mBitsPerChannel / 8 * outDescriptionFormat.mChannelsPerFrame
        outDescriptionFormat.mBytesPerPacket = outDescriptionFormat.mBytesPerFrame * outDescriptionFormat.mFramesPerPacket
        outDescriptionFormat.mReserved = 0
        /// 编码器的描述信息
        var audioClassDescription = getAudioClassDescription(with: outDescriptionFormat.mFormatID, form: kAppleSoftwareAudioCodecManufacturer)
        status = AudioConverterNewSpecific(&inDescriptionFormat, &outDescriptionFormat, 1, &audioClassDescription, &audioConverter)
        debugPrint("AudioConverterNewSpecific: result=\(status)")
        if status != noErr { return }
    }
    
    /**获取编解码器
     *  @param type         编码格式
     *  @param manufacturer 软/硬编
     *
     编解码器（codec）指的是一个能够对一个信号或者一个数据流进行变换的设备或者程序。这里指的变换既包括将 信号或者数据流进行编码（通常是为了传输、存储或者加密）或者提取得到一个编码流的操作，也包括为了观察或者处理从这个编码流中恢复适合观察或操作的形式的操作。编解码器经常用在视频会议和流媒体等应用中。
     *  @return 指定编码器
     */
    private func getAudioClassDescription(with type: AudioFormatID, form mManufacturer: UInt32) -> AudioClassDescription {
        /// 获取满足AAC编码器的总大小
        var size: UInt32 = 0
        var inSpecifier = type
        var status = AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders,
                                                UInt32(MemoryLayout.size(ofValue: inSpecifier)),
                                                &inSpecifier,
                                                &size)
        debugPrint("AudioFormatGetPropertyInfo: Decoders result=\(status)")
        if status != noErr { return AudioClassDescription.init() }
        /// 计算AAC解码器的个数
        let count = size / UInt32(MemoryLayout.size(ofValue: AudioClassDescription()))
        /// 创建一个包含count个数的编码器数组
        var description = [AudioClassDescription].init(repeating: AudioClassDescription(), count: Int(count))
        /// 将满足AAC解码的解码器的信息写入数组
        status = AudioFormatGetProperty(kAudioFormatProperty_Encoders,
                                        UInt32(MemoryLayout.size(ofValue: inSpecifier)),
                                        &inSpecifier,
                                        &size,
                                        &description)
        debugPrint("AudioFormatGetProperty: Encoders result=\(status)")
        if status != noErr { return AudioClassDescription.init() }
        for desc in description {
            if type == desc.mSubType && mManufacturer == desc.mManufacturer {
                return desc
            }
        }
        return AudioClassDescription.init()
    }
}

extension SYAudioDecoder {
    func decodeAudio(aacData: NSData) {
        decodeQueue.async { [self] in
            initConverter()
            /// 数据以及大小
            aacBuffer = aacData.bytes
            aacBufferSize = aacData.length
            /// ？？？？
            let aacBufferSize: Int = Int(2048 * config.channelCount)
            let aacBuffer = malloc(aacBufferSize)
            memset(aacBuffer, 0, aacBufferSize)
            
            var ioOutputDataPacketSize: UInt32 = 1024
            /// 配置AudioBufferList 为输出预分配内存
            var outAudioBufferList: AudioBufferList = AudioBufferList.init()
            outAudioBufferList.mNumberBuffers = 1
            outAudioBufferList.mBuffers.mNumberChannels = config.channelCount
            outAudioBufferList.mBuffers.mDataByteSize = UInt32(aacBufferSize)
            outAudioBufferList.mBuffers.mData = aacBuffer
            ///配置填充函数，获取输出数据
            let status = AudioConverterFillComplexBuffer(audioConverter,
                                                     audioConverterComplexInputDataProc,
                                                     unsafeBitCast(self, to: UnsafeMutablePointer.self),
                                                     &ioOutputDataPacketSize,
                                                     &outAudioBufferList,
                                                     nil)
            debugPrint("AudioConverterFillComplexBuffer: result=\(status)")
            if status != noErr { return }
            /// 获取到解码完成后的PCM数据
            /// 添加ADTS头 如果想要获取裸流 则不添加ADTS头 写入文件时 必须添加
            let pcmData = NSData(bytes: outAudioBufferList.mBuffers.mData, length: Int(outAudioBufferList.mBuffers.mDataByteSize))
            callbackQueue.async {
                delegate?.audioDecodeCallback(pcmData: pcmData)
            }
        }
    }
}

// MARK: -编码器输入参数回调方法
extension SYAudioDecoder {
    private func audioConverterInputData() {
        audioConverterComplexInputDataProc = {(inAudioConverter,
                                               ioNumberDataPackets,
                                               ioData,
                                               outDataPacketDescription,
                                               inUserData) in
            let encoder = unsafeBitCast(inUserData, to: SYAudioDecoder.self)
            if encoder.aacBufferSize <= 0 {
                ioNumberDataPackets.pointee = 0
                return -1
            }
            let packetDesc: UnsafeMutablePointer<AudioStreamPacketDescription> = UnsafeMutablePointer.allocate(capacity: MemoryLayout.size(ofValue: AudioStreamPacketDescription()))
            outDataPacketDescription?.pointee = packetDesc
            outDataPacketDescription?.pointee?.pointee.mStartOffset = 0
            outDataPacketDescription?.pointee?.pointee.mVariableFramesInPacket = 0
            outDataPacketDescription?.pointee?.pointee.mDataByteSize = UInt32(encoder.aacBufferSize)
            
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer.init(mutating: encoder.aacBuffer)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(encoder.aacBufferSize)
            ioData.pointee.mBuffers.mNumberChannels = encoder.config.channelCount
            /// 填充完毕 清空数据
            encoder.aacBufferSize = 0
            ioNumberDataPackets.pointee = 1
            return noErr
        }
    }
}
