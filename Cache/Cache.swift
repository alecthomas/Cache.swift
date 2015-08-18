//
//  Cache.swift
//
// An in-memory and disk-backed cache with separate limits for both.
//
//  Created by Alec Thomas on 17/08/2015.
//  Copyright (c) 2015 Urban Compass. All rights reserved.
//

import Foundation
#if os(iOS)
import UIKit
#endif

// Objects conforming to this protocol may be cached.
public protocol Cacheable {
    func encodeForCache() -> NSData
    static func decodeFromCache(data: NSData) -> Any?
}

// An in-memory and disk-backed cache with separate limits for both.
public class Cache {
    public typealias CostFunction = (CacheEntry) -> Float64

    // Options for controlling the cache.
    public struct Options {
        // The maximum in-memory size of the cache (in bytes).
        // Note that this is based on the encoded size of the objects.
        public var memoryByteLimit: Int

        // The maximum disk size of the cache (in bytes).
        public var diskByteLimit: Int

        // Used to return a cost for the entry. Lower cost objects will be evicted first.
        // Defaults to time-based cost, where older entries have a higher cost.
        public var costFunction: CostFunction

        public init(
            memoryByteLimit: Int = 1024 * 1024,              // 1MB
            diskByteLimit: Int = 1024 * 1024 * 10,           // 10MB
            costFunction: CostFunction = {e in e.ctime}
        ) {
            self.memoryByteLimit = memoryByteLimit
            self.diskByteLimit = diskByteLimit
            self.costFunction = costFunction
        }
    }

    public struct CacheEntry {
        let key: String
        let ctime: NSTimeInterval
        let size: Int
    }

    internal let background = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0)
    internal let queue = dispatch_queue_create("com.compass.Cache", DISPATCH_QUEUE_SERIAL)
    internal let root: String
    internal var metadata: [String:CacheEntry] = [:]
    internal let options: Options
    internal var cache: [String:Any] = [:]
    internal var diskSize: Int = 0
    internal var memorySize: Int = 0

    public init(name: String, directory: String? = nil, options: Options = Options()) {
        let root: String = directory ?? NSSearchPathForDirectoriesInDomains(.CachesDirectory, .UserDomainMask, true).first! as! String
        let fileManager = NSFileManager.defaultManager()

        self.options = options
        self.root = root.stringByAppendingPathComponent("\(name).cache")

        fileManager.createDirectoryAtPath(self.root, withIntermediateDirectories: true, attributes: nil, error: nil)

        for file in contentsOfDirectoryAtPath(self.root) {
            let path = self.root.stringByAppendingPathComponent(file)
            if let attr = fileManager.attributesOfItemAtPath(path, error: nil) {
                let ctime = attr[NSFileCreationDate] as! NSDate
                let size = attr[NSFileSize] as! NSNumber

                self.diskSize += size.integerValue

                let key = keyForPath(file.lastPathComponent)
                metadata[key] = CacheEntry(key: key, ctime: ctime.timeIntervalSince1970, size: size.integerValue)
            }
        }

        self.maybePurge()

#if os(iOS)
        let notifications = NSNotificationCenter.defaultCenter().addObserverForName(UIApplicationDidReceiveMemoryWarningNotification,
            object: nil,
            queue: NSOperationQueue.mainQueue(),
            usingBlock: {notification in self.onMemoryWarning() })
#endif
    }

    // All cached keys.
    public var keys: [String] {
        var out: [String] = []
        dispatch_sync(queue, { out = self.metadata.keys.array.sorted({a, b in a < b}) })
        return out
    }

    // All in-memory keys.
    public var residentKeys: [String] {
        var out: [String] = []
        dispatch_sync(queue, { out = self.cache.keys.array.sorted({a, b in a < b}) })
        return out
    }

    // Get an object from the cache.
    public func get<T: Cacheable>(key: String) -> T? {
        var value: T?
        dispatch_sync(queue, {
            if let v = self.cache[key] {
                value = v as? T
            } else if let entry = self.metadata[key], let data = NSData(contentsOfFile: self.pathForKey(key)) {
                value = T.decodeFromCache(data) as? T
                if value != nil {
                    self.cache[key] = value!
                    self.memorySize += entry.size
                }
            }
        })
        return value
    }

    // Set a value in the cache.
    public func set<T: Cacheable>(key: String, value: T) {
        dispatch_sync(queue, {
            let data = value.encodeForCache()
            let path = self.pathForKey(key)
            data.writeToFile(path, atomically: true)
            self.setValueWithPath(key, value: value, path: path, size: data.length)
        })
    }

    // Delete a key from the cache.
    public func delete(key: String) {
        dispatch_sync(queue, {
            self.purgeKey(key)
        })
    }

    // Delete everything from the cache.
    public func deleteAll() {
        dispatch_sync(queue, {
            self.purgeCache()
            NSFileManager.defaultManager().createDirectoryAtPath(self.root, withIntermediateDirectories: true, attributes: nil, error: nil)

        })
    }

    // As with deleteAll(), but also remove the cache root itself.
    // The cache is not usable after this call.
    public func invalidate() {
        dispatch_sync(queue, {
            self.purgeCache()
        })
    }

    private func setValueWithPath<T>(key: String, value: T, path: String, size: Int) {
        // Update bookkeeping.
        if let entry = self.metadata[key] {
            self.diskSize -= entry.size
            if self.cache[key] != nil {
                self.memorySize -= entry.size
            }
        }

        self.cache[key] = value
        let entry = CacheEntry(key: key, ctime: NSDate().timeIntervalSince1970, size: size)
        self.metadata[key] = entry

        self.memorySize += entry.size
        self.diskSize += entry.size

        self.maybePurge()
    }

    private func purgeKey(key: String) {
        if let entry = self.metadata[key] {
            if self.cache.removeValueForKey(key) != nil {
                self.memorySize -= entry.size
            }
            self.metadata.removeValueForKey(key)
            let path = self.pathForKey(key)
            NSFileManager.defaultManager().removeItemAtPath(path, error: nil)
            self.diskSize -= entry.size
        }
    }
    
    private func purgeCache() {
        NSFileManager.defaultManager().removeItemAtPath(self.root, error: nil)
        self.metadata = [:]
        self.cache = [:]
        self.memorySize = 0
        self.diskSize = 0
    }

    private func onMemoryWarning() {
        dispatch_sync(queue) {
            self.cache = [:]
            self.memorySize = 0
        }
    }

    // Must be called in the lock queue.
    private func maybePurge() {
        if memorySize > options.memoryByteLimit || diskSize > options.diskByteLimit {
            let entries = self.metadata.values.array.sorted({(a, b) in
                self.options.costFunction(a) < self.options.costFunction(b)
            })
            for entry in entries {
                if diskSize > options.diskByteLimit {
                    purgeKey(entry.key)
                } else if memorySize > options.memoryByteLimit {
                    cache.removeValueForKey(entry.key)
                    memorySize -= entry.size
                } else {
                    break
                }
            }
        }
    }

    private func pathForKey(key: String) -> String {
        let last = key.dataUsingEncoding(NSUTF8StringEncoding)!.base64EncodedStringWithOptions(
            NSDataBase64EncodingOptions.allZeros)
        return root.stringByAppendingPathComponent(last)
     }

    private func keyForPath(path: String) -> String {
        let data = NSData(base64EncodedString: path.lastPathComponent, options: NSDataBase64DecodingOptions.allZeros)!
        return NSString(data: data, encoding: NSUTF8StringEncoding)! as! String
    }

    private func contentsOfDirectoryAtPath(path: String) -> [String] {
        var error: NSError? = nil
        let fileManager = NSFileManager.defaultManager()
        if let contents = fileManager.contentsOfDirectoryAtPath(path, error: &error) {
            if let filenames = contents as? [String] {
                return filenames
            }
        }
        return []
    }

}

extension String: Cacheable {
    public func encodeForCache() -> NSData {
        return self.dataUsingEncoding(NSUTF8StringEncoding)!
    }

    public static func decodeFromCache(data: NSData) -> Any? {
        return NSString(data: data, encoding: NSUTF8StringEncoding)
    }
}

extension Int: Cacheable {
    public func encodeForCache() -> NSData {
        var n = self
        return NSData(bytes: &n, length: sizeof(Int))
    }

    public static func decodeFromCache(data: NSData) -> Any? {
        return 1
    }
}

extension NSCoder: Cacheable {
    public func encodeForCache() -> NSData {
        var data = NSMutableData()
        let archiver = NSKeyedArchiver(forWritingWithMutableData: data)
        archiver.encodeObject(self)
        archiver.finishEncoding()
        return data
    }

    public static func decodeFromCache(data: NSData) -> Any? {
        return NSKeyedUnarchiver(forReadingWithData: data).decodeObject()
    }
}


extension NSData: Cacheable {
    public func encodeForCache() -> NSData {
        return self
    }

    public static func decodeFromCache(data: NSData) -> Any? {
        return data
    }
}