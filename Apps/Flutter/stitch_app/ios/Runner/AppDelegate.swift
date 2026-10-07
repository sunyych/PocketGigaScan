import Flutter
import UIKit
import UniformTypeIdentifiers
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate,
  UIDocumentPickerDelegate {
  private var pendingPickerResult: FlutterResult?
  private var pendingPickerKind: PickerKind?
  private var runtimeChannel: FlutterMethodChannel?
  private var backgroundObserver: NSObjectProtocol?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.engine.binaryMessenger

    let power = FlutterMethodChannel(name: "com.lumiaiq.pocketgigascan/power", binaryMessenger: messenger)
    power.setMethodCallHandler { call, result in
      guard call.method == "readPowerState" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let device = UIDevice.current
      device.isBatteryMonitoringEnabled = true
      let state: String
      switch device.batteryState {
      case .charging, .full: state = "external"
      case .unplugged: state = "battery"
      case .unknown: state = "unknown"
      @unknown default: state = "unknown"
      }
      result(["state": state])
    }

    let network = FlutterMethodChannel(name: "com.lumiaiq.pocketgigascan/deviceNetwork", binaryMessenger: messenger)
    network.setMethodCallHandler { call, result in
      guard call.method == "openWifiSettings" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // Public iOS APIs cannot navigate to Settings > Wi-Fi. Do not use the
      // private App-Prefs URL scheme; return explicit manual steps to the UI.
      result([
        "opened": false,
        "guidance": "Open Settings > Wi-Fi, join the DWARF3 network, then return to PocketGigaScan. iOS requires you to choose the network manually.",
      ])
    }

    let runtime = FlutterMethodChannel(name: "com.lumiaiq.pocketgigascan/runtime", binaryMessenger: messenger)
    runtimeChannel = runtime
    registerBackgroundPauseNotification()
    runtime.setMethodCallHandler { call, result in
      switch call.method {
      case "readResourceBudget":
        result(Self.readResourceBudget())
      case "readPendingTimeoutJobs":
        result(UserDefaults.standard.stringArray(forKey: Self.pendingPauseJobsKey) ?? [])
      case "acknowledgeTimeoutJobs":
        let acknowledged = Set((call.arguments as? [String: Any])?["jobIds"] as? [String] ?? [])
        let pending = UserDefaults.standard.stringArray(forKey: Self.pendingPauseJobsKey) ?? []
        UserDefaults.standard.set(pending.filter { !acknowledged.contains($0) }, forKey: Self.pendingPauseJobsKey)
        result(true)
      case "setProcessingActive":
        let active = (call.arguments as? [String: Any])?["active"] as? Bool ?? false
        let jobID = (call.arguments as? [String: Any])?["jobId"] as? String
        guard let jobID, !jobID.isEmpty else { result(false); return }
        var jobs = Set(UserDefaults.standard.stringArray(forKey: Self.activeJobsKey) ?? [])
        if active { jobs.insert(jobID) } else { jobs.remove(jobID) }
        UserDefaults.standard.set(jobs.sorted(), forKey: Self.activeJobsKey)
        // This is only an in-process foreground registration. iOS can suspend
        // the app at any time after it enters the background.
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let storage = FlutterMethodChannel(name: "com.lumiaiq.pocketgigascan/storage", binaryMessenger: messenger)
    storage.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "APP_UNAVAILABLE", message: "Application is unavailable", details: nil)); return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "pickBatchParent": self.presentFolderPicker(kind: .batch, result: result)
      case "pickOutputFolder": self.presentFolderPicker(kind: .output, result: result)
      case "releaseBatchParent": result(self.releaseBatchParent(args["path"] as? String))
      case "publishExport": self.publishExport(args, result: result)
      case "saveExport": self.saveExport(args, result: result)
      case "shareExport": self.shareExport(args, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }

    let files = FlutterMethodChannel(name: "com.lumiaiq.pocketgigascan/files", binaryMessenger: messenger)
    files.setMethodCallHandler { [weak self] call, result in
      guard call.method == "shareExport", let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.shareExport(call.arguments as? [String: Any] ?? [:], result: result)
    }
  }

  private enum PickerKind { case batch, output, save }

  private func presentFolderPicker(kind: PickerKind, result: @escaping FlutterResult) {
    guard pendingPickerResult == nil, let presenter = topViewController() else {
      result(FlutterError(code: "PICKER_BUSY", message: "Another document picker is active", details: nil))
      return
    }
    pendingPickerKind = kind
    pendingPickerResult = result
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    } else {
      picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
    }
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  private func presentSavePicker(source: URL, result: @escaping FlutterResult) {
    guard pendingPickerResult == nil, let presenter = topViewController() else {
      result(FlutterError(code: "PICKER_BUSY", message: "Another document picker is active", details: nil))
      return
    }
    pendingPickerKind = .save
    pendingPickerResult = result
    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
    } else {
      picker = UIDocumentPickerViewController(url: source, in: .exportToService)
    }
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingPickerResult, let kind = pendingPickerKind else { return }
    pendingPickerResult = nil
    pendingPickerKind = nil
    guard let url = urls.first else { result(nil); return }
    do {
      switch kind {
      case .batch:
        result(try stageBatchParent(url).path)
      case .output:
        result(try saveOutputFolder(url))
      case .save:
        result(true)
      }
    } catch {
      result(FlutterError(code: "DOCUMENT_OPERATION_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pendingPickerResult
    pendingPickerResult = nil
    pendingPickerKind = nil
    result?(nil)
  }

  private func stageBatchParent(_ source: URL) throws -> URL {
    let access = source.startAccessingSecurityScopedResource()
    defer { if access { source.stopAccessingSecurityScopedResource() } }
    guard access else {
      throw NSError(domain: "PocketGigaScan", code: 2, userInfo: [NSLocalizedDescriptionKey: "The selected folder did not grant access"])
    }
    let fm = FileManager.default
    let stageRoot = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("staged-batches", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: stageRoot, withIntermediateDirectories: true)
    do {
      let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        .filter {
          let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
      var folderNames = Set<String>()
      for child in children {
        let folderName = Self.safeName(child.lastPathComponent)
        guard !folderName.isEmpty else { continue }
        let uniqueFolder = Self.uniqueName(folderName, used: &folderNames)
        let targetFolder = stageRoot.appendingPathComponent(uniqueFolder, isDirectory: true)
        try fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        let photos = try fm.contentsOfDirectory(at: child, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
          .filter {
            let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
              && ["jpg", "jpeg"].contains($0.pathExtension.lowercased())
          }
          .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        var fileNames = Set<String>()
        for photo in photos {
          let safe = Self.safeName(photo.lastPathComponent)
          guard !safe.isEmpty else { continue }
          let unique = Self.uniqueName(safe, used: &fileNames)
          try fm.copyItem(at: photo, to: targetFolder.appendingPathComponent(unique))
        }
      }
      return stageRoot
    } catch {
      try? fm.removeItem(at: stageRoot)
      throw error
    }
  }

  private func saveOutputFolder(_ folder: URL) throws -> [String: String] {
    let access = folder.startAccessingSecurityScopedResource()
    defer { if access { folder.stopAccessingSecurityScopedResource() } }
    guard access else {
      throw NSError(domain: "PocketGigaScan", code: 4, userInfo: [NSLocalizedDescriptionKey: "The selected output folder did not grant access"])
    }
    // Document-picker URLs are already security-scoped on iOS. The explicit
    // withSecurityScope option is macOS-only in some SDK overlays.
    let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    let id = UUID().uuidString
    UserDefaults.standard.set(bookmark, forKey: "output-folder-" + id)
    return ["uri": "pocketgigascan-output://" + id, "displayName": folder.lastPathComponent]
  }

  private func releaseBatchParent(_ rawPath: String?) -> Bool {
    guard let rawPath,
      let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent("staged-batches", isDirectory: true).standardizedFileURL else { return false }
    let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
    guard candidate.deletingLastPathComponent() == root else { return false }
    do { try FileManager.default.removeItem(at: candidate); return true } catch { return false }
  }

  private func publishExport(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String, let uri = args["treeUri"] as? String,
      let suggestedName = args["suggestedName"] as? String, isAppOwned(path: path),
      let id = URL(string: uri)?.host, let bookmark = UserDefaults.standard.data(forKey: "output-folder-" + id) else {
      result(FlutterError(code: "INVALID_EXPORT", message: "Export path or destination is invalid", details: nil)); return
    }
    do {
      var stale = false
      let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
      guard !stale else { throw NSError(domain: "PocketGigaScan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose the output folder again to refresh access"]) }
      let access = folder.startAccessingSecurityScopedResource()
      defer { if access { folder.stopAccessingSecurityScopedResource() } }
      guard access else { throw NSError(domain: "PocketGigaScan", code: 3, userInfo: [NSLocalizedDescriptionKey: "The selected output folder is no longer accessible"]) }
      let safeName = Self.safeName(URL(fileURLWithPath: suggestedName).lastPathComponent)
      let existing = try FileManager.default.contentsOfDirectory(atPath: folder.path)
      var usedNames = Set(existing.map { $0.lowercased() })
      let destinationName = Self.uniqueName(safeName, used: &usedNames)
      let destination = folder.appendingPathComponent(destinationName)
      try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
      result(["uri": destination.absoluteString, "displayName": destination.lastPathComponent])
    } catch {
      result(FlutterError(code: "PUBLISH_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  private func saveExport(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String, isAppOwned(path: path), FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "INVALID_EXPORT", message: "Export file is unavailable", details: nil)); return
    }
    presentSavePicker(source: URL(fileURLWithPath: path), result: result)
  }

  private func shareExport(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let path = args["path"] as? String, isAppOwned(path: path), FileManager.default.fileExists(atPath: path),
      let presenter = topViewController() else {
      result(FlutterError(code: "MISSING_FILE", message: "Exported image is unavailable", details: nil)); return
    }
    let share = UIActivityViewController(activityItems: [URL(fileURLWithPath: path)], applicationActivities: nil)
    if let popover = share.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
      popover.permittedArrowDirections = []
    }
    share.completionWithItemsHandler = { _, _, _, _ in result(true) }
    presenter.present(share, animated: true)
  }

  private func isAppOwned(path: String) -> Bool {
    let root = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path + "/"
    let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    return candidate.hasPrefix(root) && FileManager.default.fileExists(atPath: candidate)
  }

  private func registerBackgroundPauseNotification() {
    guard backgroundObserver == nil else { return }
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      let jobs = UserDefaults.standard.stringArray(forKey: Self.activeJobsKey) ?? []
      guard !jobs.isEmpty else { return }
      var pending = Set(UserDefaults.standard.stringArray(forKey: Self.pendingPauseJobsKey) ?? [])
      pending.formUnion(jobs)
      let requested = pending.sorted()
      UserDefaults.standard.set(requested, forKey: Self.pendingPauseJobsKey)
      self.runtimeChannel?.invokeMethod("processingTimeout", arguments: requested)
    }
  }

  private func topViewController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
      let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
    var current = root
    while let presented = current.presentedViewController { current = presented }
    return current
  }

  private static func safeName(_ name: String) -> String {
    let base = URL(fileURLWithPath: name).lastPathComponent
    return base.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
    guard !used.insert(name.lowercased()).inserted else { return name }
    let url = URL(fileURLWithPath: name)
    let stem = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    var n = 2
    while true {
      let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
      if used.insert(candidate.lowercased()).inserted { return candidate }
      n += 1
    }
  }

  private static func readResourceBudget() -> [String: Any] {
    let physical = max(1, Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)))
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    let available: Int
    if status == KERN_SUCCESS {
      let pageCount = UInt64(stats.free_count) + UInt64(stats.inactive_count)
      let freeBytes = pageCount * UInt64(vm_page_size)
      available = max(1, min(physical, Int(freeBytes / (1024 * 1024))))
    } else {
      available = max(1, physical / 3)
    }
    let fileSystem = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
    let freeBytes = (fileSystem?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    let thermal: String
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermal = "none"
    case .fair: thermal = "light"
    case .serious: thermal = "moderate"
    case .critical: thermal = "critical"
    @unknown default: thermal = "unknown"
    }
    return [
      "totalMemoryMiB": physical,
      "availableMemoryMiB": available,
      "cpuCount": max(1, ProcessInfo.processInfo.activeProcessorCount),
      "availableStorageMiB": max(0, Int(freeBytes / (1024 * 1024))),
      "thermalStatus": thermal,
    ]
  }

  private static let activeJobsKey = "mobile-active-jobs"
  private static let pendingPauseJobsKey = "mobile-pending-pause-jobs"
}
