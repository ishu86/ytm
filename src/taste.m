// SPDX-License-Identifier: MIT
#import "taste.h"
#include <sqlite3.h>

enum { CandidateLimit = 256 };

@implementation Track
@end

static sqlite3 *openTasteStore(BOOL create) {
    NSString *state = NSProcessInfo.processInfo.environment[@"XDG_STATE_HOME"];
    if (![state hasPrefix:@"/"]) state = [NSHomeDirectory() stringByAppendingPathComponent:@".local/state"];
    NSString *directory = [state stringByAppendingPathComponent:@"ytm"];
    NSString *path = [directory stringByAppendingPathComponent:@"taste.sqlite3"];
    if (create && ![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0700} error:NULL]) return NULL;

    sqlite3 *db = NULL;
    int flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0);
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, flags, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        return NULL;
    }
    sqlite3_busy_timeout(db, 250);
    if (sqlite3_exec(db, "PRAGMA cache_size=-64; PRAGMA foreign_keys=ON; "
            "CREATE TABLE IF NOT EXISTS songs ("
            "source TEXT PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL COLLATE NOCASE, "
            "seen INTEGER NOT NULL, listens INTEGER NOT NULL DEFAULT 0, skips INTEGER NOT NULL DEFAULT 0, "
            "liked INTEGER NOT NULL DEFAULT 0, last_listen INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID; "
            "CREATE TABLE IF NOT EXISTS related ("
            "seed TEXT NOT NULL REFERENCES songs(source) ON DELETE CASCADE, "
            "candidate TEXT NOT NULL REFERENCES songs(source) ON DELETE CASCADE, "
            "position INTEGER NOT NULL, PRIMARY KEY(seed,candidate)) WITHOUT ROWID; "
            "CREATE INDEX IF NOT EXISTS related_candidate ON related(candidate)",
            NULL, NULL, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        return NULL;
    }
    return db;
}

static void bindTrack(sqlite3_stmt *statement, Track *track) {
    sqlite3_bind_text(statement, 1, track.source.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 2, track.title.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 3, track.artist.UTF8String, -1, SQLITE_TRANSIENT);
}

static BOOL pruneCandidates(sqlite3 *db) {
    const char *sql = "DELETE FROM songs WHERE source IN (SELECT source FROM songs "
        "ORDER BY liked DESC, (listens + skips > 0) DESC, seen DESC, source LIMIT -1 OFFSET ?)";
    sqlite3_stmt *statement = NULL;
    BOOL ok = sqlite3_prepare_v2(db, sql, -1, &statement, NULL) == SQLITE_OK;
    if (ok) {
        sqlite3_bind_int(statement, 1, CandidateLimit);
        ok = sqlite3_step(statement) == SQLITE_DONE;
    }
    sqlite3_finalize(statement);
    return ok;
}

static BOOL upsertSongs(sqlite3 *db, NSArray<Track *> *tracks) {
    const char *sql = "INSERT INTO songs(source,title,artist,seen) VALUES(?,?,?,strftime('%s','now')) "
        "ON CONFLICT(source) DO UPDATE SET title=excluded.title,artist=excluded.artist,seen=excluded.seen RETURNING liked";
    sqlite3_stmt *statement = NULL;
    BOOL ok = sqlite3_prepare_v2(db, sql, -1, &statement, NULL) == SQLITE_OK;
    if (ok) for (Track *track in tracks) {
        if (!track.artist.length) continue;
        bindTrack(statement, track);
        ok = sqlite3_step(statement) == SQLITE_ROW;
        if (ok) {
            track.liked = sqlite3_column_int(statement, 0) != 0;
            ok = sqlite3_step(statement) == SQLITE_DONE;
        }
        sqlite3_reset(statement);
        if (!ok) break;
    }
    sqlite3_finalize(statement);
    return ok;
}

BOOL rememberSongs(NSArray<Track *> *tracks) {
    if (!tracks.count) return YES;
    sqlite3 *db = openTasteStore(YES);
    if (!db) return NO;
    BOOL ok = sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) == SQLITE_OK && upsertSongs(db, tracks);
    ok = ok && pruneCandidates(db) && sqlite3_exec(db, "COMMIT", NULL, NULL, NULL) == SQLITE_OK;
    sqlite3_close(db);
    return ok;
}

static BOOL saveFeedback(Track *track, const char *sql) {
    if (!track.artist.length) return NO;
    sqlite3 *db = openTasteStore(YES);
    if (!db) return NO;
    sqlite3_stmt *statement = NULL;
    BOOL liked = track.liked;
    BOOL ok = sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) == SQLITE_OK &&
        sqlite3_prepare_v2(db, sql, -1, &statement, NULL) == SQLITE_OK;
    if (ok) {
        bindTrack(statement, track);
        ok = sqlite3_step(statement) == SQLITE_ROW;
        if (ok) {
            liked = sqlite3_column_int(statement, 0) != 0;
            ok = sqlite3_step(statement) == SQLITE_DONE;
        }
    }
    sqlite3_finalize(statement);
    ok = ok && pruneCandidates(db) && sqlite3_exec(db, "COMMIT", NULL, NULL, NULL) == SQLITE_OK;
    sqlite3_close(db);
    if (ok) track.liked = liked;
    return ok;
}

BOOL recordListen(Track *track, BOOL skipped) {
    const char *listen = "INSERT INTO songs(source,title,artist,seen,listens,last_listen) "
        "VALUES(?,?,?,strftime('%s','now'),1,strftime('%s','now')) ON CONFLICT(source) DO UPDATE SET "
        "listens=min(listens+1,12), last_listen=excluded.last_listen, seen=excluded.seen RETURNING liked";
    const char *skip = "INSERT INTO songs(source,title,artist,seen,skips) "
        "VALUES(?,?,?,strftime('%s','now'),1) ON CONFLICT(source) DO UPDATE SET "
        "skips=min(skips+1,12), seen=excluded.seen RETURNING liked";
    return saveFeedback(track, skipped ? skip : listen);
}

BOOL toggleLike(Track *track) {
    return saveFeedback(track, "INSERT INTO songs(source,title,artist,seen,liked) "
        "VALUES(?,?,?,strftime('%s','now'),1) ON CONFLICT(source) DO UPDATE SET "
        "liked=1-liked, seen=excluded.seen RETURNING liked");
}

BOOL rememberDiscovery(Track *seed, NSArray<Track *> *tracks) {
    if (!seed.artist.length || !tracks.count) return NO;
    sqlite3 *db = openTasteStore(YES);
    if (!db) return NO;
    sqlite3_stmt *statement = NULL;
    BOOL ok = sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) == SQLITE_OK &&
        upsertSongs(db, [@[seed] arrayByAddingObjectsFromArray:tracks]) &&
        sqlite3_prepare_v2(db, "DELETE FROM related WHERE seed=?", -1, &statement, NULL) == SQLITE_OK;
    if (ok) {
        sqlite3_bind_text(statement, 1, seed.source.UTF8String, -1, SQLITE_TRANSIENT);
        ok = sqlite3_step(statement) == SQLITE_DONE;
    }
    sqlite3_finalize(statement);
    statement = NULL;
    ok = ok && sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO related VALUES(?,?,?)", -1, &statement, NULL) == SQLITE_OK;
    if (ok) {
        int position = 0;
        for (Track *track in tracks) {
            if (!track.artist.length || [track.source isEqualToString:seed.source]) continue;
            sqlite3_bind_text(statement, 1, seed.source.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, track.source.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(statement, 3, position++);
            ok = sqlite3_step(statement) == SQLITE_DONE;
            sqlite3_reset(statement);
            if (!ok || position == 20) break;
        }
    }
    sqlite3_finalize(statement);
    ok = ok && pruneCandidates(db) && sqlite3_exec(db, "COMMIT", NULL, NULL, NULL) == SQLITE_OK;
    sqlite3_close(db);
    return ok;
}

static NSArray<Track *> *querySongs(const char *sql, NSString *source, NSUInteger limit) {
    sqlite3 *db = openTasteStore(NO);
    if (!db) return @[];
    NSMutableArray<Track *> *tracks = [NSMutableArray arrayWithCapacity:20];
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) == SQLITE_OK) {
        if (source) sqlite3_bind_text(statement, 1, source.UTF8String, -1, SQLITE_TRANSIENT);
        else sqlite3_bind_int(statement, 1, (int)limit);
        while (sqlite3_step(statement) == SQLITE_ROW) {
            Track *track = [Track new];
            track.source = @((const char *)sqlite3_column_text(statement, 0));
            track.title = @((const char *)sqlite3_column_text(statement, 1));
            track.artist = @((const char *)sqlite3_column_text(statement, 2));
            track.liked = sqlite3_column_int(statement, 3) != 0;
            [tracks addObject:track];
        }
    }
    sqlite3_finalize(statement);
    sqlite3_close(db);
    return tracks;
}

NSArray<Track *> *discoveredSongs(Track *seed) {
    if (!seed.source.length) return @[];
    return querySongs("SELECT source,title,artist,liked FROM related JOIN songs ON source=candidate "
        "WHERE seed=? AND (skips<3 OR liked=1) "
        "ORDER BY 2*position - 3*liked + 3*min(3,listens) + 5*min(3,skips), position LIMIT 20", seed.source, 20);
}

NSArray<Track *> *recommendSongs(NSUInteger limit) {
    return querySongs(
        "WITH affinity AS (SELECT artist, sum(6*liked + min(6,2*listens) - min(6,2*skips)) AS weight "
        "FROM songs GROUP BY artist), "
        "discovery AS (SELECT candidate, max(7+4*liked+min(6,2*listens)-min(6,2*skips)-position/3) AS weight "
        "FROM related JOIN songs ON source=seed GROUP BY candidate) "
        "SELECT source,title,songs.artist,liked FROM songs LEFT JOIN affinity USING(artist) "
        "LEFT JOIN discovery ON source=candidate WHERE skips<3 OR liked=1 ORDER BY "
        "(listens=0 AND liked=0) DESC, "
        "coalesce(affinity.weight,0) + coalesce(discovery.weight,0) + 3*liked - 3*min(3,listens) - 4*min(3,skips) "
        "- 4*(last_listen > cast(strftime('%s','now') AS INTEGER)-86400) DESC, seen DESC, source LIMIT ?", nil, limit);
}
