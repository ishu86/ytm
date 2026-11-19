// SPDX-License-Identifier: MIT
#import <AVFoundation/AVFoundation.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sysexits.h>
#include <termios.h>
#include <unistd.h>

int runTUI(const char *launcher);

static struct termios originalTerminal;
static BOOL terminalChanged;

static void restoreTerminal(void) {
    if (terminalChanged) {
        tcsetattr(STDIN_FILENO, TCSANOW, &originalTerminal);
        fputc('\n', stderr);
    }
}

static dispatch_source_t watchSignal(int signum) {
    signal(signum, SIG_IGN);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signum, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{ exit(128 + signum); });
    dispatch_resume(source);
    return source;
}

static void seek(AVPlayer *player, int offset) {
    double position = CMTimeGetSeconds(player.currentTime);
    if (!isfinite(position)) return;
    double target = fmax(0, position + offset);
    double duration = CMTimeGetSeconds(player.currentItem.duration);
    if (isfinite(duration)) target = fmin(duration, target);
    [player seekToTime:CMTimeMakeWithSeconds(target, 600)];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "tui") == 0) return runTUI(argv[2]);
        if (argc != 4) return EX_USAGE;
        NSString *source = [NSString stringWithUTF8String:argv[2]];
        BOOL online = strcmp(argv[1], "hls") == 0;
        NSURL *url = online ? [NSURL URLWithString:source] : [NSURL fileURLWithPath:source];
        if (!url) return EX_UNAVAILABLE;

        NSDictionary *options = online ? @{AVURLAssetOverrideMIMETypeKey: @"application/vnd.apple.mpegurl"} : nil;
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
        AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
        item.preferredForwardBufferDuration = 5;
        AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
        const char *mute = getenv("YTM_MUTE");
        player.muted = mute && strcmp(mute, "1") == 0;

        dispatch_queue_t main = dispatch_get_main_queue();
        __attribute__((objc_precise_lifetime)) NSArray *signals = @[
            watchSignal(SIGINT), watchSignal(SIGTERM), watchSignal(SIGHUP)
        ];
        atexit(restoreTerminal);
        BOOL showStatus = isatty(STDERR_FILENO);
        __block BOOL wantsPlayback = YES;
        __block BOOL started = NO;
        __block NSTimeInterval startup = NSProcessInfo.processInfo.systemUptime;

        // Read only the playback keys, leaving Ctrl-C and other terminal signals enabled.
        __attribute__((objc_precise_lifetime)) dispatch_source_t keys = nil;
        if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &originalTerminal) == 0) {
            struct termios raw = originalTerminal;
            raw.c_lflag &= ~(ECHO | ICANON);
            raw.c_cc[VMIN] = 1;
            raw.c_cc[VTIME] = 0;
            terminalChanged = tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0;
        }
        if (terminalChanged) {
            keys = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, main);
            __block int escape = 0;
            dispatch_source_set_event_handler(keys, ^{
                unsigned char key;
                if (read(STDIN_FILENO, &key, 1) != 1) return;
                if (escape == 2 && (key == 'C' || key == 'D')) seek(player, key == 'C' ? 10 : -10);
                else if (escape == 0 && key == 'q') exit(0);
                else if (escape == 0 && key == ' ') {
                    wantsPlayback = !wantsPlayback;
                    if (wantsPlayback) {
                        startup = NSProcessInfo.processInfo.systemUptime;
                        [player play];
                    } else {
                        [player pause];
                    }
                }
                escape = key == 27 ? 1 : (escape == 1 && (key == '[' || key == 'O') ? 2 : 0);
            });
            dispatch_resume(keys);
        }

        NSNotificationCenter *events = NSNotificationCenter.defaultCenter;
        [events addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) { exit(0); }];
        [events addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:item queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            NSError *error = note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
            fprintf(stderr, "\nytm: %s\n", (error.localizedDescription ?: @"Playback interrupted").UTF8String);
            exit(started ? EXIT_FAILURE : EX_UNAVAILABLE);
        }];

        __attribute__((objc_precise_lifetime)) dispatch_source_t status = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, main);
        dispatch_source_set_timer(status, DISPATCH_TIME_NOW, NSEC_PER_SEC / 2, NSEC_PER_MSEC * 50);
        dispatch_source_set_event_handler(status, ^{
            double seconds = CMTimeGetSeconds(player.currentTime);
            if (isfinite(seconds) && seconds > 0) started = YES;
            if (player.status == AVPlayerStatusFailed || item.status == AVPlayerItemStatusFailed) {
                NSError *error = item.error ?: player.error;
                fprintf(stderr, "\nytm: %s\n", (error.localizedDescription ?: @"Playback failed").UTF8String);
                exit(started ? EXIT_FAILURE : EX_UNAVAILABLE);
            }
            if (!started && wantsPlayback && NSProcessInfo.processInfo.systemUptime - startup > 15) {
                fputs("\nytm: Native playback timed out.\n", stderr);
                exit(EX_UNAVAILABLE);
            }
            if (!showStatus) return;
            int elapsed = isfinite(seconds) && seconds >= 0 ? (int)seconds : 0;
            const char *state = !wantsPlayback ? "Paused" :
                (player.timeControlStatus == AVPlayerTimeControlStatusPlaying ? "Playing" : "Buffering");
            fprintf(stderr, "\r%-9s %02d:%02d", state, elapsed / 60, elapsed % 60);
        });
        fprintf(stderr, "%s\n", argv[3]);
        dispatch_resume(status);
        [player play];
        [NSRunLoop.mainRunLoop run];
        return EXIT_FAILURE;
    }
}
