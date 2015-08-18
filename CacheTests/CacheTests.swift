//
//  CacheTests.swift
//  CacheTests
//
//  Created by Alec Thomas on 17/08/2015.
//  Copyright (c) 2015 Compass. All rights reserved.
//

import Cocoa
import XCTest

class CacheTests: XCTestCase {
    func testCacheGetSet() {
        let cache = Cache(name: "test")
        cache.set("test", value: "hello world")
        let value: String? = cache.get("test")
        XCTAssertNotNil(value)
        XCTAssertEqual(value!, "hello world")
        cache.invalidate()
    }

    func testCacheMemoryLimit() {
        let options = Cache.Options(memoryLimit: 4, diskLimit: 1024 * 1024)
        let cache = Cache(name: "test", options: options)
        cache.set("a", value: "test")
        cache.set("b", value: "b")
        XCTAssertEqual(cache.residentKeys, ["b"])
        XCTAssertEqual(cache.keys, ["a", "b"])
        cache.invalidate()
    }

    func testCacheDiskLimit() {
        let options = Cache.Options(memoryLimit: 4, diskLimit: 4)
        let cache = Cache(name: "test", options: options)
        cache.set("a", value: "test")
        cache.set("b", value: "b")
        XCTAssertEqual(cache.residentKeys, ["b"])
        XCTAssertEqual(cache.keys, ["b"])
        cache.invalidate()
    }

    func testCustomCostFunction() {
        let options = Cache.Options(
            memoryLimit: 4,
            diskLimit: 4,
            costFunction: {e in Float64(e.size)}
        )
        let cache = Cache(name: "test", options: options)
        cache.set("a", value: "a")
        cache.set("b", value: "test")
        XCTAssertEqual(cache.residentKeys, ["b"])
        XCTAssertEqual(cache.keys, ["b"])
        cache.invalidate()
    }

    func testResumeCache() {
        let cachea = Cache(name: "test")
        cachea.set("a", value: "a")
        cachea.set("b", value: "b")
        let cacheb = Cache(name: "test")
        XCTAssertEqual(cacheb.keys, ["a", "b"])
        XCTAssertEqual(cacheb.residentKeys, [])
        XCTAssertEqual(cachea.diskSize, cacheb.diskSize)
    }
}
