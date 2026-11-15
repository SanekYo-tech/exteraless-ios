// Development-only reference vector recorder. Never runs in an app/build.
// Node 24 --experimental-transform-types; pass the independently checked-out
// MCU TypeScript directory at commit 194144d75ed7d34f06264a625e086db81a7ab9aa.
// For Node, only import suffixes (.js -> .ts) are changed in that scratch copy.
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';

const root = resolve(process.argv[2]);
const {Hct} = await import(pathToFileURL(resolve(root, 'hct/hct.ts')));
const {Blend} = await import(pathToFileURL(resolve(root, 'blend/blend.ts')));
const hex = color => (color >>> 0).toString(16).padStart(8, '0').toUpperCase();
const systemTones = [100, 99, 95, 90, 80, 70, 60, 50, 40, 30, 20, 10, 0];

function palette(seed) {
  const source = Hct.fromInt(seed);
  const neutral = source.chroma < 8;
  const specs = {
    a1: [source.hue, neutral ? source.chroma : Math.max(48, source.chroma)],
    a2: [source.hue, neutral ? source.chroma : 16],
    a3: [neutral ? source.hue : source.hue + 60, neutral ? source.chroma : 24],
    n1: [source.hue, neutral ? Math.min(4, source.chroma) : 4],
    n2: [source.hue, neutral ? Math.min(8, source.chroma) : 8],
  };
  const system = {};
  for (const [id, [hue, chroma]] of Object.entries(specs)) {
    system[id] = Object.fromEntries(systemTones.map(tone => [tone, Hct.from(hue, chroma, tone).toInt()]));
  }
  function at(id, tone) {
    if (systemTones.includes(tone)) return system[id][tone];
    // Original MonetHelper.resolveRoleTone / setLuminance, not direct seed HCT.
    const key = Hct.fromInt(system[id][40]);
    return Hct.from(key.hue, key.chroma, tone).toInt();
  }
  return {at, system};
}

const output = {mcu_commit: '194144d75ed7d34f06264a625e086db81a7ab9aa', seeds: []};
for (const seed of [0xff6750a4, 0xff007aff, 0xff777777]) {
  const {at, system} = palette(seed);
  const neutral = Hct.fromInt(at('a1', 50)).chroma < 8;
  function link(value) {
    if (!neutral) return value;
    return Hct.from(250, 70, Hct.fromInt(value).tone).toInt();
  }
  const matched = Hct.fromInt(Blend.harmonize(0xff0000ff, at('a1', 50)));
  const custom = Hct.from(matched.hue, Hct.fromInt(at('a1', 50)).chroma * 0.9, matched.tone);
  const vectors = {
    a1_600: at('a1', 40), a1_200: at('a1', 80), n1_900: at('n1', 10),
    primary_light: at('a1', 40), primary_dark: at('a1', 80),
    background_light: at('n2', 98), background_dark: at('n2', 6),
    surface_container_high_dark: at('n2', 17),
    surface_container_highest_dark: at('n2', 22),
    primary_fixed: at('a1', 90),
    neutral_primary_link_light: link(at('a1', 40)),
    neutral_primary_link_dark: link(at('a1', 80)),
    harmonized_mRed500: Blend.harmonize(0xfff44336, at('a1', 40)),
    blue_50: Hct.from(custom.hue, custom.chroma, 50).toInt(),
  };
  const frames = [
    ['Telemone', 'Light', at('n2', 98), at('n2', 90), at('a1', 90)],
    ['Telemone', 'Dark', at('n2', 6), at('n2', 22), at('a1', 30)],
    ['Telemone', 'AMOLED', 0xff000000, at('n2', 22), at('a1', 30)],
    ['Classic', 'Light', 0xffffffff, at('n1', 95), at('a1', 40)],
    ['Classic', 'Dark', at('n1', 10), at('n1', 20), at('a1', 80)],
    ['Classic', 'AMOLED', 0xff000000, at('n1', 20), at('a1', 80)],
  ].map(([style, mode, background, incoming, outgoing]) => ({style, mode, background: hex(background), incoming: hex(incoming), outgoing: hex(outgoing)}));
  output.seeds.push({seed: hex(seed), neutral, vectors: Object.fromEntries(Object.entries(vectors).map(([k, v]) => [k, hex(v)])), frames,
    system: Object.fromEntries(Object.entries(system).map(([id, values]) => [id, Object.fromEntries(Object.entries(values).map(([tone, v]) => [tone, hex(v)]))]))});
}
console.log(JSON.stringify(output, null, 2));
