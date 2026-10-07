// Reads a photo of a receipt and pulls out the store, date, currency, and line
// items. The Anthropic API key lives only here, as a Netlify environment
// variable — it must never be embedded in family-hub.html, since anything in
// that file is visible to anyone who opens the page.
//
// Only signed-in members of the board can trigger a scan (checked below via
// Supabase) — otherwise this URL would let anyone on the internet spend money
// on this app's Anthropic account, logged in or not.

// Sonnet 5 rather than Opus 5: a scan is a 1600px photo (~2,560 image tokens)
// plus a short prompt, and Opus was costing about 2.6¢ per scan for work Sonnet
// handles just as well — this lands nearer 1¢. Haiku would be cheaper still but
// is less reliable on faded or crumpled thermal receipts, which is most of them.
const MODEL = 'claude-sonnet-5';

const MAX_IMAGES = 6;
const MAX_TOTAL_BYTES = 12 * 1024 * 1024;   // ~12MB of decoded image across all photos
const ALLOWED_MEDIA_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];

const SUPABASE_URL = 'https://vxdxwqdiaghejfczpyxo.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ4ZHh3cWRpYWdoZWpmY3pweXhvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU4MDExMjcsImV4cCI6MjEwMTM3NzEyN30.sNdRtRDKblxdt1cH2j_Pz213eoHduek2EUG4wQVRAVo';

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

const RECEIPT_SCHEMA = {
  type: 'object',
  properties: {
    store: { type: 'string', description: 'Store or merchant name. Empty string if not visible.' },
    date: { type: 'string', description: 'Purchase date as YYYY-MM-DD. Empty string if not visible.' },
    currency: { type: 'string', description: '3-letter ISO currency code (e.g. USD, EUR, MXN) — best guess from symbols, language, or store location.' },
    items: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          quantity: { type: 'string', description: "Size or quantity if shown, e.g. '2', '1 dozen', '12 oz'. Empty string if not shown." },
          price: { type: 'number' }
        },
        required: ['name', 'price'],
        additionalProperties: false
      }
    }
  },
  required: ['items'],
  additionalProperties: false
};

exports.handler = async function (event) {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: JSON.stringify({ error: 'Method not allowed' }) };
  }

  if (!(await requireSignedInUser(event))) {
    return { statusCode: 401, body: JSON.stringify({ error: 'Sign in again to scan a receipt' }) };
  }

  let payload;
  try {
    payload = JSON.parse(event.body || '{}');
  } catch (e) {
    return { statusCode: 400, body: JSON.stringify({ error: 'Bad request' }) };
  }

  const images = Array.isArray(payload.images) ? payload.images : null;
  if (!images || !images.length) {
    return { statusCode: 400, body: JSON.stringify({ error: 'Missing image data' }) };
  }
  if (images.length > MAX_IMAGES) {
    return { statusCode: 400, body: JSON.stringify({ error: 'Scan up to ' + MAX_IMAGES + ' photos at a time' }) };
  }
  if (images.some(function (img) { return !img || typeof img.data !== 'string' || !img.data; })) {
    return { statusCode: 400, body: JSON.stringify({ error: 'Missing image data' }) };
  }
  // The browser resizes before upload, but the browser can't be trusted — anyone
  // signed in can post straight to this URL. Cap the payload and pin the file type
  // so a single request can't run up a large bill or reach the API as something
  // other than an image.
  if (images.some(function (img) { return ALLOWED_MEDIA_TYPES.indexOf(img.mediaType) === -1; })) {
    return { statusCode: 400, body: JSON.stringify({ error: 'Photos must be JPEG, PNG, WebP, or GIF' }) };
  }
  const totalBytes = images.reduce(function (sum, img) { return sum + Math.floor(img.data.length * 3 / 4); }, 0);
  if (totalBytes > MAX_TOTAL_BYTES) {
    return { statusCode: 413, body: JSON.stringify({ error: 'Those photos are too large — try fewer or smaller ones' }) };
  }

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    return { statusCode: 500, body: JSON.stringify({ error: 'Scanning is not set up yet — missing API key on the server' }) };
  }

  try {
    const anthropicRes = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 2000,
        thinking: { type: 'disabled' },
        output_config: { format: { type: 'json_schema', schema: RECEIPT_SCHEMA } },
        messages: [{
          role: 'user',
          content: images.map(function (img) {
            return { type: 'image', source: { type: 'base64', media_type: img.mediaType, data: img.data } };
          }).concat([{
            type: 'text',
            text: images.length > 1
              ? 'These ' + images.length + ' photos are sequential shots of one long receipt, in order, top to bottom, taken with a bit of overlap where one photo ends and the next begins. Treat them as one continuous receipt: extract the store name, purchase date, currency, and every line item with its price and quantity/size if shown, counting each item only once even if it appears in the overlap between two photos. Only include actual purchased items — not the subtotal, tax, or total line. If a value is not visible anywhere on the receipt, use an empty string for it.'
              : 'Read this photo of a shopping receipt and extract the store name, purchase date, currency, and every line item with its price and quantity/size if shown. Only include actual purchased items — not the subtotal, tax, or total line. If a value is not visible on the receipt, use an empty string for it.'
          }])
        }]
      })
    });

    const data = await anthropicRes.json();

    if (!anthropicRes.ok) {
      const message = (data && data.error && data.error.message) || 'The scanning service returned an error';
      return { statusCode: 502, body: JSON.stringify({ error: message }) };
    }

    if (data.stop_reason === 'refusal') {
      return { statusCode: 200, body: JSON.stringify({ error: "Couldn't read that photo — try a clearer shot or enter it manually" }) };
    }

    const textBlock = (data.content || []).find(function (b) { return b.type === 'text'; });
    if (!textBlock) {
      return { statusCode: 502, body: JSON.stringify({ error: 'Got no result back from the scan' }) };
    }

    const parsed = JSON.parse(textBlock.text);
    return { statusCode: 200, headers: { 'content-type': 'application/json' }, body: JSON.stringify(parsed) };
  } catch (e) {
    return { statusCode: 500, body: JSON.stringify({ error: 'Scan failed: ' + e.message }) };
  }
};
