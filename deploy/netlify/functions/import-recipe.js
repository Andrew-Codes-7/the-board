// Turns a recipe into structured ingredients + instructions, from one of three
// sources: a link, pasted text, or screenshots.
//
// The link path tries the FREE route first. Normal recipe sites publish their
// recipe as schema.org JSON-LD (Google requires it for recipe rich results), so
// the recipe can be read straight out of the page with no AI call at all — that
// is both free and more accurate than any model reading a screenshot. Only when
// a page has no usable JSON-LD does this fall back to asking Claude to read the
// page text.
//
// Instagram and TikTok are refused up front on purpose: both serve a bare JS
// shell to any server-side fetch (no og: tags, no caption, nothing), Instagram's
// public oEmbed is retired, and TikTok's rejects these requests. Pasted text or a
// screenshot is genuinely the only route for those, and pasted text is ~10x
// cheaper than a screenshot as well as more accurate.
//
// Same rules as scan-receipt.js: the Anthropic API key lives only here as a
// Netlify environment variable, and only someone signed into the board can call
// this — otherwise the URL would let anyone on the internet spend money on this
// app's Anthropic account.

const dns = require('dns').promises;

const MODEL = 'claude-sonnet-5';

const MAX_IMAGES = 3;
const MAX_TOTAL_BYTES = 8 * 1024 * 1024;    // ~8MB of decoded image across all screenshots
const ALLOWED_MEDIA_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];
const MAX_PASTED_CHARS = 20000;             // a caption, not a novel
const MAX_PAGE_BYTES = 3 * 1024 * 1024;     // stop reading a page after ~3MB
const MAX_PHOTO_BYTES = 4 * 1024 * 1024;    // a recipe photo past this isn't worth carrying
const MAX_PAGE_TEXT = 14000;                // characters of page text handed to the model
const FETCH_TIMEOUT_MS = 12000;
const MAX_REDIRECTS = 4;

const USER_AGENT = 'Mozilla/5.0 (compatible; TheBoardRecipeImporter/1.0; +https://the-family-board.netlify.app)';

const SUPABASE_URL = 'https://vxdxwqdiaghejfczpyxo.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ4ZHh3cWRpYWdoZWpmY3pweXhvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU4MDExMjcsImV4cCI6MjEwMTM3NzEyN30.sNdRtRDKblxdt1cH2j_Pz213eoHduek2EUG4wQVRAVo';

// Hosts where a link genuinely cannot be read by anyone — worth saying so
// immediately instead of burning a fetch and an AI call to fail anyway.
const UNREADABLE_HOSTS = [
  'instagram.com', 'instagr.am', 'tiktok.com', 'facebook.com', 'fb.watch', 'fb.com'
];

async function requireSignedInUser(event) {
  const auth = event.headers && (event.headers.authorization || event.headers.Authorization);
  const token = auth && auth.replace(/^Bearer\s+/i, '');
  if (!token) return false;
  try {
    const res = await fetch(SUPABASE_URL + '/auth/v1/user', {
      headers: { authorization: 'Bearer ' + token, apikey: SUPABASE_ANON_KEY }
    });
    return res.ok;
  } catch (e) {
    return false;
  }
}

const RECIPE_SCHEMA = {
  type: 'object',
  properties: {
    name: { type: 'string', description: 'The dish name. Empty string if there genuinely is none.' },
    servings: { type: 'string', description: "How many it serves, e.g. '4' or '4-6 servings'. Empty string if not stated." },
    totalTime: { type: 'string', description: "Total time start to finish, e.g. '45 min' or '1 hr 20 min'. Empty string if not stated." },
    prepTime: { type: 'string', description: "Hands-on prep time only, not counting unattended cooking, e.g. '20 min'. Empty string if not stated." },
    ingredients: {
      type: 'array',
      description: 'One entry per ingredient line, including quantity, exactly as written.',
      items: { type: 'string' }
    },
    instructions: {
      type: 'array',
      description: 'One entry per step, in order. No step numbers at the start — just the text of the step.',
      items: { type: 'string' }
    }
  },
  required: ['name', 'ingredients', 'instructions'],
  additionalProperties: false
};

// ---------------------------------------------------------------------------
//  Text helpers (no DOM available here, so entities and tags are handled by hand)
// ---------------------------------------------------------------------------

const NAMED_ENTITIES = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
  hellip: '…', mdash: '—', ndash: '–', deg: '°',
  frac12: '½', frac14: '¼', frac34: '¾', frac13: '⅓', frac23: '⅔',
  rsquo: '’', lsquo: '‘', ldquo: '“', rdquo: '”', middot: '·'
};

function decodeEntities(str) {
  return String(str).replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/g, function (whole, ent) {
    if (ent.charAt(0) === '#') {
      const hex = ent.charAt(1) === 'x' || ent.charAt(1) === 'X';
      const code = hex ? parseInt(ent.slice(2), 16) : parseInt(ent.slice(1), 10);
      if (!isFinite(code) || code <= 0 || code > 0x10ffff) return whole;
      try { return String.fromCodePoint(code); } catch (e) { return whole; }
    }
    const key = ent.toLowerCase();
    return Object.prototype.hasOwnProperty.call(NAMED_ENTITIES, key) ? NAMED_ENTITIES[key] : whole;
  });
}

function stripTags(str) {
  const withBreaks = String(str)
    .replace(/<\s*br\s*\/?>/gi, '\n')
    .replace(/<\/\s*(p|li|div|h[1-6]|tr)\s*>/gi, '\n')
    .replace(/<[^>]*>/g, '');
  return decodeEntities(withBreaks)
    .replace(/[ \t ]+/g, ' ')
    .replace(/\n[ \t]*\n+/g, '\n')
    .trim();
}

// When a page has no recipe data to read, it almost always still has the
// og:image tag that social sites use for link previews — which on a recipe page
// is the photo of the dish. Attribute order and quoting vary, so try both ways round.
function ogImage(html) {
  const patterns = [
    /<meta[^>]+property\s*=\s*["']og:image["'][^>]*content\s*=\s*["']([^"']+)["']/i,
    /<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]*property\s*=\s*["']og:image["']/i,
    /<meta[^>]+name\s*=\s*["']twitter:image["'][^>]*content\s*=\s*["']([^"']+)["']/i
  ];
  for (let i = 0; i < patterns.length; i++) {
    const m = patterns[i].exec(html);
    if (m && m[1]) return decodeEntities(m[1]).trim();
  }
  return '';
}

function pageToText(html) {
  const stripped = String(html)
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ')
    .replace(/<!--[\s\S]*?-->/g, ' ');
  return stripTags(stripped);
}

// ---------------------------------------------------------------------------
//  Fetching a page safely
//
//  This function will fetch any URL a signed-in family member types in, so the
//  address has to be checked before each request: without this, someone could
//  point it at an address only the server can reach (the cloud metadata service,
//  or anything on a private network) and read the response back out. Redirects
//  are followed by hand for the same reason — a public URL is allowed to redirect
//  to a private one, and the check has to run again on every hop.
// ---------------------------------------------------------------------------

function isBlockedAddress(ip) {
  const addr = String(ip).toLowerCase();
  if (/^\d+\.\d+\.\d+\.\d+$/.test(addr)) {
    const p = addr.split('.').map(Number);
    if (p.some(function (n) { return !isFinite(n) || n < 0 || n > 255; })) return true;
    if (p[0] === 0) return true;                                  // "this network"
    if (p[0] === 10) return true;                                 // private
    if (p[0] === 127) return true;                                // loopback
    if (p[0] === 169 && p[1] === 254) return true;                // link-local / cloud metadata
    if (p[0] === 172 && p[1] >= 16 && p[1] <= 31) return true;    // private
    if (p[0] === 192 && p[1] === 168) return true;                // private
    if (p[0] === 192 && p[1] === 0 && p[2] === 0) return true;    // IETF protocol assignments
    if (p[0] === 100 && p[1] >= 64 && p[1] <= 127) return true;   // carrier-grade NAT
    if (p[0] >= 224) return true;                                 // multicast + reserved
    return false;
  }
  if (addr === '::' || addr === '::1') return true;
  if (addr.indexOf('::ffff:') === 0) return isBlockedAddress(addr.slice(7));
  if (/^fe[89ab]/.test(addr)) return true;                        // link-local
  if (/^f[cd]/.test(addr)) return true;                           // unique local
  return false;
}

async function assertReachableHost(parsed) {
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new Error('Only http and https links can be read');
  }
  let addresses;
  try {
    addresses = await dns.lookup(parsed.hostname, { all: true });
  } catch (e) {
    throw new Error("Couldn't find that website — check the link");
  }
  if (!addresses.length || addresses.some(function (a) { return isBlockedAddress(a.address); })) {
    throw new Error('That link points somewhere this app is not allowed to read');
  }
}

async function readCappedBuffer(res, maxBytes) {
  if (!res.body) return Buffer.alloc(0);
  const reader = res.body.getReader();
  const chunks = [];
  let received = 0;
  while (true) {
    const step = await reader.read();
    if (step.done) break;
    received += step.value.length;
    if (received > maxBytes) { await reader.cancel().catch(function () {}); return null; }
    chunks.push(Buffer.from(step.value));
  }
  return Buffer.concat(chunks);
}

// One validated fetch, following redirects by hand so the address check runs
// again on every hop. Returns the response without judging its status — the
// caller decides, because a page that won't load is an error worth explaining
// while a photo that won't load is just a meal without a photo.
async function fetchValidated(startUrl, acceptHeader) {
  let current = startUrl;
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    const parsed = new URL(current);
    await assertReachableHost(parsed);

    const controller = new AbortController();
    const timer = setTimeout(function () { controller.abort(); }, FETCH_TIMEOUT_MS);
    let res;
    try {
      res = await fetch(current, {
        redirect: 'manual',
        signal: controller.signal,
        headers: {
          'user-agent': USER_AGENT,
          accept: acceptHeader,
          'accept-language': 'en-US,en;q=0.9'
        }
      });
    } catch (e) {
      clearTimeout(timer);
      if (e.name === 'AbortError') throw new Error('That site took too long to answer');
      throw new Error("Couldn't reach that site");
    }
    clearTimeout(timer);

    const location = res.status >= 300 && res.status < 400 ? res.headers.get('location') : null;
    if (location) {
      try { current = new URL(location, current).href; } catch (e) { throw new Error('That site sent us somewhere unreadable'); }
      continue;
    }
    return { res: res, finalUrl: current };
  }
  throw new Error('That link redirected too many times');
}

async function fetchRecipePage(startUrl) {
  const got = await fetchValidated(startUrl, 'text/html,application/xhtml+xml');
  const res = got.res;

  if (!res.ok) {
    if (res.status === 404 || res.status === 410) {
      throw new Error("That page wasn't found — check the link and try again");
    }
    if (res.status >= 500) {
      throw new Error('That site is having trouble right now (error ' + res.status + ') — try again in a minute');
    }
    throw new Error("That site won't let this app read the page (error " + res.status + ') — paste the recipe text or import a screenshot instead');
  }
  const buf = await readCappedBuffer(res, MAX_PAGE_BYTES);
  return { html: (buf || Buffer.alloc(0)).toString('utf8'), finalUrl: got.finalUrl };
}

// Fetch the recipe's own photo and hand it back as base64 for the browser to
// store. It has to come through here rather than being fetched by the browser:
// the page's own address is untrusted input (a hostile page could name an
// address only this server can reach), so it needs the same host checks as the
// page fetch, and the app's content rules don't let the browser reach out to
// arbitrary hosts anyway.
//
// A photo is a nice-to-have, never a reason to fail an import — every failure
// here returns null and the recipe imports without one.
async function fetchPhoto(rawUrl, pageUrl) {
  if (!rawUrl) return null;
  let parsed;
  try {
    parsed = new URL(rawUrl, pageUrl);
  } catch (e) {
    return null;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;

  try {
    const got = await fetchValidated(parsed.href, 'image/*');
    if (!got.res.ok) return null;

    const type = String(got.res.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
    if (ALLOWED_MEDIA_TYPES.indexOf(type) === -1) return null;

    const declared = Number(got.res.headers.get('content-length') || 0);
    if (declared && declared > MAX_PHOTO_BYTES) return null;

    const buf = await readCappedBuffer(got.res, MAX_PHOTO_BYTES);
    if (!buf || !buf.length) return null;

    return { data: buf.toString('base64'), mediaType: type };
  } catch (e) {
    return null;
  }
}

// ---------------------------------------------------------------------------
//  The free path: schema.org Recipe data embedded in the page
// ---------------------------------------------------------------------------

function findRecipeNode(node, depth) {
  depth = depth || 0;
  if (!node || depth > 6) return null;
  if (Array.isArray(node)) {
    for (let i = 0; i < node.length; i++) {
      const found = findRecipeNode(node[i], depth + 1);
      if (found) return found;
    }
    return null;
  }
  if (typeof node !== 'object') return null;

  const rawType = node['@type'];
  const types = Array.isArray(rawType) ? rawType : (rawType ? [rawType] : []);
  if (types.some(function (t) { return String(t).toLowerCase() === 'recipe'; })) return node;

  const nested = ['@graph', 'mainEntity', 'mainEntityOfPage', 'itemListElement'];
  for (let i = 0; i < nested.length; i++) {
    if (node[nested[i]]) {
      const found = findRecipeNode(node[nested[i]], depth + 1);
      if (found) return found;
    }
  }
  return null;
}

// schema.org `image` is sometimes a plain string, sometimes a list, sometimes an
// ImageObject wrapping the address — and often all three shapes on one site.
function imageUrlOf(value, depth) {
  depth = depth || 0;
  if (!value || depth > 4) return '';
  if (typeof value === 'string') return value.trim();
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) {
      const found = imageUrlOf(value[i], depth + 1);
      if (found) return found;
    }
    return '';
  }
  if (typeof value === 'object') return imageUrlOf(value.url || value.contentUrl || '', depth + 1);
  return '';
}

function textOfNode(value) {
  if (typeof value === 'string') return stripTags(value);
  if (value && typeof value === 'object') {
    if (typeof value.text === 'string') return stripTags(value.text);
    if (typeof value.name === 'string') return stripTags(value.name);
  }
  return '';
}

function flattenInstructions(value, out, depth) {
  out = out || [];
  depth = depth || 0;
  if (!value || depth > 4) return out;

  if (typeof value === 'string') {
    // Plenty of sites put every step into one HTML blob rather than a list.
    stripTags(value).split('\n').forEach(function (line) {
      const t = line.trim();
      if (t) out.push(t);
    });
    return out;
  }
  if (Array.isArray(value)) {
    value.forEach(function (v) { flattenInstructions(v, out, depth + 1); });
    return out;
  }
  if (typeof value === 'object') {
    // A HowToSection ("For the sauce") holds its steps in itemListElement.
    if (Array.isArray(value.itemListElement)) {
      flattenInstructions(value.itemListElement, out, depth + 1);
      return out;
    }
    const t = textOfNode(value);
    if (t) out.push(t);
  }
  return out;
}

// Some sites publish the whole method as a single step with the numbering left
// inline ("1. Season the chicken... 2. Heat the oil..."), which would otherwise
// import as one wall of text. Split it back apart — but only on a genuine run of
// sequential numbers starting at 1 or 2, so a stray "350. Add" or a measurement
// can't shred a normal step.
function splitNumberedRun(text) {
  const re = /(?:^|\s)(\d{1,2})\.\s+(?=[A-Z"“'])/g;
  const marks = [];
  let m;
  while ((m = re.exec(text)) !== null) {
    marks.push({
      start: m.index + (/^\s/.test(m[0]) ? 1 : 0),
      end: re.lastIndex,
      num: Number(m[1])
    });
  }
  if (marks.length < 3 || marks[0].num > 2) return null;
  for (let i = 0; i < marks.length; i++) {
    if (marks[i].num !== marks[0].num + i) return null;
  }
  const parts = [];
  for (let i = 0; i < marks.length; i++) {
    const to = i + 1 < marks.length ? marks[i + 1].start : text.length;
    const piece = text.slice(marks[i].end, to).trim();
    if (piece) parts.push(piece);
  }
  return parts.length >= 3 ? parts : null;
}

function expandNumberedSteps(steps) {
  const out = [];
  steps.forEach(function (s) {
    const split = splitNumberedRun(s);
    if (split) out.push.apply(out, split);
    else out.push(s);
  });
  return out;
}

function humanDuration(value) {
  const raw = String(value == null ? '' : value).trim();
  if (!raw) return '';
  if (!/^P/i.test(raw)) return raw.slice(0, 40);        // already human, e.g. "45 minutes"
  const m = /^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?/i.exec(raw);
  if (!m) return '';
  // Sites write the same duration in whichever unit suits them — a slow-cooker
  // recipe often ships as PT485M rather than PT8H5M. Total it up in minutes
  // first, so "485 min" always comes out as "8 hr 5 min".
  const totalMinutes = Number(m[1] || 0) * 1440 + Number(m[2] || 0) * 60 + Number(m[3] || 0);
  if (!totalMinutes) return '';
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  const parts = [];
  if (hours) parts.push(hours + ' hr');
  if (minutes) parts.push(minutes + ' min');
  return parts.join(' ');
}

function yieldToString(value) {
  // recipeYield is often an array of the same answer said two ways —
  // ["1", "1 cup"] or ["4", "4 servings"] — so take the wordiest one, which is
  // the one that actually tells you something.
  if (Array.isArray(value)) {
    value = value.filter(Boolean).sort(function (a, b) { return String(b).length - String(a).length; })[0];
  }
  if (value && typeof value === 'object') value = value.value || value.name || '';
  const s = stripTags(String(value == null ? '' : value));
  return s.slice(0, 40);
}

function recipeFromJsonLd(html) {
  // The quotes around an attribute value are optional in HTML, and minifiers
  // drop them — loveandlemons.com ships `<script type=application/ld+json ...>`
  // with no quotes at all, so requiring them here silently loses whole sites.
  const blockRe = /<script[^>]*\btype\s*=\s*["']?application\/ld\+json["']?[^>]*>([\s\S]*?)<\/script>/gi;
  let match;
  while ((match = blockRe.exec(html)) !== null) {
    let parsed;
    try {
      parsed = JSON.parse(match[1].trim());
    } catch (e) {
      continue;                                          // one bad block shouldn't kill the rest
    }
    const node = findRecipeNode(parsed);
    if (!node) continue;

    const ingredients = (Array.isArray(node.recipeIngredient) ? node.recipeIngredient : [])
      .map(function (i) { return stripTags(i); })
      .filter(Boolean);
    const instructions = expandNumberedSteps(flattenInstructions(node.recipeInstructions))
      .map(function (s) { return s.replace(/^\s*(?:step\s*)?\d+[.)]\s*/i, '').trim(); })
      .filter(Boolean);

    // A page can carry a Recipe node that's only a stub (a "related recipes"
    // card, say). Without ingredients there's nothing worth importing, so let
    // the AI fallback have a go at the page instead.
    if (!ingredients.length) continue;

    return {
      name: stripTags(node.name || '').slice(0, 200),
      servings: yieldToString(node.recipeYield),
      totalTime: humanDuration(node.totalTime || node.cookTime || ''),
      ingredients: ingredients,
      instructions: instructions,
      // Kept separate from totalTime because on a slow-cooker recipe the total
      // is almost all unattended waiting — the prep time is the number that
      // actually tells you whether tonight is possible.
      prepTime: humanDuration(node.prepTime || ''),
      imageUrl: imageUrlOf(node.image),
      source: 'structured'
    };
  }
  return null;
}

// ---------------------------------------------------------------------------
//  The AI path
// ---------------------------------------------------------------------------

async function askClaude(apiKey, content) {
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01'
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 3000,
      thinking: { type: 'disabled' },
      output_config: { format: { type: 'json_schema', schema: RECIPE_SCHEMA } },
      messages: [{ role: 'user', content: content }]
    })
  });

  const data = await res.json();
  if (!res.ok) {
    throw new Error((data && data.error && data.error.message) || 'The recipe reader returned an error');
  }
  if (data.stop_reason === 'refusal') {
    throw new Error("Couldn't find a recipe in that — try a clearer screenshot, or paste the text");
  }
  const block = (data.content || []).find(function (b) { return b.type === 'text'; });
  if (!block) throw new Error('Got no result back from the recipe reader');
  return JSON.parse(block.text);
}

const READ_INSTRUCTION =
  'Pull the recipe out of this: the dish name, how many it serves, the total time, ' +
  'every ingredient line with its quantity exactly as written, and every step in order. ' +
  'Drop step numbering from the start of each step, and leave out chatter, ads, comments, ' +
  'and any story around the recipe. If something is not stated, use an empty string ' +
  '(or an empty list) rather than guessing.';

// ---------------------------------------------------------------------------

function tidyResult(result, link, source, photo) {
  const list = function (v, cap) {
    return (Array.isArray(v) ? v : [])
      .map(function (s) { return String(s == null ? '' : s).trim(); })
      .filter(Boolean)
      .slice(0, cap);
  };
  return {
    name: String(result.name || '').trim().slice(0, 200),
    servings: String(result.servings || '').trim().slice(0, 40),
    totalTime: String(result.totalTime || '').trim().slice(0, 40),
    prepTime: String(result.prepTime || '').trim().slice(0, 40),
    ingredients: list(result.ingredients, 120),
    instructions: list(result.instructions, 80),
    link: link || '',
    photo: photo || null,          // { data (base64), mediaType } — the browser puts it into storage
    source: source
  };
}

exports.handler = async function (event) {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: JSON.stringify({ error: 'Method not allowed' }) };
  }

  if (!(await requireSignedInUser(event))) {
    return { statusCode: 401, body: JSON.stringify({ error: 'Sign in again to import a recipe' }) };
  }

  let payload;
  try {
    payload = JSON.parse(event.body || '{}');
  } catch (e) {
    return { statusCode: 400, body: JSON.stringify({ error: 'Bad request' }) };
  }

  const apiKey = process.env.ANTHROPIC_API_KEY;
  const ok = function (body) {
    return { statusCode: 200, headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) };
  };
  const bad = function (code, message) {
    return { statusCode: code, body: JSON.stringify({ error: message }) };
  };

  try {
    // ---- 1. From a link -----------------------------------------------------
    if (typeof payload.url === 'string' && payload.url.trim()) {
      const raw = payload.url.trim();
      let parsed;
      try {
        parsed = new URL(/^https?:\/\//i.test(raw) ? raw : 'https://' + raw);
      } catch (e) {
        return bad(400, "That doesn't look like a web address");
      }

      const host = parsed.hostname.toLowerCase().replace(/^www\./, '');
      if (UNREADABLE_HOSTS.some(function (h) { return host === h || host.endsWith('.' + h); })) {
        return bad(422, "Instagram, TikTok and Facebook don't let any app read a post from its link. Paste the caption text instead, or import a screenshot — both work, and pasting is the more accurate of the two.");
      }

      const page = await fetchRecipePage(parsed.href);

      // Free path first — no AI call at all when the site publishes its recipe.
      const structured = recipeFromJsonLd(page.html);
      if (structured) {
        const photo = await fetchPhoto(structured.imageUrl, page.finalUrl);
        return ok(tidyResult(structured, page.finalUrl, 'structured', photo));
      }

      if (!apiKey) return bad(500, 'That page has no readable recipe data, and the AI fallback is not set up (missing API key on the server)');

      const text = pageToText(page.html).slice(0, MAX_PAGE_TEXT);
      if (text.length < 200) {
        return bad(422, "That page didn't send back any readable text — it's probably one that builds itself in the browser. Try pasting the recipe text or a screenshot instead.");
      }
      const result = await askClaude(apiKey, [{ type: 'text', text: READ_INSTRUCTION + '\n\n---\n\n' + text }]);
      const photo = await fetchPhoto(ogImage(page.html), page.finalUrl);
      return ok(tidyResult(result, page.finalUrl, 'ai-page', photo));
    }

    // ---- 2. From pasted text ------------------------------------------------
    if (typeof payload.text === 'string' && payload.text.trim()) {
      if (!apiKey) return bad(500, 'Importing is not set up yet — missing API key on the server');
      const text = payload.text.trim().slice(0, MAX_PASTED_CHARS);
      const result = await askClaude(apiKey, [{ type: 'text', text: READ_INSTRUCTION + '\n\n---\n\n' + text }]);
      return ok(tidyResult(result, typeof payload.link === 'string' ? payload.link : '', 'ai-text'));
    }

    // ---- 3. From screenshots ------------------------------------------------
    if (Array.isArray(payload.images) && payload.images.length) {
      if (!apiKey) return bad(500, 'Importing is not set up yet — missing API key on the server');
      const images = payload.images;
      if (images.length > MAX_IMAGES) return bad(400, 'Import up to ' + MAX_IMAGES + ' screenshots at a time');
      if (images.some(function (img) { return !img || typeof img.data !== 'string' || !img.data; })) {
        return bad(400, 'Missing image data');
      }
      // The browser resizes before upload, but the browser can't be trusted —
      // anyone signed in can post straight to this URL.
      if (images.some(function (img) { return ALLOWED_MEDIA_TYPES.indexOf(img.mediaType) === -1; })) {
        return bad(400, 'Screenshots must be JPEG, PNG, WebP, or GIF');
      }
      const totalBytes = images.reduce(function (sum, img) { return sum + Math.floor(img.data.length * 3 / 4); }, 0);
      if (totalBytes > MAX_TOTAL_BYTES) return bad(413, 'Those screenshots are too large — try fewer or smaller ones');

      const content = images.map(function (img) {
        return { type: 'image', source: { type: 'base64', media_type: img.mediaType, data: img.data } };
      }).concat([{
        type: 'text',
        text: images.length > 1
          ? 'These ' + images.length + ' screenshots are parts of one recipe, in order. Treat them as one, and do not repeat anything that appears in two of them. ' + READ_INSTRUCTION
          : READ_INSTRUCTION
      }]);

      const result = await askClaude(apiKey, content);
      // The screenshot is already here and already paid for, so it doubles as
      // the meal's photo — better than no picture, and easily replaced later.
      const photo = { data: images[0].data, mediaType: images[0].mediaType };
      return ok(tidyResult(result, typeof payload.link === 'string' ? payload.link : '', 'ai-image', photo));
    }

    return bad(400, 'Send a link, some text, or a screenshot');
  } catch (e) {
    // Everything thrown above carries a message meant to be shown to the user.
    return { statusCode: 502, body: JSON.stringify({ error: e.message || 'Import failed' }) };
  }
};
