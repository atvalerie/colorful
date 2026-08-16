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
                withIntermediateDirectories: true,
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

    @discardableResult
    func dispatch(commandJSON: String) -> Data? {
#if COLORFUL_CORE_ENABLED
        guard handle != 0 else { return nil }
        return commandJSON.withCString { colorful_engine_dispatch(handle, $0).flatMap(Self.consume) }
#else
        return nil
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
