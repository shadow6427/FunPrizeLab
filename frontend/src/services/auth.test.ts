import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

class MockBroadcastChannel {
  name: string;
  onmessage: ((ev: MessageEvent) => any) | null = null;
  static instances: MockBroadcastChannel[] = [];
  
  constructor(name: string) {
    this.name = name;
    MockBroadcastChannel.instances.push(this);
  }
  
  addEventListener(type: string, listener: any) {
    if (type === 'message') {
      this.onmessage = listener;
    }
  }
  
  removeEventListener(type: string, listener: any) {
    if (type === 'message' && this.onmessage === listener) {
      this.onmessage = null;
    }
  }
  
  postMessage(message: any) {
    MockBroadcastChannel.instances.forEach(instance => {
      if (instance !== this && instance.name === this.name && instance.onmessage) {
        instance.onmessage({ data: message } as MessageEvent);
      }
    });
  }
  close() {}
}

vi.stubGlobal('BroadcastChannel', MockBroadcastChannel);

describe('Auth Token Refresh', () => {
  let auth: typeof import('./auth');
  let api: typeof import('./api');

  beforeEach(async () => {
    vi.resetModules();
    
    // Use doMock to mock api for dynamic import
    vi.doMock('./api', () => ({
      post: vi.fn(),
      get: vi.fn(),
      del: vi.fn(),
      put: vi.fn()
    }));
    
    api = await import('./api');
    auth = await import('./auth');
    
    vi.clearAllMocks();
    localStorage.clear();
    MockBroadcastChannel.instances = [];
    
    const initialTokens = {
      accessToken: 'header.' + btoa(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 3600 })) + '.sig',
      refreshToken: 'refresh1',
      expiresIn: 3600,
      tokenType: 'Bearer'
    };
    localStorage.setItem('tot_auth_tokens', JSON.stringify(initialTokens));
  });
  
  afterEach(() => {
    vi.useRealTimers();
  });

  it('same-tab concurrency: only one refresh request is made for concurrent calls', async () => {
    const newTokens = {
      accessToken: 'header.' + btoa(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 7200 })) + '.sig',
      refreshToken: 'refresh2',
      expiresIn: 3600,
      tokenType: 'Bearer'
    };

    let resolveApi: any;
    vi.mocked(api.post).mockReturnValue(new Promise(resolve => {
      resolveApi = resolve;
    }));

    const p1 = auth.refreshTokens();
    const p2 = auth.refreshTokens();

    resolveApi({ data: { tokens: newTokens } });

    const [r1, r2] = await Promise.all([p1, p2]);

    expect(r1).toEqual(newTokens);
    expect(r2).toEqual(newTokens);
    expect(api.post).toHaveBeenCalledTimes(1);
  });

  it('cross-tab success propagation: when one tab refreshes, the other adopts the tokens', async () => {
    const newTokens = {
      accessToken: 'header.' + btoa(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 7200 })) + '.sig',
      refreshToken: 'refresh2',
      expiresIn: 3600,
      tokenType: 'Bearer'
    };

    localStorage.setItem('tot_auth_refresh_lock', Date.now().toString());
    
    const p2 = auth.refreshTokens();
    
    const channel = new MockBroadcastChannel('tot_auth_channel');
    localStorage.setItem('tot_auth_tokens', JSON.stringify(newTokens));
    channel.postMessage({ type: 'TOKENS_REFRESHED', tokens: newTokens });
    
    const r2 = await p2;
    expect(r2).toEqual(newTokens);
    expect(api.post).toHaveBeenCalledTimes(0);
  });

  it('refresh failure behavior: fails without clearing tokens if another tab succeeded', async () => {
    const tokensA = {
      accessToken: 'header.' + btoa(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 7200 })) + '.sig',
      refreshToken: 'refresh2_A',
      expiresIn: 3600,
      tokenType: 'Bearer'
    };

    vi.mocked(api.post).mockRejectedValue(new Error('Network Error'));

    const p = auth.refreshTokens();
    localStorage.setItem('tot_auth_tokens', JSON.stringify(tokensA));
    
    const r = await p;
    expect(r).toEqual(tokensA);
  });
});
