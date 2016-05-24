// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//

import CoreFoundation

extension NotificationQueue {

    public enum PostingStyle : UInt {
        
        case postWhenIdle
        case postASAP
        case postNow
    }

    public struct Coalescing : OptionSet {
        public let rawValue : UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        
        public static let CoalescingOnName = Coalescing(rawValue: 1 << 0)
        public static let CoalescingOnSender = Coalescing(rawValue: 1 << 1)
    }
}

public class NotificationQueue: NSObject {

    internal typealias NotificationQueueList = NSMutableArray
    internal typealias NSNotificationListEntry = (Notification, [String]) // Notification ans list of modes the notification may be posted in.
    internal typealias NSNotificationList = [NSNotificationListEntry] // The list of notifications to post

    internal let notificationCenter: NotificationCenter
    internal var asapList = NSNotificationList()
    internal var idleList = NSNotificationList()
    internal lazy var idleRunloopObserver: CFRunLoopObserver = {
        return CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFOptionFlags(kCFRunLoopBeforeTimers), true, 0) {[weak self] observer, activity in
            self!.notifyQueues(.postWhenIdle)
        }
    }()
    internal lazy var asapRunloopObserver: CFRunLoopObserver = {
        return CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFOptionFlags(kCFRunLoopBeforeWaiting | kCFRunLoopExit), true, 0) {[weak self] observer, activity in
            self!.notifyQueues(.postASAP)
        }
    }()

    // The NSNotificationQueue instance is associated with current thread.
    // The _notificationQueueList represents a list of notification queues related to the current thread.
    private static var _notificationQueueList = NSThreadSpecific<NSMutableArray>()
    internal static var notificationQueueList: NotificationQueueList {
        return _notificationQueueList.get() {
            return NSMutableArray()
        }
    }

    // The default notification queue for the current thread.
    private static var _defaultQueue = NSThreadSpecific<NotificationQueue>()
    public class func defaultQueue() -> NotificationQueue {
        return _defaultQueue.get() {
            return NotificationQueue(notificationCenter: NotificationCenter.defaultCenter())
        }
    }
    
    public init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
        super.init()
        NotificationQueue.registerQueue(self)
    }

    deinit {
        NotificationQueue.unregisterQueue(self)
        removeRunloopObserver(self.idleRunloopObserver)
        removeRunloopObserver(self.asapRunloopObserver)
    }

    public func enqueueNotification(_ notification: Notification, postingStyle: PostingStyle) {
        enqueueNotification(notification, postingStyle: postingStyle, coalesceMask: [.CoalescingOnName, .CoalescingOnSender], forModes: nil)
    }

    public func enqueueNotification(_ notification: Notification, postingStyle: PostingStyle, coalesceMask: Coalescing, forModes modes: [String]?) {
        var runloopModes = [NSDefaultRunLoopMode]
        if let modes = modes  {
            runloopModes = modes
        }

        if !coalesceMask.isEmpty {
            self.dequeueNotificationsMatching(notification, coalesceMask: coalesceMask)
        }

        switch postingStyle {
        case .postNow:
            let currentMode = RunLoop.currentRunLoop().currentMode
            if currentMode == nil || runloopModes.contains(currentMode!) {
                self.notificationCenter.postNotification(notification)
            }
        case .postASAP: // post at the end of the current notification callout or timer
            addRunloopObserver(self.asapRunloopObserver)
            self.asapList.append((notification, runloopModes))
        case .postWhenIdle: // wait until the runloop is idle, then post the notification
            addRunloopObserver(self.idleRunloopObserver)
            self.idleList.append((notification, runloopModes))
        }
    }
    
    public func dequeueNotificationsMatching(_ notification: Notification, coalesceMask: Coalescing) {
        var predicate: (NSNotificationListEntry) -> Bool
        switch coalesceMask {
        case [.CoalescingOnName, .CoalescingOnSender]:
            predicate = { (entryNotification, _) in
                return notification.object !== entryNotification.object || notification.name != entryNotification.name
            }
        case [.CoalescingOnName]:
            predicate = { (entryNotification, _) in
                return notification.name != entryNotification.name
            }
        case [.CoalescingOnSender]:
            predicate = { (entryNotification, _) in
                return notification.object !== entryNotification.object
            }
        default:
            return
        }

        self.asapList = self.asapList.filter(predicate)
        self.idleList = self.idleList.filter(predicate)
    }

    // MARK: Private

    private func addRunloopObserver(_ observer: CFRunLoopObserver) {
        CFRunLoopAddObserver(RunLoop.currentRunLoop()._cfRunLoop, observer, kCFRunLoopDefaultMode)
        CFRunLoopAddObserver(RunLoop.currentRunLoop()._cfRunLoop, observer, kCFRunLoopCommonModes)
    }

    private func removeRunloopObserver(_ observer: CFRunLoopObserver) {
        CFRunLoopRemoveObserver(RunLoop.currentRunLoop()._cfRunLoop, observer, kCFRunLoopDefaultMode)
        CFRunLoopRemoveObserver(RunLoop.currentRunLoop()._cfRunLoop, observer, kCFRunLoopCommonModes)
    }

    private func notify(_ currentMode: String?, notificationList: inout NSNotificationList) {
        for (idx, (notification, modes)) in notificationList.enumerated().reversed() {
            if currentMode == nil || modes.contains(currentMode!) {
                self.notificationCenter.postNotification(notification)
                notificationList.remove(at: idx)
            }
        }
    }

    /**
     Gets queues from the notificationQueueList and posts all notification from the list related to the postingStyle parameter.
     */
    private func notifyQueues(_ postingStyle: PostingStyle) {
        let currentMode = RunLoop.currentRunLoop().currentMode
        for queue in NotificationQueue.notificationQueueList {
            let notificationQueue = queue as! NotificationQueue
            if postingStyle == .postWhenIdle {
                notificationQueue.notify(currentMode, notificationList: &notificationQueue.idleList)
            } else {
                notificationQueue.notify(currentMode, notificationList: &notificationQueue.asapList)
            }
        }
    }

    private static func registerQueue(_ notificationQueue: NotificationQueue) {
        self.notificationQueueList.addObject(notificationQueue)
    }

    private static func unregisterQueue(_ notificationQueue: NotificationQueue) {
        guard self.notificationQueueList.indexOfObject(notificationQueue) != NSNotFound else {
            return
        }
        self.notificationQueueList.removeObject(notificationQueue)
    }

}
