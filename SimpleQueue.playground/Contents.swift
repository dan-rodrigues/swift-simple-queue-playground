// SimpleQueue Playground
//
// Copyright (C) 2021 Dan Rodrigues <danrr.gh.oss@gmail.com>
//
// SPDX-License-Identifier: MIT

import Foundation

/// This playground serves as a scratchpad for implementing a very minimal equivalent of `DispatchQueue`
///
/// It's more of a sandbox to build a more complicated system out of very basic concurrency primitives
/// It's not intended to be used in an actual production app

final class Worker {

    /// Encapsulates a single item of work that can be scheduled

    final class WorkItem<Result> {

        typealias Work = () -> Result
        typealias Completion = (Result) -> Void

        private var work: Work?
        private let completion: ((Result) -> Void)?

        init(work: @escaping Work, completion: Completion? = nil) {
            self.work = work
            self.completion = completion
        }

        func execute() {
            let result: Result
            if let workToExecute = work {
                // The work closure reference must be set to nil to ensure the no-escape condition is met when completion is called
                // withoutActuallyEscaping() enforces this and commenting out the nil-assignment will cause exceptions
                //
                // Also note that workToExecute wasn't created using a guard statement
                // That would keep the work closure live until this function returns, which will lead to the same exception
                result = workToExecute()
                work = nil
            } else {
                // Since work is set to nil after execution, it should only be run once
                // This is a showstopper implementation bug and considered a fatal error
                preconditionFailure("execute() on WorkItem was called more than once")
            }

            // At this point, work will have been set to nil (to avoid the mentioned escaping-exceptions)
            // We can now call the completion handler safely
            completion?(result)
        }
    }

    /// Type-erasing wrapper intended to contain the `WorkItem<>` instances
    ///
    /// This only exists because Swift lacks covariant user-defined generics such as the stdlib `Array`

    private final class AnyWorkItem {

        private let wrappedExecute: () -> Void

        init<Value>(_ wrapped: WorkItem<Value>) {
            self.wrappedExecute = wrapped.execute
        }

        func execute() {
            wrappedExecute()
        }
    }

    /// An approximation of how much work is remaining for this worker
    ///
    /// This just returns number of pending work items but can potentially provide a more meaningful estimate

    var estimatedLoad: Double {
        return Double(pendingWork.count)
    }

    private var pendingWork = [AnyWorkItem]()
    private let condition = NSCondition()

    /// Schedules work to be performed on the queue
    ///
    /// If the worker thread is currently suspended due to lack of work, enqueing work using this function will resume the thread.
    ///
    /// - Parameters:
    ///   - work: The work item to be scheduled

    func schedule<Result>(_ work: WorkItem<Result>) {
        condition.lock()
        pendingWork.append(.init(work))
        condition.signal()
        condition.unlock()
    }

    /// The main thread loop for this worker which performs work contained in scheduled `WorkItem` instances
    ///
    /// An instance of `NSThread` should target this function. The `schedule()` function can then be used to schedule work for the thread.

    @objc func loop() -> Never {
        while (true) {
            condition.lock()
            while (pendingWork.isEmpty) {
                condition.wait()
            }

            // There must be at least 1 work item in the array to reach this point
            let work = pendingWork.removeFirst()
            condition.unlock()

            work.execute()
        }
    }
}

final class SimpleQueue {

    typealias Work = () -> Void

    private struct WorkerContext {

        let thread: Thread
        let worker: Worker
    }

    private var contexts = [WorkerContext]()

    /// Initializes a queue with a fixed number of worker threads
    ///
    /// - Parameters:
    ///   - workerCount: Number of work threads to create. Must be at least 1.

    init(workerCount: Int = 3) {
        precondition(workerCount > 0)

        contexts = (0..<workerCount).map { _ in
            let worker = Worker()
            let thread = Thread(target: worker, selector: #selector(Worker.loop), object: nil)
            thread.start()

            return WorkerContext(thread: thread, worker: worker)
        }
    }

    /// Schedules `work` asynchronously on this queue
    ///
    /// Similar to `DispatchQueue.async`
    ///
    /// - Parameters:
    ///   - work: The work to schedule.

    func async(_ work: @escaping Work) {
        workerToScheduleOn().schedule(.init(work: work))
    }

    /// Performs `work` synchronously on the queue
    ///
    /// This is similar to `DispatchQueue.sync()` however it doesn't include the `rethrows` support
    /// There was pitch posted to the Swift forums to add `rethrows(unchecked)` to deal with this case
    /// `DispatchQueue` apparently exploits compiler bugs to implement `rethrows` on `sync` support which won't be repeated here
    ///
    /// - Parameters:
    ///   - work: The work to perform.

    @discardableResult
    func sync<Result>(_ work: () -> Result) -> Result {
        let waitingCondition = 0
        let completedCondition = 1

        let conditionLock = NSConditionLock(condition: waitingCondition)

        // Since the work closure doesn't escape in practice, we can use withoutActuallyEscaping() here
        // The WorkItem struct does store the closure and therefore escapes it, but it won't outlive this function call
        // We need to ensure escapableWork doesn't escape or an exception will be thrown

        return withoutActuallyEscaping(work) { escapableWork in
            var result: Result?

            let workItem = Worker.WorkItem(work: escapableWork) { workResult in
                conditionLock.lock()
                result = workResult
                conditionLock.unlock(withCondition: completedCondition)
            }

            workerToScheduleOn().schedule(workItem)

            conditionLock.lock(whenCondition: completedCondition)
            defer { conditionLock.unlock() }

            // Assumed to not be nil based on above locking
            return result!
        }
    }

    private func workerToScheduleOn() -> Worker {
        // The force-unwrap is assumed safe based on the precondition() in the initializer
        return contexts
            .map { $0.worker }
            .sorted { $0.estimatedLoad < $1.estimatedLoad }
            .first!
    }
}

// TODO: some quick tests, cleanup

let concurrentQueue = SimpleQueue(workerCount: 3)
let serialQueue = SimpleQueue(workerCount: 1)

serialQueue.async {
    print("sq: task 1")
}

serialQueue.async {
    print("sq: task 2")

    serialQueue.async {
        print("sq: nested within 2")
    }
}

concurrentQueue.async {
    print("cq: task 1")

    print("before sync")
    let nestedSyncResult: String = serialQueue.sync {
        print("within sync")
        return "sq: nested result"
    }
    print("after sync: \(nestedSyncResult)")
}

let result: String = concurrentQueue.sync {
    serialQueue.async {
        print("sq: async within sync")
    }

    return "cq: thread sync 1"
}

print("sync result: \(result)")
