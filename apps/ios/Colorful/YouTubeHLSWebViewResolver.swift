import Foundation
import OSLog
import UIKit
import WebKit

private let colorfulYouTubeWebViewLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "sh.valerie.colorful",
    category: "YouTube"
)

private func colorfulYouTubeWebViewInfo(_ message: String) {
    colorfulYouTubeWebViewLogger.info("\(message, privacy: .public)")
    ColorfulDiagnostics.shared.append(category: "YouTube", message: message)
}

private func colorfulYouTubeWebViewError(_ message: String) {
    colorfulYouTubeWebViewLogger.error("\(message, privacy: .public)")
    ColorfulDiagnostics.shared.append(category: "YouTube", message: message)
}

struct YouTubeWebMediaResolution: @unchecked Sendable {
    let mediaURL: URL
    let userAgent: String
    let cookies: [HTTPCookie]
    let mimeType: String
}

@MainActor
final class YouTubeHLSWebViewResolver: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = YouTubeHLSWebViewResolver()

    private static let messageName = "colorfulHLS"
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<YouTubeWebMediaResolution, Error>?
    private var activeRequestID: UUID?
    private var timeoutTask: Task<Void, Never>?
    private var isFinishing = false

    func resolve(videoID: String) async throws -> YouTubeWebMediaResolution {
        try Task.checkCancellation()
        let requestID = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(videoID: videoID, requestID: requestID, continuation: continuation)
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.cancel(requestID: requestID)
            }
        }
    }

    private func start(
        videoID: String,
        requestID: UUID,
        continuation: CheckedContinuation<YouTubeWebMediaResolution, Error>
    ) {
        finishCurrent(with: .failure(CancellationError()))
        colorfulYouTubeWebViewInfo("webview media start video=\(videoID)")

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: Self.probeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.add(self, name: Self.messageName)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let userAgent = mobileSafariUserAgent
        webView.customUserAgent = userAgent
        webView.navigationDelegate = self

        self.webView = webView
        self.continuation = continuation
        activeRequestID = requestID
        isFinishing = false

        var components = URLComponents(string: "https://www.youtube.com/embed/\(videoID)")!
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "controls", value: "0"),
        ]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.timeoutInterval = 18
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        webView.load(request)

        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            guard !Task.isCancelled, self?.activeRequestID == requestID else { return }
            colorfulYouTubeWebViewError("webview media timeout video=\(videoID)")
            self?.finishCurrent(with: .failure(YouTubeMusicClientError.invalidResponse(
                "YouTube did not expose an iOS playable media stream for this track."
            )))
        }
    }

    private var mobileSafariUserAgent: String {
        let systemVersion = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        let majorVersion = UIDevice.current.systemVersion.split(separator: ".").first ?? "18"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(systemVersion) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(majorVersion).0 "
            + "Mobile/15E148 Safari/604.1"
    }

    private func cancel(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        finishCurrent(with: .failure(CancellationError()))
    }

    private func accept(candidate rawValue: String) {
        guard !isFinishing, let requestID = activeRequestID else { return }
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"\u0026"#, with: "&")
        value = value.replacingOccurrences(of: #"\u003d"#, with: "=")
        value = value.replacingOccurrences(of: #"\/"#, with: "/")
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              (host == "manifest.googlevideo.com" || host.hasSuffix(".googlevideo.com")),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return
        }

        let mimeType = components.queryItems?
            .first(where: { $0.name == "mime" })?.value?.lowercased() ?? ""
        let itag = Int(components.queryItems?.first(where: { $0.name == "itag" })?.value ?? "") ?? 0
        let isHLS = url.path.contains("/api/manifest/hls") || url.pathExtension.lowercased() == "m3u8"
        let isAudioMedia = url.path.contains("/videoplayback")
            && (mimeType.hasPrefix("audio/") || [139, 140, 141, 249, 250, 251, 599, 600].contains(itag))
        guard isHLS || isAudioMedia else { return }

        colorfulYouTubeWebViewInfo(
            "webview media candidate kind=\(isHLS ? "hls" : "audio") \(sourceDescriptor(url))"
        )
        isFinishing = true
        Task { @MainActor [weak self] in
            // Let WebKit start the media request first. This establishes the
            // googlevideo session that newer rqh=1 manifests can require.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, self.activeRequestID == requestID,
                  let webView = self.webView else { return }
            let cookies = await self.cookies(in: webView.configuration.websiteDataStore.httpCookieStore)
            self.finishCurrent(with: .success(YouTubeWebMediaResolution(
                mediaURL: url,
                userAgent: self.mobileSafariUserAgent,
                cookies: cookies,
                mimeType: isHLS ? "application/vnd.apple.mpegurl" : (mimeType.isEmpty ? "audio/mp4" : mimeType)
            )))
        }
    }

    private func cookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func finishCurrent(with result: Result<YouTubeWebMediaResolution, Error>) {
        guard let continuation else { return }
        switch result {
        case .success(let resolution):
            colorfulYouTubeWebViewInfo("webview media success mime=\(resolution.mimeType) \(sourceDescriptor(resolution.mediaURL)) cookies=\(resolution.cookies.count)")
        case .failure(let error):
            if !(error is CancellationError) {
                colorfulYouTubeWebViewError("webview HLS failed error=\(error.localizedDescription)")
            }
        }
        timeoutTask?.cancel()
        timeoutTask = nil

        webView?.evaluateJavaScript(
            "document.querySelectorAll('video').forEach(function(video) { video.pause(); });"
        )
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
        webView = nil

        self.continuation = nil
        activeRequestID = nil
        isFinishing = false
        continuation.resume(with: result)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let candidate = message.body as? String else { return }
        accept(candidate: candidate)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        colorfulYouTubeWebViewInfo("webview media navigation finished")
        webView.evaluateJavaScript("window.__colorfulProbeHLS && window.__colorfulProbeHLS();")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isFinishing else { return }
        colorfulYouTubeWebViewError("webview media provisional navigation failed error=\(error.localizedDescription)")
        finishCurrent(with: .failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isFinishing else { return }
        colorfulYouTubeWebViewError("webview media content process terminated")
        finishCurrent(with: .failure(YouTubeMusicClientError.invalidResponse(
            "The iOS YouTube playback session stopped before media was ready."
        )))
    }

    private func sourceDescriptor(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let keys = Array(Set(items.map(\.name))).sorted().joined(separator: ",")
        let hasPOT = items.contains { $0.name == "pot" && !($0.value ?? "").isEmpty }
        let host = url.host ?? ""
        return "host=\(host) queryKeys=[\(keys)] pot=\(hasPOT)"
    }

    private static let probeScript = #"""
    (() => {
      if (window.__colorfulHLSInstalled) return;
      window.__colorfulHLSInstalled = true;

      const post = (candidate) => {
        if (typeof candidate !== "string") return;
        const normalized = candidate
          .replace(/\\u0026/g, "&")
          .replace(/\\u003d/g, "=")
          .replace(/\\\//g, "/")
          .replace(/&amp;/g, "&");
        if (normalized.includes("/api/manifest/hls")
            || normalized.includes(".m3u8")
            || normalized.includes("/videoplayback")) {
          try { window.webkit.messageHandlers.colorfulHLS.postMessage(normalized); } catch (_) {}
        }
      };

      const inspectText = (text) => {
        if (typeof text !== "string" || text.length === 0 || text.length > 8_000_000) return;
        post(text);
        const manifestPattern = /["']hlsManifestUrl["']\s*:\s*["']([^"']+)["']/g;
        let match;
        while ((match = manifestPattern.exec(text)) !== null) post(match[1]);
        const urlPattern = /https?(?:\\u003a|:)(?:\\\/|\/){2}[^"'\s<>]+(?:\/api\/manifest\/hls[^"'\s<>]*|\.m3u8[^"'\s<>]*|\/videoplayback[^"'\s<>]*)/g;
        while ((match = urlPattern.exec(text)) !== null) post(match[0]);
      };

      const inspectValue = (value) => {
        try {
          if (!value) return;
          if (typeof value === "string") {
            inspectText(value);
            if (value[0] === "{" && value.length < 8_000_000) {
              try { inspectValue(JSON.parse(value)); } catch (_) {}
            }
            return;
          }
          if (typeof value !== "object") return;
          post(value.url);
          post(value.hlsManifestUrl);
          if (value.streamingData) inspectValue(value.streamingData);
          if (value.adaptiveFormats) inspectValue(value.adaptiveFormats);
          if (value.formats) inspectValue(value.formats);
          if (value.playerResponse) inspectValue(value.playerResponse);
          if (value.raw_player_response) inspectValue(value.raw_player_response);
          if (value.args) inspectValue(value.args);
        } catch (_) {}
      };

      const nativeFetch = window.fetch;
      if (nativeFetch) {
        window.fetch = function(...argumentsList) {
          const responsePromise = nativeFetch.apply(this, argumentsList);
          responsePromise.then((response) => {
            try { response.clone().text().then(inspectText).catch(() => {}); } catch (_) {}
          }).catch(() => {});
          return responsePromise;
        };
      }

      const nativeOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(...argumentsList) {
        this.addEventListener("load", function() {
          try { inspectValue(this.response); } catch (_) {}
          try { inspectText(this.responseText); } catch (_) {}
        });
        return nativeOpen.apply(this, argumentsList);
      };

      try {
        const descriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "src");
        if (descriptor && descriptor.get && descriptor.set) {
          Object.defineProperty(HTMLMediaElement.prototype, "src", {
            configurable: descriptor.configurable,
            enumerable: descriptor.enumerable,
            get: descriptor.get,
            set: function(value) {
              post(value);
              return descriptor.set.call(this, value);
            }
          });
        }
      } catch (_) {}

      try {
        const observer = new PerformanceObserver((list) => {
          list.getEntries().forEach((entry) => post(entry.name));
        });
        observer.observe({ type: "resource", buffered: true });
      } catch (_) {}

      window.__colorfulProbeHLS = () => {
        try { inspectValue(window.ytInitialPlayerResponse); } catch (_) {}
        try { inspectValue(window.ytplayer && window.ytplayer.config); } catch (_) {}
        try { inspectValue(window.ytcfg && window.ytcfg.get && window.ytcfg.get("PLAYER_CONFIG")); } catch (_) {}
        try {
          performance.getEntriesByType("resource").forEach((entry) => post(entry.name));
        } catch (_) {}
        document.querySelectorAll("video").forEach((video) => {
          post(video.currentSrc);
          post(video.src);
          video.muted = true;
          video.playsInline = true;
          if (video.paused) video.play().catch(() => {});
        });
      };

      window.setInterval(window.__colorfulProbeHLS, 250);
      window.__colorfulProbeHLS();
    })();
    """#
}
