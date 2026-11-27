import {createRequire} from 'node:module';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const [source, dependencies, output] = process.argv.slice(2).map(value => path.resolve(value));
const require = createRequire(path.join(dependencies, 'package.json'));
const {build} = require('esbuild');
const bundle = await build({
    entryPoints: [new URL('folia-rail.tsx', import.meta.url).pathname],
    bundle: true, write: false, minify: true, platform: 'browser', target: 'safari17',
    define: {'process.env.NODE_ENV': '"production"'},
    alias: {
        folia: path.join(source, 'src/components/visualizer/monet'),
        foliaUtils: path.join(source, 'src/utils'),
    },
    nodePaths: [path.join(dependencies, 'node_modules')],
    plugins: [{
        name: 'notch-active-lyric-contrast',
        setup(builder) {
            builder.onLoad({filter: /monetLyricMotion\.ts$/}, async ({path}) => {
                const upstream = await readFile(path, 'utf8');
                const contents = upstream
                    .replace(
                        'export const MONET_SCROLL_SPRING = { stiffness: 142, damping: 28, mass: 0.82 };',
                        'export const MONET_SCROLL_SPRING = { stiffness: 265, damping: 31, mass: 0.72 };',
                    )
                    .replace(
                        'export const MONET_SCALE_SPRING = { stiffness: 150, damping: 30, mass: 0.78 };',
                        'export const MONET_SCALE_SPRING = { stiffness: 270, damping: 32, mass: 0.72 };',
                    );
                return {contents, loader: 'ts'};
            });
            builder.onLoad({filter: /monetLyricsModel\.ts$/}, async ({path}) => {
                const upstream = await readFile(path, 'utf8');
                const contents = upstream
                    .replace('const MONET_INACTIVE_TEXT_LINE_LIMIT = 2;', 'const MONET_INACTIVE_TEXT_LINE_LIMIT = 4;')
                    .replace('const MONET_MIN_MEASURE_WIDTH_PX = 180;', 'const MONET_MIN_MEASURE_WIDTH_PX = 80;')
                    .replace('Math.max(fontPx * 0.16, 8)', '2')
                    .replace('Math.max(fontPx * 0.34, 14)', '4');
                return {contents, loader: 'ts'};
            });
            builder.onLoad({filter: /monetRailLayout\.ts$/}, async ({path}) => {
                const upstream = await readFile(path, 'utf8');
                const adjustments = [
                    ['baseColor: colorWithAlpha(theme.primaryColor, 0.34),',
                     'baseColor: colorWithAlpha(theme.primaryColor, 0.52),'],
                    ['clamp(0.72 - (distance - 1) * 0.18, 0.36, 0.72)',
                     'clamp(0.84 - (distance - 1) * 0.20, 0.34, 0.84)'],
                    ['isWaiting ? 0.46 : 0.36', 'isWaiting ? 0.76 : 0.46'],
                    ['const layout = getOrMeasureMonetLineLayout(layoutCache, entry, measureInputs);',
                     String.raw`if (/^(?:作[词詞曲]|[编編]曲|[词詞曲]|[製制]作人?)[\s]*[:：]/u.test(entry.line.fullText.trim())) {
            tone.scale *= 0.78;
            tone.opacity *= 0.88;
        }
        const layout = getOrMeasureMonetLineLayout(layoutCache, entry, measureInputs);`],
                    [
                        `const focusCenterY = railHeight * 0.46;\n    measuredEntries[anchorIndex].y = focusCenterY - measuredEntries[anchorIndex].scaledHeight / 2;`,
                        `const anchorHeight = measuredEntries[anchorIndex].scaledHeight;
    const rawCenterY = measuredEntries.length === 1
        ? railHeight * 0.48
        : anchorIndex === 0
            ? Math.min(railHeight * 0.30, anchorHeight / 2 + 4)
            : railHeight * 0.34;
    const unclampedY = rawCenterY - anchorHeight / 2;
    measuredEntries[anchorIndex].y = anchorHeight <= railHeight - 4
        ? clamp(unclampedY, 2, railHeight - anchorHeight - 2)
        : 1;`,
                    ],
                    ['Math.max(MONET_ACTIVE_GAP_PX, lyricFontPx * MONET_ACTIVE_GAP_RATIO)', '4'],
                    ['Math.max(MONET_INACTIVE_GAP_PX, lyricFontPx * MONET_INACTIVE_GAP_RATIO)', '3'],
                ];
                let contents = upstream;
                for (const [before, after] of adjustments) {
                    if (!contents.includes(before)) throw new Error('Review Monet compact layout for this Folia revision');
                    contents = contents.replace(before, after);
                }
                return {contents, loader: 'ts'};
            });
        },
    }],
});
const css = `html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:transparent;color:white;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}
*{box-sizing:border-box}.relative{position:relative}.absolute{position:absolute}.block{display:block}
.top-0{top:0}.left-0{left:0}.right-0{right:0}.top-1\\/2{top:50%}.-translate-y-1\\/2{translate:0 -50%}
.min-w-0{min-width:0}.w-full{width:100%}.max-w-full{max-width:100%}.overflow-hidden{overflow:hidden}
.pointer-events-none{pointer-events:none}.select-none{user-select:none}.cursor-pointer{cursor:pointer}
.whitespace-pre-wrap{white-space:pre-wrap}.break-words{overflow-wrap:anywhere;word-break:break-word}
.inline-block{display:inline-block}.inset-0{inset:0}
#rail{width:100%;height:100%;filter:drop-shadow(0 1px 1.5px #111827b8) drop-shadow(0 0 1px #37445890)}
#rail>.relative{width:100%!important;height:100vh!important;max-width:none!important;mask-image:linear-gradient(to bottom,transparent 0%,black 4%,black 93%,transparent 100%)!important;-webkit-mask-image:linear-gradient(to bottom,transparent 0%,black 4%,black 93%,transparent 100%)!important}`;
const script = bundle.outputFiles[0].text.replace(/<\/script/gi, '<\\/script');
await writeFile(output, `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><meta http-equiv=Content-Security-Policy content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'"><style>${css}</style><div id=rail></div><script>${script}</script>`);
