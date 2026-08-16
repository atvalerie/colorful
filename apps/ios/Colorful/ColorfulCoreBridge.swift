import Foundation

enum ColorfulCoreAvailability: Sendable {
    case native
    case preview

    var label: String {
        switch self {
        case .native:
            return "Rust core connected"
        case .preview:
            return "SwiftUI shell preview"
        }
    }
}

enum ColorfulCoreBridgeError: LocalizedError, Sendable {
    case unavailable
    case abiMismatch(UInt32)
    case core(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The Rust core is not available in this build."
        case .abiMismatch(let version):
            return "Unsupported Rust core ABI version \(version)."
        case .core(let message):
            return message
        case .invalidResponse:
            return "The Rust core returned an invalid snapshot."
        }
    }
}

actor ColorfulCoreBridge {
    nonisolated let availability: ColorfulCoreAvailability
    nonisolated let isReady: Bool
    private var handle: UInt64

    init() {
        var openedHandle: UInt64 = 0
        var openedAvailability: ColorfulCoreAvailability = .preview
#if COLORFUL_CORE_ENABLED
        if colorful_core_abi_version() == 1 {
            let databaseURL = Self.databaseURL()
            try? FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if let response = databaseURL.path.withCString({ colorful_engine_open($0) }),
               let data = Self.consume(response),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = object["ok"] as? Bool,
               ok,
               let value = object["value"] as? [String: Any],
               let numericHandle = value["handle"] as? NSNumber {
                openedHandle = numericHandle.uint64Value
                openedAvailability = .native
            }
        }
#endif
        handle = openedHandle
        availability = openedAvailability
        isReady = openedHandle != 0
    }

    deinit {
#if COLORFUL_CORE_ENABLED
        if handle != 0 {
            _ = colorful_engine_close(handle)
        }
#endif
    }

    func snapshot() -> Data? {
#if COLORFUL_CORE_ENABLED
        guard handle != 0 else { return nil }
        return colorful_engine_snapshot(handle).flatMap(Self.consume)
#else
        return nil
#endif
    }

    func loadSnapshot() throws -> ColorfulCoreSnapshot? {
#if COLORFUL_CORE_ENABLED
        guard let data = snapshot() else {
            throw ColorfulCoreBridgeError.unavailable
        }

        let response = try JSONDecoder().decode(
            ColorfulCoreResponse<ColorfulCoreSnapshot>.self,
            from: data
        )
        guard response.abiVersion == 1 else {
            throw ColorfulCoreBridgeError.abiMismatch(response.abiVersion)
        }
        guard response.ok else {
            throw ColorfulCoreBridgeError.core(response.error ?? "The Rust core rejected the snapshot request.")
        }
        guard let value = response.value else {
            throw ColorfulCoreBridgeError.invalidResponse
        }
        guard value.abiVersion == 1 else {
            throw ColorfulCoreBridgeError.abiMismatch(value.abiVersion)
        }
        return value
#else
        return nil
#endif
    }

    func mapTidalTracks(documentJSON: String) throws -> [CoreTrack] {
#if COLORFUL_CORE_ENABLED
        guard let data = documentJSON.withCString({ colorful_tidal_map_tracks($0).flatMap(Self.consume) }) else {
            throw ColorfulCoreBridgeError.invalidResponse
        }

        let response = try JSONDecoder().decode(
            ColorfulCoreResponse<[CoreTrack]>.self,
            from: data
        )
        guard response.abiVersion == 1 else {
            throw ColorfulCoreBridgeError.abiMismatch(response.abiVersion)
        }
        guard response.ok else {
            throw ColorfulCoreBridgeError.core(response.error ?? "The Rust TIDAL mapper rejected the catalog response.")
        }
        return response.value ?? []
#else
        throw ColorfulCoreBridgeError.unavailable
#endif
    }

    @discardableResult
    func dispatch(commandJSON: String) -> Bool {
#if COLORFUL_CORE_ENABLED
        guard handle != 0,
              let data = commandJSON.withCString({ colorful_engine_dispatch(handle, $0).flatMap(Self.consume) }),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = response["ok"] as? Bool else { return false }
        return ok
#else
        return false
#endif
    }

#if COLORFUL_CORE_ENABLED
    private static func consume(_ pointer: UnsafeMutablePointer<CChar>) -> Data? {
        defer { colorful_string_free(pointer) }
        return String(cString: pointer).data(using: .utf8)
    }

    private static func databaseURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Colorful", isDirectory: true)
            .appendingPathComponent("colorful.sqlite3", isDirectory: false)
    }
#endif
}
