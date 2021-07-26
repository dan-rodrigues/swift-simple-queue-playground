# Swift SimpleQueue Playground

This repo is a personal project and doesn't contain anything intended for use in a production setting.

## Background

This is a Swift 5.0 playground that serves as a scratchpad for implementing a minimal equivalent of `DispatchQueue` using only the condition classes provided by Foundation. Only `NSCondition` and `NSConditionLock` are used which provides enough functionality to suspend and resume threads only when needed. 

## API

The implementation is called `SimpleQueue` and is modelled after `DispatchQueue`. 

```swift
final class SimpleQueue {

    init(workerCount: Int)

    func async(_ work: @escaping Work)

    @discardableResult
    func sync<Result>(_ work: @escaping () -> Result) -> Result
}

```

## TODO

- [ ] A better set tests

## Tools

Xcode 12.5.1 was used to create the playground.

