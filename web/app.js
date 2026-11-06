'use strict';

// kora_image_maker capture page. Renders the game view through CitizenFX's
// game-texture hook, so photos and videos are taken here in the browser:
// green-screen keying, cropping, PNG/JPEG encoding and MediaRecorder video.
// Results go to the server in base64 chunks (relayed by client Lua as latent
// events) and, when asked, straight to a Discord webhook.

const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'kora_image_maker';
const CHUNK_CHARS = 256 * 1024;
const DISCORD_LIMIT = 10 * 1024 * 1024;
const STORE_LIMIT = 12;

// Greenness (g - max(r, b)) thresholds: below KEY_LO is kept, above KEY_HI is
// fully removed, in between fades. Matches the video shader's 0.12..0.31.
const KEY_LO = 30;
const KEY_HI = 80;
const DESPILL_FROM = 12;

const BACKGROUNDS = {
  black: [0, 0, 0],
  white: [255, 255, 255],
  green: [0, 255, 0],
};

function post(name, data) {
  return fetch(`https://${RES}/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(data ?? {}),
  }).then((r) => r.json()).catch(() => ({}));
}

function frames(n) {
  return new Promise((resolve) => {
    const step = () => (--n <= 0 ? resolve() : requestAnimationFrame(step));
    requestAnimationFrame(step);
  });
}

function errorText(err) {
  return String((err && err.message) || err || 'Unknown error');
}

// ---------------------------------------------------------------- game view

const VERTEX_SHADER = `
attribute vec2 a_pos;
attribute vec2 a_uv;
varying vec2 v_uv;
void main() {
  v_uv = a_uv;
  gl_Position = vec4(a_pos, 0.0, 1.0);
}`;

const FRAGMENT_SHADER = `
precision mediump float;
varying vec2 v_uv;
uniform sampler2D u_tex;
uniform float u_key;
uniform vec3 u_bg;
void main() {
  vec3 c = texture2D(u_tex, v_uv).rgb;
  if (u_key > 0.5) {
    float m = max(c.r, c.b);
    float spill = c.g - m;
    float a = 1.0 - smoothstep(0.12, 0.31, spill);
    if (spill > 0.05) c.g = m;
    c = mix(u_bg, c, a);
  }
  gl_FragColor = vec4(c, 1.0);
}`;

function compile(gl, type, src) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, src);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
  return shader;
}

// Same upload sequence as @citizenfx/three's CfxTexture: a 1x1 RGB texture,
// then the WRAP_T CLAMP -> MIRRORED -> REPEAT sequence, which the CitizenFX
// CEF build intercepts to bind the game's render target to this texture.
function createGameTexture(gl) {
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
  gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, 1, 1, 0, gl.RGB, gl.UNSIGNED_BYTE, new Uint8Array(3));
  gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT);
  gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
  return tex;
}

class GameView {
  constructor() {
    this.canvas = document.createElement('canvas');
    this.canvas.style.display = 'none';
    document.body.appendChild(this.canvas);

    const gl = this.canvas.getContext('webgl', {
      alpha: false, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: true,
    });
    if (!gl) throw new Error('WebGL is unavailable in this NUI frame.');
    this.gl = gl;

    const program = gl.createProgram();
    gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, VERTEX_SHADER));
    gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, FRAGMENT_SHADER));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
    this.program = program;

    // Clip-space bottom-left samples v=0: the game texture is bottom-up, so
    // this draws the frame upright.
    this.posBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.posBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    this.uvBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.uvBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);

    this.aPos = gl.getAttribLocation(program, 'a_pos');
    this.aUv = gl.getAttribLocation(program, 'a_uv');
    this.uTex = gl.getUniformLocation(program, 'u_tex');
    this.uKey = gl.getUniformLocation(program, 'u_key');
    this.uBg = gl.getUniformLocation(program, 'u_bg');

    this.texture = createGameTexture(gl);
    this.key = false;
    this.bg = [0, 0, 0];
    this.users = 0;
    this.raf = null;
    this.onFrame = null;
  }

  resize(width, height) {
    width = Math.max(2, Math.floor(width));
    height = Math.max(2, Math.floor(height));
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }
  }

  draw() {
    const gl = this.gl;
    gl.viewport(0, 0, this.canvas.width, this.canvas.height);
    gl.useProgram(this.program);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.posBuffer);
    gl.enableVertexAttribArray(this.aPos);
    gl.vertexAttribPointer(this.aPos, 2, gl.FLOAT, false, 0, 0);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.uvBuffer);
    gl.enableVertexAttribArray(this.aUv);
    gl.vertexAttribPointer(this.aUv, 2, gl.FLOAT, false, 0, 0);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.texture);
    gl.uniform1i(this.uTex, 0);
    gl.uniform1f(this.uKey, this.key ? 1 : 0);
    gl.uniform3f(this.uBg, this.bg[0] / 255, this.bg[1] / 255, this.bg[2] / 255);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  start() {
    if (this.users++ > 0) return;
    const loop = () => {
      this.draw();
      if (this.onFrame) this.onFrame();
      this.raf = requestAnimationFrame(loop);
    };
    this.raf = requestAnimationFrame(loop);
  }

  stop() {
    if (this.users === 0 || --this.users > 0) return;
    cancelAnimationFrame(this.raf);
    this.raf = null;
  }
}

let gameView = null;
function view() {
  if (!gameView) gameView = new GameView();
  return gameView;
}

// ------------------------------------------------------------------ photos

// Keys out the green backdrop in place. bg = null leaves alpha transparency,
// otherwise composites onto that colour. Returns the visible bounding box.
function keyPixels(d, w, h, bg) {
  let minX = w, minY = h, maxX = -1, maxY = -1;
  for (let y = 0; y < h; y++) {
    let i = y * w * 4;
    for (let x = 0; x < w; x++, i += 4) {
      const r = d[i], g = d[i + 1], b = d[i + 2];
      const m = r > b ? r : b;
      const spill = g - m;
      let a = 255;
      if (spill > KEY_LO) a = spill >= KEY_HI ? 0 : Math.round(255 * (KEY_HI - spill) / (KEY_HI - KEY_LO));
      if (spill > DESPILL_FROM) d[i + 1] = m;
      if (bg) {
        const t = a / 255, u = 1 - t;
        d[i] = d[i] * t + bg[0] * u;
        d[i + 1] = d[i + 1] * t + bg[1] * u;
        d[i + 2] = d[i + 2] * t + bg[2] * u;
        d[i + 3] = 255;
      } else {
        d[i + 3] = a;
      }
      if (a > 24) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  return maxX < 0 ? null : { x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1 };
}

function toBlob(canvas, mime, quality) {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('Could not encode the image.'))), mime, quality);
  });
}

// opts: { key, background: 'transparent'|'black'|'white'|'green', crop, padding, maxSize, format: 'png'|'jpg', quality }
async function capturePhoto(opts) {
  if (recording) throw new Error('A recording is in progress.');
  const gv = view();
  gv.resize(window.innerWidth, window.innerHeight);
  gv.key = false;
  gv.start();
  try {
    await frames(3);
    gv.draw();
  } finally {
    gv.stop();
  }

  const w = gv.canvas.width, h = gv.canvas.height;
  const src = document.createElement('canvas');
  src.width = w;
  src.height = h;
  const ctx = src.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(gv.canvas, 0, 0);

  let region = { x: 0, y: 0, w, h };
  if (opts.key) {
    const img = ctx.getImageData(0, 0, w, h);
    const bg = BACKGROUNDS[opts.background] || null;
    const box = keyPixels(img.data, w, h, bg);
    if (!box) throw new Error('Nothing visible after removing the green screen (model not rendered?).');
    ctx.putImageData(img, 0, 0);
    if (opts.crop !== false) {
      const pad = Math.round(Math.max(box.w, box.h) * (typeof opts.padding === 'number' ? opts.padding : 0.02));
      const x = Math.max(0, box.x - pad), y = Math.max(0, box.y - pad);
      region = { x, y, w: Math.min(w, box.x + box.w + pad) - x, h: Math.min(h, box.y + box.h + pad) - y };
    }
  }

  const longest = Math.max(region.w, region.h);
  const scale = opts.maxSize > 0 && longest > opts.maxSize ? opts.maxSize / longest : 1;
  const out = document.createElement('canvas');
  out.width = Math.max(1, Math.round(region.w * scale));
  out.height = Math.max(1, Math.round(region.h * scale));
  const octx = out.getContext('2d');
  octx.imageSmoothingEnabled = true;
  octx.imageSmoothingQuality = 'high';
  if (opts.format === 'jpg' && !(opts.key && BACKGROUNDS[opts.background])) {
    octx.fillStyle = '#000';
    octx.fillRect(0, 0, out.width, out.height);
  }
  octx.drawImage(src, region.x, region.y, region.w, region.h, 0, 0, out.width, out.height);

  const mime = opts.format === 'jpg' ? 'image/jpeg' : 'image/png';
  const blob = await toBlob(out, mime, typeof opts.quality === 'number' ? opts.quality : 0.92);
  return { blob, width: out.width, height: out.height };
}

// ------------------------------------------------------------------ video

let recording = null;

function pickVideoMime() {
  if (typeof MediaRecorder === 'undefined') return null;
  const candidates = [
    'video/mp4;codecs=avc1',
    'video/webm;codecs=vp8',
    'video/webm;codecs=vp9',
    'video/webm',
  ];
  return candidates.find((type) => MediaRecorder.isTypeSupported(type)) || null;
}

// Keeps a Discord-bound clip under the 10 MB upload cap; otherwise a quality default.
function pickBitrate(opts, height) {
  const base = height >= 1000 ? 8000000 : 5000000;
  if (!opts.discord || !(opts.seconds > 0)) return base;
  const fit = Math.floor((9 * 1024 * 1024 * 8) / opts.seconds);
  return Math.max(1000000, Math.min(base, fit));
}

function overlay(show, text, hint) {
  document.getElementById('rec').style.display = show ? 'block' : 'none';
  if (text !== undefined) document.getElementById('rec-text').textContent = text;
  if (hint !== undefined) document.getElementById('rec-hint').textContent = hint || '';
}

function clock(ms) {
  const s = Math.floor(ms / 1000);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

// opts: { key, background, height, fps, seconds, discord, hint }
async function startRecording(id, opts) {
  if (recording) throw new Error('A recording is already in progress.');
  const mime = pickVideoMime();
  if (!mime) throw new Error('MediaRecorder video is not supported by this client.');

  const gv = view();
  gv.resize(window.innerWidth, window.innerHeight);
  gv.key = !!opts.key;
  gv.bg = BACKGROUNDS[opts.background] || BACKGROUNDS.black;

  const height = Math.min(opts.height > 0 ? opts.height : window.innerHeight, window.innerHeight);
  const width = Math.round((height * window.innerWidth) / window.innerHeight / 2) * 2;
  const out = document.createElement('canvas');
  out.width = width;
  out.height = Math.round(height / 2) * 2;
  const ctx = out.getContext('2d');
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  gv.onFrame = () => ctx.drawImage(gv.canvas, 0, 0, out.width, out.height);

  const stream = out.captureStream(opts.fps > 0 ? opts.fps : 30);
  const recorder = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: pickBitrate(opts, out.height) });
  const chunks = [];
  recorder.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };

  gv.start();
  await frames(2);
  recorder.start(1000);

  const started = performance.now();
  const ticker = setInterval(() => overlay(true, `REC ${clock(performance.now() - started)}`), 250);
  overlay(true, 'REC 0:00', opts.hint || '');

  recording = { id, recorder, chunks, mime, stream, gv, ticker, width: out.width, height: out.height, started };
}

function stopRecording(id) {
  const rec = recording;
  if (!rec || rec.id !== id) return Promise.reject(new Error('No matching recording.'));
  recording = null;
  clearInterval(rec.ticker);
  overlay(false);

  return new Promise((resolve, reject) => {
    rec.recorder.onstop = () => {
      rec.gv.onFrame = null;
      rec.gv.stop();
      rec.stream.getTracks().forEach((t) => t.stop());
      const type = rec.mime.split(';')[0];
      const blob = new Blob(rec.chunks, { type });
      if (!blob.size) reject(new Error('The recording came out empty.'));
      else resolve({ blob, width: rec.width, height: rec.height, seconds: (performance.now() - rec.started) / 1000 });
    };
    rec.recorder.onerror = (e) => reject(new Error(errorText(e.error || e)));
    rec.recorder.stop();
  });
}

// --------------------------------------------------------- upload/discord

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error('Could not read the capture.'));
    reader.onload = () => {
      const s = String(reader.result);
      resolve(s.slice(s.indexOf(',') + 1));
    };
    reader.readAsDataURL(blob);
  });
}

async function upload(id, blob) {
  const b64 = await blobToBase64(blob);
  const n = Math.max(1, Math.ceil(b64.length / CHUNK_CHARS));
  const begin = await post('uploadBegin', { id, n, bytes: blob.size, mime: blob.type });
  if (!begin.ok) throw new Error(begin.error || 'Upload was refused.');
  for (let i = 0; i < n; i++) {
    const res = await post('uploadChunk', { id, i, data: b64.slice(i * CHUNK_CHARS, (i + 1) * CHUNK_CHARS) });
    if (!res.ok) throw new Error(res.error || 'Upload chunk was refused.');
  }
}

function withWait(url) {
  return url + (url.includes('?') ? '&' : '?') + 'wait=true';
}

async function discordFile(discord, blob, filename) {
  if (blob.size > DISCORD_LIMIT) {
    return { ok: false, error: `File is ${(blob.size / 1048576).toFixed(1)} MB, over Discord's 10 MB limit.` };
  }
  const form = new FormData();
  form.append('payload_json', JSON.stringify({
    content: discord.content || '',
    username: 'Kora Image Maker',
    allowed_mentions: { parse: [] },
  }));
  form.append('files[0]', blob, filename);
  try {
    const res = await fetch(withWait(discord.url), { method: 'POST', body: form });
    if (!res.ok) return { ok: false, error: `Discord ${res.status}: ${(await res.text()).slice(0, 160)}` };
    return { ok: true };
  } catch (err) {
    return { ok: false, error: errorText(err) };
  }
}

async function discordText(url, content) {
  try {
    const res = await fetch(withWait(url), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content, username: 'Kora Image Maker', allowed_mentions: { parse: [] } }),
    });
    if (!res.ok) return { ok: false, error: `Discord ${res.status}: ${(await res.text()).slice(0, 160)}` };
    return { ok: true };
  } catch (err) {
    return { ok: false, error: errorText(err) };
  }
}

// Recent captures stay in memory so the history list can re-post them.
const store = new Map();
function remember(id, blob, filename) {
  store.set(id, { blob, filename });
  while (store.size > STORE_LIMIT) store.delete(store.keys().next().value);
}

// Uploads to the server and posts to Discord in parallel; upload decides ok.
const EXT_BY_MIME = { 'image/png': 'png', 'image/jpeg': 'jpg', 'video/webm': 'webm', 'video/mp4': 'mp4' };
function filenameFor(name, mime) {
  const ext = EXT_BY_MIME[String(mime).split(';')[0]] || 'bin';
  return `${String(name || 'capture').replace(/\.[^.]+$/, '')}.${ext}`;
}

async function deliver(id, msg, capture) {
  const filename = filenameFor(msg.filename, capture.blob.type);
  remember(id, capture.blob, filename);
  const [up, discord] = await Promise.all([
    upload(id, capture.blob).then(() => null, (err) => errorText(err)),
    msg.discord ? discordFile(msg.discord, capture.blob, filename) : Promise.resolve(undefined),
  ]);
  const base = { id, width: capture.width, height: capture.height, bytes: capture.blob.size, mime: capture.blob.type, discord };
  if (up) return { ...base, ok: false, error: `Saving failed: ${up}` };
  return { ...base, ok: true };
}

// ---------------------------------------------------------------- messages

const handlers = {
  async photo(msg) {
    const capture = await capturePhoto(msg.opts || {});
    return deliver(msg.id, msg, capture);
  },

  async recordStart(msg) {
    try {
      await startRecording(msg.id, msg.opts || {});
      await post('recordStarted', { id: msg.id, ok: true });
    } catch (err) {
      await post('recordStarted', { id: msg.id, ok: false, error: errorText(err) });
    }
    return null;
  },

  async recordStop(msg) {
    const capture = await stopRecording(msg.id);
    return deliver(msg.id, msg, capture);
  },

  async repost(msg) {
    const entry = store.get(msg.sourceId);
    if (!entry) return { id: msg.id, ok: false, error: 'That capture is no longer in memory (only the last 12 are kept).' };
    const discord = await discordFile(msg.discord, entry.blob, entry.filename);
    return { id: msg.id, ok: discord.ok, error: discord.error, discord };
  },

  async testWebhook(msg) {
    const discord = await discordText(msg.url, msg.content || 'Kora Image Maker webhook test.');
    return { id: msg.id, ok: discord.ok, error: discord.error, discord };
  },

  async cancelRecording(msg) {
    if (recording && recording.id === msg.id) await stopRecording(msg.id).catch(() => null);
    return null;
  },
};

window.addEventListener('message', (event) => {
  const msg = event.data;
  if (!msg || typeof msg.action !== 'string' || msg.app !== 'kora_image_maker') return;
  const handler = handlers[msg.action];
  if (!handler) return;
  Promise.resolve()
    .then(() => handler(msg))
    .then((result) => { if (result) return post('result', result); })
    .catch((err) => post('result', { id: msg.id, ok: false, error: errorText(err) }));
});
