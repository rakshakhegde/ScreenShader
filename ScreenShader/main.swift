import AppKit
import CoreGraphics
import Sparkle
import Carbon

class ScreenManager: NSObject {
  private var config: Config
  private var metrics: Metrics
  private var errorMessage: ErrorMessage
  
  private var overlayControllers: [CGDirectDisplayID: OverlayController] = [:]
  private var screenSignatures: [CGDirectDisplayID: String] = [:]
  
  private var pendingScreenChange: DispatchWorkItem?

  init(config: Config, metrics: Metrics, errorMessage: ErrorMessage) {
    self.config = config
    self.metrics = metrics
    self.errorMessage = errorMessage
    super.init()
    
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleScreenChange),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )

    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(handleWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )

    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(handleWake),
      name: NSWorkspace.screensDidWakeNotification,
      object: nil
    )
    
    self.evaluateScreens(forceRestart: false)
  }

  private func getScreenSignature(displayID: CGDirectDisplayID, screen: NSScreen) -> String {
    return "\(displayID)-\(screen.frame)-\(screen.backingScaleFactor)"
  }

  @objc private func handleScreenChange() {
    pendingScreenChange?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.evaluateScreens(forceRestart: false)
    }
    pendingScreenChange = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
  }
  
  @objc private func handleWake() {
    Logger.shared.log("ScreenManager: Wake detected. Debouncing and evaluating screens.")
    pendingScreenChange?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.evaluateScreens(forceRestart: true)
    }
    pendingScreenChange = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
  }

  private func evaluateScreens(forceRestart: Bool) {
    Logger.shared.log("ScreenManager: Evaluating screens. forceRestart=\(forceRestart)")
    
    var currentDisplayIDs = Set<CGDirectDisplayID>()
    
    for screen in NSScreen.screens {
      guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
        continue
      }
      
      currentDisplayIDs.insert(displayID)
      let newSignature = getScreenSignature(displayID: displayID, screen: screen)
      let oldSignature = screenSignatures[displayID]
      
      if newSignature != oldSignature {
        Logger.shared.log("ScreenManager: Screen \(displayID) signature changed or new. Rebuilding.")
        
        if let existingController = overlayControllers[displayID] {
            existingController.stopAndTearDown()
        }
        
        let newController = OverlayController(
            targetScreen: screen,
            targetDisplayID: displayID,
            config: self.config,
            metrics: self.metrics,
            errorMessage: self.errorMessage
        )
        
        overlayControllers[displayID] = newController
        screenSignatures[displayID] = newSignature
      } else if forceRestart {
        Logger.shared.log("ScreenManager: Screen \(displayID) unchanged, but forceRestart requested.")
        overlayControllers[displayID]?.restartCapture()
      }
    }
    
    // Clean up disconnected screens
    let disconnectedIDs = Set(overlayControllers.keys).subtracting(currentDisplayIDs)
    for id in disconnectedIDs {
      Logger.shared.log("ScreenManager: Screen \(id) disconnected. Tearing down.")
      overlayControllers[id]?.stopAndTearDown()
      overlayControllers.removeValue(forKey: id)
      screenSignatures.removeValue(forKey: id)
    }
    
    // Always refresh config after evaluating to ensure shaders are active and captures start
    self.refreshConfig()
  }

  func refreshConfig() {
    for (_, controller) in overlayControllers {
      controller.refreshConfig()
    }
  }
}

class AppDelegate: NSObject, NSApplicationDelegate {
  private var updaterController: SPUStandardUpdaterController!
  private var config: Config!
  private var configChanged: Bool = false
  private var metrics: Metrics = Metrics()
  private var errorMessage: ErrorMessage = ErrorMessage()
  private var screenManager: ScreenManager!
  private var statusItem: NSStatusItem!
  private var configWindowController: ConfigWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    self.updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    if CGRequestScreenCaptureAccess() {
      print("Screen capture access granted.")
    } else {
      print("Screen capture access denied.")
      NSApp.terminate(nil)
    }
    
    self.config = Config.load()
    let configTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
      if self.configChanged {
        self.config.save()
        self.configChanged = false
      }
    }
    RunLoop.current.add(configTimer, forMode: .common)

    let metricsTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
      self.metrics.updateStats()
      self.metrics.printStats()
    }
    RunLoop.current.add(metricsTimer, forMode: .common)

    setupMenuBar()
    createMenuBarIcon()

    self.screenManager = ScreenManager(config: self.config, metrics: self.metrics, errorMessage: self.errorMessage)

    HotKeyManager.shared.toggleAction = {
      NSApp.terminate(nil)
    }
    HotKeyManager.shared.register()

    self.refreshConfig()
    self.openConfigWindow()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    self.openConfigWindow()
    return true
  }

  private func refreshConfig() {
    self.statusItem.button?.image = self.getMenuBarIcon()

    self.screenManager.refreshConfig()
    self.configWindowController?.refreshActiveEffects()

    // Indicate that the config should be saved to disk.
    self.configChanged = true
  }

  private func setupMenuBar() {
    let mainMenu = NSMenu()

    let appMenu = NSMenuItem()
    mainMenu.addItem(appMenu)
    let appSubMenu = NSMenu()
    appMenu.submenu = appSubMenu

    let settingsItem = NSMenuItem(
      title: "Settings", action: #selector(self.openConfigWindow), keyEquivalent: ",")
    settingsItem.target = self
    appSubMenu.addItem(settingsItem)
    
    let updatesItem = NSMenuItem(
      title: "Check for updates",
      action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
      keyEquivalent: "")
    updatesItem.target = self.updaterController
    appSubMenu.addItem(updatesItem)

    appSubMenu.addItem(NSMenuItem.separator())
    appSubMenu.addItem(
      NSMenuItem(
        title: "Quit ScreenShader", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))

    let editMenu = NSMenuItem()
    mainMenu.addItem(editMenu)
    let editSubMenu = NSMenu(title: "Edit")
    editMenu.submenu = editSubMenu

    editSubMenu.addItem(
      NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
    editSubMenu.addItem(
      NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
    editSubMenu.addItem(NSMenuItem.separator())
    editSubMenu.addItem(
      NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editSubMenu.addItem(
      NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editSubMenu.addItem(
      NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editSubMenu.addItem(
      NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

    NSApp.mainMenu = mainMenu
  }

  private func createMenuBarIcon() {
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    if let button = self.statusItem.button {
      button.image = self.getMenuBarIcon()
      button.action = #selector(self.statusBarButtonClicked(sender:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.target = self
    }
  }

  @objc private func statusBarButtonClicked(sender: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else {
      self.toggleEffect()
      return
    }
    
    if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
      let menu = NSMenu()
      menu.addItem(NSMenuItem(title: "Show window", action: #selector(self.openConfigWindow), keyEquivalent: ""))
      menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
      
      self.statusItem.menu = menu
      self.statusItem.button?.performClick(nil)
      self.statusItem.menu = nil
    } else {
      self.toggleEffect()
    }
  }

  private func getMenuBarIcon() -> NSImage {
    let active = self.config.effects.anyEffectActive()
    let systemSymbolName = active ? "paintbrush.fill" : "paintbrush"
    return NSImage(
      systemSymbolName: systemSymbolName, accessibilityDescription: "ScreenShader")!
  }

  @objc private func toggleEffect() {
    if self.config.effects.anyEffectActive() {
      self.config.effects.deactivateAll()
    } else {
      self.config.effects.activateDefault()
    }
    self.refreshConfig()
  }

  @objc private func openConfigWindow() {
    if self.configWindowController != nil {
      self.configWindowController!.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.center()

    self.configWindowController = ConfigWindowController(window: window)
    self.configWindowController!.config = self.config
    self.configWindowController!.onConfigUpdate = { [weak self] in
      self?.refreshConfig()
    }
    self.configWindowController!.errorMessage = self.errorMessage
    self.configWindowController!.createUI()

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

class HotKeyManager {
  static let shared = HotKeyManager()
  var toggleAction: (() -> Void)?

  private var hotKeyRef: EventHotKeyRef?

  func register() {
    var hotKeyID = EventHotKeyID()
    hotKeyID.signature = OSType(fourCharCode: "SHAD")
    hotKeyID.id = 1
    
    // kVK_ANSI_S = 0x01
    let modifiers = UInt32(cmdKey | controlKey)
    let keyCode = UInt32(0x01)
    
    RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    
    var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    
    let handler: EventHandlerUPP = { (nextHandler, theEvent, userData) -> OSStatus in
      HotKeyManager.shared.toggleAction?()
      return noErr
    }
    
    InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventSpec, nil, nil)
  }
}

extension OSType {
  init(fourCharCode: String) {
    var result: UInt32 = 0
    for char in fourCharCode.utf8 {
      result = (result << 8) + UInt32(char)
    }
    self = result
  }
}

Logger.shared.log("App starting")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
Logger.shared.log("App delegate set, running app")
app.run()
