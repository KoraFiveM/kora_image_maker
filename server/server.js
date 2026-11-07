// Receives captures from the capture page (base64 chunks relayed by client
// Lua as latent events) and writes them into the resource folder. Events
// only: no Lua<->JS callbacks (those broke the old kora_lib screenshot path).
// Also posts to Discord: Discord answers webhook calls from the in-game
// browser with 403 / code 40333, so it has to come from the server.

const fs = require('fs');
const path = require('path');
const https = require('https');

const RES = GetCurrentResourceName();
const ROOT = GetResourcePath(RES);
const MAX_BYTES = 60 * 1024 * 1024;
const MAX_CHUNKS = 4096;
const UPLOAD_TIMEOUT = 5 * 60 * 1000;

const SAFE_NAME = /^[A-Za-z0-9_\-]{1,64}$/;
const TYPES = new Set(['veh', 'ped', 'obj']);
const IMAGE_EXT = new Set(['png', 'jpg']);
const VIDEO_EXT = new Set(['webm', 'mp4']);

const DISCORD_LIMIT = 10 * 1024 * 1024;
const DISCORD_UA = 'DiscordBot (https://github.com/KoraFiveM/kora_image_maker, 1.1)';
const MIME = { png: 'image/png', jpg: 'image/jpeg', webm: 'video/webm', mp4: 'video/mp4' };

const uploads = new Map();

function webhookUrl(url) {
	if (typeof url !== 'string') return null;
	let u;
	try {
		u = new URL(url.trim());
	} catch {
		return null;
	}
	if (u.protocol !== 'https:') return null;
	if (!/^(?:[a-z]+\.)?discord(?:app)?\.com$/.test(u.hostname)) return null;
	if (!/^\/api\/webhooks\/\d+\/[\w-]+\/?$/.test(u.pathname)) return null;
	u.searchParams.set('wait', 'true');
	return u;
}

// file: { name, buf } or null for a text-only message. Resolves { ok, error? }.
function discordPost(url, content, file) {
	return new Promise((resolve) => {
		const u = webhookUrl(url);
		if (!u) return resolve({ ok: false, error: 'Not a Discord webhook URL.' });
		if (file && file.buf.length > DISCORD_LIMIT) {
			return resolve({ ok: false, error: `File is ${(file.buf.length / 1048576).toFixed(1)} MB, over Discord's 10 MB limit.` });
		}

		const payload = JSON.stringify({
			content: typeof content === 'string' ? content.slice(0, 2000) : '',
			username: 'Kora Image Maker',
			allowed_mentions: { parse: [] },
		});
		let body;
		const headers = { 'User-Agent': DISCORD_UA };
		if (file) {
			const boundary = `----KoraImageMaker${Date.now().toString(16)}${Math.random().toString(16).slice(2)}`;
			const ext = path.extname(file.name).slice(1);
			body = Buffer.concat([
				Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="payload_json"\r\nContent-Type: application/json\r\n\r\n${payload}\r\n`),
				Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="files[0]"; filename="${file.name}"\r\nContent-Type: ${MIME[ext] || 'application/octet-stream'}\r\n\r\n`),
				file.buf,
				Buffer.from(`\r\n--${boundary}--\r\n`),
			]);
			headers['Content-Type'] = `multipart/form-data; boundary=${boundary}`;
		} else {
			body = Buffer.from(payload);
			headers['Content-Type'] = 'application/json';
		}
		headers['Content-Length'] = body.length;

		const req = https.request(u, { method: 'POST', headers, timeout: 60000 }, (res) => {
			let text = '';
			res.setEncoding('utf8');
			res.on('data', (chunk) => { if (text.length < 1000) text += chunk; });
			res.on('end', () => {
				if (res.statusCode >= 200 && res.statusCode < 300) resolve({ ok: true });
				else resolve({ ok: false, error: `Discord ${res.statusCode}: ${text.slice(0, 160)}` });
			});
		});
		req.on('timeout', () => req.destroy(new Error('Discord timed out')));
		req.on('error', (err) => resolve({ ok: false, error: err.message }));
		req.end(body);
	});
}

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

function reply(src, id, ok, value, discord) {
	emitNet('kora_image_maker:client:saved', src, id, ok, value, discord);
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

async function finalize(key, upload) {
	const { src, id, rel } = upload;
	uploads.delete(key);
	clearTimeout(upload.timer);
	let buf;
	try {
		buf = Buffer.from(upload.parts.join(''), 'base64');
		if (!buf.length) throw new Error('empty file');
		if (buf.length > MAX_BYTES) throw new Error('file too large');
		const full = path.join(ROOT, rel);
		fs.mkdirSync(path.dirname(full), { recursive: true });
		fs.writeFileSync(full, buf);
		log(`saved ${rel} (${(buf.length / 1024).toFixed(0)} KB) for ${GetPlayerName(src) || src}`);
	} catch (err) {
		log(`could not save ${rel}: ${err.message}`);
		return reply(src, id, false, `Could not save: ${err.message}`);
	}

	let discord;
	if (upload.discord) {
		discord = await discordPost(upload.discord.url, upload.discord.content, { name: path.basename(rel), buf });
		if (!discord.ok) log(`Discord post of ${rel} failed: ${discord.error}`);
	}
	reply(src, id, true, rel, discord);
}

// Saved captures only: images/... or captures/..., no traversal.
function savedFile(rel) {
	if (typeof rel !== 'string' || !/^(?:images|captures)\/[\w\-\/.]+$/.test(rel) || rel.includes('..')) return null;
	const full = path.join(ROOT, rel);
	return full.startsWith(ROOT + path.sep) && fs.existsSync(full) ? full : null;
}

onNet('kora_image_maker:server:repost', async (reqId, rel, discord) => {
	const src = source;
	const done = (ok, err) => emitNet('kora_image_maker:client:discordResult', src, reqId, ok, err);
	if (!isAdmin(src)) return done(false, 'Admin permission required.');
	if (!discord || typeof discord !== 'object') return done(false, 'No webhook given.');
	const full = savedFile(rel);
	if (!full) return done(false, 'That file is no longer on the server.');
	const result = await discordPost(discord.url, discord.content, { name: path.basename(full), buf: fs.readFileSync(full) });
	done(result.ok, result.error);
});

onNet('kora_image_maker:server:testWebhook', async (reqId, url, content) => {
	const src = source;
	const done = (ok, err) => emitNet('kora_image_maker:client:discordResult', src, reqId, ok, err);
	if (!isAdmin(src)) return done(false, 'Admin permission required.');
	const result = await discordPost(url, content || 'Kora Image Maker webhook test.', null);
	done(result.ok, result.error);
});

onNet('kora_image_maker:server:begin', (id, meta, n, bytes, ext, discord) => {
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
		discord: discord && typeof discord === 'object' && typeof discord.url === 'string'
			? { url: discord.url, content: typeof discord.content === 'string' ? discord.content : '' }
			: null,
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
	const ack = (ok) => emitNet('kora_image_maker:client:chunkAck', src, id, i, ok);
	if (!upload) return ack(false);
	if (!Number.isInteger(i) || i < 0 || i >= upload.n || typeof data !== 'string' || upload.parts[i] !== undefined) return ack(false);

	upload.parts[i] = data;
	upload.size += data.length;
	if (upload.size > Math.ceil(MAX_BYTES / 3) * 4 + 4) {
		ack(false);
		return drop(key, src, id, 'File too large.');
	}
	ack(true);
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
