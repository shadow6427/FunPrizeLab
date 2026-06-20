import { get } from './api.js';
import assert from 'assert';

// Mock localStorage
globalThis.localStorage = {
  getItem: () => null,
  setItem: () => {},
  removeItem: () => {}
} as any;

let fetchCalls = 0;
let refreshCalls = 0;
let shouldRefreshSucceed = true;

globalThis.fetch = async (url: string | URL | globalThis.Request, config?: any) => {
  const urlStr = url.toString();
  
  if (urlStr.includes('/auth/refresh')) {
    // Artificial delay to test concurrency
    await new Promise(r => setTimeout(r, 50));
    refreshCalls++;
    if (shouldRefreshSucceed) {
      return new Response(JSON.stringify({ token: 'new-valid-token' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' }
      });
    } else {
      return new Response(null, { status: 403 });
    }
  }

  fetchCalls++;
  
  const token = config?.headers?.['Authorization'] || (config?.headers as any)?.get?.('Authorization');
  
  if (token === 'Bearer new-valid-token') {
    return new Response(JSON.stringify({ success: true, data: 'ok' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  return new Response(JSON.stringify({ error: 'Unauthorized' }), {
    status: 401,
    headers: { 'Content-Type': 'application/json' }
  });
};

async function runTests() {
  console.log('Test 1: Single 401 request with successful refresh');
  fetchCalls = 0;
  refreshCalls = 0;
  shouldRefreshSucceed = true;
  
  const result = await get<any>('/data');
  assert.strictEqual(result.data.success, true);
  assert.strictEqual(fetchCalls, 2); // 1st fails, 2nd succeeds
  assert.strictEqual(refreshCalls, 1);
  console.log('✓ Test 1 passed\n');

  console.log('Test 2: Concurrent 401 requests with successful refresh');
  fetchCalls = 0;
  refreshCalls = 0;
  shouldRefreshSucceed = true;

  const [res1, res2, res3] = await Promise.all([
    get<any>('/data1'),
    get<any>('/data2'),
    get<any>('/data3')
  ]);

  assert.strictEqual(res1.data.success, true);
  assert.strictEqual(res2.data.success, true);
  assert.strictEqual(res3.data.success, true);
  
  assert.strictEqual(fetchCalls, 6);
  assert.strictEqual(refreshCalls, 1); // Only 1 refresh despite 3 requests
  console.log('✓ Test 2 passed\n');

  console.log('Test 3: Refresh failure surfaces correctly');
  fetchCalls = 0;
  refreshCalls = 0;
  shouldRefreshSucceed = false;

  let caughtError: any = null;
  try {
    await get<any>('/data-fail');
  } catch (e) {
    caughtError = e;
  }

  assert.ok(caughtError);
  assert.strictEqual(caughtError.code, 401);
  assert.strictEqual(caughtError.message, 'Authentication failed. Please log in again.');
  assert.strictEqual(fetchCalls, 1);
  assert.strictEqual(refreshCalls, 1);
  console.log('✓ Test 3 passed\n');
}

runTests().then(() => {
  console.log('All tests passed!');
  process.exit(0);
}).catch(err => {
  console.error('Test failed:', err);
  process.exit(1);
});
