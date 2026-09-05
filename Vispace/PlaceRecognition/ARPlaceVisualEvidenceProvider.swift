import CoreVideo
import Foundation
import ImageIO
@preconcurrency import Vision
import VispaceCore

/// Revision-pinned, normalized camera features. These are sensitive spatial
/// descriptors, not photographs; they stay in the protected local spatial store.
struct PlaceVisualDescriptor: Codable, Equatable, Sendable {
    let revision: Int
    let values: [Float]

    init(revision: Int, values: [Float]) {
        self.revision = revision
        self.values = values
    }

    private enum CodingKeys: String, CodingKey { case revision, values }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int.self, forKey: .revision)
        var encoded = try container.nestedUnkeyedContainer(forKey: .values)
        guard revision == 2, encoded.count.map({ (64...4_096).contains($0) }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .values, in: container,
                debugDescription: "Unsupported or oversized camera descriptor.")
        }
        var decoded: [Float] = []
        while !encoded.isAtEnd {
            guard decoded.count < 4_096 else {
                throw DecodingError.dataCorruptedError(
                    in: encoded, debugDescription: "Camera descriptor exceeds capacity.")
            }
            decoded.append(try encoded.decode(Float.self))
        }
        values = decoded
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .values, in: container,
                debugDescription: "Camera descriptor is not finite and normalized.")
        }
    }

    var isValid: Bool {
        revision == 2 && (64...4_096).contains(values.count)
            && values.allSatisfy(\.isFinite)
            && abs(values.reduce(0.0) { $0 + Double($1 * $1) } - 1) < 0.01
    }

    func distance(to other: Self) -> Double? {
        guard isValid, other.isValid, revision == other.revision,
            values.count == other.values.count
        else { return nil }
        return zip(values, other.values).reduce(0.0) {
            $0 + pow(Double($1.0) - Double($1.1), 2)
        }.squareRoot()
    }
}

struct PlaceVisualLandmark: Codable, Equatable, Sendable {
    /// Portable belongings, people and animals can recur in unrelated rooms.
    /// They may be remembered as objects but cannot establish a room transform.
    static func admitsLabel(_ label: String) -> Bool {
        [
            "chair", "couch", "sofa", "dining table", "table", "desk", "bed", "tv", "tvmonitor",
            "refrigerator", "oven", "sink", "toilet", "potted plant", "pottedplant", "plant",
            "lamp", "bookcase", "bookshelf", "cabinet",
        ]
        .contains(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    let mapID: MapID
    let coordinateFrameID: CoordinateFrameID
    let segmentID: CaptureSegmentID
    let frameID: UUID
    let sessionRunGeneration: UInt64
    let attachmentEpoch: UInt64
    let objectID: ObjectID
    let semanticLabel: String
    let position: Vec3
    let capturedAt: TimeInterval
    let timestamp: TimeInterval
    let supportingCaptureCount: Int
    let appearance: PlaceVisualDescriptor
    let sceneAppearance: PlaceVisualDescriptor

    var isValid: Bool {
        !semanticLabel.isEmpty && semanticLabel.count <= 128
            && capturedAt.isFinite && capturedAt >= 0 && timestamp.isFinite && timestamp >= 0
            && (1...100).contains(supportingCaptureCount)
            && appearance.isValid && sceneAppearance.isValid
    }

    func matches(_ object: SpatialObjectMetadata) -> Bool {
        object.mapID == mapID && object.position.coordinateFrameID == coordinateFrameID
            && object.object.id == objectID && object.object.semanticLabel == semanticLabel
            && object.object.certainty == .confirmed && object.object.presence != .removed
            && object.position.value.distance(to: position) <= 0.15
    }

    func isFresh(for surface: ARSurfaceStateSnapshot) -> Bool {
        surface.isComplete && surface.mapID == mapID
            && surface.coordinateFrameID == coordinateFrameID && surface.segmentID == segmentID
            && surface.timestamp.isFinite && surface.timestamp - timestamp >= -0.25
            && surface.timestamp - timestamp <= 3
    }
}

/// Camera similarity is an independent measurement, never a semantic-label
/// identity shortcut. Thresholds deliberately favor deferral. They are not a
/// calibrated probability of physical identity and need real-device evaluation.
struct PlaceVisualCorrespondenceMatcher: Sendable {
    func correspondences(
        current: ARSurfaceStateSnapshot, candidate: PlaceFingerprintRecord,
        live: [PlaceVisualLandmark], durable: [PlaceVisualLandmark],
        objects: [SpatialObjectMetadata]
    ) throws -> [CoordinateFrameAlignmentCorrespondence] {
        let source = live.filter { record in
            record.isValid && PlaceVisualLandmark.admitsLabel(record.semanticLabel)
                && record.supportingCaptureCount >= 2 && record.isFresh(for: current)
                && objects.contains { record.matches($0) && $0.object.presence == .visible }
        }
        // Include every other map in the runner-up test. A cloned appearance
        // in two saved rooms must not be decided by catalog ordering.
        let targets = durable.filter { record in
            record.isValid && PlaceVisualLandmark.admitsLabel(record.semanticLabel)
                && record.supportingCaptureCount >= 2
                && record.coordinateFrameID != current.coordinateFrameID
                && objects.contains(where: record.matches)
        }
        guard source.count >= 3, targets.count >= 3,
            Set(source.map(\.objectID)).count == source.count,
            Set(targets.map { LandmarkKey(mapID: $0.mapID, objectID: $0.objectID) }).count == targets.count
        else { return [] }

        var result: [CoordinateFrameAlignmentCorrespondence] = []
        for item in source {
            let ranked = targets.compactMap { target -> (PlaceVisualLandmark, Double)? in
                guard let distance = item.appearance.distance(to: target.appearance) else { return nil }
                return (target, distance)
            }.sorted { $0.1 < $1.1 }
            guard let best = ranked.first, best.0.mapID == candidate.mapID,
                best.0.coordinateFrameID == candidate.coordinateFrameID,
                item.semanticLabel == best.0.semanticLabel,
                admits(ranked.map(\.1)),
                let sceneDistance = item.sceneAppearance.distance(to: best.0.sceneAppearance),
                sceneDistance <= 0.20
            else { continue }
            let reverse = source.compactMap { other -> (ObjectID, Double)? in
                guard let distance = best.0.appearance.distance(to: other.appearance) else { return nil }
                return (other.objectID, distance)
            }.sorted { $0.1 < $1.1 }
            guard reverse.first?.0 == item.objectID, admits(reverse.map(\.1)) else { continue }
            result.append(
                try CoordinateFrameAlignmentCorrespondence(
                    source: CoordinateFrameAlignmentSourcePoint(
                        objectID: item.objectID, coordinateFrameID: item.coordinateFrameID,
                        semanticLabel: item.semanticLabel, position: item.position
                    ),
                    target: CoordinateFrameAlignmentTargetPoint(
                        objectID: best.0.objectID, coordinateFrameID: best.0.coordinateFrameID,
                        semanticLabel: best.0.semanticLabel, position: best.0.position
                    ),
                    identityConfidence: ConfidenceScore(clamping: 0.95)
                ))
        }
        return result
    }

    private func admits(_ distances: [Double]) -> Bool {
        guard distances.count >= 2, let best = distances.first, best <= 0.12 else { return false }
        return distances[1] - best >= 0.10 && best <= distances[1] * 0.60
    }
}

private struct LandmarkKey: Hashable {
    let mapID: MapID
    let objectID: ObjectID
}

private struct PlaceVisualCatalog: Codable {
    let schemaVersion: Int
    var landmarks: [PlaceVisualLandmark]

    init(schemaVersion: Int, landmarks: [PlaceVisualLandmark]) {
        self.schemaVersion = schemaVersion
        self.landmarks = landmarks
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, landmarks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        var encoded = try container.nestedUnkeyedContainer(forKey: .landmarks)
        guard schemaVersion == 1,
            encoded.count.map({ $0 <= ARPlaceVisualEvidenceProvider.maximumLandmarks }) ?? true
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .landmarks, in: container,
                debugDescription: "Unsupported or oversized camera evidence catalog.")
        }
        var decoded: [PlaceVisualLandmark] = []
        while !encoded.isAtEnd {
            guard decoded.count < ARPlaceVisualEvidenceProvider.maximumLandmarks else {
                throw DecodingError.dataCorruptedError(
                    in: encoded, debugDescription: "Camera catalog exceeds capacity.")
            }
            let record = try encoded.decode(PlaceVisualLandmark.self)
            guard record.isValid else {
                throw DecodingError.dataCorruptedError(
                    in: encoded, debugDescription: "Invalid camera landmark provenance.")
            }
            decoded.append(record)
        }
        landmarks = decoded
    }
}

/// The production bridge from real detector crops and verified depth into
/// cross-session map alignment. Persisted records can only be targets: source
/// evidence must have been captured in this process and current segment.
public actor ARPlaceVisualEvidenceProvider {
    static let fileName = "place-visual-evidence-v1.json"
    static let maximumBytes = 16 * 1_024 * 1_024
    static let maximumLandmarks = 256
    private let directoryURL: URL
    private let catalogURL: URL
    private var live: [LandmarkKey: PlaceVisualLandmark] = [:]
    private var latestHistogram: (ARPoseSnapshot, NormalizedPlaceHistogram)?
    private var lastCapture: ARPoseSnapshot?
    private var generation: UInt64 = 0

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
        catalogURL = directoryURL.standardizedFileURL.appendingPathComponent(Self.fileName)
    }

    public func ingest(
        frame: ARFrameSnapshot, detections: [DetectedObject], objects: [SpatialObjectMetadata]
    ) async throws {
        let pose = frame.pose
        guard pose.trackingState == .normal, pose.coordinateFrameStatus == .confirmed,
            let mapID = pose.mapID, pose.timestamp.isFinite, pose.capturedAt.isFinite
        else { return }
        if let previous = lastCapture, previous.segmentID == pose.segmentID,
            previous.sessionToken == pose.sessionToken, pose.timestamp - previous.timestamp < 0.75
        {
            return
        }
        if let previous = lastCapture,
            previous.segmentID != pose.segmentID || previous.sessionToken != pose.sessionToken
        {
            live.removeAll()
            latestHistogram = nil
        }
        lastCapture = pose
        let workGeneration = generation
        let identity = ARCaptureIdentity(
            coordinateFrameID: pose.coordinateFrameID,
            segmentID: pose.segmentID, mapID: mapID, status: .confirmed)
        let extraction = Task.detached(priority: .utility) {
            try PlaceVisualCameraExtractor().extract(
                frame: frame, detections: detections, objects: objects, identity: identity
            )
        }
        let extracted = try await withTaskCancellationHandler {
            try await extraction.value
        } onCancel: {
            extraction.cancel()
        }
        try Task.checkCancellation()
        guard generation == workGeneration, lastCapture?.id == pose.id else { return }
        if let histogram = extracted.histogram { latestHistogram = (pose, histogram) }
        guard !extracted.landmarks.isEmpty else { return }
        var catalog = try load()
        for sample in extracted.landmarks {
            let key = LandmarkKey(mapID: sample.mapID, objectID: sample.objectID)
            var support = 1
            if let previous = live[key], previous.frameID != sample.frameID,
                previous.segmentID == sample.segmentID,
                previous.sessionRunGeneration == sample.sessionRunGeneration,
                previous.attachmentEpoch == sample.attachmentEpoch,
                sample.timestamp - previous.timestamp >= 0.5,
                sample.timestamp - previous.timestamp <= 3,
                sample.position.distance(to: previous.position) <= 0.15,
                let distance = sample.appearance.distance(to: previous.appearance), distance <= 0.12
            {
                support = min(100, previous.supportingCaptureCount + 1)
            }
            let record = sample.withSupport(support)
            live[key] = record
            guard support >= 2 else { continue }
            catalog.landmarks.removeAll { $0.mapID == record.mapID && $0.objectID == record.objectID }
            catalog.landmarks.append(record)
        }
        live = live.filter {
            $0.value.segmentID == pose.segmentID && pose.timestamp - $0.value.timestamp <= 3
        }
        // Eviction limits stored biometric-like descriptors independently of the
        // broader spatial-data budget; it only reduces future match coverage.
        catalog.landmarks.sort { $0.capturedAt > $1.capturedAt }
        catalog.landmarks = Array(catalog.landmarks.prefix(Self.maximumLandmarks))
        try save(catalog)
    }

    public func visualHistogram(matching snapshot: ARSurfaceStateSnapshot) -> NormalizedPlaceHistogram? {
        guard let (pose, histogram) = latestHistogram, snapshot.isComplete,
            pose.mapID == snapshot.mapID, pose.coordinateFrameID == snapshot.coordinateFrameID,
            pose.segmentID == snapshot.segmentID,
            snapshot.timestamp - pose.timestamp >= -0.25,
            snapshot.timestamp - pose.timestamp <= 3
        else { return nil }
        return histogram
    }

    public func resolve(
        current snapshot: ARSurfaceStateSnapshot, candidate: PlaceFingerprintRecord,
        objects: [SpatialObjectMetadata]
    ) throws -> PlaceCoordinateAlignmentResolution {
        try Task.checkCancellation()
        let now = Date().timeIntervalSince1970
        let matches = try PlaceVisualCorrespondenceMatcher().correspondences(
            current: snapshot, candidate: candidate,
            live: live.values.filter {
                now - $0.capturedAt >= -0.25 && now - $0.capturedAt <= 3
            },
            durable: load().landmarks, objects: objects
        )
        return PlaceCoordinateAlignmentResolver().resolve(
            current: snapshot, candidate: candidate, verifiedVisualCorrespondences: matches
        )
    }

    public func reset() {
        generation &+= 1
        live.removeAll()
        lastCapture = nil
        latestHistogram = nil
    }

    public func deleteMap(_ mapID: MapID) throws {
        reset()
        var catalog = try load()
        catalog.landmarks.removeAll { $0.mapID == mapID }
        try save(catalog)
    }

    private func load() throws -> PlaceVisualCatalog {
        try SpatialStorageDirectory.prepare(at: directoryURL)
        try SpatialStorageDirectory.validatePath(at: catalogURL)
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            return PlaceVisualCatalog(schemaVersion: 1, landmarks: [])
        }
        try SpatialStorageDirectory.validateRegularFile(at: catalogURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: catalogURL.path)
        guard let bytes = (attributes[.size] as? NSNumber)?.intValue, bytes <= Self.maximumBytes else {
            throw SpatialStorageError.capacityExceeded(maximumBytes: Int64(Self.maximumBytes))
        }
        let catalog = try JSONDecoder().decode(PlaceVisualCatalog.self, from: Data(contentsOf: catalogURL))
        guard catalog.schemaVersion == 1, catalog.landmarks.count <= Self.maximumLandmarks,
            catalog.landmarks.allSatisfy(\.isValid),
            Set(catalog.landmarks.map { LandmarkKey(mapID: $0.mapID, objectID: $0.objectID) }).count
                == catalog.landmarks.count
        else { throw SpatialStorageError.unsupportedSchema(actual: catalog.schemaVersion) }
        return catalog
    }

    private func save(_ catalog: PlaceVisualCatalog) throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(catalog)
        guard data.count <= Self.maximumBytes else {
            throw SpatialStorageError.capacityExceeded(maximumBytes: Int64(Self.maximumBytes))
        }
        try SpatialStorageDirectory.atomicWrite(data, to: catalogURL, directory: directoryURL)
    }
}

extension PlaceVisualLandmark {
    fileprivate func withSupport(_ count: Int) -> Self {
        Self(
            mapID: mapID, coordinateFrameID: coordinateFrameID, segmentID: segmentID,
            frameID: frameID, sessionRunGeneration: sessionRunGeneration, attachmentEpoch: attachmentEpoch,
            objectID: objectID, semanticLabel: semanticLabel, position: position, capturedAt: capturedAt,
            timestamp: timestamp, supportingCaptureCount: count,
            appearance: appearance, sceneAppearance: sceneAppearance)
    }
}

struct PlaceVisualCameraExtraction: Sendable {
    let landmarks: [PlaceVisualLandmark]
    let histogram: NormalizedPlaceHistogram?
}

struct PlaceVisualCameraExtractor: Sendable {
    func extract(
        frame: ARFrameSnapshot, detections: [DetectedObject], objects: [SpatialObjectMetadata],
        identity: ARCaptureIdentity
    ) throws -> PlaceVisualCameraExtraction {
        guard let mapID = identity.mapID else { return .init(landmarks: [], histogram: nil) }
        let whole = NormalizedBoundingBox(x: 0, y: 0, width: 1, height: 1)
        guard let scene = try descriptor(frame: frame, box: whole) else {
            return .init(landmarks: [], histogram: nil)
        }
        let eligible = objects.filter {
            $0.mapID == mapID && $0.position.coordinateFrameID == identity.coordinateFrameID
                && $0.object.certainty == .confirmed && $0.object.presence == .visible
                && frame.pose.capturedAt - $0.position.observedAt >= -0.1
                && frame.pose.capturedAt - $0.position.observedAt <= 1
        }
        let locator = ObjectDepthLocator()
        var landmarks: [PlaceVisualLandmark] = []
        for detection in detections.prefix(16) {
            try Task.checkCancellation()
            guard PlaceVisualLandmark.admitsLabel(detection.label),
                detection.confidence >= 0.85, detection.boundingBox.isValidNonEmpty,
                detection.boundingBox.width >= 0.08, detection.boundingBox.height >= 0.08,
                case .located(let located) = locator.locate(detection, in: frame, currentIdentity: identity),
                located.geometryConfidence.value >= 0.8
            else { continue }
            let matches = eligible.filter {
                $0.object.semanticLabel.lowercased() == detection.label.lowercased()
                    && $0.position.value.distance(to: located.position.value) <= 0.15
            }
            guard matches.count == 1, let object = matches.first,
                !landmarks.contains(where: { $0.objectID == object.object.id }),
                let appearance = try descriptor(frame: frame, box: detection.boundingBox)
            else { continue }
            landmarks.append(
                PlaceVisualLandmark(
                    mapID: mapID, coordinateFrameID: identity.coordinateFrameID,
                    segmentID: identity.segmentID,
                    frameID: frame.pose.id.rawValue,
                    sessionRunGeneration: frame.pose.sessionToken.sessionRunGeneration,
                    attachmentEpoch: frame.pose.sessionToken.attachmentEpoch,
                    objectID: object.object.id, semanticLabel: object.object.semanticLabel,
                    position: located.position.value, capturedAt: frame.pose.capturedAt,
                    timestamp: frame.pose.timestamp, supportingCaptureCount: 1,
                    appearance: appearance, sceneAppearance: scene
                ))
        }
        return .init(landmarks: landmarks, histogram: luminanceHistogram(frame.capturedImage.pixelBuffer))
    }

    func descriptor(frame: ARFrameSnapshot, box: NormalizedBoundingBox) throws -> PlaceVisualDescriptor? {
        try Task.checkCancellation()
        #if targetEnvironment(simulator)
            // The iOS 26.5 Simulator's CPU backend returns identical features for
            // distinct inputs, and its GPU cannot create an Espresso context.
            // Such features cannot establish independent place identity.
            return nil
        #else
            guard let orientation = CGImagePropertyOrientation(rawValue: frame.imageOrientation.rawValue)
            else {
                return nil
            }
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = VNGenerateImageFeaturePrintRequestRevision2
            request.regionOfInterest = CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
            request.imageCropAndScaleOption = .scaleFit
            let handler = VNImageRequestHandler(
                cvPixelBuffer: frame.capturedImage.pixelBuffer, orientation: orientation)
            try handler.perform([request])
            guard let observation = request.results?.first,
                observation.requestRevision == VNGenerateImageFeaturePrintRequestRevision2,
                observation.elementType == .float,
                (64...4_096).contains(observation.elementCount),
                observation.data.count == observation.elementCount * MemoryLayout<Float>.size
            else { return nil }
            var values = observation.data.withUnsafeBytes { data in
                (0..<observation.elementCount).map {
                    data.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self)
                }
            }
            guard values.allSatisfy(\.isFinite) else { return nil }
            let norm = values.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            guard norm.isFinite, norm > 0.0001 else { return nil }
            values = values.map { Float(Double($0) / norm) }
            let result = PlaceVisualDescriptor(revision: observation.requestRevision, values: values)
            return result.isValid ? result : nil
        #endif
    }

    private func luminanceHistogram(_ buffer: CVPixelBuffer) -> NormalizedPlaceHistogram? {
        guard CVPixelBufferGetPlaneCount(buffer) >= 1,
            [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                .contains(CVPixelBufferGetPixelFormatType(buffer)),
            CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let strideBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0, strideBytes >= width else { return nil }
        var bins = Array(repeating: 0.0, count: 16)
        for y in stride(from: 0, to: height, by: max(1, height / 32)) {
            for x in stride(from: 0, to: width, by: max(1, width / 32)) {
                bins[Int(base.load(fromByteOffset: y * strideBytes + x, as: UInt8.self)) / 16] += 1
            }
        }
        let total = bins.reduce(0, +)
        return try? NormalizedPlaceHistogram(values: bins.map { $0 / total })
    }
}
