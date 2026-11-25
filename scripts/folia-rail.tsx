import React, {useEffect, useMemo, useRef, useState} from 'react';
import {createRoot} from 'react-dom/client';
import {useMotionValue, MotionConfig} from 'framer-motion';
import MonetLyricsRail from 'folia/MonetLyricsRail';
import {buildMonetVisibleLineEntries} from 'folia/monetLyricsModel';

type Snapshot = {
    key: string;
    lines: {time: number; text: string}[];
    elapsed: number;
    duration: number;
    rate?: number;
    playing?: boolean;
    reduced: boolean;
    albumInk?: string;
};
type PlaybackAnchor = {
    elapsed: number;
    at: number;
    rate: number;
    playing: boolean;
    duration: number;
    lines: Snapshot['lines'];
};
let update: (data: Snapshot) => void = () => {};
const baseTheme = {
    name: 'Notch', backgroundColor: '#17191e', primaryColor: '#ffffff', accentColor: '#ffffff',
    secondaryColor: '#adb2bf', fontStyle: 'sans', fontWeight: 700, animationIntensity: 'normal',
} as const;
const fonts = '-apple-system, BlinkMacSystemFont, sans-serif';

function findLineIndex(lines: Snapshot['lines'], elapsed: number): number {
    let low = 0, high = lines.length;
    while (low < high) {
        const mid = (low + high) >>> 1;
        if (lines[mid].time <= elapsed) low = mid + 1; else high = mid;
    }
    return low - 1;
}

function estimateElapsed(anchor: PlaybackAnchor, now: number): number {
    let elapsed = anchor.elapsed;
    if (anchor.playing && anchor.rate > 0) {
        elapsed += Math.max(0, (now - anchor.at) / 1000) * anchor.rate;
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
            const anchor: PlaybackAnchor = {
                elapsed: Number.isFinite(data.elapsed) ? data.elapsed : 0,
                at: performance.now(),
                rate: typeof data.rate === 'number' && Number.isFinite(data.rate) ? data.rate : 1,
                playing: Boolean(data.playing),
                duration: Number.isFinite(data.duration) ? data.duration : 0,
                lines: data.lines,
            };
            anchorRef.current = anchor;
            clock.set(anchor.elapsed);
            setSnapshot(previous => previous?.key === data.key && previous.reduced === data.reduced
                && previous.albumInk === data.albumInk ? previous : data);
            const nextIndex = findLineIndex(data.lines, anchor.elapsed);
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
        const end = Math.max(line.time + 0.05, list[index + 1]?.time ?? snapshot.duration);
        return {startTime: line.time, endTime: end, fullText: line.text || '间奏',
            words: [{text: line.text || '间奏', startTime: line.time, endTime: end}]};
    }) ?? [], [snapshot]);

    const theme = useMemo(() => ({
        ...baseTheme,
        primaryColor: snapshot?.albumInk ?? baseTheme.primaryColor,
    }), [snapshot?.albumInk]);

    const entries = useMemo(() => buildMonetVisibleLineEntries({
        lines, currentLineIndex: current,
        activeLine: lines[current] ?? null, recentCompletedLine: lines[current - 1] ?? null,
        upcomingLine: lines[current + 1] ?? null, currentTime: clock.get(), before: 1, after: 1,
    }), [lines, current, clock]);

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
                    && Number(getComputedStyle(row).opacity) > 0.25;
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
        <MonetLyricsRail key={snapshot.key} entries={entries} lines={lines} currentLineIndex={current}
            currentTime={clock} theme={theme}
            lyricFontPx={20} inactiveFontPx={15} translationFontPx={12}
            fontStack={fonts} keywordColoringEnabled={false} emptyText=""
            onLyricLineSeek={elapsed => (window as any).webkit.messageHandlers.foliaSeek.postMessage(elapsed)} />
    </MotionConfig>;
}
let cachedLines: Snapshot['lines'] = [];
(window as any).updateFolia = (data: Snapshot) => {
    if (data.lines) cachedLines = data.lines;
    update({...data, lines: cachedLines});
};
createRoot(document.getElementById('rail')!).render(<Rail />);
