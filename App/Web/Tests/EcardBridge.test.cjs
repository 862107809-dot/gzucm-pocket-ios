// Execute the shipped WebKit script against a small browser fixture. No mirrored parser logic.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.resolve(__dirname, '../../Resources/EcardBridge.js'), 'utf8');

function response(url, payload, status = 200) {
  return {
    url, status, ok: status >= 200 && status < 300,
    clone() { return response(url, payload, status); },
    async text() { return typeof payload === 'string' ? payload : JSON.stringify(payload); },
    async json() { return typeof payload === 'string' ? JSON.parse(payload) : payload; }
  };
}

function fixture(options = {}) {
  const messages = [];
  const requests = [];
  const inputs = Object.assign({ roomNum: 'room-fixture', schoolAreaNo: 'area-fixture', buildingNo: 'building-fixture', roomChooseText: '示例宿舍 101' }, options.inputs);
  const tips = options.tips ?? [];
  class XHR {
    open(method, url) { this.method = method; this.url = url; }
    send() {}
    addEventListener(event, callback) { if (event === 'load') this.loaded = callback; }
    respond(payload, status = 200, url = this.url) {
      this.status = status;
      this.responseURL = new URL(url, context.location.href).href;
      this.responseText = typeof payload === 'string' ? payload : JSON.stringify(payload);
      this.loaded();
    }
  }
  const context = {
    URL, URLSearchParams, setTimeout, clearTimeout,
    location: new URL(options.url || 'https://ecard.gzucm.edu.cn/user/powerfee/index'),
    XMLHttpRequest: XHR,
    MutationObserver: class { observe() {} },
    webkit: { messageHandlers: { pocketPower: { postMessage(body) { messages.push(JSON.parse(JSON.stringify(body))); } } } },
    document: {
      readyState: options.loading ? 'loading' : 'complete',
      querySelectorAll(selector) {
        if (selector === '[id="powerTips"]') return tips.map(textContent => ({ textContent }));
        if (selector === 'a[href]') return (options.links ?? []).map(href => ({ href }));
        const match = selector.match(/^input\[name="(.+)"\]$/);
        return match && inputs[match[1]] ? [{ value: inputs[match[1]] }] : [];
      },
      addEventListener(event, callback) { this.ready = callback; }
    },
    async fetch(url, init) {
      requests.push({ url, init });
      if (options.fetch) return options.fetch(url, init, requests.length);
      return response(new URL(url, context.location.href).href, { ret: false });
    }
  };
  if (options.now) {
    const timestamp = new Date(options.now).getTime();
    context.Date = class extends Date {
      constructor(...args) { super(...(args.length ? args : [timestamp])); }
      static now() { return timestamp; }
    };
  }
  context.window = context;
  context.top = options.subframe ? {} : context;
  vm.runInNewContext(source, context, { filename: 'EcardBridge.js' });
  return { context, messages, requests, inputs, xhr(url) {
    const xhr = new XHR(); xhr.open('POST', url); xhr.send(); return xhr;
  } };
}
const settle = () => new Promise(resolve => setImmediate(resolve));

test('bridge is absent on authentication, foreign, deceptive and child-frame origins', () => {
  for (const url of [
    'https://authserver.gzucm.edu.cn/authserver/login',
    'https://ecard.gzucm.edu.cn/user/index',
    'http://ecard.gzucm.edu.cn/user/powerfee/index',
    'https://ecard.gzucm.edu.cn.evil.example/user/powerfee/index'
  ]) {
    const f = fixture({ url, tips: ['剩余电量：42度'] });
    assert.equal(f.context.__pocketEcard, undefined);
    assert.equal(f.messages.length, 0);
  }
  assert.equal(fixture({ subframe: true }).context.__pocketEcard, undefined);
});

test('DOM extracts the populated duplicate balance node, preserving a real zero', () => {
  const f = fixture({ tips: ['', '剩余电量：0.00度'] });
  assert.deepEqual(f.messages, [{ version: 1, kind: 'balance', balance: 0, unit: '度', roomLabel: '示例宿舍 101', roomKey: 'area-fixture/building-fixture/room-fixture' }]);
});

test('missing balance and login-like text cannot become zero', () => {
  for (const tips of [[], ['剩余电量：--'], ['请登录 2026 年教务系统'], ['验证码：1234']]) {
    assert.equal(fixture({ tips }).messages.length, 0);
  }
  assert.equal(fixture({ tips: ['剩余电量：12.3度'], inputs: { roomNum: '' } }).messages.length, 0);
});

test('real XHR capture accepts unit strings, API room labels, zero and negative balance', () => {
  const f = fixture();
  for (const raw of ['剩余电量：3.23度', '0.00', '-2.25']) {
    f.xhr('/user/powerfee/getBalance').respond({ ret: true, obj: { formatPowerBalanceStr: raw, building: '示例 6 栋', room: '102' } });
  }
  assert.deepEqual(f.messages.map(m => m.balance), [3.23, 0, -2.25]);
  assert.equal(f.messages[0].roomLabel, '示例 6 栋 102');
});

test('invalid balance responses, non-2xx and foreign response origins are rejected', () => {
  const f = fixture();
  for (const payload of [
    { ret: false, obj: { powerBalance: 123 } },
    { ret: true, obj: { powerBalance: '' } },
    { ret: true, obj: { powerBalance: '--' } },
    { ret: true, obj: { powerBalance: false } },
    '<html>请登录</html>'
  ]) f.xhr('/user/powerfee/getBalance').respond(payload);
  f.xhr('/user/powerfee/getBalance').respond({ ret: true, obj: { powerBalance: 123 } }, 401);
  f.xhr('https://evil.example/user/powerfee/getBalance').respond({ ret: true, obj: { powerBalance: 123 } });
  assert.equal(f.messages.length, 0);
});

test('daily response uses dateTime, sorts, deduplicates, validates dates and retains valid zero use', () => {
  const f = fixture();
  f.xhr('/user/powerfee/getDailyDetails').respond({ ret: true, obj: { dailyDetailsInfos: [
    { dateTime: '2026/10/03 12:00:00', dailyUsed: '2.5', leftUsed: '30.1', totalUsed: '90.1' },
    { accountTime: '2026-10-01', dailyUsed: '0.00', leftUsed: '32.6' },
    { dateTime: '2026-10-03', dailyUsed: '3', leftUsed: '29.6' },
    { dateTime: '2026-02-31', dailyUsed: '3', leftUsed: '29.6' },
    { dateTime: '2026-10-04', dailyUsed: '', leftUsed: '29.6' },
    { dateTime: '2026-10-05', dailyUsed: '-2', leftUsed: '29.6' }
  ] } });
  assert.deepEqual(f.messages[0].daily, [
    { date: '2026-10-01', usage: 0, remain: 32.6, total: 0 },
    { date: '2026-10-03', usage: 3, remain: 29.6, total: 0 }
  ]);
});

test('daily-before-balance arrival remains observable for the native room-key merger', () => {
  const f = fixture();
  f.xhr('/user/powerfee/getDailyDetails').respond({ ret: true, obj: { dailyDetailsInfos: [{ dateTime: '2026-10-01', dailyUsed: 2, leftUsed: 40 }] } });
  f.xhr('/user/powerfee/getBalance').respond({ ret: true, obj: { powerBalance: 40 } });
  assert.deepEqual(f.messages.map(m => m.kind), ['daily', 'balance']);
  assert.equal(f.messages[0].roomKey, f.messages[1].roomKey);
});

test('a pending previous-room response is discarded after a room change', () => {
  const f = fixture();
  const pending = f.xhr('/user/powerfee/getDailyDetails');
  f.inputs.roomNum = 'second-room';
  pending.respond({ ret: true, obj: { dailyDetailsInfos: [{ dateTime: '2026-10-01', dailyUsed: 99, leftUsed: 1 }] } });
  assert.equal(f.messages.length, 0);
  f.xhr('/user/powerfee/getBalance').respond({ ret: true, obj: { powerBalance: 80 } });
  assert.equal(f.messages[0].roomKey, 'area-fixture/building-fixture/second-room');
});

test('fetch interception returns the original response and emits normalized data without token', async () => {
  const expected = response('https://ecard.gzucm.edu.cn/user/powerfee/getBalance', { ret: true, obj: { powerBalance: '18.5度', token: 'fixture-secret' } });
  const f = fixture({ fetch: async () => expected });
  assert.equal(await f.context.fetch('/user/powerfee/getBalance'), expected);
  await settle();
  assert.equal(f.messages[0].balance, 18.5);
  assert.ok(!JSON.stringify(f.messages).includes('fixture-secret'));
});

test('month paging reuses only a rendered same-origin detail link and never emits its token', async () => {
  const url = 'https://ecard.gzucm.edu.cn/user/powerfee/toDailyDetails?implType=CGCOMMON1001&type=2&schoolAreaNo=area-fixture&buildingNo=building-fixture&roomNum=room-fixture&token=fixture-secret&from=';
  const f = fixture({ links: [url], tips: ['剩余电量：50度'], fetch: async (raw, init) => {
    assert.equal(raw, '/user/powerfee/getDailyDetails');
    const fields = new URLSearchParams(init.body);
    assert.equal(fields.get('token'), 'fixture-secret');
    assert.equal(fields.get('roomNum'), 'room-fixture');
    assert.equal(fields.get('pageSize'), '30');
    assert.match(fields.get('lastDate'), /^\d{4}-\d{2}$/);
    const page = Number(fields.get('pageNum'));
    return response('https://ecard.gzucm.edu.cn/user/powerfee/getDailyDetails', { ret: true, obj: {
      totalPage: 2,
      dailyDetailsInfos: Array.from({ length: page === 1 ? 30 : 1 }, (_, i) => ({ dateTime: '2026-10-' + String((i % 28) + 1).padStart(2, '0'), dailyUsed: 1.1, leftUsed: 50 }))
    } });
  } });
  await settle(); await settle();
  assert.ok(f.requests.length >= 1 && f.requests.length <= 8);
  assert.ok(f.messages.some(m => m.kind === 'daily' && m.daily.length));
  assert.ok(!JSON.stringify(f.messages).includes('fixture-secret'));
  const before = f.requests.length;
  f.context.__pocketEcard.refresh();
  await settle();
  assert.equal(f.requests.length, before, 'completed room is not repeatedly fetched on DOM mutation');
});

test('foreign detail links trigger no background request', () => {
  const f = fixture({ links: ['https://evil.example/user/powerfee/toDailyDetails?roomNum=x&token=x&schoolAreaNo=x'] });
  assert.equal(f.requests.length, 0);
});

const detailURL = 'https://ecard.gzucm.edu.cn/user/powerfee/toDailyDetails?implType=CGCOMMON1001&type=2&schoolAreaNo=area-fixture&buildingNo=building-fixture&roomNum=room-fixture&token=fixture-secret';

test('completion is emitted after all intended month batches and follows incremental data', async () => {
  const months = [];
  const f = fixture({ now: '2026-11-03T08:00:00Z', links: [detailURL], tips: ['剩余电量：40度'], fetch: async (url, init) => {
    const month = new URLSearchParams(init.body).get('lastDate');
    months.push(month);
    return response('https://ecard.gzucm.edu.cn/user/powerfee/getDailyDetails', {
      ret: true, obj: { totalPage: 1, dailyDetailsInfos: [{ dateTime: month + '-01', dailyUsed: 1, leftUsed: 40 }] }
    });
  } });
  await settle(); await settle();
  assert.deepEqual(months, ['2026-11', '2026-10']);
  assert.deepEqual(f.messages.map(m => m.kind), ['balance', 'daily', 'daily', 'complete', 'status']);
  const complete = f.messages.find(m => m.kind === 'complete');
  assert.equal(complete.roomKey, f.messages[0].roomKey);
  assert.deepEqual(Object.keys(complete).sort(), ['kind', 'roomKey', 'version']);
});

test('valid empty monthly histories still complete successfully', async () => {
  const f = fixture({ now: '2026-11-20T08:00:00Z', links: [detailURL], tips: ['剩余电量：0度'], fetch: async () => {
    return response('https://ecard.gzucm.edu.cn/user/powerfee/getDailyDetails', { ret: true, obj: { totalPage: 0, dailyDetailsInfos: [] } });
  } });
  await settle();
  assert.deepEqual(f.messages.map(m => m.kind), ['balance', 'daily', 'complete', 'status']);
  assert.equal(f.messages[0].balance, 0);
});

test('a later month failure leaves earlier visible data incomplete', async () => {
  const f = fixture({ now: '2026-11-03T08:00:00Z', links: [detailURL], tips: ['剩余电量：40度'], fetch: async (url, init) => {
    const month = new URLSearchParams(init.body).get('lastDate');
    return response('https://ecard.gzucm.edu.cn/user/powerfee/getDailyDetails', month === '2026-11'
      ? { ret: true, obj: { totalPage: 0, dailyDetailsInfos: [] } }
      : { ret: false, obj: null });
  } });
  await settle(); await settle();
  assert.ok(f.messages.some(m => m.kind === 'daily'));
  assert.ok(!f.messages.some(m => m.kind === 'complete'));
});

test('bounded truncated pagination never claims completeness', async () => {
  const f = fixture({ now: '2026-11-20T08:00:00Z', links: [detailURL], fetch: async () => {
    return response('https://ecard.gzucm.edu.cn/user/powerfee/getDailyDetails', { ret: true, obj: {
      totalPage: 5,
      dailyDetailsInfos: Array.from({ length: 30 }, (_, i) => ({ dateTime: '2026-11-' + String(i + 1).padStart(2, '0'), dailyUsed: 1, leftUsed: 50 }))
    } });
  } });
  await settle(); await settle();
  assert.equal(f.requests.length, 4);
  assert.ok(!f.messages.some(m => m.kind === 'complete'));
});

test('a changed balance starts another history read before its next completion', async () => {
  const f = fixture({ now: '2026-11-20T08:00:00Z', links: [detailURL], tips: ['剩余电量：40度'], fetch: async () => {
    return response('https://ecard.gzucm.edu.cn/user/powerfee/getDailyDetails', { ret: true, obj: { totalPage: 0, dailyDetailsInfos: [] } });
  } });
  await settle();
  assert.equal(f.messages.filter(m => m.kind === 'complete').length, 1);
  f.xhr('/user/powerfee/getBalance').respond({ ret: true, obj: { powerBalance: 80 } });
  const changed = f.messages.findIndex(m => m.kind === 'balance' && m.balance === 80);
  assert.equal(f.messages.slice(changed).filter(m => m.kind === 'complete').length, 0);
  await settle();
  assert.equal(f.requests.length, 2);
  assert.deepEqual(f.messages.slice(changed).map(m => m.kind), ['balance', 'daily', 'complete', 'status']);
});

test('previously bound room performs read-only same-origin balance lookup without importing cookies', async () => {
  const url = detailURL;
  const calls = [];
  const f = fixture({ links: [url], fetch: async (raw, init) => {
    calls.push({ raw, init });
    if (raw === '/user/powerfee/getBalance') {
      const form = new URLSearchParams(init.body);
      assert.equal(init.credentials, 'same-origin');
      assert.equal(form.get('roomNum'), 'room-fixture');
      assert.equal(form.get('token'), 'fixture-secret');
      assert.equal(form.get('from'), '');
      return response('https://ecard.gzucm.edu.cn/user/powerfee/getBalance', {
        ret: true, obj: { powerBalance: '19.60', roomNum: 'room-fixture', token: 'server-only' }
      });
    }
    return response('https://ecard.gzucm.edu.cn/user/powerfee/getDailyDetails', {
      ret: true, obj: { totalPage: 0, dailyDetailsInfos: [{ dateTime: '2026-11-04', dailyUsed: '1.4', leftUsed: '19.6' }] }
    });
  } });
  await settle();
  await settle();
  assert.equal(f.messages.some(m => m.kind === 'balance' && m.balance === 19.6), true);
  assert.equal(calls.filter(x => x.raw.endsWith('/getBalance')).length, 1);
  assert.equal(JSON.stringify(f.messages).includes('fixture-secret'), false);
  assert.equal(JSON.stringify(f.messages).includes('server-only'), false);
});

test('automatic balance reader does not query unbound or mismatched room URLs', async () => {
  const wrongRoomLink = detailURL.replace('roomNum=room-fixture', 'roomNum=someone-else');
  const f = fixture({ links: [wrongRoomLink], tips: [] });
  await settle();
  assert.equal(f.requests.some(x => x.url.endsWith('/getBalance')), false);
});
