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
    alias: {folia: path.join(source, 'src/components/visualizer/monet')},
    nodePaths: [path.join(dependencies, 'node_modules')],
    plugins: [{
        name: 'notch-active-lyric-contrast',
        setup(builder) {
            builder.onLoad({filter: /monetRailLayout\.ts$/}, async ({path}) => {
                const upstream = await readFile(path, 'utf8');
                const adjustments = [
                    ['baseColor: colorWithAlpha(theme.primaryColor, 0.34),',
                     'baseColor: colorWithAlpha(theme.primaryColor, 0.96),'],
                    ['clamp(0.72 - (distance - 1) * 0.18, 0.36, 0.72)',
                     'clamp(0.88 - (distance - 1) * 0.18, 0.36, 0.88)'],
                    ['isWaiting ? 0.46 : 0.36', 'isWaiting ? 0.98 : 0.36'],
                    ['const layout = getOrMeasureMonetLineLayout(layoutCache, entry, measureInputs);',
                     String.raw`if (/^(?:作[词詞曲]|[编編]曲|[词詞曲]|[製制]作人?)[\s]*[:：]/u.test(entry.line.fullText.trim())) {
            tone.scale *= 0.72;
            tone.opacity *= 0.88;
        }
        const layout = getOrMeasureMonetLineLayout(layoutCache, entry, measureInputs);`],
                    ['const focusCenterY = railHeight * 0.46;', 'const focusCenterY = Math.max(railHeight * 0.40, measuredEntries[anchorIndex].scaledHeight / 2 + 2);'],
                    ['Math.max(MONET_ACTIVE_GAP_PX, lyricFontPx * MONET_ACTIVE_GAP_RATIO)',
                     'Math.min(10, Math.max(MONET_ACTIVE_GAP_PX, lyricFontPx * MONET_ACTIVE_GAP_RATIO))'],
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
const css = `html,body{margin:0;overflow:hidden;background:transparent;color:white;font-family:-apple-system}
*{box-sizing:border-box}.relative{position:relative}.absolute{position:absolute}.block{display:block}
.top-0{top:0}.left-0{left:0}.right-0{right:0}.top-1\\/2{top:50%}.-translate-y-1\\/2{translate:0 -50%}
.min-w-0{min-width:0}.w-full{width:100%}.max-w-full{max-width:100%}.overflow-hidden{overflow:hidden}
.pointer-events-none{pointer-events:none}.select-none{user-select:none}.cursor-pointer{cursor:pointer}
.whitespace-pre-wrap{white-space:pre-wrap}.break-words{overflow-wrap:break-word}
.inline-block{display:inline-block}.inset-0{inset:0}
#rail>.relative{height:100vh!important;max-width:none!important;mask-image:linear-gradient(black 0%,black 84%,transparent 100%)!important}
#rail{filter:drop-shadow(0 1px 1px #374458c0) drop-shadow(0 0 1px #485670a0)}`;
const script = bundle.outputFiles[0].text.replace(/<\/script/gi, '<\\/script');
await writeFile(output, `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><meta http-equiv=Content-Security-Policy content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'"><style>${css}</style><div id=rail></div><script>${script}</script>`);
