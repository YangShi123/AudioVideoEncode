//
//  ViewController.swift
//  AudioVideoEncode
//

import UIKit
import AVFoundation

class ViewController: UIViewController {
    
    var capture: SYCapture!
    
    var videoEncoder: SYVideoEncoder!
    
    var videoDecoder: SYVideoDecoder!
    
    var videoPlayLayer: AAPLEAGLLayer!
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        let size = CGSize(width: view.bounds.width / 2, height: view.bounds.height / 2)
        
        capture = SYCapture.init(type: .video)
        capture.videoPreset = .hd1920x1080
        capture.preView.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        capture.prepare(size: size)
        capture.delegate = self
        view.addSubview(capture.preView)
        
        let videoConfig = SYVideoConfig.init()
        videoConfig.width = capture.width
        videoConfig.height = capture.height
        videoConfig.bitRate = capture.width * capture.height * 5
        videoConfig.fps = 30
        
        videoEncoder = SYVideoEncoder(config: videoConfig)
        videoEncoder.delegate = self
        
        videoDecoder = SYVideoDecoder.init(config: videoConfig)
        videoDecoder.delegate = self
        
        videoPlayLayer = AAPLEAGLLayer.init(frame: CGRect(x: size.width, y: 0, width: size.width, height: size.height))
        view.layer.addSublayer(videoPlayLayer)
        
        capture.startCapture()
    }
}
// MARK: -捕获音视频回调
extension ViewController: SYCaptureDelegate {
    func captureSampleBuffer(sampleBuffer: CMSampleBuffer, type: SYCaptureType) {
        if type == .video {
            videoEncoder.encodeVideo(sampleBuffer: sampleBuffer)
        } else if type == .audio {
            
        } else {
            videoEncoder.encodeVideo(sampleBuffer: sampleBuffer)
        }
    }
}

// MARK: -h264编码回调
extension ViewController: SYVideoEncoderDelegate {
    /// 数据
    func videoEncodeCallback(h264Data: NSData) {
        /// 直接解码
        videoDecoder.decodeVideo(data: h264Data)
    }
    /// sps pps
    func videoEncodeCallback(sps: NSData, pps: NSData) {
        /// 解码sps
        videoDecoder.decodeVideo(data: sps)
        /// 解码pps
        videoDecoder.decodeVideo(data: pps)
    }
}

// MARK: -h264解码回调
extension ViewController: SYVideoDecoderDelegate {
    func videoDecodeCallback(imageBuffer: CVPixelBuffer) {
        videoPlayLayer.pixelBuffer = imageBuffer
    }
}

