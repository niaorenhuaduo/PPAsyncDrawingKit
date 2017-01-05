//
//  PPImageCache.m
//  PPAsyncDrawingKit
//
//  Created by DSKcpp on 2016/11/23.
//  Copyright © 2016年 DSKcpp. All rights reserved.
//

#import "PPImageCache.h"
#import <CommonCrypto/CommonCrypto.h>
#import "PPImage.h"

#define kPPImageCacheMaxAge 604800.0f // 7 day
#define kPPImageCacheMaxMemorySize 20971520 // 20 MB

static NSString *_PPNSStringMD5(NSString *string) {
    if (!string) return nil;
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, result);
    return [NSString stringWithFormat:
            @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            result[0],  result[1],  result[2],  result[3],
            result[4],  result[5],  result[6],  result[7],
            result[8],  result[9],  result[10], result[11],
            result[12], result[13], result[14], result[15]
            ];
}

@interface PPImageCache ()
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *cache;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, strong) NSRecursiveLock *readingTaskLock;
@property (nonatomic, strong) NSDate *createDate;
@property (nonatomic, strong) NSMutableDictionary *memoryMutableDict;
@property (nonatomic, strong) NSArray *resourceKeys;
@end

@implementation PPImageCache
+ (PPImageCache *)sharedCache
{
    static PPImageCache *_sharedCache;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        _sharedCache = [[self alloc] init];
    });
    return _sharedCache;
}

- (instancetype)init
{
    if (self = [super init]) {
        NSString *name = @"io.github.dskcpp.PPAsyncDrawingKit.imageCache";
        _cache = [[NSCache alloc] init];
        _cache.name = name;
        _maxCacheAge = kPPImageCacheMaxAge;
        _maxMemorySize = kPPImageCacheMaxMemorySize;
        _createDate = [NSDate date];
        _memoryMutableDict = [NSMutableDictionary dictionaryWithCapacity:2];
        _cachePath = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"ImageCache"];
        _ioQueue = dispatch_queue_create("io.github.dskcpp.PPAsyncDrawingKit.imageCache.ioQueue", DISPATCH_QUEUE_SERIAL);
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:_cachePath]) {
            [fileManager createDirectoryAtPath:_cachePath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        
        _readingTaskLock = [[NSRecursiveLock alloc] init];
        _currentReadingTaskKeys = [NSMutableArray array];
        _resourceKeys = @[NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLFileAllocatedSizeKey];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
//        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(checkAndAutoClean) name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)receiveMemoryWarning:(NSNotification *)notification
{
    [self cleanMemoryCache];
}

- (NSString *)keyWithURL:(NSString *)URL
{
    if (URL.length) {
        return _PPNSStringMD5(URL);
    }
    return nil;
}

- (NSString *)cachePathForKey:(NSString *)key
{
    return [_cachePath stringByAppendingPathComponent:key];
}

- (UIImage *)imageForURL:(NSString *)URL
{
    return [self imageForURL:URL taskKey:nil];
}

- (UIImage *)imageForURL:(NSString *)URL taskKey:(NSString *)taskKey
{
    [self.readingTaskLock lock];
    BOOL taskConstains = [self.currentReadingTaskKeys containsObject:taskKey];
    [self.readingTaskLock unlock];
    
    if ((!URL || taskKey) && !taskConstains) {
//        [self removeFromCurrentReadingTaskKeys:taskKey];
    }

    BOOL cache = [self imageCachedForURL:URL];
    if (cache) {
        NSString *key = [self keyWithURL:URL];
        UIImage *image = [_cache objectForKey:key];
        if (!image) {
            image = [UIImage imageWithContentsOfFile:[self cachePathForKey:key]];
        }
        return image;
    }
    return nil;
}

- (void)imageForURL:(NSString *)URL callback:(nonnull void (^)(UIImage * _Nullable, PPImageCacheType))callback
{
    if (!callback) {
        return;
    }
    NSString *key = [self keyWithURL:URL];
    UIImage *image = [_cache objectForKey:key];
    if (image) {
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(image, PPImageCacheTypeMemory);
        });
    } else {
        dispatch_async(_ioQueue, ^{
            UIImage *image = [PPImage imageWithContentsOfFile:[self cachePathForKey:key]];
            if (image) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    callback(image, PPImageCacheTypeDisk);
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    callback(nil, PPImageCacheTypeNone);
                });
            }
        });
    }
}

- (BOOL)imageCachedForURL:(NSString *)URL
{
    NSString *key = [self keyWithURL:URL];
    UIImage *image = [_cache objectForKey:key];
    if (image) {
        return YES;
    } else {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        return [fileManager fileExistsAtPath:[self cachePathForKey:key]];
    }
}

- (BOOL)imageHasDiskCachedForURL:(NSString *)URL
{
    NSString *key = [self keyWithURL:URL];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    return [fileManager fileExistsAtPath:[self cachePathForKey:key]];
}

- (NSString *)diskCachePathForImageURL:(NSString *)imageURL
{
    return [self cachePathForKey:[self keyWithURL:imageURL]];
}

- (void)storeImage:(UIImage *)image forURL:(NSString *)URL
{
    if (!image || !URL) {
        return;
    }
    NSString *key = [self keyWithURL:URL];
    NSUInteger cost = image.size.height * image.size.width;
    if (cost <= 1024 * 1024) {
        [_cache setObject:image forKey:key cost:cost];
    }
}

- (void)storeImage:(UIImage *)image data:(NSData *)data forURL:(NSString *)URL toDisk:(BOOL)toDisk
{
    if (!URL) {
        return;
    }
    
    if (image) {
        [self storeImage:image forURL:URL];
    }
    if (toDisk) {
        NSData *_data = data;
        if (_data == nil) {
            if (!image) {
                return;
            }
            _data = UIImageJPEGRepresentation(image, 1.0);
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self storeImageDataToDisk:_data forURL:URL];
        });
    }
}

- (void)storeImageDataToDisk:(NSData *)imageData forURL:(NSString *)URL;
{
    if (!imageData || !URL) {
        return;
    }

    dispatch_async(_ioQueue, ^{
        NSFileManager *fileManager = [[NSFileManager alloc] init];
        NSString *path = _cachePath;
        if (![fileManager fileExistsAtPath:path]) {
            [fileManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        }
        path = [self cachePathForKey:[self keyWithURL:URL]];
        [fileManager createFileAtPath:path contents:imageData attributes:nil];
    });
}

- (void)addToCurrentReadingTaskKeys:(NSString *)TaskKeys
{
    [_readingTaskLock lock];
    [_currentReadingTaskKeys addObject:TaskKeys];
    [_readingTaskLock unlock];
}

- (void)removeFromCurrentReadingTaskKeys:(NSString *)TaskKeys
{
    [_readingTaskLock lock];
    [_currentReadingTaskKeys removeObject:TaskKeys];
    [_readingTaskLock unlock];
}

- (NSUInteger)cacheSize
{
    __block NSUInteger totalCacheSize = 0;
    dispatch_sync(_ioQueue, ^{
        NSDirectoryEnumerator<NSString *> *files = [[NSFileManager defaultManager] enumeratorAtPath:_cachePath];
        for (NSString *fileName in files) {
            NSString *filePath = [self cachePathForKey:fileName];
            NSDictionary<NSFileAttributeKey, id> * attr = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
            totalCacheSize += [attr fileSize];
        }
    });
    return totalCacheSize;
}

- (void)cleanDiskCache
{
    dispatch_async(_ioQueue, ^{
        NSFileManager *fileManager = [[NSFileManager alloc] init];
        [fileManager removeItemAtPath:_cachePath error:nil];
        [fileManager createDirectoryAtPath:_cachePath withIntermediateDirectories:YES attributes:nil error:nil];
    });
}

- (void)cleanMemoryCache
{
    [_cache removeAllObjects];
}
@end
