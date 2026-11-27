"""Match only synthetic lyric fixtures using the production selection function."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'boringNotch/managers/MusicManager.swift').read_text()
source=s[s.index('enum MusicLyricText {'):]
harness='import Foundation\n'+source+r'''
let wrong: [String:Any] = ["id":1,"trackName":"Echo","artistName":"Other","duration":207,"plainLyrics":"Different words"]
let right: [String:Any] = ["id":2,"trackName":"Ｅｃｈｏ","artistName":"The Band","duration":207,"plainLyrics":"A synthetic line", "syncedLyrics":"[00:01.00]A synthetic line"]
let live: [String:Any] = ["id":3,"trackName":"Echo","artistName":"The Band","duration":290,"plainLyrics":"Another recording"]
let numeric: [String:Any] = ["id":4,"trackName":"Echo","artistName":"The Band","duration":207,"plainLyrics":"100", "syncedLyrics":"[00:01]100"]
func id(_ records:[[String:Any]], duration:Double=207) -> Int? {
 LyricsRecordSelection.best(records,title:"Echo",artist:"The Band",duration:duration)?["id"] as? Int
}
assert(id([wrong,live,numeric,right])==2)
assert(id([wrong,live,numeric])==nil)
assert(id([right],duration: .nan)==2)
assert(LyricsRecordSelection.best([right],title:"Another song",artist:"The Band",duration:207)==nil)
assert(LyricsRecordSelection.best([],title:"Echo",artist:"The Band",duration:207)==nil)
assert(LyricsRecordSelection.normalized("陈小Ｃ.Ｃ")=="陈小cc")
var missing = right;missing.removeValue(forKey:"duration")
assert(id([missing])==nil)
var malformed = right;malformed["duration"] = Double.infinity
assert(id([malformed])==nil)
let plain:[String:Any] = ["id":5,"trackName":"Echo","artistName":"The Band","duration":207,"plainLyrics":"Another synthetic line"]
assert(id([plain,right])==2)
var lessExactTimed = right; lessExactTimed["duration"] = 211
assert(id([plain,lessExactTimed])==2)
lessExactTimed["syncedLyrics"] = "not timestamped"
assert(id([plain,lessExactTimed])==5)
func song(_ id: Int, _ artist: String, _ milliseconds: Int) -> [String: Any] {
    ["id": id, "name": "果实", "artists": [["name": artist]], "duration": milliseconds]
}
let cloudSongs = [song(1, "其他歌手", 261862), song(2, "陈粒", 310000), song(3, "陳粒", 261862)]
assert(LyricsRecordSelection.netEaseIDs(cloudSongs, title: "果实", artist: "陈粒", album: "", duration: 262) == [3])
assert(LyricsRecordSelection.netEaseIDs(cloudSongs, title: "果实", artist: "陈粒", album: "", duration: .nan).isEmpty)
func edition(_ id: Int, _ album: String, _ duration: Int) -> [String: Any] {
    var result = song(id, "陈粒", duration)
    result["album"] = ["name": album]
    return result
}
let editions = [edition(10, "原版", 214157), edition(30, "精选", 214575), edition(20, "典藏版", 214157)]
func editionIDs(_ songs: [[String: Any]], album: String = "", duration: Double = 214.204) -> [Int] {
    LyricsRecordSelection.netEaseIDs(songs, title: "果实", artist: "陈粒", album: album, duration: duration)
}
assert(editionIDs(editions) == [10, 20])
assert(editionIDs(editions, album: "典藏版") == [20, 10])
assert(editionIDs(editions + [edition(40, "另一版", 214231)]).isEmpty)
assert(editionIDs(editions, duration: .nan).isEmpty)
let cloudEdition: [String: Any] = ["id": 60, "name": "果实", "ar": [["name": "陈粒"], ["name": "嘉宾"]],
                                    "al": ["name": "原版"], "dt": 214_157]
assert(editionIDs([cloudEdition], album: "原版") == [60])
assert(editionIDs([cloudEdition], album: "非同一专辑").isEmpty)
assert(editionIDs([cloudEdition], album: "原版", duration: 215.6).isEmpty)
let timed: [(time:Double,text:String)] = [(5,"first"),(10,"repeat"),(10,"repeat"),(20,"last")]
let prelude = MusicLyricTimeline.frame(lines:timed,plain:"",elapsed:0)
assert(prelude.isPrelude && prelude.current.isEmpty && prelude.next == "first")
let first = MusicLyricTimeline.frame(lines:timed,plain:"",elapsed:5)
assert(first.index == 0 && first.current == "first" && first.next == "repeat")
let repeated = MusicLyricTimeline.frame(lines:timed,plain:"",elapsed:10)
assert(repeated.index == 2 && repeated.current == "repeat")
assert(MusicLyricTimeline.frame(lines:timed,plain:"",elapsed:25).next == nil)
assert(MusicLyricTimeline.frame(lines:timed,plain:"",elapsed:7).current == "first")
assert(MusicLyricTimeline.frame(lines:timed,plain:"",elapsed:Double.nan).isPrelude)
assert(MusicLyricTimeline.frame(lines:timed,plain:"",elapsed:-100).isPrelude)
assert(MusicLyricTimeline.frame(lines:[],plain:" \n first \n\n second \n third",elapsed:3).current == "first\nsecond")
assert(MusicLyricTimeline.frame(lines:[],plain:"",elapsed:3).current.isEmpty)
assert(MusicLyricText.simplified("臺灣與愛，English 日本語") == "台湾与爱，English 日本语")
let parsed = MusicLyricText.parse("[offset:+250]\n[00:01.5][00:02.125]愛與樂\n[00:03.05]\n[00:04.00]End")
assert(parsed.count == 4)
assert(abs(parsed[0].time - 1.75) < 0.00001 && parsed[0].text == "爱与乐")
assert(abs(parsed[1].time - 2.375) < 0.00001)
assert(abs(parsed[2].time - 3.30) < 0.00001 && parsed[2].text.isEmpty)
assert(MusicLyricTimeline.frame(lines: parsed, plain: "", elapsed: 3.5).current.isEmpty)
assert(MusicLyricText.parse("[00:01.2]A\n[offset:-500]")[0].time == 0.7)
assert(LyricsRecordSelection.normalized("臺灣愛") == LyricsRecordSelection.normalized("台湾爱"))
let delayed = MusicLyricCalibration.adjusted(timed, by: 250)
assert(MusicLyricTimeline.frame(lines: delayed, plain: "", elapsed: 5).isPrelude)
assert(MusicLyricTimeline.frame(lines: delayed, plain: "", elapsed: 5.25).current == "first")
let advanced = MusicLyricCalibration.adjusted(timed, by: -250)
assert(MusicLyricTimeline.frame(lines: advanced, plain: "", elapsed: 4.75).current == "first")
assert(MusicLyricCalibration.adjusted([(0.1, "start")], by: -250)[0].time == 0)
let suite = "boringnotch.tests.lyrics." + UUID().uuidString
let settings = UserDefaults(suiteName: suite)!
defer { settings.removePersistentDomain(forName: suite) }
MusicLyricCalibration.save(250, trackKey: "studio", defaults: settings)
MusicLyricCalibration.save(-500, trackKey: "live", defaults: settings)
let reopened = UserDefaults(suiteName: suite)!
assert(MusicLyricCalibration.load(trackKey: "studio", defaults: reopened) == 250)
assert(MusicLyricCalibration.load(trackKey: "live", defaults: reopened) == -500)
assert(MusicLyricCalibration.load(trackKey: "other", defaults: reopened) == 0)
MusicLyricCalibration.save(9000, trackKey: "studio", defaults: settings)
assert(MusicLyricCalibration.load(trackKey: "studio", defaults: reopened) == 5000)
MusicLyricCalibration.save(0, trackKey: "studio", defaults: settings)
assert(MusicLyricCalibration.load(trackKey: "studio", defaults: reopened) == 0)
let yrcSample = "[12000,2600](12000,500,0)把(12500,900,0)每一次(13400,1200,0)切窗\n[16000,1800](16000,800,0)留住"
let parsedYRC = MusicLyricText.parseYRC(yrcSample)
assert(parsedYRC.count == 2 && parsedYRC[0].text == "把每一次切窗" && parsedYRC[0].words.count == 3)
assert(abs(parsedYRC[0].time - 12.0) < 0.0001 && abs((parsedYRC[0].endTime ?? 0) - 14.6) < 0.0001)
assert(abs(parsedYRC[0].words[1].startTime - 12.5) < 0.0001 && abs(parsedYRC[0].words[1].endTime - 13.4) < 0.0001)
let enhancedLRC = "[00:05.00]<00:05.00>Hello <00:05.60>World"
assert(MusicLyricText.parse(enhancedLRC).first?.text == "Hello World")
let richLRC = MusicLyricText.parseRich(lrc: enhancedLRC)
assert(richLRC.count == 1 && richLRC[0].words.count == 2 && richLRC[0].words[0].text == "Hello ")
let shiftedRich = MusicLyricCalibration.adjustedRich(parsedYRC, by: 250)
assert(abs(shiftedRich[0].time - 12.25) < 0.0001 && abs(shiftedRich[0].words[0].startTime - 12.25) < 0.0001)
print("PASS: YRC word timings, enhanced LRC inline tag parsing/stripping and rich calibration")
print("PASS: earlier/later lyric timing, first-frame bounds, per-recording persistence and reset")
print("PASS: prelude, exact/duplicate timestamps, backwards seek, final line, invalid position and bounded plain text")
print("PASS: recording identity, duration, Unicode metadata, numeric-only rejection, empty/malformed response and synchronized preference")
'''
with tempfile.TemporaryDirectory(prefix='notch-lyrics-') as d:
 d=Path(d);(d/'main.swift').write_text(harness)
 subprocess.run(['xcrun','swiftc',str(d/'main.swift'),'-o',str(d/'test')],check=True)
 subprocess.run([str(d/'test')],check=True)
