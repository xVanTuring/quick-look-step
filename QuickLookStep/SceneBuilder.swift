import SceneKit
import Cocoa
import Quartz
import simd


/// A tiny helper that converts a STEP file into a ready-to-render `SCNScene`,
/// replicating the same camera and lighting configuration we use in the preview
/// extension so thumbnails and previews look identical before any user
/// interaction.
enum SceneBuilder {
    /// sRGB colour for solids that carry no STEP colour. foxtrot reports those
    /// as exactly 50 % grey, which renders too dark.
    static let defaultColor = SIMD3<Float>(0.74, 0.78, 0.84)

    /// Builds a SceneKit scene containing the geometry loaded from the STEP
    /// file at `url`.
    /// - Throws: An `NSError` if the STEP file cannot be parsed by the Rust
    ///           backend.
    static func scene(for url: URL) throws -> SCNScene {
        // --- Load via FFI and measure duration ---
        var mesh = MeshSlice()
        let start = CFAbsoluteTimeGetCurrent()
        let ok = url.path.withCString { cPath in
            foxtrot_load_step(cPath, &mesh)
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        NSLog("foxtrot_load_step(%@) -> %@ in %.2f ms", url.path, ok ? "OK" : "FAIL", elapsedMs)
        guard ok else {
            throw NSError(
                domain: "SceneBuilder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load STEP file"]
            )
        }
        defer { foxtrot_free_mesh(mesh) }

        // Build SceneKit geometry from the raw buffers.
        let vertexCount = Int(mesh.vert_count)
        let indexCount = Int(mesh.tri_count) * 3
        let vectorBytes = vertexCount * 3 * MemoryLayout<Float>.size

        func floatSource(_ data: Data, _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            SCNGeometrySource(
                data: data,
                semantic: semantic,
                vectorCount: vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: 3 * MemoryLayout<Float>.size
            )
        }

        let vertexSource = floatSource(Data(bytes: mesh.verts!, count: vectorBytes), .vertex)
        let normalSource = floatSource(Data(bytes: mesh.normals!, count: vectorBytes), .normal)
        let colorSource = floatSource(linearColors(mesh.colors!, count: vertexCount), .color)

        let indexData = Data(
            bytes: mesh.tris!,
            count: indexCount * MemoryLayout<UInt32>.size
        )
        let geometryElement = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: Int(mesh.tri_count),
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource, normalSource, colorSource], elements: [geometryElement])
        let material = SCNMaterial()
        material.lightingModel = .blinn
        // Per-vertex colours are multiplied with the diffuse colour, so keep it white.
        material.diffuse.contents = NSColor.white
        material.specular.contents = NSColor(white: 0.35, alpha: 1)
        material.shininess = 0.25
        material.isDoubleSided = true
        geometry.firstMaterial = material

        // Assemble the scene graph.
        let scene = SCNScene()
        let node = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(node)

        // --- Scale & centre geometry ---
        let (minBounds, maxBounds) = node.boundingBox
        let size = SCNVector3(
            maxBounds.x - minBounds.x,
            maxBounds.y - minBounds.y,
            maxBounds.z - minBounds.z
        )

        // Uniformly scale so the largest dimension maps to `targetSize` units.
        let targetSize: CGFloat = 100.0
        let maxExtent = max(size.x, max(size.y, size.z))
        let scaleFactor = targetSize / maxExtent
        let sf = Float(scaleFactor)
        node.scale = SCNVector3(sf, sf, sf)

        // Re-centre so model origin is at (0,0,0)
        let center = SCNVector3(
            (maxBounds.x + minBounds.x) / 2.0,
            (maxBounds.y + minBounds.y) / 2.0,
            (maxBounds.z + minBounds.z) / 2.0
        )
        node.position = SCNVector3(Float(-center.x * scaleFactor),
                                   Float(-center.y * scaleFactor),
                                   Float(-center.z * scaleFactor))

        // --- Camera setup ---
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 10000
        camera.fieldOfView = 45
        cameraNode.camera = camera

        // Use a diagonal viewing direction for depth, and back off just far
        // enough that every corner of the bounding box fits in the view.
        let viewDirection = simd_normalize(SIMD3<Float>(1, 1, 1))
        let halfExtent = SIMD3<Float>(Float(size.x), Float(size.y), Float(size.z)) * (sf / 2)
        let distance = fittingDistance(
            halfExtent: halfExtent,
            viewDirection: viewDirection,
            fieldOfViewDegrees: Float(camera.fieldOfView)
        )
        let eye = viewDirection * distance
        cameraNode.position = SCNVector3(eye.x, eye.y, eye.z)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        // --- Lighting ---
        // Key light rides on the camera so the side facing the viewer stays lit
        // while orbiting; it is tilted up-left so faces read as distinct shades.
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 850
        keyLight.eulerAngles = SCNVector3(0.35, 0.45, 0)
        cameraNode.addChildNode(keyLight)

        // Fixed fill light from below so undersides are not black.
        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .directional
        fillLight.light?.intensity = 300
        fillLight.look(at: SCNVector3(0.4, 1, 0.2))
        scene.rootNode.addChildNode(fillLight)

        let ambientNode = SCNNode()
        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.color = NSColor(white: 1, alpha: 1)
        ambientNode.light?.intensity = 380
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }

    /// Converts foxtrot's sRGB vertex colours to the linear values SceneKit
    /// expects, swapping foxtrot's 50 % grey placeholder for `defaultColor`.
    private static func linearColors(_ colors: UnsafePointer<Float>, count: Int) -> Data {
        func linear(_ c: Float) -> Float {
            c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        let fallback = SIMD3<Float>(linear(defaultColor.x), linear(defaultColor.y), linear(defaultColor.z))
        var out = [Float](repeating: 0, count: count * 3)
        for i in 0..<count {
            let r = colors[i * 3], g = colors[i * 3 + 1], b = colors[i * 3 + 2]
            if r == 0.5 && g == 0.5 && b == 0.5 {
                out[i * 3] = fallback.x
                out[i * 3 + 1] = fallback.y
                out[i * 3 + 2] = fallback.z
            } else {
                out[i * 3] = linear(r)
                out[i * 3 + 1] = linear(g)
                out[i * 3 + 2] = linear(b)
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Camera distance from the origin, along `viewDirection`, at which a box
    /// of `halfExtent` centred on the origin fills the view with a small margin.
    private static func fittingDistance(halfExtent: SIMD3<Float>, viewDirection: SIMD3<Float>, fieldOfViewDegrees: Float) -> Float {
        let forward = -viewDirection
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, forward)
        let tanHalfFov = tanf(fieldOfViewDegrees / 2 * .pi / 180)

        var distance: Float = 0
        for sx: Float in [-1, 1] {
            for sy: Float in [-1, 1] {
                for sz: Float in [-1, 1] {
                    let corner = halfExtent * SIMD3<Float>(sx, sy, sz)
                    let lateral = max(abs(simd_dot(corner, right)), abs(simd_dot(corner, up)))
                    distance = max(distance, lateral / tanHalfFov + simd_dot(corner, viewDirection))
                }
            }
        }
        return distance * 1.08
    }
}
