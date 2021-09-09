//
//  SYCapture.swift
//  AudioVideoEncode
//

import Foundation
import AVFoundation
import VideoToolbox
import AudioToolbox
import UIKit

/// 采集类型
enum SYCaptureType {
    case video, audio, all
}
/// 代理方法
protocol SYCaptureDelegate {
    func captureSampleBuffer(sampleBuffer: CMSampleBuffer, type: SYCaptureType) -> Void
}

class SYCapture: NSObject {
    /// 需要采集的类型
    private var captureType: SYCaptureType!
    /// 预览图层的尺寸
    private var preLayerSize: CGSize!
    /// 采集的session
    private var captureSession: AVCaptureSession
    /// 采集队列
    private var captureQueue: dispatch_queue_global_t
    /// 视频宽
    var width: Int {
        get {
            if captureSession.sessionPreset == .hd1920x1080 {
                return 1080
            } else if captureSession.sessionPreset == .hd1280x720 {
                return 720
            } else {
                return 480
            }
        }
    }
    /// 视频高
    var height: Int {
        get {
            if captureSession.sessionPreset == .hd1920x1080 {
                return 1920
            } else if captureSession.sessionPreset == .hd1280x720 {
                return 1280
            } else {
                return 640
            }
        }
    }
    /// 分辨率
    var videoPreset: AVCaptureSession.Preset {
        set {
            if captureSession.canSetSessionPreset(newValue) {
                captureSession.sessionPreset = newValue
            }
        }
        get { captureSession.sessionPreset }
    }
    /// 预览图层
    private var preLayer: AVCaptureVideoPreviewLayer!
    /// 提供给外层显示的view
    lazy var preView: UIView = {
        let view = UIView.init()
        return view
    }()
    /// 代理方法
    var delegate: SYCaptureDelegate?
    
    
    init(type: SYCaptureType) {
        captureType = type
        captureSession = AVCaptureSession.init()
        if type != .audio {
            captureSession.sessionPreset = .hd1280x720
        }
        captureQueue = dispatch_queue_global_t.init(label: "captureQueue")
        super.init()
    }
}
// MARK: -暴露给外面使用的方法
extension SYCapture {
    /// 准备捕获
    func prepare(size: CGSize? = .zero) {
        preLayerSize = size
        if captureType == .audio {
            setupAudio()
        } else if captureType == .video {
            setupVideo()
        } else {
            setupAudio()
            setupVideo()
        }
    }
    /// 开始捕获
    func startCapture() {
        if !captureSession.isRunning {
            captureSession.startRunning()
        }
    }
    /// 停止捕获
    func stopCapture() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }
}
// MARK: -private method
extension SYCapture {
    /// 初始化音频
    private func setupAudio() {
        /// 拿到麦克风设备
        let device = AVCaptureDevice.default(for: .audio)
        /// input
        let audioInput = try? AVCaptureDeviceInput.init(device: device!)
        if audioInput != nil {
            if captureSession.canAddInput(audioInput!) {
                captureSession.addInput(audioInput!)
            }
        }
        /// output
        let audioOutput = AVCaptureAudioDataOutput.init()
        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if captureSession.canAddOutput(audioOutput) {
            captureSession.addOutput(audioOutput)
        }
    }
    
    /// 初始化视频
    private func setupVideo() {
        /// 拿到后置摄像头
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        /// input
        let videoInput = try? AVCaptureDeviceInput.init(device: device!)
        if videoInput != nil {
            if captureSession.canAddInput(videoInput!) {
                captureSession.addInput(videoInput!)
            }
        }
        /// output
        let videoOutput = AVCaptureVideoDataOutput.init()
        /// 设置像素点压缩方式为YUV420
        videoOutput.videoSettings = [String(kCVPixelBufferPixelFormatTypeKey): kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        /// 设置代理
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        let connection = videoOutput.connection(with: .video)
        /// 设置视频输出方向
        connection?.videoOrientation = .portrait
        setupPreViewLayer()
    }
    
    /// 初始化预览图层
    private func setupPreViewLayer() {
        preLayer = AVCaptureVideoPreviewLayer.init(session: captureSession)
        preLayer.frame = CGRect(x: 0, y: 0, width: preLayerSize.width, height: preLayerSize.height)
        preLayer.videoGravity = .resizeAspectFill
        preView.layer.addSublayer(preLayer)
    }
}

// MARK: -AVCaptureVideoDataOutputSampleBufferDelegate
extension SYCapture: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        delegate?.captureSampleBuffer(sampleBuffer: sampleBuffer, type: captureType)
    }
}
