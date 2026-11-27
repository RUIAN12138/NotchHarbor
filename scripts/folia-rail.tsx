import React, {useEffect, useMemo, useRef, useState} from 'react';
import {createRoot} from 'react-dom/client';
import {useMotionValue, MotionConfig} from 'framer-motion';
import MonetLyricsRail from 'folia/MonetLyricsRail';
import {buildMonetVisibleLineEntries} from 'folia/monetLyricsModel';
import {estimateLrcLineEndTime} from 'foliaUtils/lyrics/estimatedLineTiming';

type SnapshotWord = {
    text: string;
    startTime: number;
    endTime: number;
};

type SnapshotLine = {
    time: number;
    endTime?: number;
    text: string;
    words?: SnapshotWord[];
};

type Snapshot = {
    key: string;
    trackKey?: string;
    lines: SnapshotLine[];
    elapsed: number;
    anchorElapsed?: number;
    anchorWallMs?: number;
    duration: number;
    rate?: number;
    playing?: boolean;
    reduced: boolean;
    albumInk?: string;
    lineCount: number;
};

type PlaybackAnchor = {
    elapsed: number;
    anchorElapsed: number;
    anchorWallMs: number | null;
    at: number;
    rate: number;
    playing: boolean;
    duration: number;
    lines: SnapshotLine[];
};

let update: (data: Snapshot) => void = () => {};
const baseTheme = {
    name: 'Notch', backgroundColor: '#17191e', primaryColor: '#ffffff', accentColor: '#ffffff',
    secondaryColor: '#adb2bf', fontStyle: 'sans', fontWeight: 700, animationIntensity: 'normal',
} as const;
const fonts = '-apple-system, BlinkMacSystemFont, "PingFang SC", "SF Pro Display", sans-serif';

function findLineIndex(lines: SnapshotLine[], elapsed: number): number {
    let low = 0, high = lines.length;
    while (low < high) {
        const mid = (low + high) >>> 1;
        if (lines[mid].time <= elapsed) low = mid + 1; else high = mid;
    }
    return low - 1;
}

function estimateElapsed(anchor: PlaybackAnchor, nowPerf: number): number {
    let elapsed: number;
    if (anchor.anchorWallMs !== null && anchor.anchorWallMs > 0) {
        elapsed = anchor.anchorElapsed;
        if (anchor.playing && anchor.rate > 0) {
            const wallDeltaSec = Math.max(0, (Date.now() - anchor.anchorWallMs) / 1000);
            elapsed += wallDeltaSec * anchor.rate;
        }
    } else {
        elapsed = anchor.elapsed;
        if (anchor.playing && anchor.rate > 0) {
            elapsed += Math.max(0, (nowPerf - anchor.at) / 1000) * anchor.rate;
        }
    }
    if (Number.isFinite(anchor.duration) && anchor.duration > 0) {
        elapsed = Math.min(anchor.duration, elapsed);
    }
    return Math.max(0, elapsed);
}

function Rail() {
    const [snapshot, setSnapshot] = useState<Snapshot>();
    const [current, setCurrent] = useState(-1);
    const clock = useMotionValue(0);
    const anchorRef = useRef<PlaybackAnchor | null>(null);
    const rafRef = useRef<number | null>(null);

    useEffect(() => {
        const stopLoop = () => {
            if (rafRef.current !== null) {
                cancelAnimationFrame(rafRef.current);
                rafRef.current = null;
            }
        };
        const step = () => {
            rafRef.current = null;
            const anchor = anchorRef.current;
            if (!anchor) return;
            const nowElapsed = estimateElapsed(anchor, performance.now());
            clock.set(nowElapsed);
            const nextIndex = findLineIndex(anchor.lines, nowElapsed);
            setCurrent(prev => (prev === nextIndex ? prev : nextIndex));
            if (anchor.playing && anchor.rate > 0 && !document.hidden) {
                rafRef.current = requestAnimationFrame(step);
            }
        };
        const handleVisibility = () => {
            stopLoop();
            if (!document.hidden && anchorRef.current) step();
        };
        document.addEventListener('visibilitychange', handleVisibility);

        update = data => {
            const nowPerf = performance.now();
            const validWallMs = typeof data.anchorWallMs === 'number' && Number.isFinite(data.anchorWallMs) && data.anchorWallMs > 0
                ? data.anchorWallMs
                : null;
            const anchorElapsed = typeof data.anchorElapsed === 'number' && Number.isFinite(data.anchorElapsed)
                ? data.anchorElapsed
                : (Number.isFinite(data.elapsed) ? data.elapsed : 0);
            const anchor: PlaybackAnchor = {
                elapsed: Number.isFinite(data.elapsed) ? data.elapsed : 0,
                anchorElapsed,
                anchorWallMs: validWallMs,
                at: nowPerf,
                rate: typeof data.rate === 'number' && Number.isFinite(data.rate) ? data.rate : 1,
                playing: Boolean(data.playing),
                duration: Number.isFinite(data.duration) ? data.duration : 0,
                lines: data.lines,
            };
            anchorRef.current = anchor;
            const initialElapsed = estimateElapsed(anchor, nowPerf);
            clock.set(initialElapsed);
            setSnapshot(previous => previous?.key === data.key && previous.reduced === data.reduced
                && previous.albumInk === data.albumInk ? previous : data);
            const nextIndex = findLineIndex(data.lines, initialElapsed);
            setCurrent(prev => (prev === nextIndex ? prev : nextIndex));
            stopLoop();
            if (anchor.playing && anchor.rate > 0 && !document.hidden) {
                rafRef.current = requestAnimationFrame(step);
            }
        };
        (window as any).webkit.messageHandlers.foliaReady.postMessage(null);
        return () => {
            stopLoop();
            document.removeEventListener('visibilitychange', handleVisibility);
        };
    }, [clock]);

    const lines = useMemo(() => snapshot?.lines.map((line, index, list) => {
        const nextTime = list[index + 1]?.time;
        const maxEnd = nextTime !== undefined
            ? Math.max(line.time + 0.05, nextTime)
            : Math.max(line.time + 0.5, snapshot.duration > 0 ? snapshot.duration : line.time + 5);
        const text = line.text || '间奏';
        const naturalEnd = typeof line.endTime === 'number' && Number.isFinite(line.endTime) && line.endTime > line.time
            ? Math.min(maxEnd, line.endTime)
            : Math.min(maxEnd, Math.max(line.time + 0.25, estimateLrcLineEndTime(text, line.time, nextTime)));
        const words = line.words && line.words.length > 0
            ? line.words.map(w => ({
                text: w.text,
                startTime: w.startTime,
                endTime: Math.min(maxEnd, Math.max(w.startTime + 0.03, w.endTime)),
            }))
            : [{text, startTime: line.time, endTime: naturalEnd}];
        return {
            startTime: line.time,
            endTime: naturalEnd,
            fullText: text,
            words,
        };
    }) ?? [], [snapshot?.lines, snapshot?.duration]);

    const theme = useMemo(() => ({
        ...baseTheme,
        primaryColor: snapshot?.albumInk ?? baseTheme.primaryColor,
    }), [snapshot?.albumInk]);

    const singleLine = snapshot?.lineCount === 1;
    const entries = useMemo(() => buildMonetVisibleLineEntries({
        lines,
        currentLineIndex: current,
        activeLine: lines[current] ?? null,
        recentCompletedLine: lines[current - 1] ?? null,
        upcomingLine: lines[current + 1] ?? null,
        currentTime: clock.get(),
        before: singleLine ? 0 : 1,
        after: singleLine ? 0 : 3,
    }), [lines, current, clock, singleLine]);

    useEffect(() => {
        if (!lines.length) return;
        let frame: number | null = null;
        let attempts = 0;
        const check = () => {
            frame = null;
            if (document.hidden) return;
            const rail = document.querySelector('#rail>.relative');
            const bounds = rail?.getBoundingClientRect();
            const visible = bounds && [...rail!.querySelectorAll('[role=button]')].some(row => {
                const rect = row.getBoundingClientRect();
                return rect.height > 0 && rect.bottom > bounds.top && rect.top < bounds.bottom
                    && Number(getComputedStyle(row).opacity) > 0.2;
            });
            if (visible) {
                (window as any).webkit.messageHandlers.foliaRendered?.postMessage(null);
            } else if (++attempts < 120) {
                frame = requestAnimationFrame(check);
            }
        };
        frame = requestAnimationFrame(check);
        return () => {
            if (frame !== null) cancelAnimationFrame(frame);
        };
    }, [lines]);

    if (!snapshot || !lines.length) return null;
    return <MotionConfig reducedMotion={snapshot.reduced ? 'always' : 'never'}>
        <MonetLyricsRail
            key={snapshot.trackKey ?? 'folia-rail'}
            entries={entries}
            lines={lines}
            currentLineIndex={current}
            currentTime={clock}
            theme={theme}
            lyricFontPx={singleLine ? 16.5 : 15.5}
            inactiveFontPx={12.5}
            translationFontPx={11}
            fontStack={fonts}
            keywordColoringEnabled={false}
            emptyText=""
            onLyricLineSeek={elapsed => (window as any).webkit.messageHandlers.foliaSeek.postMessage(elapsed)}
        />
    </MotionConfig>;
}

let cachedLines: SnapshotLine[] = [];
(window as any).updateFolia = (data: Snapshot) => {
    if (data.lines) cachedLines = data.lines;
    update({...data, lines: cachedLines});
};
createRoot(document.getElementById('rail')!).render(<Rail />);
