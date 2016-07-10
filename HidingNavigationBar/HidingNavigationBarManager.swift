//
//  HidingNavigationBarManager.swift
//  Optimus
//
//  Created by Tristan Himmelman on 2015-03-17.
//  Copyright (c) 2015 Hearst TV. All rights reserved.
//

import Foundation
import UIKit

public protocol HidingNavigationBarManagerDelegate: class {
	func hidingNavigationBarManagerDidUpdateScrollViewInsets(_ manager: HidingNavigationBarManager)
	func hidingNavigationBarManagerDidChangeState(_ manager: HidingNavigationBarManager, toState state: HidingNavigationBarState)
}

public enum HidingNavigationBarState: String {
	case Closed			= "Closed"
	case Contracting	= "Contracting"
	case Expanding		= "Expanding"
	case Open			= "Open"
}

public enum HidingNavigationForegroundAction {
	case `default`
	case show
	case hide
}

public class HidingNavigationBarManager: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
	// The view controller that is part of the navigation stack
	unowned var viewController: UIViewController
	
	// The scrollView that will drive the contraction/expansion
	unowned var scrollView: UIScrollView
	
	// The extension view to be shown beneath the navbar
	weak var extensionView: UIView?
	
	// Control the resistance when scrolling up/down before the navbar expands/contracts again.
	public var expansionResistance: CGFloat = 0
	public var contractionResistance: CGFloat = 0
	
	weak public var delegate: HidingNavigationBarManagerDelegate?
	
	public var refreshControl: UIRefreshControl?
	
	private var navBarController: HidingViewController
	private var extensionController: HidingViewController
	private var tabBarController: HidingViewController?
	
	// Scroll calculation values
	private var topInset: CGFloat = 0
	private var previousYOffset = CGFloat.nan
	private var resistanceConsumed: CGFloat = 0
	private var isUpdatingValues = false
	
	// Hiding navigation bar state
	private var currentState = HidingNavigationBarState.Open
	private var previousState = HidingNavigationBarState.Open

	//Options
	public var onForegroundAction = HidingNavigationForegroundAction.default
	
	public init(viewController: UIViewController, scrollView: UIScrollView){
		if viewController.navigationController == nil || viewController.navigationController?.navigationBar == nil {
			fatalError("ViewController must be within a UINavigationController")
		}
        
        viewController.extendedLayoutIncludesOpaqueBars = true
        
		self.viewController = viewController
		self.scrollView = scrollView
		
		// Create extensionController
		extensionController = HidingViewController()
		viewController.view.addSubview(extensionController.view)
		
		let navBar = viewController.navigationController!.navigationBar
		navBarController = HidingViewController(view: navBar)
		navBarController.child = extensionController
		navBarController.alphaFadeEnabled = true
		
		viewController.tabBarController?.tabBar
		
		super.init()
		
		// track panning on scroll view
		let panGesture = UIPanGestureRecognizer(target: self, action: Selector("handlePanGesture:"))
		panGesture.delegate = self
		scrollView.addGestureRecognizer(panGesture)
		
		navBarController.expandedCenter = {[weak self] (view: UIView) -> CGPoint in
			return CGPoint(x: view.bounds.midX, y: view.bounds.midY + (self?.statusBarHeight() ?? 0))
		}
		
		extensionController.expandedCenter = {[weak self] (view: UIView) -> CGPoint in
			let topOffset = (self?.navBarController.contractionAmountValue() ?? 0) + (self?.statusBarHeight() ?? 0)
			let point = CGPoint(x: view.bounds.midX, y: view.bounds.midY + topOffset)
			
			return point
		}
		
		updateContentInsets()
		
		NotificationCenter.default.addObserver(self, selector: Selector("applicationWillEnterForeground"), name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
	}
	
	deinit {
		NotificationCenter.default.removeObserver(self)
	}
	
	//MARK: Public methods

	public func manageBottomBar(_ view: UIView){
		tabBarController = HidingViewController(view: view)
		tabBarController?.contractsUpwards = false
		tabBarController?.expandedCenter = {[weak self] (view: UIView) -> CGPoint in
			let height = self?.viewController.view.frame.size.height ?? 0
			let point = CGPoint(x: view.bounds.midX, y: height - view.bounds.midY)
			
			return point
		}
	}
	
	public func addExtensionView(_ view: UIView) {
		extensionView?.removeFromSuperview()
		extensionView = view
		
		var bounds = view.frame
		bounds.origin = CGPoint.zero
		
		extensionView?.frame = bounds
		extensionController.view.frame = bounds
		extensionController.view.addSubview(view)
		extensionController.expand()
		
		extensionController.view.superview?.bringSubview(toFront: extensionController.view)
		updateContentInsets()
	}
	
	public func viewWillAppear(_ animated: Bool) {
		expand()
	}
	
	public func viewDidLayoutSubviews() {
		updateContentInsets()
	}
	
	public func viewWillDisappear(_ animated: Bool) {
		expand()
	}
	
	public func updateValues()	{
		isUpdatingValues = true
		
		var scrolledToTop = false
		
		if scrollView.contentInset.top == -scrollView.contentOffset.y {
			scrolledToTop = true
		}
		
		if let extensionView = extensionView {
			var frame = extensionController.view.frame
			frame.size.width = extensionView.bounds.size.width
			frame.size.height = extensionView.bounds.size.height
			extensionController.view.frame = frame
		}
		
		updateContentInsets()
		
		if scrolledToTop {
			var offset = scrollView.contentOffset
			offset.y = -scrollView.contentInset.top
			scrollView.contentOffset = offset
		}
		
		isUpdatingValues = false
	}
	
	public func shouldScrollToTop(){
		// update content Inset
		let top = statusBarHeight() + navBarController.totalHeight()
		updateScrollContentInsetTop(top)

		navBarController.snap(false, completion: nil)
		tabBarController?.snap(false, completion: nil)
	}
	
	public func contract(){
		navBarController.contract()
		tabBarController?.contract()
		
		previousYOffset = CGFloat.nan
		
		handleScrolling()
	}
	
	public func expand() {
		navBarController.expand()
		tabBarController?.expand()
		
		previousYOffset = CGFloat.nan
		
		handleScrolling()
	}
	
	//MARK: NSNotification
	
	func applicationWillEnterForeground() {
		switch onForegroundAction {
		case .show:
			navBarController.expand()
			tabBarController?.expand()
		case .hide:
			navBarController.contract()
			tabBarController?.contract()
		default:
			break;
		}
	}
	
	//MARK: Private methods
	
	private func isViewControllerVisible() -> Bool {
		return viewController.isViewLoaded() && viewController.view.window != nil
	}
	
	private func statusBarHeight() -> CGFloat {
		if UIApplication.shared().isStatusBarHidden {
			return 0
		}
		
		let statusBarSize = UIApplication.shared().statusBarFrame.size
		return min(statusBarSize.width, statusBarSize.height)
	}
	
	private func shouldHandleScrolling() -> Bool {
		// if scrolling down past top
		if scrollView.contentOffset.y <= -scrollView.contentInset.top && currentState == .Open {
			return false
		}
		
		// if refreshing
		if refreshControl?.isRefreshing == true {
			return false
		}
		
		let scrollFrame = UIEdgeInsetsInsetRect(scrollView.bounds, scrollView.contentInset)
		let scrollableAmount: CGFloat = scrollView.contentSize.height - scrollFrame.height
		let scrollViewIsSuffecientlyLong: Bool = scrollableAmount > navBarController.totalHeight() * 3
		
		return isViewControllerVisible() && scrollViewIsSuffecientlyLong && !isUpdatingValues
	}
	
	private func handleScrolling(){
		if shouldHandleScrolling() == false {
			return
		}
		
		if previousYOffset.isNaN == false {
			// 1 - Calculate the delta
			var deltaY = previousYOffset - scrollView.contentOffset.y
			
			// 2 - Ignore any scrollOffset beyond the bounds
			let start = -topInset
			if previousYOffset < start {
				deltaY = min(0, deltaY - previousYOffset - start)
			}
			
			/* rounding to resolve a dumb issue with the contentOffset value */
			let end = floor(scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom - 0.5)
			if previousYOffset > end {
				deltaY = max(0, deltaY - previousYOffset + end)
			}
			
			// 3 - Update contracting variable
			if Float(fabs(deltaY)) > FLT_EPSILON {
				if deltaY < 0 {
					currentState = .Contracting
				} else {
					currentState = .Expanding
				}
			}
			
			// 4 - Check if contracting state changed, and do stuff if so
			if currentState != previousState {
				previousState = currentState
				resistanceConsumed = 0
			}
			
			// 5 - Apply resistance
			if currentState == .Contracting {
				let availableResistance = contractionResistance - resistanceConsumed
				resistanceConsumed = min(contractionResistance, resistanceConsumed - deltaY)
				
				deltaY = min(0, availableResistance + deltaY)
			} else if scrollView.contentOffset.y > -statusBarHeight() {
				let availableResistance = expansionResistance - resistanceConsumed
				resistanceConsumed = min(expansionResistance, resistanceConsumed + deltaY)
				
				deltaY = max(0, deltaY - availableResistance)
			}
			
			// 6 - Update the shyViewController
			navBarController.updateYOffset(deltaY)
			tabBarController?.updateYOffset(deltaY)
		}
		
		// update content Inset
		updateContentInsets()
		
		previousYOffset = scrollView.contentOffset.y
		
		// update the visible state
		let state = currentState
		if navBarController.view.center.equalTo(navBarController.expandedCenterValue()) && extensionController.view.center.equalTo(extensionController.expandedCenterValue()) {
			currentState = .Open
		} else if navBarController.view.center.equalTo(navBarController.contractedCenterValue()) &&  extensionController.view.center.equalTo(extensionController.contractedCenterValue()) {
			currentState = .Closed
		}
		
		if state != currentState {
			delegate?.hidingNavigationBarManagerDidChangeState(self, toState: currentState)
		}
	}
	
	private func updateContentInsets() {
		let navBarBottomY = navBarController.view.frame.origin.y + navBarController.view.frame.size.height
		let top: CGFloat
		if extensionController.isContracted() == false {
			top = extensionController.view.frame.origin.y + extensionController.view.bounds.size.height
		} else {
			top = navBarBottomY
		}
		updateScrollContentInsetTop(top)
	}
	
	private func updateScrollContentInsetTop(_ top: CGFloat){
        if viewController.automaticallyAdjustsScrollViewInsets {
            var contentInset = scrollView.contentInset
            contentInset.top = top
            scrollView.contentInset = contentInset
        }
        var scrollInsets = scrollView.scrollIndicatorInsets
        scrollInsets.top = top
        scrollView.scrollIndicatorInsets = scrollInsets
        delegate?.hidingNavigationBarManagerDidUpdateScrollViewInsets(self)
	}
	
	private func handleScrollingEnded(_ velocity: CGFloat) {
		let minVelocity: CGFloat = 500.0
		if isViewControllerVisible() == false || (navBarController.isContracted() && velocity < minVelocity) {
			return
		}
		
		resistanceConsumed = 0
		if currentState == .Contracting || currentState == .Expanding || velocity > minVelocity {
			var contracting: Bool = currentState == .Contracting

			if velocity > minVelocity { // if velocity is greater than minVelocity we expand
				contracting = false
			}
			
			let deltaY = navBarController.snap(contracting, completion: nil)
			let tabBarShouldContract = deltaY < 0
			tabBarController?.snap(tabBarShouldContract, completion: nil)
			
			var newContentOffset = scrollView.contentOffset
			newContentOffset.y -= deltaY
			
			let contentInset = scrollView.contentInset
			let top = contentInset.top + deltaY
			
			UIView.animate(withDuration: 0.2){
				self.updateScrollContentInsetTop(top)
				self.scrollView.contentOffset = newContentOffset
			}
            
            previousYOffset = CGFloat.nan
		}
	}
	
	//MARK: Scroll handling
	
	func handlePanGesture(_ gesture: UIPanGestureRecognizer){
		switch gesture.state {
		case .began:
			topInset = navBarController.view.frame.size.height + extensionController.view.bounds.size.height + statusBarHeight()
			handleScrolling()
		case .changed:
			handleScrolling()
		default:
			let velocity = gesture.velocity(in: scrollView).y
			handleScrollingEnded(velocity)
		}
	}
	
	//MARK: UIGestureRecognizerDelegate
	
	public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		return true
	}

}
