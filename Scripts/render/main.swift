import Foundation
import RealityKit
import ArgumentParser
import SFOMuseumLogger
import PhotogrammetryRenderer
import Progress
import ImageIO

actor Bar {
    var progressBar = ProgressBar(count: 100)
    func setValue(_ value: Int) {
        progressBar.setValue(value)
    }
}

enum CLIErrors: Error, LocalizedError {
    case invalidInputFolder(String)
    case invalidOutputFolder(String)
    case noImagesFound(String)
    case invalidMinimumValue(String)
    case photogrammetryNotSupported
    case inputValidationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidInputFolder(let path):
            return "Input folder does not exist or is not a directory: \(path)"
        case .invalidOutputFolder(let path):
            return "Output directory is invalid: \(path)"
        case .noImagesFound(let path):
            return "No supported image files were found in: \(path)"
        case .invalidMinimumValue(let option):
            return "\(option) must be greater than zero"
        case .photogrammetryNotSupported:
            return "Photogrammetry is not supported on this machine"
        case .inputValidationFailed(let message):
            return message
        }
    }
}

let supportedImageExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"])

func mapDetail(_ rawDetail: String) throws -> PhotogrammetrySession.Request.Detail {
    switch rawDetail.lowercased() {
    case "preview":
        return .preview
    case "reduced":
        return .reduced
    case "medium":
        return .medium
    case "full":
        return .full
    case "raw":
        return .raw
    default:
        throw RenderErrors.invalidDetail
    }
}

func collectImageFiles(in folderURL: URL) throws -> [URL] {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    
    guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw CLIErrors.invalidInputFolder(folderURL.path)
    }
    
    guard let enumerator = fileManager.enumerator(
        at: folderURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        throw CLIErrors.invalidInputFolder(folderURL.path)
    }
    
    var imageFiles: [URL] = []
    
    for case let fileURL as URL in enumerator {
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            continue
        }
        
        let ext = fileURL.pathExtension.lowercased()
        if supportedImageExtensions.contains(ext) {
            imageFiles.append(fileURL)
        }
    }
    
    return imageFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func imageSize(for url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return nil
    }
    
    let widthValue = properties[kCGImagePropertyPixelWidth]
    let heightValue = properties[kCGImagePropertyPixelHeight]
    
    let width: Double?
    if let n = widthValue as? NSNumber {
        width = n.doubleValue
    } else if let d = widthValue as? Double {
        width = d
    } else if let i = widthValue as? Int {
        width = Double(i)
    } else {
        width = nil
    }
    
    let height: Double?
    if let n = heightValue as? NSNumber {
        height = n.doubleValue
    } else if let d = heightValue as? Double {
        height = d
    } else if let i = heightValue as? Int {
        height = Double(i)
    } else {
        height = nil
    }
    
    guard let safeWidth = width, let safeHeight = height else {
        return nil
    }
    
    return CGSize(width: safeWidth, height: safeHeight)
}

func ensureOutputDirectory(for outputFileURL: URL) throws {
    let fileManager = FileManager.default
    let outputDirURL = outputFileURL.deletingLastPathComponent()
    
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: outputDirURL.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw CLIErrors.invalidOutputFolder(outputDirURL.path)
        }
        return
    }
    
    do {
        try fileManager.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
    } catch {
        throw CLIErrors.invalidOutputFolder(outputDirURL.path)
    }
}

func validateInputImages(
    inputFolderURL: URL,
    minImages: Int,
    minShortSide: Int,
    strictChecks: Bool,
    logInfo: (_ message: String) -> Void,
    logWarning: (_ message: String) -> Void
) throws {
    if minImages <= 0 {
        throw CLIErrors.invalidMinimumValue("--min-images")
    }
    
    if minShortSide <= 0 {
        throw CLIErrors.invalidMinimumValue("--min-short-side")
    }
    
    let imageFiles = try collectImageFiles(in: inputFolderURL)
    
    guard !imageFiles.isEmpty else {
        throw CLIErrors.noImagesFound(inputFolderURL.path)
    }
    
    var warnings: [String] = []
    var unreadableCount = 0
    var lowResolutionCount = 0
    
    if imageFiles.count < minImages {
        warnings.append("Only \(imageFiles.count) images found; recommended minimum is \(minImages)")
    }
    
    for imageURL in imageFiles {
        guard let size = imageSize(for: imageURL) else {
            unreadableCount += 1
            continue
        }
        
        if min(size.width, size.height) < Double(minShortSide) {
            lowResolutionCount += 1
        }
    }
    
    if unreadableCount > 0 {
        warnings.append("\(unreadableCount) images could not be read and may fail processing")
    }
    
    if lowResolutionCount > 0 {
        warnings.append("\(lowResolutionCount) images have short side below \(minShortSide)px")
    }
    
    logInfo("Input image summary: \(imageFiles.count) files found")
    
    if warnings.isEmpty {
        return
    }
    
    for warning in warnings {
        logWarning(warning)
    }
    
    if strictChecks {
        throw CLIErrors.inputValidationFailed("Input validation failed in strict mode")
    }
}

@available(macOS 12.0, *)
struct Photogrammetry: ParsableCommand {
    
    @Argument(help:"The path to the folder containing images used to derive 3D model")
    var inputFolder: String
    
    @Argument(help:"The path (and filename) of the 3D model to create")
    var outputFile: String
    
    @Option(help: "Log events to system log files")
    var logfile: Bool = false
    
    @Option(help: "Enable verbose logging")
    var verbose: Bool = false
    
    @Option(help: "The level of detail to use when creating the 3D model. Valid options are: preview, reduced, medium, full, raw.")
    var detail: String = "medium"
    
    @Option(help: "Recommended minimum number of photos before processing")
    var minImages: Int = 40
    
    @Option(help: "Recommended minimum short-side image resolution in pixels")
    var minShortSide: Int = 1200
    
    @Flag(help: "Skip input image quality checks before rendering")
    var skipInputChecks: Bool = false
    
    @Flag(help: "Fail before rendering if quality checks emit warnings")
    var strictInputChecks: Bool = false
    
    func run() throws {
        
        let log_label = "org.sfomuseum.render"
        
        let logger_opts = SFOMuseumLoggerOptions(
            label: log_label,
            console: true,
            logfile: logfile,
            verbose: verbose
        )
        
        let logger = try NewSFOMuseumLogger(logger_opts)
        
        guard PhotogrammetrySession.isSupported else {
            logger.error("PhotogrammetrySession is not supported on this machine")
            throw CLIErrors.photogrammetryNotSupported
        }
        
        let req_detail = try mapDetail(detail)
        
        let inputFolderURL = URL(fileURLWithPath: inputFolder,
                                 isDirectory: true)
        
        let outputFileURL = URL(fileURLWithPath: outputFile)
        try ensureOutputDirectory(for: outputFileURL)
        
        if !skipInputChecks {
            try validateInputImages(
                inputFolderURL: inputFolderURL,
                minImages: minImages,
                minShortSide: minShortSide,
                strictChecks: strictInputChecks,
                logInfo: { message in logger.info("\(message)") },
                logWarning: { message in logger.warning("\(message)") }
            )
        } else {
            logger.info("Skipping input checks by request")
        }
        
        let r = PhotogrammetryRenderer(
            inputFolder: inputFolderURL,
            outputFile: outputFileURL,
            detail: req_detail,
            logger: logger
        )
        
        let bar = Bar()
        
        r.Render(
            onprogress: { (fractionComplete) in
                await bar.setValue(Int(fractionComplete * 100))
            },
            oncomplete: { (result) in
                if case let .success(modelUrl) = result {
                    print(modelUrl)
                    Foundation.exit(0)
                } else if case let .failure(error) = result {
                    logger.error("Failed to process model, \(error)")
                    Foundation.exit(1)
                }
            })
        
        RunLoop.main.run()
    }
}

if #available(macOS 12.0, *) {
    Photogrammetry.main()
} else {
    fatalError("Requires macOS 12.0 or higher")
}
