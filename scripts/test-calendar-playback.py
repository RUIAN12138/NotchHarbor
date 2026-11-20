"""Compile production calendar arithmetic and playback clock against synthetic data."""
from pathlib import Path
import tempfile, subprocess
root=Path(__file__).resolve().parents[1]
calendar=(root/'boringNotch/managers/CalendarManager.swift').read_text()
calendar=calendar[calendar.index('// === AGENDA_DATE_RANGE_BEGIN ==='):calendar.index('// === AGENDA_DATE_RANGE_END ===')]
playback=(root/'boringNotch/models/PlaybackState.swift').read_text()
checks=r'''
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
func date(_ year:Int,_ month:Int,_ day:Int,_ hour:Int=0) -> Date {
 calendar.date(from:DateComponents(year:year,month:month,day:day,hour:hour))!
}
let spring=date(2026,3,8)
let days=AgendaDateRange.days(anchor:spring,now:spring,calendar:calendar)
assert(days.count == 2 && calendar.component(.day,from:days[1]) == 9)
assert(days[1].timeIntervalSince(days[0]) == 23*3600)
assert(AgendaDateRange.end(anchor:spring,now:spring,calendar:calendar) == date(2026,3,10))
let fall=date(2026,11,1)
assert(AgendaDateRange.days(anchor:fall,now:fall,calendar:calendar)[1].timeIntervalSince(fall) == 25*3600)
assert(AgendaDateRange.days(anchor:spring,now:date(2026,3,10),calendar:calendar).count == 1)
assert(AgendaDateRange.overlaps(start:date(2026,3,7,23),end:date(2026,3,8,1),day:spring,calendar:calendar))
assert(!AgendaDateRange.overlaps(start:date(2026,3,7),end:spring,day:spring,calendar:calendar))
assert(!AgendaDateRange.overlaps(start:date(2026,3,9),end:date(2026,3,10),day:spring,calendar:calendar))
assert(AgendaDateRange.overlaps(start:spring,end:spring,day:spring,calendar:calendar))
calendar.timeZone=TimeZone(secondsFromGMT:8*3600)!
let today=date(2026,11,16,15)
assert(AgendaDateRange.days(anchor:today,now:today,calendar:calendar) == [date(2026,11,16),date(2026,11,17)])
func occurrence(_ calendarID: String, _ start: Date) -> String {
    AgendaDateRange.occurrenceKey(calendarID: calendarID, eventID: "same-series", start: start,
                                  end: start.addingTimeInterval(3600))
}
assert(occurrence("local", today) != occurrence("shared", today))
assert(occurrence("shared", today) != occurrence("shared", today.addingTimeInterval(3600)))
let now=Date(timeIntervalSince1970:1000)
func estimate(_ elapsed:Double=10,_ anchor:Date=Date(timeIntervalSince1970:990),_ rate:Double=1,_ playing:Bool=true,_ duration:Double=100) -> Double {
 PlaybackPositionClock.position(elapsed:elapsed,anchor:anchor,rate:rate,playing:playing,duration:duration,now:now)
}
assert(estimate() == 20)
assert(estimate(10,Date(timeIntervalSince1970:990),2) == 30)
assert(estimate(10,Date(timeIntervalSince1970:990),1,false) == 10)
assert(estimate(10,Date(timeIntervalSince1970:990),1,true,0) == 20)
assert(estimate(.nan) == 10)
assert(estimate(10,.distantPast) == 10)
assert(estimate(10,Date(timeIntervalSince1970:1001)) == 10)
assert(estimate(98) == 100)
// Re-anchoring an unrelated metadata update preserves the running position.
let carried=PlaybackPositionClock.position(elapsed:10,anchor:Date(timeIntervalSince1970:980),rate:1,playing:true,duration:100,now:Date(timeIntervalSince1970:990))
assert(estimate(carried) == 30)
assert(PlaybackPositionClock.timestamp("2026-11-16T02:00:00.125Z") != nil)
assert(PlaybackPositionClock.timestamp("2026-11-16T02:00:00Z") != nil)
assert(PlaybackPositionClock.timestamp("malformed") == nil)
var previous = PlaybackState(bundleIdentifier: "synthetic", isPlaying: true, currentTime: 30,
    duration: 180, lastUpdated: Date(timeIntervalSince1970: 990))
let metadata = PlaybackPositionClock.merge(previous: previous, elapsed: nil, stamp: now,
    now: now, sameTrack: true, playing: true, rate: 1)
assert(metadata.elapsed == 30 && metadata.anchor == previous.lastUpdated)
let paused = PlaybackPositionClock.merge(previous: previous, elapsed: nil, stamp: previous.lastUpdated,
    now: now, sameTrack: true, playing: false, rate: 0)
assert(paused.elapsed == 40 && paused.anchor == now)
let stale = PlaybackPositionClock.merge(previous: previous, elapsed: 2,
    stamp: Date(timeIntervalSince1970: 980), now: now, sameTrack: true, playing: true, rate: 1)
assert(stale.elapsed == 30 && stale.anchor == previous.lastUpdated)
let backSeek = PlaybackPositionClock.merge(previous: previous, elapsed: 9, stamp: now,
    now: now, sameTrack: true, playing: true, rate: 1)
assert(backSeek.elapsed == 9 && backSeek.anchor == now)
let song = PlaybackState(bundleIdentifier: "com.netease.163music", isPlaying: true, title: "歌曲")
let browser = PlaybackState(bundleIdentifier: "com.apple.Safari", isPlaying: true, title: "直播",
                            mediaType: "kMRMediaRemoteNowPlayingInfoTypeVideo")
let sameProvider = PlaybackState(bundleIdentifier: "com.netease.163music", isPlaying: true, title: "歌曲")
let pausedBrowser = PlaybackState(bundleIdentifier: "com.apple.Safari", title: "视频")
let untouched = PlaybackState(bundleIdentifier: "com.apple.Music")
assert(!untouched.hasPanelMedia)
assert(!PlaybackState(bundleIdentifier: "com.apple.Music", title: "Not Playing", artist: "Unknown").hasPanelMedia)
assert(!PlaybackState(bundleIdentifier: "com.spotify.client", title: "Unknown", artist: "Unknown", album: "Unknown").hasPanelMedia)
assert(!PlaybackState(bundleIdentifier: "com.apple.Safari", title: "  ").hasPanelMedia)
assert(pausedBrowser.hasPanelMedia && song.hasPanelMedia)
assert(PlaybackState(bundleIdentifier: "com.apple.Safari", title: "", duration: 150).hasPanelMedia)
assert(PlaybackState(bundleIdentifier: "com.apple.Safari", isPlaying: true, title: "").hasPanelMedia)
print("PASS: music standby omits startup placeholders and preserves paused media and untitled live streams")

assert(song.isSong && !browser.isSong && !untouched.hasMedia)
assert(PlaybackState.preferSystem(browser, over: song, previouslySystem: false))
assert(!PlaybackState.preferSystem(sameProvider, over: song, previouslySystem: false))
assert(!PlaybackState.preferSystem(pausedBrowser, over: song, previouslySystem: true))
assert(PlaybackState.preferSystem(pausedBrowser, over: untouched, previouslySystem: true))
assert(PlaybackState(bundleIdentifier: "com.apple.Safari", mediaType: "MRMediaRemoteMediaTypeMusic").isSong)
assert(abs(PlaybackPositionClock.timestamp("2026-11-16T02:00:00.125Z")!
    .timeIntervalSince(PlaybackPositionClock.timestamp("2026-11-16T02:00:00Z")!) - 0.125) < 0.0001)
var a=PlaybackState(bundleIdentifier:"synthetic")
var b=a;b.playbackRate=2;assert(a != b)
b=a;b.lastUpdated=Date();assert(a != b)
assert(MusicScrubPosition.at(x: -20, width: 100, range: 0...240) == 0)
assert(MusicScrubPosition.at(x: 25, width: 100, range: 0...240) == 60)
assert(MusicScrubPosition.at(x: 120, width: 100, range: 0...240) == 240)
assert(MusicScrubPosition.at(x: 20, width: 100, range: 10...110) == 30)
assert(MusicScrubPosition.at(x: 20, width: 0, range: 0...240) == nil)
assert(MusicScrubPosition.at(x: .nan, width: 100, range: 0...240) == nil)
let committed = Date(timeIntervalSince1970: 1000)
let nextTick = committed.addingTimeInterval(0.1)
assert(!MusicScrubPosition.shouldFollowPlayback(target: 120, observedPosition: 34, anchor: nextTick,
                                               committedAt: committed, now: nextTick))
assert(!MusicScrubPosition.shouldFollowPlayback(target: 120, observedPosition: 120,
                                               anchor: committed.addingTimeInterval(-0.1),
                                               committedAt: committed, now: nextTick))
assert(MusicScrubPosition.shouldFollowPlayback(target: 120, observedPosition: 120.3, anchor: nextTick,
                                              committedAt: committed, now: nextTick))
assert(MusicScrubPosition.shouldFollowPlayback(target: 120, observedPosition: 34, anchor: nextTick,
                                              committedAt: committed, now: committed.addingTimeInterval(1)))
print("PASS: scrub bounds, target confirmation, old-position rejection and confirmation timeout")
print("PASS: today/tomorrow, exclusive midnight, overlaps, DST 23h/25h, selected day and time zones")
print("PASS: pause, unknown duration, repeat anchors, rate, timestamp correction and fractional ISO dates")
'''
with tempfile.TemporaryDirectory(prefix='notch-calendar-playback-') as folder:
 p=Path(folder);(p/'main.swift').write_text(playback+'\n'+calendar+'\n'+checks)
 subprocess.run(['xcrun','swiftc',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
