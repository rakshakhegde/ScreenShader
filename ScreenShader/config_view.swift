import AppKit

class ConfigViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
  var config: Config! = nil
  var effects: Effects {
    return self.config.effects
  }
  var onConfigUpdate: () -> Void = {}
  var errorMessage: ErrorMessage! = nil

  private var tableView: NSTableView! = nil
  private var errorMessageField: NSTextField! = nil
  private var newEffectButton: NSButton! = nil
  private var useCustomCursorCheckbox: NSButton! = nil
  private var customCursorSlider: NSSlider! = nil
  private var customCursorSliderLabel: NSTextField! = nil
  private var customCursorSliderStack: NSStackView! = nil
  private var contentPane: NSView! = nil
  private var effectToController: [UUID: EffectViewController] = [:]

  @objc private func onSliderChange() {
    self.config.customCursorScale = Float(self.customCursorSlider.doubleValue)
    self.onConfigUpdate()
  }

  @objc private func toggleUseCustomCursor() {
    self.config.useCustomCursor = (self.useCustomCursorCheckbox.state == .on)
    self.customCursorSliderStack.isHidden = !self.config.useCustomCursor
    self.onConfigUpdate()
  }

  override func loadView() {
    let splitView = NSSplitView()
    splitView.dividerStyle = .thin
    splitView.isVertical = true
    splitView.translatesAutoresizingMaskIntoConstraints = false

    let tabsPane = NSStackView()
    tabsPane.orientation = .vertical
    tabsPane.spacing = 16
    tabsPane.translatesAutoresizingMaskIntoConstraints = false

    self.tableView = NSTableView()
    self.tableView.delegate = self
    self.tableView.dataSource = self
    self.tableView.headerView = nil
    self.tableView.focusRingType = .none
    if #available(macOS 11.0, *) {
        self.tableView.style = .sourceList
    }
    self.tableView.rowHeight = 32
    self.tableView.intercellSpacing = NSSize(width: 0, height: 8)

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Tabs"))
    column.title = "Tabs"
    self.tableView.addTableColumn(column)

    let scrollView = NSScrollView()
    scrollView.documentView = self.tableView
    scrollView.hasVerticalScroller = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    self.errorMessageField = NSTextField()
    self.errorMessageField.isEditable = false
    self.errorMessageField.drawsBackground = false
    self.errorMessageField.font = NSFont.monospacedSystemFont(
      ofSize: NSFont.systemFontSize, weight: .regular)
    self.errorMessageField.textColor = .red
    self.errorMessageField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    self.errorMessageField.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    self.errorMessageField.translatesAutoresizingMaskIntoConstraints = false

    self.errorMessage.onMessageChanged = {
      self.errorMessageField.stringValue = self.errorMessage.get() ?? ""
      self.errorMessageField.isHidden = self.errorMessage.get() == nil
    }
    self.errorMessage.onMessageChanged?()

    self.newEffectButton = NSButton(
      title: "New Effect", target: self, action: #selector(self.newEffect))
    self.newEffectButton.translatesAutoresizingMaskIntoConstraints = false

    self.useCustomCursorCheckbox = NSButton(
      checkboxWithTitle: "  Use custom cursor", target: self, action: #selector(self.toggleUseCustomCursor))
    self.useCustomCursorCheckbox.state = self.config.useCustomCursor ? .on : .off
    self.useCustomCursorCheckbox.translatesAutoresizingMaskIntoConstraints = false
    self.useCustomCursorCheckbox.font = NSFont.systemFont(ofSize: 13) // Slightly larger text to balance

    self.customCursorSlider = NSSlider(value: Double(self.config.customCursorScale), minValue: 1.0, maxValue: 4.0, target: self, action: #selector(self.onSliderChange))
    self.customCursorSlider.isContinuous = true
    self.customCursorSlider.translatesAutoresizingMaskIntoConstraints = false

    self.customCursorSliderLabel = NSTextField(labelWithString: "Size:")
    self.customCursorSliderLabel.font = NSFont.systemFont(ofSize: 13)
    self.customCursorSliderLabel.translatesAutoresizingMaskIntoConstraints = false

    self.customCursorSliderStack = NSStackView()
    self.customCursorSliderStack.orientation = .horizontal
    self.customCursorSliderStack.spacing = 8
    self.customCursorSliderStack.translatesAutoresizingMaskIntoConstraints = false
    self.customCursorSliderStack.addArrangedSubview(self.customCursorSliderLabel)
    self.customCursorSliderStack.addArrangedSubview(self.customCursorSlider)
    self.customCursorSliderStack.isHidden = !self.config.useCustomCursor

    tabsPane.addArrangedSubview(scrollView)
    tabsPane.addArrangedSubview(self.errorMessageField)
    tabsPane.addArrangedSubview(self.newEffectButton)
    tabsPane.setCustomSpacing(12, after: self.newEffectButton)
    tabsPane.addArrangedSubview(self.useCustomCursorCheckbox)
    tabsPane.setCustomSpacing(4, after: self.useCustomCursorCheckbox)
    tabsPane.addArrangedSubview(self.customCursorSliderStack)
    tabsPane.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)

    self.contentPane = NSView()

    splitView.addArrangedSubview(tabsPane)
    splitView.addArrangedSubview(self.contentPane)

    NSLayoutConstraint.activate([
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

      self.errorMessageField.leftAnchor.constraint(equalTo: tabsPane.leftAnchor, constant: 16),
      self.errorMessageField.rightAnchor.constraint(equalTo: tabsPane.rightAnchor, constant: -16),

      self.newEffectButton.heightAnchor.constraint(equalToConstant: 30),
      self.useCustomCursorCheckbox.heightAnchor.constraint(equalToConstant: 24),
      self.useCustomCursorCheckbox.leadingAnchor.constraint(equalTo: tabsPane.leadingAnchor, constant: 18),
      
      self.customCursorSliderStack.heightAnchor.constraint(equalToConstant: 24),
      self.customCursorSliderStack.leadingAnchor.constraint(equalTo: tabsPane.leadingAnchor, constant: 36),
      self.customCursorSliderStack.trailingAnchor.constraint(equalTo: tabsPane.trailingAnchor, constant: -18),

      self.contentPane.topAnchor.constraint(equalTo: splitView.topAnchor),
      self.contentPane.bottomAnchor.constraint(equalTo: splitView.bottomAnchor),

      tabsPane.widthAnchor.constraint(equalTo: splitView.widthAnchor, multiplier: 0.3),
    ])

    self.view = splitView
    if self.effects.effectList().count > 0 {
      if let activeIndex = self.effects.effectList().firstIndex(where: { self.effects.isActive(effect: $0) }) {
        self.selectTab(index: activeIndex)
      } else {
        self.selectTab(index: 0)
      }
    }
  }

  private func selectTab(index: Int) {
    self.tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    self.tableView.scrollRowToVisible(index)
  }

  @objc private func newEffect() {
    let _ = self.effects.new()
    self.tableView.reloadData()
    self.selectTab(index: self.effects.effectList().count - 1)
    self.onConfigUpdate()
  }

  private func onUpdateEffect(effect: UUID) {
    self.tableView.reloadData()
    self.onConfigUpdate()
  }

  private func onDeleteEffect(effect: UUID) {
    self.tableView.reloadData()
    self.tableView.deselectAll(nil)
    self.effectToController.removeValue(forKey: effect)
    self.onConfigUpdate()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    return self.effects.effectList().count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let effect = self.effects.effectList()[row]
    let name = self.effects.getName(effect: effect)
    let isActive = self.effects.isActive(effect: effect)

    let identifier = NSUserInterfaceItemIdentifier("EffectCell")
    var cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView

    if cellView == nil {
      cellView = NSTableCellView()
      cellView?.identifier = identifier
      
      let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleActiveFromList(_:)))
      checkbox.translatesAutoresizingMaskIntoConstraints = false
      checkbox.identifier = NSUserInterfaceItemIdentifier("ActiveCheckbox")
      
      let textField = NSTextField(labelWithString: "")
      textField.translatesAutoresizingMaskIntoConstraints = false
      textField.font = NSFont.systemFont(ofSize: 14)
      textField.identifier = NSUserInterfaceItemIdentifier("NameField")
      
      cellView?.addSubview(checkbox)
      cellView?.addSubview(textField)
      cellView?.textField = textField
      
      NSLayoutConstraint.activate([
        textField.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 8),
        textField.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor),
        
        checkbox.leadingAnchor.constraint(greaterThanOrEqualTo: textField.trailingAnchor, constant: 8),
        checkbox.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -8),
        checkbox.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor)
      ])
    }
    
    if let checkbox = cellView?.subviews.first(where: { $0.identifier?.rawValue == "ActiveCheckbox" }) as? NSButton {
      checkbox.state = isActive ? .on : .off
      checkbox.tag = row
    }
    cellView?.textField?.stringValue = name
    
    return cellView
  }

  @objc private func toggleActiveFromList(_ sender: NSButton) {
    let row = sender.tag
    guard row >= 0 && row < self.effects.effectList().count else { return }
    let effect = self.effects.effectList()[row]
    self.effects.toggleActive(effect: effect)
    self.selectTab(index: row)
    self.refreshActiveEffects()
    self.onConfigUpdate()
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    let selectedRow = self.tableView.selectedRow
    if selectedRow >= 0 && selectedRow < self.effects.effectList().count {
      let selectedEffect = self.effects.effectList()[selectedRow]

      if !self.effectToController.keys.contains(selectedEffect) {
        let controller = EffectViewController()
        controller.effects = self.effects
        controller.effect = selectedEffect
        controller.onUpdate = { self.onUpdateEffect(effect: selectedEffect) }
        controller.onDelete = { self.onDeleteEffect(effect: selectedEffect) }
        self.effectToController[selectedEffect] = controller
      }

      let controller = self.effectToController[selectedEffect]!
      self.contentPane.subviews = [controller.view]

      NSLayoutConstraint.activate([
        controller.view.leadingAnchor.constraint(equalTo: self.contentPane.leadingAnchor),
        controller.view.trailingAnchor.constraint(equalTo: self.contentPane.trailingAnchor),
        controller.view.topAnchor.constraint(equalTo: self.contentPane.topAnchor),
        controller.view.bottomAnchor.constraint(equalTo: self.contentPane.bottomAnchor),
      ])
    } else {
      self.contentPane.subviews = []
    }
  }

  func refreshActiveEffects() {
    for row in 0..<self.tableView.numberOfRows {
      if let cellView = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView {
        if let checkbox = cellView.subviews.first(where: { $0.identifier?.rawValue == "ActiveCheckbox" }) as? NSButton {
           let effect = self.effects.effectList()[row]
           checkbox.state = self.effects.isActive(effect: effect) ? .on : .off
        }
      }
    }
    for controller in self.effectToController.values {
      controller.refreshActiveCheckbox()
    }
  }
}

class ConfigWindowController: NSWindowController {
  var config: Config! = nil
  var errorMessage: ErrorMessage! = nil
  var onConfigUpdate: () -> Void = {}

  private var configViewController: ConfigViewController! = ConfigViewController()

  func createUI() {
    guard let window = self.window else { return }

    window.title = "ScreenShader"
    window.setFrameAutosaveName("ScreenShaderMainWindow")

    self.configViewController.config = self.config
    self.configViewController.onConfigUpdate = self.onConfigUpdate
    self.configViewController.errorMessage = self.errorMessage
    window.contentView?.addSubview(self.configViewController.view)

    NSLayoutConstraint.activate([
      self.configViewController.view.leadingAnchor.constraint(
        equalTo: window.contentView!.leadingAnchor),
      self.configViewController.view.trailingAnchor.constraint(
        equalTo: window.contentView!.trailingAnchor),
      self.configViewController.view.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
      self.configViewController.view.bottomAnchor.constraint(
        equalTo: window.contentView!.bottomAnchor),
    ])
  }

  func refreshActiveEffects() {
    self.configViewController.refreshActiveEffects()
  }
}
