/*
 Copyright (c) 2017 LOTUM GmbH
 Licensed under Apache License v2.0
 
 See https://github.com/LOTUM/EventHub/blob/master/LICENSE for license information
 */



import Foundation



/** 
 This class is an pub/sub implementation. You can register for events.
 And you can emit events on specific queues. Threadsafe.
 */
public final class EventHub<EventT: Hashable, PayloadT> {

    
    //MARK: Public API
    
    public init() {}
    
    public func on(_ event: EventT, action: @escaping (PayloadT)->Void) -> Disposable {
        return on(event, lifetime: .always, action: action)
    }
    
    
    @discardableResult
    public func once(_ event: EventT, action: @escaping (PayloadT)->Void) -> Disposable {
        return on(event, lifetime: .once, action: action)
    }
    
    public func removeAllListeners(forEvent: EventT? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let event = forEvent {
            queuedActions[event] = nil
        } else {
            queuedActions = [:]
        }
    }
    
    public func numberOfListeners(forEvent: EventT? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let event = forEvent {
            return queuedActions[event]?.count ?? 0
        } else {
            return queuedActions.values.flatMap { $0 }.count
        }
    }
    
    /**
     The event listeners registered for the given event get fired. If you don't specify a queue the listeners get
     fired on the current queue synchronously. Otherwise they are called asynchonously on the given queue.
     
     The payload block only evaluate if there are listeners.
    */
    public func emit(_ event: EventT,
                     on queue: DispatchQueue? = nil,
                     with value: @autoclosure ()->PayloadT) {
        lock.lock()
        let actionsToExecute = queuedActions[event] ?? []
        self.queuedActions[event] = actionsToExecute.flatMap { $0.reduce() }
        lock.unlock()
        //run blocks after filtering the actions, so you can emit from within block()
        //without infinite recursion when emitting the same event although action lifetime is once
        guard actionsToExecute.count > 0 else { return }
        let valueToSend = value()
        actionsToExecute.forEach { $0.run(onQueue: queue, with: valueToSend) }
    }

    
    //MARK: Private
    
    private var queuedActions: [EventT:[Action<PayloadT>]] = [:]
    private let lock = NSLock()
    
    private func on(_ event: EventT,
                    lifetime: ActionLifetime,
                    action: @escaping (PayloadT)->Void) -> Disposable
    {
        lock.lock()
        let act = Action(runTime: lifetime, action: action)
        queuedActions[event] = (queuedActions[event] ?? []) + [act]
        lock.unlock()
        return EventDisposable { [weak self, weak act] in
            guard let act = act else { return }
            self?.removeListener(with: act, forEvent: event)
        }
    }
    
    private func removeListener(with toRemove: Action<PayloadT>, forEvent event: EventT) {
        lock.lock()
        defer { lock.unlock() }
        if let allActionsForEvent = queuedActions[event] {
            let filteredActions = allActionsForEvent.filter { $0 !== toRemove }
            queuedActions[event] = filteredActions
        }
    }
}



extension EventHub where PayloadT == Void {
    
    public func emit(_ event: EventT,
                     on queue: DispatchQueue? = nil) {
        emit(event, on: queue, with: {}())
    }
    
}



//MARK:- Private


/// How often will the action fire for event
private enum ActionLifetime {
    case once, always
}



private final class EventDisposable: Disposable {
    
    private let disposeBlock: ()->Void
    
    init(_ block: @escaping ()->Void) {
        disposeBlock = block
    }
    
    func dispose() {
        disposeBlock()
    }
}



private final class Action<PayloadT> {
    
    let runTime: ActionLifetime
    let block: (PayloadT)->Void
    
    init(runTime rt: ActionLifetime, action act: @escaping (PayloadT)->Void) {
        runTime = rt
        block = act
    }
    
    func run(onQueue queue: DispatchQueue? = nil, with val: PayloadT) {
        let b = block
        
        if let q = queue {
            q.async(execute: { b(val) })
        } else {
            b(val)
        }
    }
    
    func reduce() -> Action? {
        switch self.runTime {
        case .always:
            return self
        case .once:
            return nil
        }
    }
}

