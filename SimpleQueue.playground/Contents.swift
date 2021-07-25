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

        private let work: Work
        private let completion: ((Result) -> Void)?

        init(work: @escaping Work, completion: Completion? = nil) {
            self.work = work
            self.completion = completion
        }

        func execute() {
            let result = work()
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
        let runner: Worker
    }

    private var workers = [WorkerContext]()

    /// Initializes a queue with a fixed number of worker threads
    ///
    /// - Parameters:
    ///   - workerCount: Number of work threads to create. Must be at least 1.

    init(workerCount: Int = 3) {
        precondition(workerCount > 0)

        workers = (0..<workerCount).map { _ in
            let worker = Worker()
            let thread = Thread(target: worker, selector: #selector(Worker.loop), object: nil)
            thread.start()

            return WorkerContext(thread: thread, runner: worker)
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
    func sync<Result>(_ work: @escaping () -> Result) -> Result {
        let condition = NSConditionLock(condition: 0)
        var result: Result?

        let workItem = Worker.WorkItem(work: work) { workResult in
            condition.lock()
            result = workResult
            condition.unlock(withCondition: 1)
        }

        workerToScheduleOn().schedule(workItem)

        condition.lock(whenCondition: 1)
        condition.unlock(withCondition: 0)

        // Assumed to not be nil based on above locking
        return result!
    }

    private func workerToScheduleOn() -> Worker {
        // The force-unwrap is assumed safe based on the precondition() in the initializer
        return workers
            .map { $0.runner }
            .sorted { $0.estimatedLoad < $1.estimatedLoad }.first!
    }
}

// TODO: some quick tests, cleanup

let queue = SimpleQueue()

queue.async {
    print("task 1")
}

queue.async {
    print("task 2")

    queue.async {
        print("nested after 2")
    }
}

queue.async {
    print("task 3")

    // This is expected to deadlock if there is only 1 worker thread (serial)
    // It will function if there are 2 or more threads (concurrent)

    print("before sync")
    let nestedSyncResult = queue.sync {
        return "nested result"
    }
    print("after sync: \(nestedSyncResult)")
}

let result: String = queue.sync {
    queue.async {
        print("async within sync")
    }

    return "thread sync 1"
}
