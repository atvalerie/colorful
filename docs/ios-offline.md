# iOS offline downloads

The iOS client downloads TIDAL HLS assets with `AVAssetDownloadURLSession`.
The session uses the stable identifier `sh.valerie.colorful.offline-audio`,
sets `sessionSendsLaunchEvents`, and runs as a non-discretionary session because
downloads are started by an explicit user action.

## Relaunch and termination

The app delegate creates the process-owned offline service during application
launch, before a SwiftUI root view is required. It receives
`application(_:handleEventsForBackgroundURLSession:completionHandler:)` and
attaches the completion handler to that same manager and session. Any manager
created by the view layer is a proxy to the process owner, so it cannot create a
second session with the same identifier.

The manager restores tasks with `getAllTasks`. Managed package locations arrive
through `willDownloadTo`; `didCompleteWithError` is the success or failure
boundary. Delegate events and durable-state writes each use a serial queue. The
UIKit completion handler is called only after `urlSessionDidFinishEvents`, all
earlier delegate work, package reconciliation, and the final persistence barrier
have completed. A two-sided handshake also covers the case where the session's
finish callback arrives before UIKit attaches its completion handler.

Download records remain in the Rust-backed state store. Task descriptions carry
the provider and provider ID, and an in-memory task-ID map covers callbacks
where the restored task description is not available to the delegate. Orphaned
tasks are canceled during restoration. Restoration does not delete completed
records: a queued package-location callback is applied first, and only the
post-drain reconciliation can remove a record whose package is unavailable.
Removing a download clears any queued package location and tombstones its task
ID for the lifetime of the session, preventing late callbacks from recreating
the record.

Force-quitting the app is not a supported way to keep a transfer running. iOS
cancels active background URL-session downloads after a force-quit. Let the
download finish or pause it from the app before leaving for a trip.

## Managed package paths

Apple owns the downloaded `.movpkg` package. The app stores a path relative to
the current application container and does not move, copy, enumerate, or rewrite
the package contents. Older absolute paths are rebased onto the current
`Library`, `Documents`, or `tmp` directory so an application-container UUID
change from reinstalling or sideloading does not orphan a valid package.

Offline availability is checked with `AVAssetCache.isPlayableOffline`. A package
that exists on disk but is not playable offline is removed from the durable
download list and can be downloaded again. This prevents the offline screen from
offering a package that will fail when the device has no network connection.

LiveContainer keeps the managed package in the location returned by
`willDownloadTo`. Exporting a standalone file is a separate operation;
copying the private package elsewhere is not used as an offline-playback path.

## Device validation checklist

The repository can run static checks on non-macOS hosts, but background asset
downloads require Xcode and an iOS device for meaningful validation:

1. Start a TIDAL download on a physical iPhone and confirm the state reaches
   `Offline`.
2. Lock the phone, background the app, and terminate it from Xcode while the
   transfer is active. Relaunch and confirm progress or completion is restored.
3. Let a transfer finish while the app is suspended. Confirm iOS relaunches the
   app, the offline record appears, and the retained background completion is
   delivered.
4. Disable networking after completion and play the track from the Offline tab.
5. Repeat after reinstalling or moving the sideloaded container. Confirm the
   record resolves to the current container and remains playable.
6. Repeat in LiveContainer and verify playback from the managed package before
   testing an export.

The current target is unsigned in CI. A locally signed device build or a
LiveContainer-compatible sideload is required for these tests.

References: [AVAssetDownloadURLSession](https://developer.apple.com/documentation/avfoundation/avassetdownloadurlsession),
[background URL-session events](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application%28_%3Ahandleeventsforbackgroundurlsession%3Acompletionhandler%3A%29),
[managed download locations](https://developer.apple.com/documentation/avfoundation/avassetdownloaddelegate/urlsession(_:assetdownloadtask:willdownloadto:)),
and [AVAssetCache](https://developer.apple.com/documentation/avfoundation/avassetcache).
