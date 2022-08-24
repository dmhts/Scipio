import Foundation
import TSCBasic

public struct Runner {
    private let options: Options
    private let fileSystem: any FileSystem

    public enum Mode {
        case createPackage
        case prepareDependencies
    }

    public enum CacheStorageKind {
        case local
        case custom(any CacheStorage)
    }

    public enum Error: Swift.Error, LocalizedError {
        case invalidPackage(AbsolutePath)
        case platformNotSpecified
        case compilerError(Swift.Error)

        public var errorDescription: String? {
            switch self {
            case .platformNotSpecified:
                return "Any platforms are not spcified in Package.swift"
            case .invalidPackage(let path):
                return "Invalid package. \(path.pathString)"
            case .compilerError(let error):
                return "\(error.localizedDescription)"
            }
        }
    }

    public struct Options {
        public init(buildConfiguration: BuildConfiguration, isSimulatorSupported: Bool, isDebugSymbolsEmbedded: Bool, outputDirectory: URL? = nil, isCacheEnabled: Bool, cacheStorage: CacheStorageKind?, verbose: Bool) {
            self.buildConfiguration = buildConfiguration
            self.isSimulatorSupported = isSimulatorSupported
            self.isDebugSymbolsEmbedded = isDebugSymbolsEmbedded
            self.outputDirectory = outputDirectory
            self.isCacheEnabled = isCacheEnabled
            self.cacheStorage = cacheStorage
            self.verbose = verbose
        }

        public var buildConfiguration: BuildConfiguration
        public var isSimulatorSupported: Bool
        public var isDebugSymbolsEmbedded: Bool
        public var outputDirectory: URL?
        public var isCacheEnabled: Bool
        public var cacheStorage: CacheStorageKind?
        public var verbose: Bool
    }
    private var mode: Mode

    public init(mode: Mode, options: Options, fileSystem: FileSystem = localFileSystem) {
        self.mode = mode
        if options.verbose {
            setLogLevel(.trace)
        } else {
            setLogLevel(.info)
        }

        self.options = options
        self.fileSystem = fileSystem
    }

    private func resolveURL(_ fileURL: URL) -> AbsolutePath {
        if fileURL.path.hasPrefix("/") {
            return AbsolutePath(fileURL.path)
        } else if let cd = fileSystem.currentWorkingDirectory {
            return cd.appending(RelativePath(fileURL.path))
        } else {
            return AbsolutePath(fileURL.path)
        }
    }

    public enum OutputDirectory {
        case `default`
        case custom(URL)

        fileprivate func resolve(packageDirectory: URL) -> AbsolutePath {
            switch self {
            case .default:
                return AbsolutePath(packageDirectory.appendingPathComponent("XCFramework").path)
            case .custom(let url):
                return AbsolutePath(url.path)
            }
        }
    }

    public func run(packageDirectory: URL, frameworkOutputDir: OutputDirectory) async throws {
        let packagePath = resolveURL(packageDirectory)
        let package: Package
        do {
            package = try Package(packageDirectory: packagePath)
        } catch {
            throw Error.invalidPackage(packagePath)
        }

        let sdks = package.supportedSDKs
        guard !sdks.isEmpty else {
            throw Error.platformNotSpecified
        }

        let buildOptions = BuildOptions(buildConfiguration: options.buildConfiguration,
                                        isSimulatorSupported: options.isSimulatorSupported,
                                        isDebugSymbolsEmbedded: options.isDebugSymbolsEmbedded,
                                        sdks: sdks)
        try fileSystem.createDirectory(package.workspaceDirectory, recursive: true)

        let resolver = Resolver(package: package)
        try await resolver.resolve()

        let generator = ProjectGenerator()
        try generator.generate(for: package, embedDebugSymbols: buildOptions.isDebugSymbolsEmbedded)

        let outputDir = frameworkOutputDir.resolve(packageDirectory: packageDirectory)
        
        try fileSystem.createDirectory(outputDir, recursive: true)

        let cacheStorage: (any CacheStorage)?
        switch options.cacheStorage {
        case .none:
            cacheStorage = nil
        case .local:
            cacheStorage = LocalCacheStorage()
        case .custom(let storage):
            cacheStorage = storage
        }

        let compiler = Compiler(rootPackage: package,
                                cacheStorage: cacheStorage,
                                executor: ProcessExecutor(),
                                fileSystem: fileSystem)
        do {
            switch mode {
            case .createPackage:
                try await compiler.build(
                    mode: .createPackage,
                    buildOptions: buildOptions,
                    outputDir: outputDir,
                    isCacheEnabled: options.isCacheEnabled
                )
            case .prepareDependencies:
                try await compiler.build(
                    mode: .prepareDependencies,
                    buildOptions: buildOptions,
                    outputDir: outputDir,
                    isCacheEnabled: options.isCacheEnabled
                )
            }
            logger.info("❇️ Succeeded.", metadata: .color(.green))
        } catch {
            logger.error("Something went wrong during building", metadata: .color(.red))
            logger.error("Please execute with --verbose option.", metadata: .color(.red))
            logger.error("\(error.localizedDescription)")
            throw Error.compilerError(error)
        }
    }
}
