import Flutter
import AVFoundation
import NextLevelSessionExporter

public class SwiftVideoCompressPlugin: NSObject, FlutterPlugin {
    private let channelName = "video_compress"
    private var exporter: AVAssetExportSession? = nil
    private var stopCommand = false
    private let channel: FlutterMethodChannel
    private let avController = AvController()
    
    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "video_compress", binaryMessenger: registrar.messenger())
        let instance = SwiftVideoCompressPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? Dictionary<String, Any>
        switch call.method {
        case "getByteThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getByteThumbnail(path, quality, position, result)
        case "getFileThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getFileThumbnail(path, quality, position, result)
        case "getMediaInfo":
            let path = args!["path"] as! String
            getMediaInfo(path, result)
        case "compressVideo":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let deleteOrigin = args!["deleteOrigin"] as! Bool
            let startTime = args!["startTime"] as? Double
            let duration = args!["duration"] as? Double
            let includeAudio = args!["includeAudio"] as? Bool
            let frameRate = args!["frameRate"] as? Int
            let maxSizeMinor = args!["maxSizeMinor"] as? Int
            let bitRateMultiplier = args!["bitRateMultiplier"] as? Double
            compressVideo(path, quality, deleteOrigin, startTime, duration, includeAudio,
                          frameRate, maxSizeMinor, bitRateMultiplier, result)
        case "cancelCompression":
            cancelCompression(result)
        case "deleteAllCache":
            Utility.deleteFile(Utility.basePath(), clear: true)
            result(true)
        case "setLogLevel":
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func getBitMap(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult)-> Data?  {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return nil }
        
        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true
        
        let timeScale = CMTimeScale(track.nominalFrameRate)
        let time = CMTimeMakeWithSeconds(Float64(truncating: position),preferredTimescale: timeScale)
        guard let img = try? assetImgGenerate.copyCGImage(at:time, actualTime: nil) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: img)
        let compressionQuality = CGFloat(0.01 * Double(truncating: quality))
        return thumbnail.jpegData(compressionQuality: compressionQuality)
    }
    
    private func getByteThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        if let bitmap = getBitMap(path,quality,position,result) {
            result(bitmap)
        }
    }
    
    private func getFileThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        let fileName = Utility.getFileName(path)
        let url = Utility.getPathUrl("\(Utility.basePath())/\(fileName).jpg")
        Utility.deleteFile(path)
        if let bitmap = getBitMap(path,quality,position,result) {
            guard (try? bitmap.write(to: url)) != nil else {
                return result(FlutterError(code: channelName,message: "getFileThumbnail error",details: "getFileThumbnail error"))
            }
            result(Utility.excludeFileProtocol(url.absoluteString))
        }
    }
    
    public func getMediaInfoJson(_ path: String)->[String : Any?] {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return [:] }
        
        let playerItem = AVPlayerItem(url: url)
        let metadataAsset = playerItem.asset
        
        let orientation = avController.getVideoOrientation(path)
        
        let title = avController.getMetaDataByTag(metadataAsset,key: "title")
        let author = avController.getMetaDataByTag(metadataAsset,key: "author")
        
        let duration = asset.duration.seconds * 1000
        let filesize = track.totalSampleDataLength
        
        let size = track.naturalSize.applying(track.preferredTransform)
        
        let width = abs(size.width)
        let height = abs(size.height)
        
        let dictionary = [
            "path":Utility.excludeFileProtocol(path),
            "title":title,
            "author":author,
            "width":width,
            "height":height,
            "duration":duration,
            "filesize":filesize,
            "orientation":orientation
            ] as [String : Any?]
        return dictionary
    }
    
    private func getMediaInfo(_ path: String,_ result: FlutterResult) {
        let json = getMediaInfoJson(path)
        let string = Utility.keyValueToJson(json)
        result(string)
    }
    
    
    private func updateProgress(progress: Float) {
        if(!stopCommand) {
            channel.invokeMethod("updateProgress", arguments: progress * 100)
        }
    }
    
    private func getExportPreset(_ quality: NSNumber)->String {
        switch(quality) {
        case 1:
            return AVAssetExportPresetLowQuality    
        case 2:
            return AVAssetExportPresetMediumQuality
        case 3:
            return AVAssetExportPresetHighestQuality
        default:
            return AVAssetExportPresetMediumQuality
        }
    }
    
    private func getComposition(_ isIncludeAudio: Bool,_ timeRange: CMTimeRange, _ sourceVideoTrack: AVAssetTrack)->AVAsset {
        let composition = AVMutableComposition()
        if !isIncludeAudio {
            let compressionVideoTrack = composition.addMutableTrack(withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid)
            compressionVideoTrack!.preferredTransform = sourceVideoTrack.preferredTransform
            try? compressionVideoTrack!.insertTimeRange(timeRange, of: sourceVideoTrack, at: CMTime.zero)
        } else {
            return sourceVideoTrack.asset!
        }
        
        return composition    
    }
    
    private func compressVideo(_ path: String,_ quality: NSNumber,_ deleteOrigin: Bool,_ startTime: Double?,
                               _ duration: Double?,_ includeAudio: Bool?,_ frameRate: Int?, _ maxSizeMinor: Int?,
                               _ bitRateMultiplier: Double?, _ result: @escaping FlutterResult) {
        let sourceVideoUrl = Utility.getPathUrl(path)
        let sourceVideoType = "mp4"
        
        let sourceVideoAsset = avController.getVideoAsset(sourceVideoUrl)
        let sourceVideoTrack = avController.getTrack(sourceVideoAsset)
        
        let compressionUrl =
            Utility.getPathUrl("\(Utility.basePath())/\(Utility.getFileName(path)).\(sourceVideoType)")
        
        let timescale = sourceVideoAsset.duration.timescale
        let minStartTime = Double(startTime ?? 0)
        
        let videoDuration = sourceVideoAsset.duration.seconds
        let minDuration = Double(duration ?? videoDuration)
        let maxDurationTime = minStartTime + minDuration < videoDuration ? minDuration : videoDuration
        
        let cmStartTime = CMTimeMakeWithSeconds(minStartTime, preferredTimescale: timescale)
        let cmDurationTime = CMTimeMakeWithSeconds(maxDurationTime, preferredTimescale: timescale)
        let timeRange: CMTimeRange = CMTimeRangeMake(start: cmStartTime, duration: cmDurationTime)
        
        let isIncludeAudio = includeAudio != nil ? includeAudio! : true
        
        let session = getComposition(isIncludeAudio, timeRange, sourceVideoTrack!)

        // Get the orientation of the video track
        let videoOrientation = self.videoOrientation(videoTrack: sourceVideoTrack)
        let isLandscape = videoOrientation.orientation.isLandscape


        // Get the height/width of the track, swapping if needed due to orientation of video track
        let originalHeight = (isLandscape ? sourceVideoTrack?.naturalSize.height : sourceVideoTrack?.naturalSize.width) ?? 480
        let originalWidth = (isLandscape ? sourceVideoTrack?.naturalSize.width : sourceVideoTrack?.naturalSize.height) ?? 480
        
        // Calculate new height/width. Setting smallest side to maxSizeMinor and keeping aspect ratio
        // for the other side
        let resizedMinor = CGFloat(maxSizeMinor ?? 480)
        var newHeight = Int(originalHeight.rounded())
        var newWidth = Int(originalWidth.rounded())
//        print("original \(originalWidth) x \(originalHeight)")
        if (originalHeight > resizedMinor && originalWidth > resizedMinor) {
            if (originalHeight > originalWidth) {
                newWidth = Int(resizedMinor)-1
                newHeight = Int((originalHeight * (resizedMinor / originalWidth)).rounded())
            } else {
                newHeight = Int(resizedMinor)
                newWidth = Int((originalWidth * (resizedMinor / originalHeight)).rounded())
            }
        }
//        print("new \(newWidth) x \(newHeight)")
//        let exporter = AVAssetExportSession(asset: session, presetName: getExportPreset(quality))!
        let exporter = NextLevelSessionExporter(withAsset: session)
        
        // Calculate input frame rate
        let videoComposition = AVMutableVideoComposition(propertiesOf: sourceVideoAsset)
        var sourceFrameRate = Double(videoComposition.frameDuration.timescale) / Double(videoComposition.frameDuration.value)
        if (sourceFrameRate < 24) {
            sourceFrameRate = 24
        }
        if (sourceFrameRate > 120) {
            sourceFrameRate = 120
        }
        
//        print("frameRate = \(sourceFrameRate)")
        
        // Calculate appropriate bitRate -
        // https://stackoverflow.com/questions/5024114/suggested-compression-ratio-with-h-264/5220554#5220554
        let bitRate = Double(newHeight * newWidth) * sourceFrameRate * (bitRateMultiplier ?? 2.0) * 0.07
//        print("bitRate = \(bitRate)")
        let compressionDict: [String: Any] = [
            AVVideoAverageBitRateKey: NSNumber(integerLiteral: Int(bitRate.rounded())),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel as String,
        ]
        
        // For whatever reason, the encoder crashes when frameRate is set. It's probably better
        // to leave as the default which should be the input frame rate anyway.
//        if frameRate != nil {
//            let videoComposition = AVMutableVideoComposition(propertiesOf: sourceVideoAsset)
//
//            print("Framerate = \(videoComposition.frameDuration)")
//            videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(frameRate!))
//            exporter.videoComposition = videoComposition
//        }
        
        exporter.outputURL = compressionUrl
        exporter.outputFileType = AVFileType.mp4
        exporter.videoOutputConfiguration = [
            AVVideoCodecKey: AVVideoCodecH264,
            AVVideoWidthKey: NSNumber(integerLiteral: newWidth),
            AVVideoHeightKey: NSNumber(integerLiteral: newHeight),
            AVVideoCompressionPropertiesKey: compressionDict
//            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect
        ]
        exporter.audioOutputConfiguration = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: NSNumber(integerLiteral: 128000),
            AVNumberOfChannelsKey: NSNumber(integerLiteral: 2),
            AVSampleRateKey: NSNumber(value: Float(44100))
        ]
        
        exporter.optimizeForNetworkUse = true
                
        if !isIncludeAudio {
            exporter.timeRange = timeRange
        }
        
        Utility.deleteFile(compressionUrl.absoluteString)
        
        exporter.export(
            progressHandler: { (progress) in
                self.updateProgress(progress: progress)
//                print(progress)
            },
            completionHandler: {
                r in
                    switch r {
                        
                    case .success(let status):
                        switch status {
                        case .completed:
                            print("NextLevelSessionExporter, export completed, \(exporter.outputURL?.description ?? "")")
                            if (self.stopCommand) {
                                self.stopCommand = false
                                var json = self.getMediaInfoJson(path)
                                json["isCancel"] = true
                                let jsonString = Utility.keyValueToJson(json)
                                return result(jsonString)
                            }
                            if deleteOrigin {
                                let fileManager = FileManager.default
                                do {
                                    if fileManager.fileExists(atPath: path) {
                                        try fileManager.removeItem(atPath: path)
                                    }
                                    self.exporter = nil
                                    self.stopCommand = false
                                }
                                catch let error as NSError {
                                    print(error)
                                }
                            }
                            var json = self.getMediaInfoJson(compressionUrl.absoluteString)
                            json["isCancel"] = false
                            let jsonString = Utility.keyValueToJson(json)
                            result(jsonString)

                            break
                        default:
                            print("NextLevelSessionExporter, did not complete")
                            break
                        }
                        break
                    case .failure(let error):
                        print("NextLevelSessionExporter, failed to export \(error)")
                        break
                    }
            }
        )
    }
    
    private func cancelCompression(_ result: FlutterResult) {
        exporter?.cancelExport()
        stopCommand = true
        result("")
    }
    
    // From: https://gist.github.com/mooshee/6b9e35c53047373568f5
    func videoOrientation(videoTrack: AVAssetTrack?) -> (orientation: UIInterfaceOrientation, device: AVCaptureDevice.Position) {
        var orientation: UIInterfaceOrientation = .unknown
        var device: AVCaptureDevice.Position = .unspecified
        if (videoTrack == nil) {
            return (orientation, device)
        }
        
        let t = videoTrack!.preferredTransform
        
        if (t.a == 0 && t.b == 1.0 && t.d == 0) {
            orientation = .portrait
            
            if t.c == 1.0 {
                device = .front
            } else if t.c == -1.0 {
                device = .back
            }
        }
        else if (t.a == 0 && t.b == -1.0 && t.d == 0) {
            orientation = .portraitUpsideDown
            
            if t.c == -1.0 {
                device = .front
            } else if t.c == 1.0 {
                device = .back
            }
        }
        else if (t.a == 1.0 && t.b == 0 && t.c == 0) {
            orientation = .landscapeRight
            
            if t.d == -1.0 {
                device = .front
            } else if t.d == 1.0 {
                device = .back
            }
        }
        else if (t.a == -1.0 && t.b == 0 && t.c == 0) {
            orientation = .landscapeLeft
            
            if t.d == 1.0 {
                device = .front
            } else if t.d == -1.0 {
                device = .back
            }
        }
        return (orientation, device)
    }
    
}
