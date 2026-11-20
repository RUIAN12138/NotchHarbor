import React, {useEffect, useState} from 'react';
import {createRoot} from 'react-dom/client';
import {useMotionValue, MotionConfig} from 'framer-motion';
import MonetLyricsRail from 'folia/MonetLyricsRail';
import {buildMonetVisibleLineEntries} from 'folia/monetLyricsModel';

type Snapshot = {key: string; lines: {time: number; text: string}[]; elapsed: number; duration: number; reduced: boolean; albumInk?: string};
let update: (data: Snapshot) => void = () => {};
const theme = {
    name: 'Notch', backgroundColor: '#17191e', primaryColor: '#ffffff', accentColor: '#ffffff',
    secondaryColor: '#adb2bf', fontStyle: 'sans', fontWeight: 700, animationIntensity: 'normal',
} as const;
const fonts = '-apple-system, BlinkMacSystemFont, sans-serif';
function Rail() {
    const [snapshot, setSnapshot] = useState<Snapshot>();
    const [current, setCurrent] = useState(-1);
    const clock = useMotionValue(0);
    useEffect(() => {
        update = data => {
            clock.set(data.elapsed);
            setSnapshot(previous => previous?.key === data.key && previous.reduced === data.reduced
                && previous.albumInk === data.albumInk ? previous : data);
            let low = 0, high = data.lines.length;
            while (low < high) {
                const mid = (low + high) >>> 1;
                if (data.lines[mid].time <= data.elapsed) low = mid + 1; else high = mid;
            }
            setCurrent(low - 1);
        };
        (window as any).webkit.messageHandlers.foliaReady.postMessage(null);
    }, [clock]);
    const lines = React.useMemo(() => snapshot?.lines.map((line, index, list) => {
        const end = Math.max(line.time + 0.05, list[index + 1]?.time ?? snapshot.duration);
        return {startTime: line.time, endTime: end, fullText: line.text || '间奏',
            words: [{text: line.text || '间奏', startTime: line.time, endTime: end}]};
    }) ?? [], [snapshot]);
    useEffect(() => {
        if (!lines.length) return;
        let frame: number;
        const check = () => {
            const rail = document.querySelector('#rail>.relative');
            const bounds = rail?.getBoundingClientRect();
            const visible = bounds && [...rail!.querySelectorAll('[role=button]')].some(row => {
                const rect = row.getBoundingClientRect();
                return rect.height > 0 && rect.bottom > bounds.top && rect.top < bounds.bottom
                    && Number(getComputedStyle(row).opacity) > 0.25;
            });
            if (visible) (window as any).webkit.messageHandlers.foliaRendered?.postMessage(null);
            else frame = requestAnimationFrame(check);
        };
        frame = requestAnimationFrame(check);
        return () => cancelAnimationFrame(frame);
    }, [lines]);
    if (!snapshot || !lines.length) return null;
    const entries = buildMonetVisibleLineEntries({lines, currentLineIndex: current,
        activeLine: lines[current] ?? null, recentCompletedLine: lines[current - 1] ?? null,
        upcomingLine: lines[current + 1] ?? null, currentTime: clock.get(), before: 1, after: 1});
    return <MotionConfig reducedMotion={snapshot.reduced ? 'always' : 'never'}>
        <MonetLyricsRail key={snapshot.key} entries={entries} lines={lines} currentLineIndex={current}
            currentTime={clock} theme={{...theme, primaryColor: snapshot.albumInk ?? theme.primaryColor}}
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
