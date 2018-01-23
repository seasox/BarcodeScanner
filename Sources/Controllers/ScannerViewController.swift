import UIKit
import AVFoundation

// MARK: - Delegates

/// Delegate to handle the captured code.
public protocol ScannerCodeDelegate: class {
  func scanner(_ controller: ScannerController, didCaptureCode code: String, type: String)
}

/// Delegate to report errors.
public protocol ScannerErrorDelegate: class {
  func scanner(_ controller: ScannerController, didReceiveError error: Error)
}

/// Delegate to dismiss barcode scanner when the close button has been pressed.
public protocol ScannerDismissalDelegate: class {
  func scannerDidDismiss(_ controller: ScannerController)
}

// MARK: - Controller

/**
 Barcode scanner controller with 4 sates:
 - Scanning mode
 - Processing animation
 - Unauthorized mode
 - Not found error message
 */
open class ScannerController: UIViewController {
  /// Video capture device. This may be nil when running in Simulator.
  private lazy var captureDevice: AVCaptureDevice! = AVCaptureDevice.default(for: AVMediaType.video)

  /// Capture session.
  private lazy var captureSession: AVCaptureSession = AVCaptureSession()

  /// Information view with description label.
  private lazy var messageViewController: MessageViewController = .init()

  private var infoView: UIView {
    return messageViewController.view
  }

  /// Button to change torch mode.
  public lazy var flashButton: UIButton = { [unowned self] in
    let button = UIButton(type: .custom)
    button.addTarget(self, action: #selector(flashButtonDidPress), for: .touchUpInside)
    return button
    }()

  /// Animated focus view.
  private lazy var focusView: UIView = {
    let view = UIView()
    view.layer.borderColor = UIColor.white.cgColor
    view.layer.borderWidth = 2
    view.layer.cornerRadius = 5
    view.layer.shadowColor = UIColor.white.cgColor
    view.layer.shadowRadius = 10.0
    view.layer.shadowOpacity = 0.9
    view.layer.shadowOffset = CGSize.zero
    view.layer.masksToBounds = false

    return view
  }()

  /// Button that opens settings to allow camera usage.
  private lazy var settingsButton: UIButton = { [unowned self] in
    let button = UIButton(type: .system)
    let title = NSAttributedString(string: SettingsButton.text,
                                   attributes: [
                                    NSAttributedStringKey.font : SettingsButton.font,
                                    NSAttributedStringKey.foregroundColor : SettingsButton.color,
                                    ])

    button.setAttributedTitle(title, for: UIControlState())
    button.sizeToFit()
    button.addTarget(self, action: #selector(settingsButtonDidPress), for: .touchUpInside)

    return button
    }()

  /// Video preview layer.
  private var videoPreviewLayer: AVCaptureVideoPreviewLayer?

  /// The current controller's status mode.
  private var status: Status = Status(state: .scanning) {
    didSet {
      let duration = status.animated &&
        (status.state == .processing
          || oldValue.state == .processing
          || oldValue.state == .notFound
        ) ? 0.5 : 0.0

      guard status.state != .notFound else {
        messageViewController.state = status.state

        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 2.0) {
          self.status = Status(state: .scanning)
        }

        return
      }

      let delayReset = oldValue.state == .processing || oldValue.state == .notFound

      if !delayReset {
        resetState()
      }

      self.messageViewController.state = self.status.state
      UIView.animate(withDuration: duration,
                     animations: {
                      self.infoView.layoutIfNeeded()
                      self.infoView.frame = self.infoFrame
      },
                     completion: { [weak self] _ in
                      if delayReset {
                        self?.resetState()
                      }

                      self?.infoView.layer.removeAllAnimations()
                      if self?.status.state == .processing {
                        self?.messageViewController.animateLoading()
                      }
      })
    }
  }

  public var barCodeFocusViewType: FocusViewType = .animated

  /// The current torch mode on the capture device.
  private var torchMode: TorchMode = .off {
    didSet {
      guard let captureDevice = captureDevice, captureDevice.hasFlash else { return }

      do {
        try captureDevice.lockForConfiguration()
        captureDevice.torchMode = torchMode.captureTorchMode
        captureDevice.unlockForConfiguration()
      } catch {}

      flashButton.setImage(torchMode.image, for: UIControlState())
    }
  }

  /// Calculated frame for the info view.
  private var infoFrame: CGRect {
    let height = status.state != .processing ? 75 : view.bounds.height
    return CGRect(x: 0, y: view.bounds.height - height,
                  width: view.bounds.width, height: height)
  }

  /// When the flag is set to `true` controller returns a captured code
  /// and waits for the next reset action.
  public var isOneTimeSearch = true

  /// Delegate to handle the captured code.
  public weak var codeDelegate: ScannerCodeDelegate?

  /// Delegate to report errors.
  public weak var errorDelegate: ScannerErrorDelegate?

  /// Delegate to dismiss barcode scanner when the close button has been pressed.
  public weak var dismissalDelegate: ScannerDismissalDelegate?

  /// Flag to lock session from capturing.
  private var locked = false

  // MARK: - Initialization

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - View lifecycle

  open override func viewDidLoad() {
    super.viewDidLoad()

    videoPreviewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
    videoPreviewLayer?.videoGravity = AVLayerVideoGravity.resizeAspectFill

    view.backgroundColor = UIColor.black

    guard let videoPreviewLayer = videoPreviewLayer else {
      return
    }

    view.layer.addSublayer(videoPreviewLayer)

    add(childViewController: messageViewController)
    [settingsButton, flashButton, focusView].forEach {
      view.addSubview($0)
      view.bringSubview(toFront: $0)
    }

    torchMode = .off
    focusView.isHidden = true

    setupCamera()

    NotificationCenter.default.addObserver(
      self, selector: #selector(appWillEnterForeground),
      name: NSNotification.Name.UIApplicationWillEnterForeground,
      object: nil)
  }

  open override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)

    if navigationController == nil {
      let headerViewController = HeaderViewController()
      headerViewController.delegate = self
      add(childViewController: headerViewController)
    }
  }

  open override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    animateFocusView()
  }

  open override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate(alongsideTransition: { (context) in
      self.setupFrame()
    }) { (context) in
      self.focusView.layer.removeAllAnimations()
      self.animateFocusView()
    }
  }

  /**
   `UIApplicationWillEnterForegroundNotification` action.
   */
  @objc private func appWillEnterForeground() {
    torchMode = .off
    animateFocusView()
  }

  // MARK: - Configuration

  /**
   Sets up camera and checks for camera permissions.
   */
  private func setupCamera() {
    let authorizationStatus = AVCaptureDevice.authorizationStatus(for: AVMediaType.video)

    if authorizationStatus == .authorized {
      setupSession()
      status = Status(state: .scanning)
    } else if authorizationStatus == .notDetermined {
      AVCaptureDevice.requestAccess(for: AVMediaType.video,
                                    completionHandler: { (granted: Bool) -> Void in
                                      DispatchQueue.main.async {
                                        if granted {
                                          self.setupSession()
                                        }

                                        self.status = granted ? Status(state: .scanning) : Status(state: .unauthorized)
                                      }
      })
    } else {
      status = Status(state: .unauthorized)
    }
  }

  /**
   Sets up capture input, output and session.
   */
  private func setupSession() {
    guard let captureDevice = captureDevice else {
      return
    }

    do {
      let input = try AVCaptureDeviceInput(device: captureDevice)
      captureSession.addInput(input)
    } catch {
      errorDelegate?.scanner(self, didReceiveError: error)
    }

    let output = AVCaptureMetadataOutput()
    captureSession.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
    output.metadataObjectTypes = metadata
    videoPreviewLayer?.session = captureSession

    view.setNeedsLayout()
  }

  // MARK: - Reset

  /**
   Shows error message and goes back to the scanning mode.

   - Parameter errorMessage: Error message that overrides the message from the config.
   */
  public func resetWithError(message: String? = nil) {
    status = Status(state: .notFound, text: message)
  }

  /**
   Resets the controller to the scanning mode.

   - Parameter animated: Flag to show scanner with or without animation.
   */
  public func reset(animated: Bool = true) {
    status = Status(state: .scanning, animated: animated)
  }

  /**
   Resets the current state.
   */
  private func resetState() {
    let alpha: CGFloat = status.state == .scanning ? 1 : 0

    torchMode = .off
    locked = status.state == .processing && isOneTimeSearch

    status.state == .scanning
      ? captureSession.startRunning()
      : captureSession.stopRunning()

    focusView.alpha = alpha
    flashButton.alpha = alpha
    settingsButton.isHidden = status.state != .unauthorized
  }

  // MARK: - Layout
  private func setupFrame() {
    let flashButtonSize: CGFloat = 37
    let isLandscape = view.frame.width > view.frame.height
    let insets = view.viewInsets
    // On iPhone X devices, extend the size of the top nav bar
    let navbarSize: CGFloat = isLandscape ? 32 : insets.top > 0 ? 88 : 64

    flashButton.frame = CGRect(
      x: view.frame.width - 50 - insets.right,
      y: navbarSize + 10 + (flashButtonSize / 2),
      width: flashButtonSize,
      height: flashButtonSize
    )
    infoView.frame = infoFrame

    if let videoPreviewLayer = videoPreviewLayer {
      videoPreviewLayer.frame = view.layer.bounds

      if let connection = videoPreviewLayer.connection, connection.isVideoOrientationSupported {
        switch (UIApplication.shared.statusBarOrientation) {
        case .portrait: connection.videoOrientation = .portrait
        case .landscapeRight: connection.videoOrientation = .landscapeRight
        case .landscapeLeft: connection.videoOrientation = .landscapeLeft
        case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
        default: connection.videoOrientation = .portrait
        }
      }
    }

    if barCodeFocusViewType == .oneDimension {
      center(subview: focusView, inSize: CGSize(width: 280, height: 80))
    } else {
      center(subview: focusView, inSize: CGSize(width: 218, height: 150))
    }

    center(subview: settingsButton, inSize: CGSize(width: 150, height: 50))
  }

  /**
   Sets a new size and center aligns subview's position.

   - Parameter subview: The subview.
   - Parameter size: A new size.
   */
  private func center(subview: UIView, inSize size: CGSize) {
    subview.frame = CGRect(
      x: (view.frame.width - size.width) / 2,
      y: (view.frame.height - size.height) / 2,
      width: size.width,
      height: size.height
    )
  }

  // MARK: - Animations

  /**
   Simulates flash animation.

   - Parameter processing: Flag to set the current state to `.Processing`.
   */
  private func animateFlash(whenProcessing: Bool = false) {
    let flashView = UIView(frame: view.bounds)
    flashView.backgroundColor = UIColor.white
    flashView.alpha = 1

    view.addSubview(flashView)
    view.bringSubview(toFront: flashView)

    UIView.animate(withDuration: 0.2,
                   animations: {
                    flashView.alpha = 0.0
    },
                   completion: { [weak self] _ in
                    flashView.removeFromSuperview()

                    if whenProcessing {
                      self?.status = Status(state: .processing)
                    }
    })
  }

  /**
   Performs focus view animation.
   */
  private func animateFocusView() {
    focusView.layer.removeAllAnimations()
    focusView.isHidden = false

    setupFrame()

    if barCodeFocusViewType == .animated {
      UIView.animate(withDuration: 1.0, delay:0,
                     options: [.repeat, .autoreverse, .beginFromCurrentState],
                     animations: {
                      self.center(subview: self.focusView, inSize: CGSize(width: 280, height: 80))
      }, completion: nil)
    }
    view.setNeedsLayout()
  }

  // MARK: - Actions

  /**
   Opens setting to allow camera usage.
   */
  @objc private func settingsButtonDidPress() {
    DispatchQueue.main.async {
      if let settingsURL = URL(string: UIApplicationOpenSettingsURLString) {
        UIApplication.shared.openURL(settingsURL)
      }
    }
  }

  /**
   Sets the next torch mode.
   */
  @objc private func flashButtonDidPress() {
    torchMode = torchMode.next
  }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension ScannerController: AVCaptureMetadataOutputObjectsDelegate {
  public func metadataOutput(_ output: AVCaptureMetadataOutput,
                             didOutput metadataObjects: [AVMetadataObject],
                             from connection: AVCaptureConnection) {
    guard !locked else { return }
    guard !metadataObjects.isEmpty else { return }

    guard
      let metadataObj = metadataObjects[0] as? AVMetadataMachineReadableCodeObject,
      var code = metadataObj.stringValue,
      metadata.contains(metadataObj.type)
      else { return }

    if isOneTimeSearch {
      locked = true
    }

    var rawType = metadataObj.type.rawValue

    // UPC-A is an EAN-13 barcode with a zero prefix.
    // See: https://stackoverflow.com/questions/22767584/ios7-barcode-scanner-api-adds-a-zero-to-upca-barcode-format
    if metadataObj.type == AVMetadataObject.ObjectType.ean13 && code.hasPrefix("0") {
      code = String(code.dropFirst())
      rawType = AVMetadataObject.ObjectType.upca.rawValue
    }

    codeDelegate?.scanner(self, didCaptureCode: code, type: rawType)
    animateFlash(whenProcessing: isOneTimeSearch)
  }
}

// MARK: - HeaderViewControllerDelegate

extension ScannerController: HeaderViewControllerDelegate {
  public func headerViewControllerDidTapCloseButton(_ controller: HeaderViewController) {
    status = Status(state: .scanning)
    dismissalDelegate?.scannerDidDismiss(self)
  }
}
