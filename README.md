# Cache.swift is a flexible RAM and disk-backed caching library for Swift

It exists because other solutions do not provide customisable eviction or
disk-backed caching.

## Example

Basic usage (default options of 1MB in-memory limit and 10MB on-disk limit and
age-based eviction):

```swift
let cache = Cache(name: "test")
cache.set("a", value: "a value")
if let a: String? = cache.get("a") {
  println(a)
}
```

Here's an example with RAM and disk limits set to 4 bytes, for illustrative
purposes:

```swift
let options = Cache.Options(memoryByteLimit: 4, diskByteLimit: 4)
let cache = Cache(name: "test", options: options)
cache.set("a", value: "test")
cache.set("b", value: "b")                                // "a" is evicted here
XCTAssertEqual(cache.residentKeys, ["b"])
XCTAssertEqual(cache.keys, ["b"])
```
