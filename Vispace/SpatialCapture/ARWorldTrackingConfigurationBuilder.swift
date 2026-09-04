@preconcurrency import ARKit
import Foundation

public struct ARCaptureCapabilities: Equatable, Sendable {
    public let supportsWorldTracking: Bool
    public let supportsSceneDepth: Bool
    public let supportsSmoothedSceneDepth: Bool
    public let supportsMeshReconstruction: Bool
    public let supportsMeshClassification: Bool

    public init(
        supportsWorldTracking: Bool,
        supportsSceneDepth: Bool,
        supportsSmoothedSceneDepth: Bool,
        supportsMeshReconstruction: Bool,
        supportsMeshClassification: Bool
    ) {
        self.supportsWorldTracking = supportsWorldTracking
        self.supportsSceneDepth = supportsSceneDepth
        self.supportsSmoothedSceneDepth = supportsSmoothedSceneDepth
        self.supportsMeshReconstruction = supportsMeshReconstruction
        self.supportsMeshClassification = supportsMeshClassification
    }
}

public struct ARWorldTrackingOptions: Equatable, Sendable {
    public var requestsSceneDepth: Bool
    public var requestsSmoothedSceneDepth: Bool
    public var requestsMeshReconstruction: Bool
    public var requestsMeshClassification: Bool
    public var detectsHorizontalPlanes: Bool
    public var detectsVerticalPlanes: Bool

    public init(
        requestsSceneDepth: Bool = true,
        requestsSmoothedSceneDepth: Bool = true,
        requestsMeshReconstruction: Bool = true,
        requestsMeshClassification: Bool = true,
        detectsHorizontalPlanes: Bool = true,
        detectsVerticalPlanes: Bool = true
    ) {
        self.requestsSceneDepth = requestsSceneDepth
        self.requestsSmoothedSceneDepth = requestsSmoothedSceneDepth
        self.requestsMeshReconstruction = requestsMeshReconstruction
        self.requestsMeshClassification = requestsMeshClassification
        self.detectsHorizontalPlanes = detectsHorizontalPlanes
        self.detectsVerticalPlanes = detectsVerticalPlanes
    }

    public static let productionDefault = ARWorldTrackingOptions()
}

public enum ARWorldTrackingConfigurationError: Error, Equatable, Sendable {
    case worldTrackingUnsupported
}

public enum ARWorldTrackingConfigurationBuilder {
    public static func capabilities() -> ARCaptureCapabilities {
        let sceneDepth: ARConfiguration.FrameSemantics = .sceneDepth
        let smoothedSceneDepth: ARConfiguration.FrameSemantics = .smoothedSceneDepth

        return ARCaptureCapabilities(
            supportsWorldTracking: ARWorldTrackingConfiguration.isSupported,
            supportsSceneDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(sceneDepth),
            supportsSmoothedSceneDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(
                smoothedSceneDepth
            ),
            supportsMeshReconstruction: ARWorldTrackingConfiguration.supportsSceneReconstruction(
                .mesh
            ),
            supportsMeshClassification: ARWorldTrackingConfiguration.supportsSceneReconstruction(
                .meshWithClassification
            )
        )
    }

    public static func make(
        options: ARWorldTrackingOptions = .productionDefault,
        initialWorldMap: ARWorldMap? = nil
    ) throws -> (configuration: ARWorldTrackingConfiguration, capabilities: ARCaptureCapabilities) {
        let capabilities = capabilities()
        guard capabilities.supportsWorldTracking else {
            throw ARWorldTrackingConfigurationError.worldTrackingUnsupported
        }

        return build(
            options: options,
            initialWorldMap: initialWorldMap,
            capabilities: capabilities
        )
    }

    fileprivate static func build(
        options: ARWorldTrackingOptions,
        initialWorldMap: ARWorldMap?,
        capabilities: ARCaptureCapabilities
    ) -> (configuration: ARWorldTrackingConfiguration, capabilities: ARCaptureCapabilities) {

        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = initialWorldMap
        configuration.isAutoFocusEnabled = true
        configuration.providesAudioData = false

        var planeDetection: ARWorldTrackingConfiguration.PlaneDetection = []
        if options.detectsHorizontalPlanes {
            planeDetection.insert(.horizontal)
        }
        if options.detectsVerticalPlanes {
            planeDetection.insert(.vertical)
        }
        configuration.planeDetection = planeDetection

        var semantics: ARConfiguration.FrameSemantics = []
        let requestedSemantics: [ARConfiguration.FrameSemantics] = [
            options.requestsSceneDepth ? .sceneDepth : [],
            options.requestsSmoothedSceneDepth ? .smoothedSceneDepth : [],
        ]
        for candidate in requestedSemantics where !candidate.isEmpty {
            let combined = semantics.union(candidate)
            if ARWorldTrackingConfiguration.supportsFrameSemantics(combined) {
                semantics = combined
            }
        }
        configuration.frameSemantics = semantics

        if options.requestsMeshReconstruction {
            if options.requestsMeshClassification, capabilities.supportsMeshClassification {
                configuration.sceneReconstruction = .meshWithClassification
            } else if capabilities.supportsMeshReconstruction {
                configuration.sceneReconstruction = .mesh
            }
        }

        return (configuration, capabilities)
    }
}

/// Small injectable facade retained for tests and composition code that need
/// to inspect a configuration even on a Simulator where world tracking itself
/// cannot run. Production startup uses the throwing builder above.
public struct ARSessionConfigurationBuilder: Sendable {
    public static let live = ARSessionConfigurationBuilder()

    public let options: ARWorldTrackingOptions

    public init(options: ARWorldTrackingOptions = .productionDefault) {
        self.options = options
    }

    public func makeConfiguration(
        initialWorldMap: ARWorldMap? = nil
    ) -> ARWorldTrackingConfiguration {
        let capabilities = ARWorldTrackingConfigurationBuilder.capabilities()
        return ARWorldTrackingConfigurationBuilder.build(
            options: options,
            initialWorldMap: initialWorldMap,
            capabilities: capabilities
        ).configuration
    }
}
