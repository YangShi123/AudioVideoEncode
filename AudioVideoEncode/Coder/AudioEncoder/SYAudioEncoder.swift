//
//  SYAudioEncoder.swift
//  AudioVideoEncode
//

import AudioToolbox
import AVFoundation

protocol SYAudioEncoderDelegate {
    func audioEncodeCallback(aacData: NSData) -> Void
}

class SYAudioEncoder {
    /// 代理
    var delegate: SYAudioEncoderDelegate?
    
    private var config: SYAudioConfig!
    /// 编码器
    private var audioConverter: AudioConverterRef!
    /// 编码回调函数
    private var audioConverterComplexInputDataProc: AudioConverterComplexInputDataProc!
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
    /// pcm数据
    private var pcmBuffer: UnsafeMutablePointer<Int8>? = nil
    /// pcm数据大小
    private var pcmBufferSize: Int = 0
    
    required init(config: SYAudioConfig) {
        self.config = config
        audioConverterInputData()
    }
}

// MARK: -初始化编码器
extension SYAudioEncoder {
    private func initConverter(sampleBuffer: CMSampleBuffer) {
        if audioConverter != nil { return }
        let desc = CMSampleBufferGetFormatDescription(sampleBuffer)
        /// 获取输入参数
        let inDescriptionFormat = CMAudioFormatDescriptionGetStreamBasicDescription(desc!)
        /// 设置输出参数
        var outDescriptionFormat = AudioStreamBasicDescription.init()
        outDescriptionFormat.mSampleRate = Float64(config.sampleRate)    ///采样率
        outDescriptionFormat.mFormatID = kAudioFormatMPEG4AAC            ///输出格式
        outDescriptionFormat.mFormatFlags = 2                            ///如果设为0 代表无损编码
        outDescriptionFormat.mBytesPerPacket = 0                         ///自己确定每个packet 大小
        outDescriptionFormat.mBytesPerFrame = 0                          ///每一帧大小
        outDescriptionFormat.mFramesPerPacket = 1024                     ///每一个packet帧数 AAC-1024
        outDescriptionFormat.mChannelsPerFrame = config.channelCount     ///输出声道数
        outDescriptionFormat.mBitsPerChannel = 0                         ///数据帧中每个通道的采样位数
        outDescriptionFormat.mReserved = 0                               ///对其方式 0(8字节对齐)
        /// 填充输出相关信息
        var outDestinationFormatSize: UInt32 = UInt32(MemoryLayout.size(ofValue: outDescriptionFormat))
        var status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                                            0,
                                            nil,
                                            &outDestinationFormatSize,
                                            &outDescriptionFormat)
        debugPrint("AudioFormatGetProperty: FormatInfo result=\(status)")
        if status != noErr { return }
        /// 编码器的描述信息
        var audioClassDescriptions = getAudioClassDescription(with: outDescriptionFormat.mFormatID, form: kAppleSoftwareAudioCodecManufacturer)!
        
        /** 创建converter
         参数1：输入音频格式描述
         参数2：输出音频格式描述
         参数3：class desc的数量
         参数4：class desc
         参数5：创建的解码器
         */
        status = AudioConverterNewSpecific(inDescriptionFormat!,
                                           &outDescriptionFormat,
                                           1,
                                           &audioClassDescriptions,
                                           &audioConverter)
        debugPrint("AudioConverterNewSpecific: result=\(status)")
        if status != noErr { return }
        /**设置呈现质量
         kAudioConverterQuality_Max                              = 0x7F,
         kAudioConverterQuality_High                             = 0x60,
         kAudioConverterQuality_Medium                           = 0x40,
         kAudioConverterQuality_Low                              = 0x20,
         kAudioConverterQuality_Min                              = 0
         */
        var quality = kAudioConverterQuality_Medium
        status = AudioConverterSetProperty(audioConverter,
                                           kAudioConverterCodecQuality,
                                           UInt32(MemoryLayout.size(ofValue: quality)),
                                           &quality)
        debugPrint("AudioConverterSetProperty: Quality result=\(status)")
        /// 设置比特率
        var bitRate: UInt32 = UInt32(config.bitRate)
        status = AudioConverterSetProperty(audioConverter,
                                           kAudioConverterEncodeBitRate,
                                           UInt32(MemoryLayout.size(ofValue: bitRate)),
                                           &bitRate)
        debugPrint("AudioConverterSetProperty: BitRate result=\(status)")
    }
    
    /**获取编解码器
     *  @param type         编码格式
     *  @param manufacturer 软/硬编
     *
     编解码器（codec）指的是一个能够对一个信号或者一个数据流进行变换的设备或者程序。这里指的变换既包括将 信号或者数据流进行编码（通常是为了传输、存储或者加密）或者提取得到一个编码流的操作，也包括为了观察或者处理从这个编码流中恢复适合观察或操作的形式的操作。编解码器经常用在视频会议和流媒体等应用中。
     *  @return 指定编码器
     */
    private func getAudioClassDescription(with type: AudioFormatID, form mManufacturer: UInt32) -> AudioClassDescription? {
        /// 获取满足AAC编码器的总大小
        var size: UInt32 = 0
        var inSpecifier = type
        var status = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders,
                                                UInt32(MemoryLayout.size(ofValue: inSpecifier)),
                                                &inSpecifier, &size)
        debugPrint("AudioFormatGetPropertyInfo: Encoders result=\(status)")
        if status != noErr { return nil }
        /// 计算AAC编码器的个数
        let count = size / UInt32(MemoryLayout.size(ofValue: AudioClassDescription()))
        /// 创建一个包含count个数的编码器数组
        var description = [AudioClassDescription].init(repeating: AudioClassDescription(), count: Int(count))
        /// 将满足AAC编码的编码器的信息写入数组
        status = AudioFormatGetProperty(kAudioFormatProperty_Encoders,
                                        UInt32(MemoryLayout.size(ofValue: inSpecifier)),
                                        &inSpecifier,
                                        &size, &description)
        debugPrint("AudioFormatGetProperty: Encoders result=\(status)")
        if status != noErr { return nil }
        for desc in description {
            if type == desc.mSubType && mManufacturer == desc.mManufacturer {
                return desc
            }
        }
        return nil
    }
}

// MARK: -暴露给外面使用的编码方法
extension SYAudioEncoder {
    func encodeAudio(sampleBuffer: CMSampleBuffer) {
        encodeQueue.async { [self] in
            initConverter(sampleBuffer: sampleBuffer)
            /// 获取CMBlockBuffer 里面存了PCM数据
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
            /// 获取blockBuffer中音频数据大小以及音频数据地址
            var status = CMBlockBufferGetDataPointer(blockBuffer!,
                                                     atOffset: 0,
                                                     lengthAtOffsetOut: nil,
                                                     totalLengthOut: &pcmBufferSize,
                                                     dataPointerOut: &pcmBuffer)
            debugPrint("CMBlockBufferGetDataPointer: result=\(status)")
            if status != noErr { return }
            /**转换由输入回调函数提供的数据
             参数1: inAudioConverter 音频转换器
             参数2: inInputDataProc 回调函数.提供要转换的音频数据的回调函数。当转换器准备好接受新的输入数据时，会重复调用此回调.
             参数3: inInputDataProcUserData
             参数4: inInputDataProcUserData,self
             参数5: ioOutputDataPacketSize,输出缓冲区的大小
             参数6: outOutputData,需要转换的音频数据
             参数7: outPacketDescription,输出包信息
             */
            let pcmBuffer = malloc(pcmBufferSize)
            memset(pcmBuffer, 0, pcmBufferSize)
            var ioOutputDataPacketSize: UInt32 = 1
            /// 配置AudioBufferList 为输出预分配内存
            var outAudioBufferList: AudioBufferList = AudioBufferList.init()
            outAudioBufferList.mNumberBuffers = 1
            outAudioBufferList.mBuffers.mNumberChannels = config.channelCount
            outAudioBufferList.mBuffers.mDataByteSize = UInt32(pcmBufferSize)
            outAudioBufferList.mBuffers.mData = pcmBuffer
            ///配置填充函数，获取输出数据
            status = AudioConverterFillComplexBuffer(audioConverter,
                                                     audioConverterComplexInputDataProc,
                                                     unsafeBitCast(self, to: UnsafeMutablePointer.self),
                                                     &ioOutputDataPacketSize,
                                                     &outAudioBufferList,
                                                     nil)
            debugPrint("AudioConverterFillComplexBuffer: result=\(status)")
            if status != noErr { return }
            /// 获取到编码完成后的AAC数据
            let aacData = NSData(bytes: outAudioBufferList.mBuffers.mData, length: Int(outAudioBufferList.mBuffers.mDataByteSize))
            callbackQueue.async {
                delegate?.audioEncodeCallback(aacData: aacData)
            }
        }
    }
}

// MARK: -编码器输入参数回调方法
extension SYAudioEncoder {
    private func audioConverterInputData() {
        audioConverterComplexInputDataProc = {(inAudioConverter,
                                               ioNumberDataPackets,
                                               ioData,
                                               outDataPacketDescription,
                                               inUserData) in
            let encoder = unsafeBitCast(inUserData, to: SYAudioEncoder.self)
            if encoder.pcmBufferSize == 0 {
                ioNumberDataPackets.pointee = 0
                return -1
            }
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer.init(encoder.pcmBuffer)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(encoder.pcmBufferSize)
            ioData.pointee.mBuffers.mNumberChannels = encoder.config.channelCount
            /// 填充完毕 清空数据
            encoder.pcmBufferSize = 0
            ioNumberDataPackets.pointee = 1
            return noErr
        }
    }
}
