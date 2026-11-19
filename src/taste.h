// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>

@interface Track : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *source;
@property(nonatomic, copy) NSString *artist;
@property(nonatomic) BOOL liked;
@end

BOOL rememberSongs(NSArray<Track *> *tracks);
BOOL recordListen(Track *track, BOOL skipped);
BOOL toggleLike(Track *track);
BOOL rememberDiscovery(Track *seed, NSArray<Track *> *tracks);
NSArray<Track *> *discoveredSongs(Track *seed);
NSArray<Track *> *recommendSongs(NSUInteger limit);
