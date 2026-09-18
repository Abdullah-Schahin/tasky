// Run with mongosh against the LOCAL exercise MongoDB container (see command below).
// Creates a unique temporary user and todos, then removes only those test records.
// kubectl --context tasky-local -n tasky exec -i deployment/tasky-mongo -- mongosh --quiet --file /dev/stdin < tests/todo-roundtrip.js
(async () => {
  const http = require('http');
  const assert = require('assert').strict;
  const id = require('crypto').randomUUID();
  const email = `refresh-test-${id}@example.invalid`;
  const admin = db.getSiblingDB('admin');
  const authenticated = admin.auth(process.env.MONGO_INITDB_ROOT_USERNAME, process.env.MONGO_INITDB_ROOT_PASSWORD);
  assert(authenticated === 1 || authenticated.ok === 1);
  const database = db.getSiblingDB('go-mongodb');
  let cookies = '';
  let userId;
  function request(method, path, body) {
    return new Promise((resolve, reject) => {
      const req = http.request({hostname: 'tasky.tasky.svc.cluster.local', path, method,
        headers: {'Content-Type': 'application/json', Cookie: cookies}}, res => {
        if (res.headers['set-cookie']) {
          cookies = res.headers['set-cookie'].map(c => c.split(';')[0]).join('; ');
          const userCookie = res.headers['set-cookie'].find(c => c.startsWith('userID='));
          if (userCookie) userId = userCookie.split(';')[0].slice('userID='.length);
        }
        let data = '';
        res.on('data', chunk => { data += chunk; });
        res.on('end', () => {
          try { assert.equal(res.statusCode, 200, `${method} ${path}: ${data}`); resolve(JSON.parse(data)); }
          catch (error) { reject(error); }
        });
      });
      req.setTimeout(15000, () => req.destroy(new Error('API timeout')));
      req.on('error', reject);
      req.end(body ? JSON.stringify(body) : undefined);
    });
  }
  try {
    await request('POST', '/signup', {username: `test-${id}`, email, password: require('crypto').randomBytes(24).toString('hex')});
    assert(userId);
    const created = await request('POST', `/todo/${userId}`, {name: `persist-${id}`, status: 'pending'});
    // Independent GETs exercise the page refresh path, rather than client-side state.
    for (let i = 0; i < 2; i++) {
      const items = await request('GET', `/todos/${userId}`);
      assert.equal(items.length, 1);
      assert.equal(items[0].ID, created.insertedId);
      assert.equal(items[0].user_id, userId);
    }
    await request('PUT', '/todo', {ID: created.insertedId, name: `edited-${id}`, status: 'completed', user_id: userId});
    const updated = await request('GET', `/todos/${userId}`);
    assert.equal(updated[0].status, 'completed');
    await request('DELETE', `/todo/${userId}/${created.insertedId}`);
    assert.deepEqual(await request('GET', `/todos/${userId}`), []);
    await request('POST', `/todo/${userId}`, {name: `clear-${id}`, status: 'pending'});
    await request('DELETE', `/todos/${userId}`);
    assert.deepEqual(await request('GET', `/todos/${userId}`), []);
    print('PASS: create, repeated GET, update, delete, clear-all, and empty array response.');
  } finally {
    if (userId) database.todos.deleteMany({user_id: userId});
    database.user.deleteMany({email});
  }
})().then(() => quit(0)).catch(error => { print(error.message); quit(1); });
