// SPDX-License-Identifier: MIT
#define _XOPEN_SOURCE_EXTENDED 1
#import <AVFoundation/AVFoundation.h>
#import "taste.h"
#include <curses.h>
#include <locale.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <wchar.h>
#include <wctype.h>

typedef NS_ENUM(int, Tab) { MusicTab, VideosTab, OpenTab, QueueTab, ForYouTab };
typedef NS_ENUM(int, Action) {
    SelectMusic, SelectVideos, SelectOpen, SelectQueue, SelectForYou, Find, PlaySelection,
    AddSelection, RemoveSelection, LikeSelection, DiscoverSelection, Back, Pause, Forward, Next, Stop,
    ToggleAutoplay, ToggleLoop, Quit
};
enum { MousePrefix = KEY_MAX + 1, FirstRow = 7, MinWidth = 58, MinHeight = 17, AmberPair = 1, RecentMusicLimit = 32 };

typedef struct { int y, x, width; Action action; } Hit;

static void restoreScreen(void) {
    fputs("\033[?1000l\033[?1006l", stdout);
    fflush(stdout);
    endwin();
}

// Clip by terminal columns, including double-width characters in track names.
static int putText(int y, int x, int width, NSString *text) {
    const char *cursor = text.UTF8String;
    if (!cursor || width <= 0) return 0;
    wchar_t visible[1024];
    mbstate_t state = {0};
    int columns = 0, length = 0;
    while (*cursor && length < (int)(sizeof visible / sizeof *visible) - 1) {
        wchar_t character;
        size_t bytes = mbrtowc(&character, cursor, MB_CUR_MAX, &state);
        if (bytes == (size_t)-1 || bytes == (size_t)-2) break;
        cursor += bytes;
        if (iswcntrl(character)) character = L' ';
        int cells = wcwidth(character);
        if (cells < 0) continue;
        if (columns + cells > width) break;
        visible[length++] = character;
        columns += cells;
    }
    visible[length] = L'\0';
    mvaddnwstr(y, x, visible, length);
    return columns;
}

static NSString *clockLabel(double seconds) {
    if (!isfinite(seconds) || seconds < 0) return @"--:--";
    long whole = (long)seconds;
    return [NSString stringWithFormat:@"%ld:%02ld", whole / 60, whole % 60];
}

static BOOL isWebSource(NSString *source) {
    return [source hasPrefix:@"https://"] || [source hasPrefix:@"http://"];
}

static BOOL usesLightTheme(void) {
    const char *theme = getenv("YTM_THEME");
    if (theme && strcmp(theme, "light") == 0) return YES;
    if (theme && strcmp(theme, "dark") == 0) return NO;

    const char *colors = getenv("COLORFGBG");
    const char *background = colors ? strrchr(colors, ';') : NULL;
    if (background && (strcmp(background + 1, "7") == 0 || strcmp(background + 1, "15") == 0)) return YES;
    if (background && (strcmp(background + 1, "0") == 0 || strcmp(background + 1, "8") == 0)) return NO;

    NSString *appearance = [NSUserDefaults.standardUserDefaults stringForKey:@"AppleInterfaceStyle"];
    return ![appearance isEqualToString:@"Dark"];
}

static NSArray<Track *> *tracksFromOutput(NSString *output, BOOL music, NSUInteger limit) {
    NSMutableArray<Track *> *tracks = [NSMutableArray arrayWithCapacity:limit];
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        if (tracks.count == limit) break;
        NSArray<NSString *> *fields = [line componentsSeparatedByString:@"\t"];
        if (fields.count < 2 || fields[0].length != 11 || !fields[1].length) continue;
        Track *track = [Track new];
        track.source = [@"https://www.youtube.com/watch?v=" stringByAppendingString:fields[0]];
        track.title = fields[1];
        if (music && fields.count == 3) track.artist = fields[2];
        [tracks addObject:track];
    }
    return tracks;
}

@interface TerminalPlayer : NSObject {
    Hit _hits[20];
    int _hitCount, _scrubWidth;
    char _mouse[48];
    int _mouseLength;
    BOOL _readingMouse;
}
@property(nonatomic, copy) NSString *launcher;
@property(nonatomic) Tab tab;
@property(nonatomic) BOOL editing, searching, resolving, paused, hasStarted, recordedListen, autoplay, loopTrack;
@property(nonatomic) NSUInteger selected, offset, caret;
@property(nonatomic) NSTimeInterval openedAt, lastClick;
@property(nonatomic) NSTimeInterval listenedSeconds, lastListenTick;
@property(nonatomic) NSUInteger lastClickRow;
@property(nonatomic, strong) NSMutableString *query;
@property(nonatomic, strong) NSArray<Track *> *songs, *videos, *recommendations;
@property(nonatomic, strong) NSMutableArray<Track *> *queue;
@property(nonatomic, strong) NSMutableOrderedSet<NSString *> *recentMusic;
@property(nonatomic, strong) Track *current, *discoverySeed;
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, strong) NSTask *searchTask, *resolveTask, *discoverTask;
@property(nonatomic, strong) dispatch_source_t tick;
@property(nonatomic, copy) NSString *notice;
- (void)draw;
- (void)readInput;
- (void)pollPlayback;
- (void)advanceManually:(BOOL)manual;
- (void)clearPlayback:(NSString *)notice;
@end

@implementation TerminalPlayer

- (NSArray<Track *> *)rows {
    switch (self.tab) {
        case MusicTab: return self.songs;
        case VideosTab: return self.videos;
        case QueueTab: return self.queue;
        case ForYouTab: return self.recommendations;
        case OpenTab: return @[];
    }
}

- (int)button:(NSString *)label action:(Action)action y:(int)y x:(int)x active:(BOOL)active {
    attr_t style = active ? A_REVERSE | A_BOLD : A_NORMAL;
    if (active && action <= SelectForYou) style |= COLOR_PAIR(AmberPair);
    if (style) attron(style);
    int width = putText(y, x, COLS - x - 1, [NSString stringWithFormat:@"[ %@ ]", label]);
    if (style) attroff(style);
    if (width && _hitCount < (int)(sizeof _hits / sizeof *_hits)) {
        _hits[_hitCount++] = (Hit){y, x, width, action};
    }
    return x + width + 1;
}

- (void)draw {
    erase();
    _hitCount = 0;
    _scrubWidth = 0;
    if (COLS < MinWidth || LINES < MinHeight) {
        putText(0, 0, COLS - 1, @"Resize to 58 columns × 17 rows, or Esc to quit.");
        curs_set(0);
        refresh();
        return;
    }

    attron(A_BOLD);
    putText(0, 2, COLS - 4, @"ytm");
    attroff(A_BOLD);
    [self button:@"Quit" action:Quit y:0 x:COLS - 10 active:NO];
    int x = [self button:@"Music" action:SelectMusic y:2 x:2 active:self.tab == MusicTab];
    x = [self button:@"Videos" action:SelectVideos y:2 x:x active:self.tab == VideosTab];
    x = [self button:@"Open" action:SelectOpen y:2 x:x active:self.tab == OpenTab];
    x = [self button:[NSString stringWithFormat:@"Queue %lu", (unsigned long)self.queue.count]
          action:SelectQueue y:2 x:x active:self.tab == QueueTab];
    [self button:@"For You" action:SelectForYou y:2 x:x active:self.tab == ForYouTab];

    int cursorX = 0;
    if (self.tab < QueueTab) {
        NSString *label = self.tab == OpenTab ? @"Link or file" : @"Query";
        x = [self button:label action:Find y:4 x:2 active:self.editing];
        NSUInteger start = 0;
        int available = COLS - x - 14;
        // Keep the caret visible for long URLs and mixed-width names.
        while (self.caret - start > (NSUInteger)MAX(1, (available - 1) / 2)) {
            NSUInteger next = NSMaxRange([self.query rangeOfComposedCharacterSequenceAtIndex:start]);
            if (next > self.caret) break;
            start = next;
        }
        NSString *visible = [self.query substringFromIndex:start];
        if (self.editing) attron(A_UNDERLINE);
        putText(4, x, available, visible);
        if (self.editing) attroff(A_UNDERLINE);
        if (self.editing) {
            NSString *before = [self.query substringWithRange:NSMakeRange(start, self.caret - start)];
            cursorX = x + putText(4, x, available - 1, before);
        }
        [self button:self.tab == OpenTab ? @"Play" : @"Search" action:Find y:4 x:COLS - 12 active:NO];
    } else if (self.discoverySeed) {
        putText(4, 2, COLS - 18, [@"Related to " stringByAppendingString:self.discoverySeed.title]);
        [self button:@"All picks" action:SelectForYou y:4 x:COLS - 14 active:NO];
    }

    int actionsY = LINES - 8;
    NSArray<Track *> *rows = self.rows;
    int height = actionsY - FirstRow;
    if (self.selected < self.offset) self.offset = self.selected;
    if (self.selected >= self.offset + (NSUInteger)height) self.offset = self.selected - height + 1;
    attron(A_BOLD);
    NSArray *headings = @[@"RESULTS", @"RESULTS", @"OPEN AUDIO", @"UP NEXT", @"FOR YOU"];
    putText(6, 2, COLS - 4, self.discoverySeed ? @"RELATED TRACKS" : headings[self.tab]);
    attroff(A_BOLD);
    for (int row = 0; row < height && self.offset + row < rows.count; row++) {
        NSUInteger index = self.offset + row;
        BOOL selected = index == self.selected;
        if (selected) attron(A_REVERSE);
        mvhline(FirstRow + row, 2, ' ', COLS - 4);
        putText(FirstRow + row, 2, COLS - 4,
                [NSString stringWithFormat:@" %@  %@", selected ? @">" : @" ", rows[index].title]);
        if (selected) attroff(A_REVERSE);
    }
    if (!rows.count) {
        NSString *empty = self.tab == QueueTab ? @"Add a track from search results." :
            (self.tab == OpenTab ? @"Paste a YouTube link or enter a local audio or video path." : @"Search for a title or artist.");
        if (self.tab == ForYouTab) empty = @"Search for a song or artist to get started.";
        if (self.discoverySeed) empty = self.discoverTask ? @"Finding related tracks..." : @"No related tracks to show.";
        putText(FirstRow, 2, COLS - 4, self.searching && self.tab < OpenTab ? @"Searching..." : empty);
        if (self.tab == ForYouTab && !self.discoverySeed) {
            [self button:@"Search Music" action:SelectMusic y:actionsY x:2 active:NO];
        }
    } else {
        Track *selected = rows[self.selected];
        x = [self button:selected.artist.length ? @"Play" : @"Play selected" action:PlaySelection y:actionsY x:2 active:NO];
        x = [self button:self.tab == QueueTab ? @"Remove" : @"Add to queue"
              action:self.tab == QueueTab ? RemoveSelection : AddSelection y:actionsY x:x active:NO];
        if (selected.artist.length) {
            x = [self button:selected.liked ? @"Unlike" : @"Like" action:LikeSelection y:actionsY x:x active:NO];
            [self button:@"Discover" action:DiscoverSelection y:actionsY x:x active:NO];
        }
    }
    putText(LINES - 7, 2, COLS - 4, self.notice);
    mvhline(LINES - 6, 2, ACS_HLINE, COLS - 4);

    AVPlayerItem *item = self.player.currentItem;
    double elapsed = item ? CMTimeGetSeconds(self.player.currentTime) : NAN;
    double duration = item ? CMTimeGetSeconds(item.duration) : NAN;
    NSString *state = @"Idle";
    if (self.resolving) state = @"Opening";
    else if (item) state = self.paused ? @"Paused" :
        (self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying ? @"Playing" : @"Buffering");
    attr_t stateStyle = A_BOLD;
    if ([state isEqualToString:@"Playing"]) stateStyle |= COLOR_PAIR(AmberPair);
    attron(stateStyle);
    putText(LINES - 5, 2, 10, state);
    attroff(stateStyle);
    putText(LINES - 5, 13, COLS - 15, self.current.title);
    NSString *times = [NSString stringWithFormat:@"%@ / %@", clockLabel(elapsed), clockLabel(duration)];
    _scrubWidth = COLS - (int)times.length - 6;
    mvhline(LINES - 4, 2, ACS_HLINE, _scrubWidth);
    if (isfinite(elapsed) && isfinite(duration) && duration > 0) {
        int played = (int)(fmin(1, fmax(0, elapsed / duration)) * (_scrubWidth - 1));
        attron(A_BOLD | COLOR_PAIR(AmberPair));
        mvhline(LINES - 4, 2, ACS_HLINE, played);
        mvaddch(LINES - 4, 2 + played, ACS_DIAMOND);
        attroff(A_BOLD | COLOR_PAIR(AmberPair));
    }
    putText(LINES - 4, _scrubWidth + 4, (int)times.length, times);

    x = [self button:@"-10s" action:Back y:LINES - 3 x:2 active:NO];
    x = [self button:self.paused ? @"Resume" : @"Pause" action:Pause y:LINES - 3 x:x active:NO];
    x = [self button:@"+10s" action:Forward y:LINES - 3 x:x active:NO];
    x = [self button:@"Next" action:Next y:LINES - 3 x:x active:NO];
    [self button:@"Stop" action:Stop y:LINES - 3 x:x active:NO];
    x = [self button:self.autoplay ? @"Autoplay on" : @"Autoplay off" action:ToggleAutoplay y:LINES - 2 x:2 active:self.autoplay];
    [self button:self.loopTrack ? @"Loop on" : @"Loop off" action:ToggleLoop y:LINES - 2 x:x active:self.loopTrack];
    putText(LINES - 1, 2, COLS - 4, @"Tab view  / focus  Enter select  a add  Space pause  q quit");
    curs_set(cursorX ? 1 : 0);
    if (cursorX) move(4, cursorX);
    refresh();
}

- (void)switchTo:(Tab)tab {
    if (self.discoverTask.running) [self.discoverTask terminate];
    self.discoverTask = nil;
    self.discoverySeed = nil;
    self.tab = tab;
    self.selected = self.offset = 0;
    [self.query setString:@""];
    self.caret = 0;
    self.editing = tab < QueueTab;
    self.notice = @"";
    self.recommendations = tab == ForYouTab ? recommendSongs(20) : nil;
}

- (void)reloadRecommendations {
    if (self.tab != ForYouTab) return;
    NSString *source = self.selected < self.recommendations.count ? self.recommendations[self.selected].source : nil;
    NSArray<Track *> *tracks = self.discoverySeed ? discoveredSongs(self.discoverySeed) : recommendSongs(20);
    if (self.discoverySeed && !tracks.count) return;
    self.recommendations = tracks;
    NSUInteger index = [self.recommendations indexOfObjectPassingTest:^BOOL(Track *track, __unused NSUInteger i, __unused BOOL *stop) {
        return [track.source isEqualToString:source];
    }];
    self.selected = index == NSNotFound ? 0 : index;
}

- (NSTask *)request:(NSArray<NSString *> *)arguments completion:(void (^)(NSTask *, NSString *))completion {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:self.launcher];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardOutput = pipe;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:NULL]) return nil;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        NSString *output = task.terminationStatus == 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(task, output); });
    });
    return task;
}

- (void)submit {
    NSString *text = [self.query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length || self.tab >= QueueTab) return;
    self.editing = NO;
    if (self.tab == OpenTab) {
        Track *track = [Track new];
        BOOL online = isWebSource(text);
        track.source = online ? text : [text stringByExpandingTildeInPath];
        track.title = online ? @"YouTube link" : text.lastPathComponent;
        [self start:track];
        return;
    }

    if (self.searchTask.running) [self.searchTask terminate];
    Tab tab = self.tab;
    self.searching = YES;
    self.notice = @"Searching...";
    __weak TerminalPlayer *weakSelf = self;
    self.searchTask = [self request:@[@"--search", tab == MusicTab ? @"song" : @"video", text]
                         completion:^(NSTask *task, NSString *output) {
        TerminalPlayer *ui = weakSelf;
        if (ui.searchTask != task) return;
        ui.searchTask = nil;
        ui.searching = NO;
        NSArray<Track *> *tracks = tracksFromOutput(output, tab == MusicTab, 10);
        if (tab == MusicTab) {
            ui.songs = tracks;
            if (rememberSongs(tracks)) [ui reloadRecommendations];
        }
        else ui.videos = tracks;
        if (ui.tab == tab) {
            ui.selected = ui.offset = 0;
            ui.notice = !output ? @"Search failed. Try again." :
                (tracks.count ? @"" : @"No results. Try another search.");
        }
        [ui draw];
    }];
    if (!self.searchTask) {
        self.searching = NO;
        self.notice = @"Could not start search.";
    }
}

- (void)discoverSelected {
    NSArray<Track *> *rows = self.rows;
    if (self.selected >= rows.count || !rows[self.selected].artist.length) return;
    Track *seed = rows[self.selected];
    NSURLComponents *link = [NSURLComponents componentsWithString:seed.source];
    NSString *videoID = nil;
    for (NSURLQueryItem *item in link.queryItems) {
        if ([item.name isEqualToString:@"v"]) { videoID = item.value; break; }
    }
    if (videoID.length != 11) return;

    [self switchTo:ForYouTab];
    self.discoverySeed = seed;
    self.recommendations = discoveredSongs(seed);
    if (self.recommendations.count) return;

    __weak TerminalPlayer *weakSelf = self;
    self.discoverTask = [self request:@[@"--discover", videoID] completion:^(NSTask *task, NSString *output) {
        TerminalPlayer *ui = weakSelf;
        if (ui.discoverTask != task) return;
        ui.discoverTask = nil;
        NSArray<Track *> *tracks = tracksFromOutput(output, YES, 20);
        if (!output || !tracks.count) {
            ui.notice = output ? @"YouTube Music did not return any related tracks." : @"Could not look up related tracks. Try again from Music.";
        } else if (rememberDiscovery(seed, tracks)) {
            NSArray<Track *> *cached = discoveredSongs(seed);
            ui.recommendations = cached.count ? cached : tracks;
        } else {
            ui.recommendations = tracks;
            ui.notice = @"Could not save this mix to the local cache.";
        }
        ui.selected = ui.offset = 0;
        [ui draw];
    }];
    if (!self.discoverTask) self.notice = @"Could not start Discover.";
}

- (void)installItem:(NSURL *)url hls:(BOOL)hls {
    NSDictionary *options = hls ? @{AVURLAssetOverrideMIMETypeKey: @"application/vnd.apple.mpegurl"} : nil;
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:[AVURLAsset URLAssetWithURL:url options:options]];
    if (hls) item.preferredForwardBufferDuration = 5;
    if (!self.player) {
        self.player = [AVPlayer new];
        const char *mute = getenv("YTM_MUTE");
        self.player.muted = mute && strcmp(mute, "1") == 0;
    }
    [self.player replaceCurrentItemWithPlayerItem:item];
    self.openedAt = NSProcessInfo.processInfo.systemUptime;
    self.lastListenTick = self.openedAt;
    self.listenedSeconds = 0;
    self.recordedListen = NO;
    self.paused = self.hasStarted = NO;
    if (self.current.artist.length) {
        [self.recentMusic removeObject:self.current.source];
        [self.recentMusic addObject:self.current.source];
        if (self.recentMusic.count > RecentMusicLimit) [self.recentMusic removeObjectAtIndex:0];
    }
    [self.player play];
    dispatch_source_set_timer(self.tick, DISPATCH_TIME_NOW, NSEC_PER_SEC / 2, NSEC_PER_MSEC * 75);
}

- (void)start:(Track *)track {
    if (!track) return;
    if (self.resolveTask.running) [self.resolveTask terminate];
    self.resolveTask = nil;
    self.resolving = NO;
    [self.player replaceCurrentItemWithPlayerItem:nil];
    dispatch_source_set_timer(self.tick, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    self.current = track;
    self.notice = @"";
    if (!isWebSource(track.source)) {
        [self installItem:[NSURL fileURLWithPath:track.source] hls:NO];
        return;
    }

    self.resolving = YES;
    __weak TerminalPlayer *weakSelf = self;
    self.resolveTask = [self request:@[@"--resolve", track.source] completion:^(NSTask *task, NSString *output) {
        TerminalPlayer *ui = weakSelf;
        if (ui.resolveTask != task) return;
        ui.resolveTask = nil;
        ui.resolving = NO;
        NSArray<NSString *> *lines = [[output stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsSeparatedByString:@"\n"];
        NSURL *url = [NSURL URLWithString:lines.lastObject ?: @""];
        if (lines.count != 2 || ![url.scheme isEqualToString:@"https"]) {
            [ui clearPlayback:@"No compatible audio stream. Try the link with ytm play."];
            return;
        }
        if (!ui.current.artist.length) ui.current.title = lines.firstObject;
        [ui installItem:url hls:YES];
        [ui draw];
    }];
    if (!self.resolveTask) [self clearPlayback:@"Could not open the link."];
}

- (void)clearPlayback:(NSString *)notice {
    if (self.resolveTask.running) [self.resolveTask terminate];
    self.resolveTask = nil;
    [self.player replaceCurrentItemWithPlayerItem:nil];
    self.player = nil;
    self.current = nil;
    self.resolving = NO;
    self.paused = NO;
    self.notice = notice;
    dispatch_source_set_timer(self.tick, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    [self draw];
}

- (void)playSelected {
    NSArray<Track *> *rows = self.rows;
    if (self.selected >= rows.count) return;
    Track *track = rows[self.selected];
    if (self.tab == QueueTab) [self removeSelected];
    if (![track.source isEqualToString:self.current.source]) [self recordEarlySkip];
    [self start:track];
}

- (void)recordEarlySkip {
    if (!self.recordedListen && self.listenedSeconds >= 3 && self.current.artist.length) {
        if (recordListen(self.current, YES)) [self reloadRecommendations];
        self.recordedListen = YES;
    }
}

- (void)removeSelected {
    if (self.tab != QueueTab || self.selected >= self.queue.count) return;
    [self.queue removeObjectAtIndex:self.selected];
    if (self.selected && self.selected == self.queue.count) self.selected--;
}

- (void)loopCurrentTrack {
    AVPlayer *player = self.player;
    AVPlayerItem *item = player.currentItem;
    self.paused = NO;
    self.recordedListen = YES;
    __weak TerminalPlayer *weakSelf = self;
    [player seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            TerminalPlayer *ui = weakSelf;
            if (ui.player != player || player.currentItem != item) return;
            if (!finished) return;
            if (!ui.paused) [player play];
        });
    }];
}

- (Track *)nextRecommendation {
    NSArray<Track *> *related = discoveredSongs(self.current);
    for (Track *track in related) {
        if (![self.recentMusic containsObject:track.source]) return track;
    }
    for (Track *track in recommendSongs(self.recentMusic.count + 1)) {
        if (![self.recentMusic containsObject:track.source]) return track;
    }
    return nil;
}

- (void)advanceManually:(BOOL)manual {
    if (!manual && self.loopTrack && self.player.currentItem) {
        [self loopCurrentTrack];
        return;
    }
    Track *track = self.queue.firstObject;
    BOOL fromQueue = track != nil;
    if (!track && self.autoplay && self.current.artist.length) track = [self nextRecommendation];
    if (!track) {
        NSString *message = self.autoplay && self.current.artist.length ? @"No fresh picks. Search Music or try Discover." : @"Queue is empty.";
        if (manual) self.notice = message;
        else [self clearPlayback:self.autoplay && self.current.artist.length ? message : @"Playback finished."];
        return;
    }
    if (fromQueue) {
        [self.queue removeObjectAtIndex:0];
        if (self.tab == QueueTab && self.selected && self.selected >= self.queue.count) self.selected--;
    }
    if (manual && ![track.source isEqualToString:self.current.source]) [self recordEarlySkip];
    [self start:track];
}

- (void)pollPlayback {
    AVPlayerItem *item = self.player.currentItem;
    if (!item) return;
    double seconds = CMTimeGetSeconds(self.player.currentTime);
    if (isfinite(seconds) && seconds > 0) self.hasStarted = YES;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!self.recordedListen && self.current.artist.length && self.hasStarted &&
        self.player.timeControlStatus == AVPlayerTimeControlStatusPlaying) {
        self.listenedSeconds += fmin(1, now - self.lastListenTick);
        double duration = CMTimeGetSeconds(item.duration);
        double threshold = isfinite(duration) && duration > 0 ? fmin(30, duration / 2) : 30;
        if (self.listenedSeconds >= threshold) {
            self.recordedListen = YES;
            if (recordListen(self.current, NO)) [self reloadRecommendations];
        }
    }
    self.lastListenTick = now;
    if (item.status == AVPlayerItemStatusFailed || self.player.status == AVPlayerStatusFailed) {
        [self clearPlayback:item.error.localizedDescription ?: @"Could not play this source."];
    } else if (!self.hasStarted && !self.paused && NSProcessInfo.processInfo.systemUptime - self.openedAt > 15) {
        [self clearPlayback:@"Playback timed out. Try this source with ytm play."];
    } else {
        [self draw];
    }
}

- (void)seekTo:(double)seconds {
    if (!self.player.currentItem || !isfinite(seconds)) return;
    double duration = CMTimeGetSeconds(self.player.currentItem.duration);
    if (!isfinite(duration) || duration <= 0) return;
    [self.player seekToTime:CMTimeMakeWithSeconds(fmin(duration, fmax(0, seconds)), 600)];
}

- (void)perform:(Action)action {
    switch (action) {
        case SelectMusic: case SelectVideos: case SelectOpen: case SelectQueue: case SelectForYou:
            [self switchTo:(Tab)action]; break;
        case Find: self.editing = YES; break;
        case PlaySelection: self.editing = NO; [self playSelected]; break;
        case AddSelection: {
            NSArray<Track *> *rows = self.rows;
            if (self.tab == QueueTab || self.selected >= rows.count) break;
            if (self.queue.count >= 100) { self.notice = @"Queue is full (100 tracks)."; break; }
            [self.queue addObject:rows[self.selected]];
            self.notice = @"Added to queue.";
            break;
        }
        case LikeSelection: {
            NSArray<Track *> *rows = self.rows;
            if (self.selected >= rows.count || !rows[self.selected].artist.length) break;
            Track *track = rows[self.selected];
            if (!toggleLike(track)) { self.notice = @"Could not save your like."; break; }
            self.notice = track.liked ? @"Liked on this Mac." : @"Like removed.";
            for (Track *other in self.songs) if ([other.source isEqualToString:track.source]) other.liked = track.liked;
            for (Track *other in self.queue) if ([other.source isEqualToString:track.source]) other.liked = track.liked;
            [self reloadRecommendations];
            break;
        }
        case DiscoverSelection: [self discoverSelected]; break;
        case RemoveSelection: [self removeSelected]; break;
        case Back: case Forward:
            [self seekTo:CMTimeGetSeconds(self.player.currentTime) + (action == Back ? -10 : 10)]; break;
        case Pause:
            if (!self.player.currentItem) break;
            self.paused = !self.paused;
            if (self.paused) [self.player pause];
            else { self.openedAt = NSProcessInfo.processInfo.systemUptime; [self.player play]; }
            break;
        case Next: [self advanceManually:YES]; break;
        case Stop: [self clearPlayback:@"Playback stopped."]; break;
        case ToggleAutoplay: self.autoplay = !self.autoplay; break;
        case ToggleLoop: self.loopTrack = !self.loopTrack; break;
        case Quit: CFRunLoopStop(CFRunLoopGetMain()); break;
    }
}

- (void)moveSelection:(int)change {
    NSInteger last = (NSInteger)self.rows.count - 1;
    if (last >= 0) self.selected = (NSUInteger)MIN(last, MAX(0, (NSInteger)self.selected + change));
    self.editing = NO;
}

- (void)mouseButton:(int)button x:(int)x y:(int)y {
    if (button == 64 || button == 65) {
        if (y >= FirstRow && y < LINES - 8) [self moveSelection:button == 64 ? -3 : 3];
        return;
    }
    if (button != 0) return;
    for (int i = 0; i < _hitCount; i++) {
        Hit hit = _hits[i];
        if (y != hit.y || x < hit.x || x >= hit.x + hit.width) continue;
        if (hit.action == Find && x >= COLS - 12) [self submit];
        else [self perform:hit.action];
        return;
    }
    if (y == 4 && self.tab < QueueTab) { self.editing = YES; return; }
    if (y == LINES - 4 && x >= 2 && x < 2 + _scrubWidth) {
        double duration = CMTimeGetSeconds(self.player.currentItem.duration);
        [self seekTo:duration * (x - 2) / MAX(1, _scrubWidth - 1)];
        return;
    }
    if (y >= FirstRow && y < LINES - 8 && x >= 2 && x < COLS - 2) {
        NSUInteger row = self.offset + y - FirstRow;
        if (row >= self.rows.count) return;
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        self.selected = row;
        self.editing = NO;
        if (now - self.lastClick < 0.4 && self.lastClickRow == row) {
            [self playSelected];
            self.lastClick = 0;
        } else {
            self.lastClick = now;
            self.lastClickRow = row;
        }
    }
}

- (void)readInput {
    wint_t key;
    int type;
    while ((type = get_wch(&key)) != ERR) {
        // xterm SGR mouse coordinates are 1-based. Act on presses only.
        if (type == KEY_CODE_YES && key == MousePrefix) { _readingMouse = YES; _mouseLength = 0; continue; }
        if (_readingMouse) {
            if (type != OK || _mouseLength >= (int)sizeof _mouse - 1) { _readingMouse = NO; continue; }
            if (key == 'M' || key == 'm') {
                _mouse[_mouseLength] = 0;
                int button, x, y;
                if (key == 'M' && sscanf(_mouse, "%d;%d;%d", &button, &x, &y) == 3)
                    [self mouseButton:button x:x-1 y:y-1];
                _readingMouse = NO;
            } else if ((key >= '0' && key <= '9') || key == ';') _mouse[_mouseLength++] = (char)key;
            else _readingMouse = NO;
            continue;
        }
        if (COLS < MinWidth || LINES < MinHeight) {
            if (type == OK && (key == 27 || key == 'q')) [self perform:Quit];
            continue;
        }
        if (type == KEY_CODE_YES && (key == KEY_UP || key == KEY_DOWN)) {
            [self moveSelection:key == KEY_UP ? -1 : 1];
        } else if (type == OK && key == '\t') {
            [self switchTo:(self.tab + 1) % (ForYouTab + 1)];
        } else if ((type == OK && (key == '\n' || key == '\r')) || (type == KEY_CODE_YES && key == KEY_ENTER)) {
            if (self.editing) [self submit];
            else if (self.tab == ForYouTab && !self.discoverySeed && !self.rows.count) [self switchTo:MusicTab];
            else [self playSelected];
        } else if (type == OK && key == 27) {
            self.editing = NO;
        } else if (self.editing) {
            if ((type == OK && (key == 127 || key == 8)) || (type == KEY_CODE_YES && key == KEY_BACKSPACE)) {
                if (!self.caret) continue;
                NSRange previous = [self.query rangeOfComposedCharacterSequenceAtIndex:self.caret - 1];
                [self.query deleteCharactersInRange:previous];
                self.caret = previous.location;
            } else if (type == KEY_CODE_YES && key == KEY_LEFT && self.caret) {
                self.caret = [self.query rangeOfComposedCharacterSequenceAtIndex:self.caret - 1].location;
            } else if (type == KEY_CODE_YES && key == KEY_RIGHT && self.caret < self.query.length) {
                self.caret = NSMaxRange([self.query rangeOfComposedCharacterSequenceAtIndex:self.caret]);
            } else if (type == OK && key == 21) {
                [self.query setString:@""];
                self.caret = 0;
            } else if (type == OK && iswprint(key) && self.query.length < 4096) {
                uint32_t codepoint = (uint32_t)key;
                NSString *letter = [[NSString alloc] initWithBytes:&codepoint length:sizeof codepoint encoding:NSUTF32LittleEndianStringEncoding];
                if (!letter) continue;
                [self.query insertString:letter atIndex:self.caret];
                self.caret += letter.length;
            }
        } else if (type == KEY_CODE_YES && (key == KEY_LEFT || key == KEY_RIGHT)) {
            [self perform:key == KEY_LEFT ? Back : Forward];
        } else if (type == OK) {
            switch (key) {
                case '/': if (self.tab >= QueueTab) [self switchTo:MusicTab]; else self.editing = YES; break;
                case ' ': [self perform:Pause]; break;
                case 'a': [self perform:AddSelection]; break;
                case 'l': [self perform:LikeSelection]; break;
                case 'D': [self perform:DiscoverSelection]; break;
                case 'd': [self perform:RemoveSelection]; break;
                case 'n': [self perform:Next]; break;
                case 's': [self perform:Stop]; break;
                case 'r': [self perform:ToggleLoop]; break;
                case 'q': [self perform:Quit]; break;
            }
        }
    }
    [self draw];
}

@end

int runTUI(const char *launcher) {
    setlocale(LC_CTYPE, "");
    SCREEN *screen = newterm(NULL, stdout, stdin);
    if (!screen) screen = newterm("xterm-256color", stdout, stdin);
    if (!screen) { fputs("ytm: This terminal does not support the full-screen player. Try ytm menu.\n", stderr); return 1; }
    atexit(restoreScreen);
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
    nodelay(stdscr, TRUE);
    set_escdelay(35);
    if (has_colors()) {
        start_color();
        use_default_colors();
        // Use the nearest xterm palette colors without changing the user's palette.
        short amber = (short)(COLORS >= 256 ? (usesLightTheme() ? 94 : 215) : COLOR_YELLOW);
        init_pair(AmberPair, amber, -1);
    }
    define_key("\033[<", MousePrefix);
    fputs("\033[?1000h\033[?1006h", stdout);
    fflush(stdout);

    TerminalPlayer *ui = [TerminalPlayer new];
    ui.launcher = [NSString stringWithUTF8String:launcher];
    ui.query = [NSMutableString string];
    ui.queue = [NSMutableArray array];
    ui.recentMusic = [NSMutableOrderedSet orderedSet];
    ui.autoplay = YES;
    ui.editing = YES;
    dispatch_queue_t main = dispatch_get_main_queue();
    ui.tick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, main);
    dispatch_source_set_timer(ui.tick, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(ui.tick, ^{ @autoreleasepool { [ui pollPlayback]; } });
    dispatch_resume(ui.tick);
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, main);
    dispatch_source_set_event_handler(input, ^{ @autoreleasepool { [ui readInput]; } });
    dispatch_resume(input);

    NSMutableArray *signals = [NSMutableArray array];
    for (NSNumber *number in @[@SIGINT, @SIGTERM, @SIGHUP, @SIGWINCH]) {
        int signum = number.intValue;
        signal(signum, SIG_IGN);
        dispatch_source_t watcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signum, 0, main);
        dispatch_source_set_event_handler(watcher, ^{
            if (signum != SIGWINCH) { CFRunLoopStop(CFRunLoopGetMain()); return; }
            struct winsize size;
            if (ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_row && size.ws_col) {
                resizeterm(size.ws_row, size.ws_col);
                @autoreleasepool { [ui draw]; }
            }
        });
        [signals addObject:watcher];
        dispatch_resume(watcher);
    }

    NSNotificationCenter *events = NSNotificationCenter.defaultCenter;
    id ended = [events addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:nil queue:NSOperationQueue.mainQueue
                              usingBlock:^(NSNotification *note) {
        if (note.object == ui.player.currentItem) { [ui advanceManually:NO]; [ui draw]; }
    }];
    id failed = [events addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:nil queue:NSOperationQueue.mainQueue
                               usingBlock:^(NSNotification *note) {
        if (note.object != ui.player.currentItem) return;
        NSError *error = note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
        [ui clearPlayback:error.localizedDescription ?: @"Playback interrupted."];
    }];
    [ui draw];
    CFRunLoopRun();
    if (ui.searchTask.running) [ui.searchTask terminate];
    if (ui.resolveTask.running) [ui.resolveTask terminate];
    if (ui.discoverTask.running) [ui.discoverTask terminate];
    [ui.player pause];
    [events removeObserver:ended];
    [events removeObserver:failed];
    for (dispatch_source_t watcher in signals) dispatch_source_cancel(watcher);
    dispatch_source_cancel(input);
    dispatch_source_cancel(ui.tick);
    return 0;
}
