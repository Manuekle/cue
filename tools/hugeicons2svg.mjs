// Convierte íconos de @hugeicons/core-free-icons (npm pack, carpeta dist/cjs) en imagesets plantilla para Xcode.
// Uso: node tools/hugeicons2svg.mjs [--fill] <dist/cjs> Shared/Hugeicons.xcassets 1.8 Mic01:hi-mic Play:hi-play ...
// Lee los módulos como TEXTO (no los ejecuta). currentColor pasa a negro; el color real lo pone foregroundStyle.
import fs from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
// --fill: variante "rellena" para botones redondos: las formas cerradas (que terminan en Z) se rellenan;
// las líneas abiertas siguen siendo trazo.
const fill = args.includes('--fill');
const [cjsDir, outDir, strokeWidth, ...pairs] = args.filter((a) => a !== '--fill');
const kebab = (k) => k.replace(/[A-Z]/g, (m) => '-' + m.toLowerCase());
for (const pair of pairs) {
  const [name, asset] = pair.split(':');
  const src = fs.readFileSync(path.join(cjsDir, `${name}Icon.js`), 'utf8');
  const body = src.slice(src.indexOf('= [') + 2, src.lastIndexOf('];') + 1);
  const json = body.replace(/([{,]\s*)([A-Za-z][A-Za-z0-9]*)\s*:/g, '$1"$2":');
  const nodes = JSON.parse(json);
  const tags = new Set();
  const els = nodes.map(([tag, attrs]) => {
    tags.add(tag);
    const closed = tag === 'circle' || tag === 'rect' || (tag === 'path' && /z\s*$/i.test(attrs.d || ''));
    if (fill && closed) attrs = { ...attrs, fill: '#000000' };
    const parts = Object.entries(attrs)
      .filter(([k]) => k !== 'key')
      .map(([k, v]) => {
        let val = String(v).replace(/currentColor/g, '#000000');
        if (k === 'strokeWidth') val = strokeWidth;
        return `${kebab(k)}="${val}"`;
      });
    return `  <${tag} ${parts.join(' ')}/>`;
  });
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">\n${els.join('\n')}\n</svg>\n`;
  const dir = path.join(outDir, `${asset}.imageset`);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${asset}.svg`), svg);
  // Variantes rellenas con recortes (líneas de texto huecas) que el relleno automático no puede hacer.
  const override = path.join(path.dirname(new URL(import.meta.url).pathname), 'fill-overrides', `${asset}.svg`);
  if (fill && fs.existsSync(override)) fs.copyFileSync(override, path.join(dir, `${asset}.svg`));
  fs.writeFileSync(path.join(dir, 'Contents.json'), JSON.stringify({
    images: [{ filename: `${asset}.svg`, idiom: 'universal' }],
    info: { author: 'xcode', version: 1 },
    properties: { 'preserves-vector-representation': true, 'template-rendering-intent': 'template' },
  }, null, 2) + '\n');
  console.log(asset, [...tags].join(','), /fill="#000000"/.test(svg) ? 'FILL' : '');
}
