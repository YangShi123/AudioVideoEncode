//
//  SYAudioConfig.swift
//  AudioVideoEncode
//

import Foundation

class SYAudioConfig {
    /// 码率
    var bitRate: Int = 96000
    /// 声道
    var channelCount: UInt32 = 1
    /// 采样率
    var sampleRate = 44100
    /// 采样点量化
    var sampleSize = 16
}
