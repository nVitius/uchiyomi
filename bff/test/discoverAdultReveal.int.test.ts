// A mixed-content source can hide individual adult-rated titles without hiding any whole source.
// The reveal must remain available to eligible accounts, while an age cap still wins over adult=1.
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';

const DSN = process.env.TEST_DATABASE_URL;
const skip = DSN ? false : 'set TEST_DATABASE_URL to run';
if (DSN) {
  process.env.DATABASE_URL = DSN;
  process.env.JWT_SECRET ||= 'test-secret-at-least-16-chars';
  process.env.CONFIG_DIR ||= '/tmp/uchiyomi-discover-reveal';
  process.env.LIBRARY_BACKEND = 'owned';
}
const SOURCE = 'mixed-reveal-test';
const users = ['dr-uncapped', 'dr-adult', 'dr-capped'];
let app: any;
let q: typeof import('../src/lib/db').q;
let unregister: (id: string) => boolean;
const ids: string[] = [];
const titles = [
  { source: SOURCE, sourceId: 'clean', title: 'Mixed Safe Title', contentRating: 'safe' as const },
  { source: SOURCE, sourceId: 'adult', title: 'Mixed Adult Title', contentRating: 'erotica' as const },
];
before(async () => {
  if (!DSN) return;
  ({ q } = await import('../src/lib/db'));
  await (await import('../src/lib/migrate')).migrate();
  const { registerAdapter, unregisterAdapter } = await import('../src/lib/sources');
  unregister = unregisterAdapter;
  registerAdapter({
    id: SOURCE, name: 'Mixed Source', isNsfw: false,
    async search() { return titles; },
    async getSeries(id) { return titles.find(t => t.sourceId === id) ?? null; },
    async listChapters() { return []; },
    async getPageUrls() { return []; },
  });
  await q('DELETE FROM users WHERE username = ANY($1)', [users]);
  for (const [i, cap] of [null, 18, 13].entries()) {
    const [row] = await q<{ id: string }>(
      `INSERT INTO users (username, display_name, password_hash, role, auth_kind, perms, max_age_rating)
       VALUES ($1, $1, 'x', 'user', 'password', '{}', $2) RETURNING id`, [users[i], cap]);
    ids.push(row.id);
  }
  const Fastify = (await import('fastify')).default;
  app = Fastify();
  await app.register((await import('@fastify/jwt')).default, { secret: process.env.JWT_SECRET! });
  await app.register((await import('../src/routes/sources')).default);
  await app.ready();
});
after(async () => {
  if (!DSN) return;
  await app?.close();
  unregister(SOURCE);
  await q('DELETE FROM source_health WHERE source_id = $1', [SOURCE]);
  await q('DELETE FROM users WHERE username = ANY($1)', [users]);
});

test('Discover can reveal adult-rated titles from a mixed source without an adult library', { skip }, async t => {
  for (const [i, label] of ['uncapped', '18+', 'capped below 18'].entries()) {
    await t.test(label, async () => {
      const headers = { authorization: 'Bearer ' + app.jwt.sign({ sub: ids[i], role: 'user' }) };
      const get = async (url: string) => {
        const r = await app.inject({ method: 'GET', url, headers });
        assert.equal(r.statusCode, 200, r.body);
        return r.json();
      };
      for (const reveal of ['', '?adult=1']) {
        const sources = await get('/api/sources' + reveal);
        assert.equal(sources.hiddenAdult, 0, 'there are no adult providers to trigger the old button');
        assert.equal(sources.canRevealAdult, i !== 2, 'only an eligible account may be offered the reveal');
        assert.ok(sources.content.some((s: any) => s.id === SOURCE));
      }
      const hidden = await get('/api/sources/search-all?q=Mixed&source=' + SOURCE);
      assert.equal(hidden.rating, 'safe');
      assert.deepEqual(hidden.content.map((r: any) => r.title), ['Mixed Safe Title']);
      const revealed = await get('/api/sources/search-all?q=Mixed&source=' + SOURCE + '&adult=1');
      assert.equal(revealed.rating, i === 2 ? 'safe' : 'all');
      assert.deepEqual(revealed.content.map((r: any) => r.title).sort(),
        (i === 2 ? ['Mixed Safe Title'] : ['Mixed Adult Title', 'Mixed Safe Title']).sort());
      // The import review's manual matcher consumes the source-grouped form of this same search.
      for (const reveal of ['', '&adult=1']) {
        const manual = await get('/api/sources/search-all?q=Mixed&source=' + SOURCE + '&groupBy=source' + reveal);
        const names = manual.content.flatMap((g: any) => g.results.map((r: any) => r.title)).sort();
        assert.deepEqual(names, (reveal && i !== 2 ? ['Mixed Adult Title', 'Mixed Safe Title'] : ['Mixed Safe Title']).sort());
      }
      const adultOnly = await get('/api/sources/search-all?q=Mixed&source=' + SOURCE + '&adult=1&rating=adult');
      assert.equal(adultOnly.rating, i === 2 ? 'safe' : 'adult');
      assert.deepEqual(adultOnly.content.map((r: any) => r.title), [i === 2 ? 'Mixed Safe Title' : 'Mixed Adult Title']);
    });
  }
});
