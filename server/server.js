// Receives captures from the capture page (base64 chunks relayed by client
// Lua as latent events) and writes them into the resource folder. Events
// only: no Lua<->JS callbacks (those broke the old kora_lib screenshot path).

const fs = require('fs');
const path = require('path');

const RES = GetCurrentResourceName();
const ROOT = GetResourcePath(RES);
const MAX_BYTES = 60 * 1024 * 1024;
const MAX_CHUNKS = 4096;
const UPLOAD_TIMEOUT = 5 * 60 * 1000;

const SAFE_NAME = /^[A-Za-z0-9_\-]{1,64}$/;
const TYPES = new Set(['veh', 'ped', 'obj']);
const IMAGE_EXT = new Set(['png', 'jpg']);
const VIDEO_EXT = new Set(['webm', 'mp4']);

const uploads = new Map();

function log(...args) {
	console.log('[kora_image_maker]', ...args);
}

function isAdmin(src) {
	try {
		return !!exports.kora_core.hasPermission(src, 'admin');
	} catch (err) {
		log('permission check failed:', err.message);
		return false;
	}
}

function stamp() {
	const d = new Date();
	const p = (n) => String(n).padStart(2, '0');
	return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

function unique(rel) {
	if (!fs.existsSync(path.join(ROOT, rel))) return rel;
	const ext = path.extname(rel);
	const base = rel.slice(0, -ext.length);
	for (let i = 2; i < 1000; i++) {
		const next = `${base}_${i}${ext}`;
		if (!fs.existsSync(path.join(ROOT, next))) return next;
	}
	return `${base}_${Date.now()}${ext}`;
}

// Entity photos go to images/<type>/<model>[_<angle>].png and overwrite on
// purpose (that folder is the model image library). Scene photos and videos
// are timestamped under captures/.
function targetFor(meta, ext) {
	if (!meta || typeof meta !== 'object') return null;
	if (meta.kind === 'entity') {
		if (!TYPES.has(meta.type) || !SAFE_NAME.test(meta.model || '') || !IMAGE_EXT.has(ext)) return null;
		const angle = SAFE_NAME.test(meta.angle || '') ? meta.angle : 'default';
		const name = angle === 'default' ? meta.model : `${meta.model}_${angle}`;
		return `images/${meta.type}/${name}.${ext}`;
	}
	if (meta.kind === 'scene') {
		if (!IMAGE_EXT.has(ext)) return null;
		return unique(`captures/photos/scene_${stamp()}.${ext}`);
	}
	if (meta.kind === 'video') {
		if (!VIDEO_EXT.has(ext)) return null;
		const model = SAFE_NAME.test(meta.model || '') ? meta.model : null;
		const motion = SAFE_NAME.test(meta.motion || '') ? meta.motion : 'clip';
		const base = model ? `${model}_${motion}` : motion;
		return unique(`captures/videos/${base}_${stamp()}.${ext}`);
	}
	return null;
}

function reply(src, id, ok, value) {
	emitNet('kora_image_maker:client:saved', src, id, ok, value);
}

function drop(key, src, id, error) {
	const upload = uploads.get(key);
	if (upload) clearTimeout(upload.timer);
	uploads.delete(key);
	if (error) {
		log(`upload ${id} from ${GetPlayerName(src) || src} failed: ${error}`);
		reply(src, id, false, error);
	}
}

function finalize(key, upload) {
	const { src, id, rel } = upload;
	uploads.delete(key);
	clearTimeout(upload.timer);
	try {
		const buf = Buffer.from(upload.parts.join(''), 'base64');
		if (!buf.length) throw new Error('empty file');
		if (buf.length > MAX_BYTES) throw new Error('file too large');
		const full = path.join(ROOT, rel);
		fs.mkdirSync(path.dirname(full), { recursive: true });
		fs.writeFileSync(full, buf);
		log(`saved ${rel} (${(buf.length / 1024).toFixed(0)} KB) for ${GetPlayerName(src) || src}`);
		reply(src, id, true, rel);
	} catch (err) {
		log(`could not save ${rel}: ${err.message}`);
		reply(src, id, false, `Could not save: ${err.message}`);
	}
}

onNet('kora_image_maker:server:begin', (id, meta, n, bytes, ext) => {
	const src = source;
	if (typeof id !== 'string' || id.length > 64) return;
	const key = `${src}:${id}`;

	if (!isAdmin(src)) return reply(src, id, false, 'Admin permission required.');
	if (!Number.isInteger(n) || n < 1 || n > MAX_CHUNKS) return reply(src, id, false, 'Bad chunk count.');
	if (typeof bytes === 'number' && bytes > MAX_BYTES) {
		return reply(src, id, false, `File is over the ${MAX_BYTES / 1048576} MB limit.`);
	}
	const rel = targetFor(meta, ext);
	if (!rel) return reply(src, id, false, 'Invalid capture name or format.');

	drop(key, src, id);
	uploads.set(key, {
		src, id, rel, n,
		got: 0,
		size: 0,
		parts: new Array(n),
		timer: setTimeout(() => drop(key, src, id, 'Upload timed out.'), UPLOAD_TIMEOUT),
	});
});

onNet('kora_image_maker:server:chunk', (id, i, data) => {
	const src = source;
	const key = `${src}:${id}`;
	const upload = uploads.get(key);
	if (!upload) return;
	if (!Number.isInteger(i) || i < 0 || i >= upload.n || typeof data !== 'string' || upload.parts[i] !== undefined) return;

	upload.parts[i] = data;
	upload.size += data.length;
	if (upload.size > Math.ceil(MAX_BYTES / 3) * 4 + 4) return drop(key, src, id, 'File too large.');
	if (++upload.got === upload.n) finalize(key, upload);
});

on('playerDropped', () => {
	const prefix = `${source}:`;
	for (const [key, upload] of uploads) {
		if (key.startsWith(prefix)) {
			clearTimeout(upload.timer);
			uploads.delete(key);
		}
	}
});
