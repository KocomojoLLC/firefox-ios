/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import SnapKit
import UIKit
import Storage        // For VisitType.

private struct HomePanelViewControllerUX {
    // Height of the top panel switcher button toolbar.
    static let ButtonContainerHeight: CGFloat = 40
    static let ButtonContainerBorderColor = UIColor.blackColor().colorWithAlphaComponent(0.1)
    static let BackgroundColorNormalMode = UIConstants.PanelBackgroundColor
    static let BackgroundColorPrivateMode = UIConstants.PrivateModeAssistantToolbarBackgroundColor
    static let EditDoneButtonRightPadding: CGFloat = -12
    static let ToolbarButtonDeselectedColorNormalMode = UIColor(white: 0.2, alpha: 0.5)
    static let ToolbarButtonDeselectedColorPrivateMode = UIColor(white: 0.9, alpha: 1)
}

protocol HomePanelViewControllerDelegate: class {
    func homePanelViewController(homePanelViewController: HomePanelViewController, didSelectURL url: NSURL, visitType: VisitType)
    func homePanelViewController(HomePanelViewController: HomePanelViewController, didSelectPanel panel: Int)
    func homePanelViewControllerDidRequestToSignIn(homePanelViewController: HomePanelViewController)
    func homePanelViewControllerDidRequestToCreateAccount(homePanelViewController: HomePanelViewController)
    func homePanelViewControllerDidRequestToOpenInNewTab(url: NSURL, isPrivate: Bool)
}

@objc
protocol HomePanel: class {
    weak var homePanelDelegate: HomePanelDelegate? { get set }
    optional func endEditing()
}

struct HomePanelUX {
    static let EmptyTabContentOffset = -180
}

@objc
protocol HomePanelDelegate: class {
    func homePanelDidRequestToSignIn(homePanel: HomePanel)
    func homePanelDidRequestToCreateAccount(homePanel: HomePanel)
    func homePanelDidRequestToOpenInNewTab(url: NSURL, isPrivate: Bool)
    func homePanel(homePanel: HomePanel, didSelectURL url: NSURL, visitType: VisitType)
    func homePanel(homePanel: HomePanel, didSelectURLString url: String, visitType: VisitType)
    optional func homePanelWillEnterEditingMode(homePanel: HomePanel)
}

struct HomePanelState {
    var isPrivate: Bool = false
    var selectedIndex: Int = 0
}

enum HomePanelType: Int {
    case TopSites = 0
    case Bookmarks = 1
    case History = 2
    case ReadingList = 3

    var localhostURL: NSURL {
        return NSURL(string:"#panel=\(self.rawValue)", relativeToURL: UIConstants.AboutHomePage)!
    }
}

class HomePanelViewController: UIViewController, UITextFieldDelegate, HomePanelDelegate {
    var profile: Profile!
    var notificationToken: NSObjectProtocol!
    var panels: [HomePanelDescriptor]!
    var url: NSURL?
    weak var delegate: HomePanelViewControllerDelegate?
    weak var appStateDelegate: AppStateDelegate?

    private var buttonContainerView: UIView!
    private var buttonContainerBottomBorderView: UIView!
    private var controllerContainerView: UIView!
    private var buttons: [UIButton] = []

    private var finishEditingButton: UIButton?
    private var editingPanel: HomePanel?

    var isPrivateMode: Bool = false {
        didSet {
            if oldValue != isPrivateMode {
                self.buttonContainerView.backgroundColor = isPrivateMode ? HomePanelViewControllerUX.BackgroundColorPrivateMode : HomePanelViewControllerUX.BackgroundColorNormalMode
                self.updateButtonTints()
                self.updateAppState()
            }
        }
    }

    var homePanelState: HomePanelState {
        return HomePanelState(isPrivate: isPrivateMode, selectedIndex: selectedPanel?.rawValue ?? 0)
    }

    override func viewDidLoad() {
        view.backgroundColor = HomePanelViewControllerUX.BackgroundColorNormalMode

        let blur: UIVisualEffectView? = DeviceInfo.isBlurSupported() ? UIVisualEffectView(effect: UIBlurEffect(style: UIBlurEffectStyle.Light)) : nil

        if let blur = blur {
            view.addSubview(blur)
        }

        buttonContainerView = UIView()
        buttonContainerView.backgroundColor = HomePanelViewControllerUX.BackgroundColorNormalMode
        buttonContainerView.clipsToBounds = true
        buttonContainerView.accessibilityNavigationStyle = .Combined
        buttonContainerView.accessibilityLabel = NSLocalizedString("Panel Chooser", comment: "Accessibility label for the Home panel's top toolbar containing list of the home panels (top sites, bookmarsk, history, remote tabs, reading list).")
        view.addSubview(buttonContainerView)

        self.buttonContainerBottomBorderView = UIView()
        buttonContainerView.addSubview(buttonContainerBottomBorderView)
        buttonContainerBottomBorderView.backgroundColor = HomePanelViewControllerUX.ButtonContainerBorderColor

        controllerContainerView = UIView()
        view.addSubview(controllerContainerView)

        blur?.snp_makeConstraints { make in
            make.edges.equalTo(self.view)
        }

        buttonContainerView.snp_makeConstraints { make in
            make.top.left.right.equalTo(self.view)
            make.height.equalTo(HomePanelViewControllerUX.ButtonContainerHeight)
        }

        buttonContainerBottomBorderView.snp_makeConstraints { make in
            make.top.equalTo(self.buttonContainerView.snp_bottom).offset(-1)
            make.left.right.bottom.equalTo(self.buttonContainerView)
        }

        controllerContainerView.snp_makeConstraints { make in
            make.top.equalTo(self.buttonContainerView.snp_bottom)
            make.left.right.bottom.equalTo(self.view)
        }

        self.panels = HomePanels().enabledPanels
        updateButtons()

        // Gesture recognizer to dismiss the keyboard in the URLBarView when the buttonContainerView is tapped
        let dismissKeyboardGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(HomePanelViewController.SELhandleDismissKeyboardGestureRecognizer(_:)))
        dismissKeyboardGestureRecognizer.cancelsTouchesInView = false
        buttonContainerView.addGestureRecognizer(dismissKeyboardGestureRecognizer)
    }

    private func updateAppState() {
        let state = mainStore.updateState(.HomePanels(homePanelState: homePanelState))
        self.appStateDelegate?.appDidUpdateState(state)
    }

    func SELhandleDismissKeyboardGestureRecognizer(gestureRecognizer: UITapGestureRecognizer) {
        view.window?.rootViewController?.view.endEditing(true)
    }

    var selectedPanel: HomePanelType? = nil {
        didSet {
            if oldValue == selectedPanel {
                // Prevent flicker, allocations, and disk access: avoid duplicate view controllers.
                return
            }

            if let index = oldValue?.rawValue {
                if index < buttons.count {
                    let currentButton = buttons[index]
                    currentButton.selected = false
                    currentButton.userInteractionEnabled = true
                }
            }

            hideCurrentPanel()

            if let index = selectedPanel?.rawValue {
                if index < buttons.count {
                    let newButton = buttons[index]
                    newButton.selected = true
                    newButton.userInteractionEnabled = false
                }

                if index < panels.count {
                    let panel = self.panels[index].makeViewController(profile: profile)
                    let accessibilityLabel = self.panels[index].accessibilityLabel
                    if let panelController = panel as? UINavigationController,
                        let rootPanel = panelController.viewControllers.first {
                        setupHomePanel(rootPanel, accessibilityLabel: accessibilityLabel)
                        self.showPanel(panelController)
                    } else {
                        setupHomePanel(panel, accessibilityLabel: accessibilityLabel)
                        self.showPanel(panel)
                    }
                }
            }
            self.updateButtonTints()
            self.updateAppState()
        }
    }

    func setupHomePanel(panel: UIViewController, accessibilityLabel: String) {
        (panel as? HomePanel)?.homePanelDelegate = self
        panel.view.accessibilityNavigationStyle = .Combined
        panel.view.accessibilityLabel = accessibilityLabel
    }

    override func preferredStatusBarStyle() -> UIStatusBarStyle {
        return UIStatusBarStyle.LightContent
    }

    private func hideCurrentPanel() {
        if let panel = childViewControllers.first {
            panel.willMoveToParentViewController(nil)
            panel.beginAppearanceTransition(false, animated: false)
            panel.view.removeFromSuperview()
            panel.endAppearanceTransition()
            panel.removeFromParentViewController()
        }
    }

    private func showPanel(panel: UIViewController) {
        addChildViewController(panel)
        panel.beginAppearanceTransition(true, animated: false)
        controllerContainerView.addSubview(panel.view)
        panel.endAppearanceTransition()
        panel.view.snp_makeConstraints { make in
            make.top.equalTo(self.buttonContainerView.snp_bottom)
            make.left.right.bottom.equalTo(self.view)
        }
        panel.didMoveToParentViewController(self)
    }

    func SELtappedButton(sender: UIButton!) {
        for (index, button) in buttons.enumerate() {
            if button == sender {
                selectedPanel = HomePanelType(rawValue: index)
                delegate?.homePanelViewController(self, didSelectPanel: index)
                break
            }
        }
    }

    func endEditing(sender: UIButton!) {
        toggleEditingMode(false)
        editingPanel?.endEditing?()
        editingPanel = nil
    }

    private func updateButtons() {
        // Remove any existing buttons if we're rebuilding the toolbar.
        for button in buttons {
            button.removeFromSuperview()
        }
        buttons.removeAll()

        var prev: UIView? = nil
        for panel in panels {
            let button = UIButton()
            buttonContainerView.addSubview(button)
            button.addTarget(self, action: #selector(HomePanelViewController.SELtappedButton(_:)), forControlEvents: UIControlEvents.TouchUpInside)
            if let image = UIImage.templateImageNamed("panelIcon\(panel.imageName)") {
                button.setImage(image, forState: UIControlState.Normal)
            }
            if let image = UIImage.templateImageNamed("panelIcon\(panel.imageName)Selected") {
                button.setImage(image, forState: UIControlState.Selected)
            }
            button.accessibilityLabel = panel.accessibilityLabel
            button.accessibilityIdentifier = panel.accessibilityIdentifier
            buttons.append(button)

            button.snp_remakeConstraints { make in
                let left = prev?.snp_right ?? self.view.snp_left
                make.left.equalTo(left)
                make.height.centerY.equalTo(self.buttonContainerView)
                make.width.equalTo(self.buttonContainerView).dividedBy(self.panels.count)
            }

            prev = button
        }
    }
    
    func updateButtonTints() {
        for (index, button) in self.buttons.enumerate() {
            if index == self.selectedPanel?.rawValue {
                button.tintColor = isPrivateMode ? UIConstants.PrivateModePurple : UIConstants.HighlightBlue
            } else {
                button.tintColor = isPrivateMode ? HomePanelViewControllerUX.ToolbarButtonDeselectedColorPrivateMode : HomePanelViewControllerUX.ToolbarButtonDeselectedColorNormalMode
            }
        }
    }

    func homePanel(homePanel: HomePanel, didSelectURLString url: String, visitType: VisitType) {
        // If we can't get a real URL out of what should be a URL, we let the user's
        // default search engine give it a shot.
        // Typically we'll be in this state if the user has tapped a bookmarked search template
        // (e.g., "http://foo.com/bar/?query=%s"), and this will get them the same behavior as if
        // they'd copied and pasted into the URL bar.
        // See BrowserViewController.urlBar:didSubmitText:.
        guard let url = URIFixup.getURL(url) ??
                        profile.searchEngines.defaultEngine.searchURLForQuery(url) else {
            Logger.browserLogger.warning("Invalid URL, and couldn't generate a search URL for it.")
            return
        }

        return self.homePanel(homePanel, didSelectURL: url, visitType: visitType)
    }

    func homePanel(homePanel: HomePanel, didSelectURL url: NSURL, visitType: VisitType) {
        delegate?.homePanelViewController(self, didSelectURL: url, visitType: visitType)
        dismissViewControllerAnimated(true, completion: nil)
    }

    func homePanelDidRequestToCreateAccount(homePanel: HomePanel) {
        delegate?.homePanelViewControllerDidRequestToCreateAccount(self)
    }

    func homePanelDidRequestToSignIn(homePanel: HomePanel) {
        delegate?.homePanelViewControllerDidRequestToSignIn(self)
    }
    
    func homePanelDidRequestToOpenInNewTab(url: NSURL, isPrivate: Bool) {
        delegate?.homePanelViewControllerDidRequestToOpenInNewTab(url, isPrivate: isPrivate)
    }

    func homePanelWillEnterEditingMode(homePanel: HomePanel) {
        editingPanel = homePanel
        toggleEditingMode(true)
    }

    func toggleEditingMode(editing: Bool) {
        let translateDown = CGAffineTransformMakeTranslation(0, UIConstants.ToolbarHeight)
        let translateUp = CGAffineTransformMakeTranslation(0, -UIConstants.ToolbarHeight)

        if editing {
            let button = UIButton(type: UIButtonType.System)
            button.setTitle(NSLocalizedString("Done", comment: "Done editing button"), forState: UIControlState.Normal)
            button.addTarget(self, action: #selector(HomePanelViewController.endEditing(_:)), forControlEvents: UIControlEvents.TouchUpInside)
            button.transform = translateDown
            button.titleLabel?.textAlignment = .Right
            button.tintColor = self.isPrivateMode ? UIConstants.PrivateModeActionButtonTintColor : UIConstants.SystemBlueColor
            self.buttonContainerView.addSubview(button)
            button.snp_makeConstraints { make in
                make.right.equalTo(self.buttonContainerView).offset(HomePanelViewControllerUX.EditDoneButtonRightPadding)
                make.centerY.equalTo(self.buttonContainerView)
            }
            self.buttonContainerView.layoutIfNeeded()
            finishEditingButton = button
        }

        UIView.animateWithDuration(0.4, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: [UIViewAnimationOptions.AllowUserInteraction, UIViewAnimationOptions.CurveEaseInOut], animations: { () -> Void in
            self.buttons.forEach { $0.transform = editing ? translateUp : CGAffineTransformIdentity }
            self.finishEditingButton?.transform = editing ? CGAffineTransformIdentity : translateDown
        }, completion: { _ in
            if !editing {
                self.finishEditingButton?.removeFromSuperview()
                self.finishEditingButton = nil
            }
        })
    }
}
