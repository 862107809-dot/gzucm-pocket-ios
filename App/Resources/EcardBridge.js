/*
 * GZUCM Pocket iOS. Derived from the MIT-licensed Android port by 朱致辉.
 * Runs only in the top-level official electricity page. No form credentials,
 * session cookies, signatures or tokens cross the native message bridge.
 */
(function () {
  'use strict';
  if (window.top !== window || location.protocol !== 'https:' ||
      location.hostname !== 'ecard.gzucm.edu.cn' ||
      !location.pathname.startsWith('/user/powerfee/') || window.__pocketEcard) return;

  const originalFetch = typeof window.fetch === 'function' ? window.fetch.bind(window) : null;
  let apiBalanceSeen = false;
  let lastBalance = '';
  let lastAutomaticBalanceRequest = 0;
  let automaticBalanceInFlight = false;
  const syncInFlight = new Set();
  const syncedRooms = new Set();
  const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pocketPower;
  if (!native || typeof native.postMessage !== 'function') return;

  function send(body) {
    native.postMessage(Object.assign({ version: 1 }, body));
  }
  function text(value) {
    return value == null ? '' : String(value).replace(/\s+/g, ' ').trim();
  }
  function number(value) {
    if (typeof value === 'boolean' || value == null || text(value) === '') return null;
    const match = text(value).replace(/,/g, '').match(/-?\d+(?:\.\d+)?/);
    const n = match ? Number(match[0]) : NaN;
    return Number.isFinite(n) ? n : null;
  }
  function value(name) {
    const inputs = document.querySelectorAll('input[name="' + name + '"]');
    for (const input of inputs) if (text(input.value)) return text(input.value);
    return '';
  }
  function pageRoom() {
    return {
      roomNum: value('roomNum'),
      schoolAreaNo: value('schoolAreaNo'),
      buildingNo: value('buildingNo'),
      roomLabel: value('roomChooseText')
    };
  }
  function roomKey(room) {
    return [room.schoolAreaNo, room.buildingNo, room.roomNum].map(text).join('/');
  }
  function apiRoom(obj, requestRoom) {
    const fallback = requestRoom || pageRoom();
    return {
      roomNum: text(obj.roomNum) || fallback.roomNum,
      schoolAreaNo: text(obj.schoolAreaNo) || fallback.schoolAreaNo,
      buildingNo: text(obj.buildingNo) || fallback.buildingNo,
      roomLabel: obj.building && obj.room
        ? text(obj.building) + ' ' + text(obj.room)
        : text(obj.roomLabel) || fallback.roomLabel || text(obj.roomNum)
    };
  }
  function isSuccessful(json) {
    return json && (json.ret === true || json.ret === 'true') && json.obj && typeof json.obj === 'object';
  }
  function parseBalance(json, requestRoom) {
    if (!isSuccessful(json)) return null;
    const obj = json.obj;
    const balance = number(text(obj.formatPowerBalanceStr) || obj.powerBalance);
    if (balance === null) return null; // Missing balance must never overwrite a good value with zero.
    const room = apiRoom(obj, requestRoom);
    return { kind: 'balance', balance, unit: text(obj.du) || '度', roomLabel: room.roomLabel || '宿舍', roomKey: roomKey(room) };
  }
  function isoDate(raw) {
    const date = text(raw).replace(/\//g, '-').slice(0, 10);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
    const parsed = new Date(date + 'T00:00:00Z');
    return Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== date ? null : date;
  }
  function parseDaily(json) {
    if (!isSuccessful(json) || !Array.isArray(json.obj.dailyDetailsInfos)) return null;
    const byDate = new Map();
    for (const row of json.obj.dailyDetailsInfos.slice(0, 500)) {
      if (!row || typeof row !== 'object') continue;
      const date = isoDate(row.dateTime || row.accountTime || row.date || row.time);
      const usage = number(row.dailyUsed);
      const remain = number(row.leftUsed);
      if (!date || usage === null || usage < 0 || remain === null) continue;
      byDate.set(date, { date, usage, remain, total: number(row.totalUsed) ?? 0 });
    }
    return Array.from(byDate.values()).sort((a, b) => a.date.localeCompare(b.date));
  }
  function officialPowerURL(raw) {
    try {
      const url = new URL(raw, location.href);
      return url.origin === location.origin && url.pathname.startsWith('/user/powerfee/') ? url : null;
    } catch (_) { return null; }
  }
  function requestRoom(rawURL, body) {
    const room = pageRoom();
    const url = officialPowerURL(rawURL);
    const parameters = new URLSearchParams(url ? url.search : '');
    const form = typeof body === 'string' || body instanceof URLSearchParams ? new URLSearchParams(body) : null;
    for (const key of ['schoolAreaNo', 'buildingNo', 'roomNum']) {
      room[key] = (form && form.get(key)) || parameters.get(key) || room[key];
    }
    return room;
  }
  function capture(rawURL, responseText, status, requestedRoom) {
    const url = officialPowerURL(rawURL);
    if (!url || status < 200 || status >= 300 || typeof responseText !== 'string' || responseText.length > 1000000) return;
    const currentRoom = pageRoom();
    // A room change must not attach a late response from the previous room to the new one.
    if (requestedRoom && requestedRoom.roomNum && currentRoom.roomNum && roomKey(requestedRoom) !== roomKey(currentRoom)) return;
    let json;
    try { json = JSON.parse(responseText); } catch (_) { return; }
    if (/\/(getBalance|getSelfBalance)$/.test(url.pathname)) {
      const balance = parseBalance(json, requestedRoom);
      if (balance) {
        apiBalanceSeen = true;
        sendBalance(balance);
        syncDailyFromPage();
      }
    } else if (/\/getDailyDetails$/.test(url.pathname)) {
      const daily = parseDaily(json);
      if (daily) send({ kind: 'daily', daily, roomKey: roomKey(requestedRoom || currentRoom) });
    }
  }
  function sendBalance(balance) {
    const signature = JSON.stringify(balance);
    if (signature !== lastBalance) {
      lastBalance = signature;
      // A changed balance starts a new snapshot. Refresh its history before marking it complete.
      syncedRooms.delete(balance.roomKey);
      send(balance);
    }
  }

  // XHR is used by the school's jQuery. Forward the original arguments and response unchanged.
  if (typeof XMLHttpRequest !== 'undefined') {
    const originalOpen = XMLHttpRequest.prototype.open;
    const originalSend = XMLHttpRequest.prototype.send;
    const urls = new WeakMap();
    XMLHttpRequest.prototype.open = function (method, url) {
      urls.set(this, url);
      return originalOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      const requestedRoom = requestRoom(urls.get(this), arguments[0]);
      this.addEventListener('load', () => {
        try { capture(this.responseURL || urls.get(this), this.responseText, this.status, requestedRoom); } catch (_) {}
      }, { once: true });
      return originalSend.apply(this, arguments);
    };
  }
  if (originalFetch) {
    window.fetch = function () {
      const input = arguments[0];
      const init = arguments[1];
      const requestedRoom = requestRoom(typeof input === 'string' ? input : input && input.url, init && init.body);
      return originalFetch.apply(window, arguments).then(response => {
        try {
          const url = response.url;
          if (officialPowerURL(url)) {
            response.clone().text().then(body => capture(url, body, response.status, requestedRoom)).catch(() => {});
          }
        } catch (_) {}
        return response;
      });
    };
  }

  function domBalance() {
    const room = pageRoom();
    if (!room.roomNum || apiBalanceSeen) return;
    for (const node of document.querySelectorAll('[id="powerTips"]')) {
      const tips = text(node.textContent);
      const match = tips.match(/(?:剩余电量|剩余电费|电费余额)\s*[:：]?\s*(-?\d+(?:\.\d+)?)/);
      if (!match) continue;
      const balance = Number(match[1]);
      if (!Number.isFinite(balance)) continue;
      sendBalance({ kind: 'balance', balance, unit: /元/.test(tips) ? '元' : '度', roomLabel: room.roomLabel || '宿舍', roomKey: roomKey(room) });
      return;
    }
  }

  // Read the school's rendered detail link, rather than manufacturing a token/signature.
  // Only this verified endpoint is paginated, with at most four requests per month.
  function detailLink() {
    for (const anchor of document.querySelectorAll('a[href]')) {
      const url = officialPowerURL(anchor.href);
      if (url && /\/toDailyDetails$/.test(url.pathname) && url.searchParams.get('roomNum') &&
          url.searchParams.get('token') && url.searchParams.get('schoolAreaNo')) return url;
    }
    return null;
  }
  async function syncDailyFromPage() {
    const link = detailLink();
    if (!link || !originalFetch) return;
    const linkRoom = {
      roomNum: link.searchParams.get('roomNum'),
      schoolAreaNo: link.searchParams.get('schoolAreaNo'),
      buildingNo: link.searchParams.get('buildingNo') || value('buildingNo')
    };
    const key = roomKey(linkRoom);
    if (syncInFlight.has(key) || syncedRooms.has(key)) return;
    syncInFlight.add(key);
    const chinaNow = new Date(Date.now() + 8 * 60 * 60 * 1000);
    const year = chinaNow.getUTCFullYear();
    const month = chinaNow.getUTCMonth();
    let count = 0;
    try {
      // A prior-month request supplies a usable recent history at the start of a month.
      const monthOffsets = chinaNow.getUTCDate() <= 7 ? [0, -1] : [0];
      for (const offset of monthOffsets) {
        const date = new Date(Date.UTC(year, month + offset, 1));
        const ym = date.getUTCFullYear() + '-' + String(date.getUTCMonth() + 1).padStart(2, '0');
        let monthComplete = false;
        for (let page = 1; page <= 4; page++) {
          const parameters = new URLSearchParams(link.search);
          parameters.set('lastDate', ym);
          parameters.set('pageNum', String(page));
          parameters.set('pageSize', '30');
          const response = await originalFetch('/user/powerfee/getDailyDetails', {
            method: 'POST', credentials: 'same-origin',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8', 'X-Requested-With': 'XMLHttpRequest' },
            body: parameters.toString()
          });
          if (!response.ok || !officialPowerURL(response.url)) throw new Error('school response');
          const json = await response.json();
          const daily = parseDaily(json);
          if (!daily) throw new Error('daily response');
          send({ kind: 'daily', daily, roomKey: key });
          count += daily.length;
          const pageCount = Number(json.obj.totalPage);
          const rawCount = json.obj.dailyDetailsInfos.length;
          if (rawCount < 30 || (Number.isFinite(pageCount) && pageCount >= 0 && page >= pageCount)) {
            monthComplete = true;
            break;
          }
        }
        if (!monthComplete) throw new Error('pagination limit');
      }
      syncedRooms.add(key);
      send({ kind: 'complete', roomKey: key });
      send({ kind: 'status', message: count ? '余额与用电明细已读取，可点完成返回。' : '余额已读取，学校暂无用电明细。' });
    } catch (_) {
      send({ kind: 'status', message: '余额保留。明细暂未读取，可在学校网页中点击用电明细或重新加载。' });
    } finally {
      syncInFlight.delete(key);
    }
  }
  // Prefer the normal page's authenticated requests. When its balance remains
  // blank after load, issue ONLY the school's read-only getBalance using the
  // already-rendered, same-origin room and token. No credentials are extracted.
  async function syncBalanceFromPage() {
    if (apiBalanceSeen || lastBalance || automaticBalanceInFlight || !originalFetch ||
        Date.now() - lastAutomaticBalanceRequest < 120000) return;
    const link = detailLink();
    const room = pageRoom();
    if (!link || !room.roomNum ||
        link.searchParams.get('roomNum') !== room.roomNum ||
        link.searchParams.get('schoolAreaNo') !== room.schoolAreaNo) return;
    automaticBalanceInFlight = true;
    lastAutomaticBalanceRequest = Date.now();
    try {
      const form = new URLSearchParams({
        implType: 'CGCOMMON1001',
        schoolAreaNo: room.schoolAreaNo,
        buildingNo: room.buildingNo || link.searchParams.get('buildingNo') || '',
        roomNum: room.roomNum,
        token: link.searchParams.get('token') || '',
        from: ''
      });
      const response = await originalFetch('/user/powerfee/getBalance', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'X-Requested-With': 'XMLHttpRequest'
        },
        body: form.toString()
      });
      if (response.ok && officialPowerURL(response.url)) {
        const payload = await response.text();
        capture(response.url, payload, response.status, room);
      }
    } catch (_) {
      // Leave the existing balance intact. A real auth challenge will be
      // handled by the visible school page, never by this script.
    } finally {
      automaticBalanceInFlight = false;
    }
  }
  function refresh() {
    domBalance();
    syncDailyFromPage();
    syncBalanceFromPage();
  }
  window.__pocketEcard = Object.freeze({ refresh });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', refresh, { once: true });
  else refresh();
  let scheduled = false;
  const observer = new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => { scheduled = false; refresh(); }, 250);
  });
  observer.observe(document, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['value', 'href'] });
})();
