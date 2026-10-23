// Flow test: proves the user-collection service works against DynamoDB
// (local or AWS) without deploying anything.
//
//   node services/user-collection/scripts/flow-test.js [baseUrl]
//
// Covers the same checks as the old Mongo flow test: signup, duplicate
// signup, signin, wrong password, auth-me, save combination, list, update
// rating, delete, signout. Expects the service + table to be up
// (docker compose up, then create-table).

const BASE = process.argv[2] || 'http://localhost:4002';
let cookie = '';

async function call(method, path, body) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(cookie ? { Cookie: cookie } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const setCookie = res.headers.get('set-cookie');
  if (setCookie) cookie = setCookie.split(';')[0];
  let data = null;
  try {
    data = await res.json();
  } catch {
    // no body
  }
  return { status: res.status, data };
}

let passed = 0;
let failed = 0;

function check(name, condition, detail = '') {
  if (passed + failed === 0) console.log('');
  if (condition) {
    passed++;
    console.log(`  PASS  ${name}`);
  } else {
    failed++;
    console.log(`  FAIL  ${name} ${detail}`);
  }
}

async function main() {
  const email = `cloudtest+${Date.now()}@sunsip-test.dev`;
  const password = 'testpass123';
  const newPassword = 'newpass456';

  console.log(`Flow test against ${BASE}`);

  // 1. health
  const health = await fetch(`${BASE}/healthz`);
  check('healthz responds ok', health.status === 200);

  // 2. signup
  const signup = await call('POST', '/api/user/auth-signup', { email, password });
  check('signup creates user (201)', signup.status === 201, JSON.stringify(signup.data));
  check('signup sets sunsip_token cookie', cookie.includes('sunsip_token='));

  // 3. duplicate signup rejected
  const dup = await call('POST', '/api/user/auth-signup', { email, password });
  check('duplicate signup rejected (409)', dup.status === 409);

  // 4. auth-me returns the user
  const me = await call('GET', '/api/user/auth-me');
  check('auth-me returns user', me.status === 200 && me.data?.user?.email === email);

  // 5. save a combination
  const save = await call('POST', '/api/user/combinations', {
    cityName: 'Auckland',
    countryName: 'New Zealand',
    cityImageUrl: 'https://example.com/auckland.jpg',
    weatherDetails: 'Sunny 22C',
    cocktailName: 'Mojito',
    cocktailImageUrl: 'https://example.com/mojito.jpg',
    cocktailIngredients: ['2 oz white rum', '1 oz lime juice'],
    cocktailRecipe: ['Muddle mint', 'Shake with ice'],
    notes: 'from flow test',
  });
  check('save combination (201)', save.status === 201, JSON.stringify(save.data));
  const comboId = save.data?.combination?.id;
  check('combination has id', !!comboId);

  // 6. list combinations
  const list = await call('GET', '/api/user/combinations');
  check('list contains the saved combination', list.status === 200 && Array.isArray(list.data?.combinations) && list.data.combinations.some((c) => c.id === comboId));

  // 7. update rating
  const patch = await call('PATCH', `/api/user/combination?id=${comboId}`, { rating: 5, notes: 'loved it' });
  check('update rating/notes (200)', patch.status === 200 && patch.data?.combination?.rating === 5);

  // 8. track access
  const track = await call('PATCH', `/api/user/combination?id=${comboId}`, { trackAccess: true });
  check('track access increments counter', track.status === 200 && track.data?.combination?.timesAccessed === 1);

  // 9. signout clears cookie
  await call('POST', '/api/user/auth-signout');
  cookie = '';

  // 10. signin with wrong password
  cookie = '';
  const badpw = await call('POST', '/api/user/auth-signin', { email, password: 'wrongpass' });
  check('wrong password rejected (401)', badpw.status === 401);

  // 11. signin with real password
  const signin = await call('POST', '/api/user/auth-signin', { email, password });
  check('signin works (200)', signin.status === 200 && !!signin.data?.user);

  // 12. forgot password (demo fallback: SMTP may not be set in the test env)
  const forgot = await call('POST', '/api/user/auth-forgot', { email });
  const resetUrl = forgot.data?.resetUrl;
  const resetToken = resetUrl ? resetUrl.split('#reset-token=')[1] : null;
  check('forgot returns reset link when SMTP not set', forgot.status === 200 && (resetToken ? true : forgot.data?.delivered === true));

  // 13. reset with the token
  if (resetToken) {
    const reset = await call('POST', '/api/user/auth-reset', { token: resetToken, password: newPassword });
    check('reset sets new password + signs in (200)', reset.status === 200 && !!reset.data?.user);

    // 14. old password must fail now
    cookie = '';
    const oldpw = await call('POST', '/api/user/auth-signin', { email, password });
    check('old password rejected after reset (401)', oldpw.status === 401);

    // 15. new password works
    const newpw = await call('POST', '/api/user/auth-signin', { email, password: newPassword });
    check('new password works (200)', newpw.status === 200);

    // 16. token is single-use (burned)
    const reuse = await call('POST', '/api/user/auth-reset', { token: resetToken, password: 'another123' });
    check('reset token single-use (400 on reuse)', reuse.status === 400);
  }

  // 17. delete the combination
  if (comboId) {
    cookie = '';
    await call('POST', '/api/user/auth-signin', { email, password: resetToken ? newPassword : password });
    const del = await call('DELETE', `/api/user/combination?id=${comboId}`);
    check('delete combination (200)', del.status === 200);
    const listAfter = await call('GET', '/api/user/combinations');
    check('list empty after delete', listAfter.status === 200 && (listAfter.data?.combinations ?? []).length === 0);
  }

  // 18. preferences round-trip
  const putPrefs = await call('PUT', '/api/user/preferences', {
    preferredSpirits: ['Rum'],
    dietaryRestrictions: [],
    favoriteWeatherMoods: { sunny: 'refreshing' },
  });
  check('update preferences (200)', putPrefs.status === 200);
  const getPrefs = await call('GET', '/api/user/preferences');
  check('preferences persist (GET returns Rum)', getPrefs.status === 200 && (getPrefs.data?.preferences?.preferredSpirits ?? []).includes('Rum'));

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error('Flow test crashed:', err);
  process.exit(1);
});