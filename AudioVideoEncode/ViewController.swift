//
//  ViewController.swift
//  AudioVideoEncode
//

import UIKit
import AVFoundation

class ViewController: UIViewController {
    
    var capture: SYCapture!
    
    var videoEncoder: SYVideoEncoder!
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        capture = SYCapture.init(type: .video)
        capture.videoPreset = .hd1920x1080
        capture.preView.frame = view.bounds
        capture.prepare(size: CGSize(width: view.bounds.width, height: view.bounds.height))
        capture.delegate = self
        view.addSubview(capture.preView)
        
        let videoConfig = SYVideoConfig.init()
        videoConfig.width = capture.width
        videoConfig.height = capture.height
        videoConfig.bitRate = capture.width * capture.height * 5
        videoConfig.fps = 30
        
        videoEncoder = SYVideoEncoder(config: videoConfig)
        videoEncoder.delegate = self
        
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
    func videoEncodeCallBack(h264Data: NSData) {
        print(h264Data)
    }
    /// sps pps
    func videoEncodeCallBack(sps: NSData, pps: NSData) {
        print("sps=\(sps)", "pps=\(pps)")
    }
    
    
}

