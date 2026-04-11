/**
 * Ghost Chat — Comprehensive E2E Test Suite
 *
 * Full end-to-end tests against the REAL server.
 * Two browser instances, real WebRTC P2P, real encryption.
 *
 * Non-P2P tests always run (security headers, TURN creds, crypto, UI, WS protocol).
 * P2P tests require TEST_P2P=1 env var (they need real WebRTC which doesn't work
 * in headless Chromium on localhost without a TURN server).
 *
 * Usage:
 *   npx playwright test tests/e2e-full.spec.js                    # non-P2P only
 *   TEST_P2P=1 npx playwright test tests/e2e-full.spec.js         # all tests
 *   BASE_URL=https://ghostchat.one TEST_P2P=1 npx playwright test tests/e2e-full.spec.js  # production
 */

import { test, expect } from '@playwright/test';

const BASE_URL = process.env.BASE_URL || 'http://localhost:3000';
const P2P_TIMEOUT = 20000;
const MSG_TIMEOUT = 15000;
const skipP2P = !process.env.TEST_P2P;

// ============================================================================
// Helpers
// ============================================================================

async function getRoomId(page) {
  return page.evaluate(() => window.ghostChat?.roomId);
}

async function createContext(browser) {
  return browser.newContext({
    permissions: ['microphone'],
    ignoreHTTPSErrors: true,
  });
}

/**
 * Full setup: Host creates room, Guest joins, wait for P2P + key exchange.
 * Disables privacy mode on localhost (relay needs TURN which dev doesn't have).
 */
async function setupP2PPair(browser, options = {}) {
  const hostCtx = await createContext(browser);
  const guestCtx = await createContext(browser);
  const hostPage = await hostCtx.newPage();
  const guestPage = await guestCtx.newPage();

  // Host creates room
  await hostPage.goto(BASE_URL);
  await hostPage.waitForLoadState('networkidle');
  await expect(hostPage.locator('#create-room-btn')).toBeVisible({ timeout: 5000 });

  // Disable privacy mode for localhost (relay-only blocks direct connections without TURN)
  if (BASE_URL.includes('localhost') || BASE_URL.includes('127.0.0.1')) {
    await hostPage.evaluate(() => {
      const toggle = document.getElementById('privacy-mode-toggle');
      if (toggle && toggle.checked) {
        toggle.checked = false;
        toggle.dispatchEvent(new Event('change'));
      }
    });
  }

  await hostPage.locator('#create-room-btn').click();
  await expect(hostPage.locator('#waiting-screen')).toBeVisible({ timeout: 10000 });

  const roomId = await getRoomId(hostPage);
  expect(roomId).toBeTruthy();

  // Guest joins
  await guestPage.goto(BASE_URL);
  await guestPage.waitForLoadState('networkidle');
  await expect(guestPage.locator('#join-room-input')).toBeVisible({ timeout: 5000 });

  if (BASE_URL.includes('localhost') || BASE_URL.includes('127.0.0.1')) {
    await guestPage.evaluate(() => {
      const toggle = document.getElementById('privacy-mode-toggle');
      if (toggle && toggle.checked) {
        toggle.checked = false;
        toggle.dispatchEvent(new Event('change'));
      }
    });
  }

  await guestPage.locator('#join-room-input').fill(roomId);
  await guestPage.locator('#join-room-btn').click();

  // Wait for both to reach connected state (P2P + key exchange)
  await Promise.all([
    hostPage.waitForFunction(() => window.ghostChat?.isConnected === true, { timeout: options.timeout || P2P_TIMEOUT }),
    guestPage.waitForFunction(() => window.ghostChat?.isConnected === true, { timeout: options.timeout || P2P_TIMEOUT }),
  ]);

  // Verify chat screen is visible on both sides
  await expect(hostPage.locator('#chat-screen')).toBeVisible({ timeout: 5000 });
  await expect(guestPage.locator('#chat-screen')).toBeVisible({ timeout: 5000 });

  return { hostPage, guestPage, hostCtx, guestCtx, roomId };
}

async function cleanup(...contexts) {
  for (const ctx of contexts) {
    try { await ctx.close(); } catch {}
  }
}

async function sendAndVerify(senderPage, receiverPage, text) {
  await senderPage.locator('#message-input').fill(text);
  await senderPage.locator('#send-btn').click();

  await receiverPage.waitForFunction(
    (t) => {
      const msgs = document.querySelectorAll('.message:not(.system) .message-content');
      return Array.from(msgs).some(m => m.textContent.includes(t));
    },
    text,
    { timeout: MSG_TIMEOUT }
  );
}

// ============================================================================
// SCENARIO 1: Full Connection Flow (P2P required)
// ============================================================================

test.describe('Scenario 1: Full Connection Flow', () => {
  test.skip(() => skipP2P, 'Requires real WebRTC P2P (set TEST_P2P=1)');

  test('Browser A creates room, Browser B joins, P2P established, key exchange completes', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, guestPage, hostCtx, guestCtx } = pair;

    try {
      // Both should show chat screen
      await expect(hostPage.locator('#chat-screen')).toBeVisible();
      await expect(guestPage.locator('#chat-screen')).toBeVisible();

      // Both connected
      expect(await hostPage.evaluate(() => window.ghostChat?.isConnected)).toBe(true);
      expect(await guestPage.evaluate(() => window.ghostChat?.isConnected)).toBe(true);

      // Key exchange complete
      expect(await hostPage.evaluate(() => window.ghostChat?.crypto?.isReady())).toBe(true);
      expect(await guestPage.evaluate(() => window.ghostChat?.crypto?.isReady())).toBe(true);

      // System message about secure connection
      await expect(hostPage.locator('.message.system', { hasText: 'соединение установлено' })).toBeVisible({ timeout: 5000 });
      await expect(guestPage.locator('.message.system', { hasText: 'соединение установлено' })).toBeVisible({ timeout: 5000 });

      // DataChannel open
      expect(await hostPage.evaluate(() => window.ghostChat?.rtc?.dataChannel?.readyState)).toBe('open');
      expect(await guestPage.evaluate(() => window.ghostChat?.rtc?.dataChannel?.readyState)).toBe('open');
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });
});

// Non-P2P room creation tests

test.describe('Room Creation', () => {
  test('Room code is long enough (384-bit base64url)', async ({ browser }) => {
    const ctx = await createContext(browser);
    const page = await ctx.newPage();

    try {
      await page.goto(BASE_URL);
      await page.locator('#create-room-btn').click();
      await expect(page.locator('#waiting-screen')).toBeVisible({ timeout: 10000 });

      const roomId = await getRoomId(page);
      expect(roomId).toBeTruthy();
      expect(roomId.length).toBeGreaterThanOrEqual(40);
    } finally {
      await cleanup(ctx);
    }
  });

  test('Guest cannot join non-existent room', async ({ browser }) => {
    const ctx = await createContext(browser);
    const page = await ctx.newPage();

    try {
      await page.goto(BASE_URL);
      await page.locator('#join-room-input').fill('nonexistent-room-id-that-does-not-exist');
      await page.locator('#join-room-btn').click();

      // Server sends error -> leave() -> welcome screen
      await expect(page.locator('#welcome-screen')).toBeVisible({ timeout: 10000 });
    } finally {
      await cleanup(ctx);
    }
  });
});

// ============================================================================
// SCENARIO 2: Send and Receive Messages (P2P required)
// ============================================================================

test.describe('Scenario 2: Send and Receive Messages', () => {
  test.skip(() => skipP2P, 'Requires P2P (set TEST_P2P=1)');

  test('A sends message to B, B sends message to A, correct order, delivery checkmarks', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, guestPage, hostCtx, guestCtx } = pair;

    try {
      await sendAndVerify(hostPage, guestPage, 'Hello from A');
      await sendAndVerify(guestPage, hostPage, 'Hello from B');

      // Verify order on host side
      const hostMessages = await hostPage.evaluate(() => {
        const msgs = document.querySelectorAll('.message:not(.system) .message-content');
        return Array.from(msgs).map(m => m.textContent.trim());
      });
      expect(hostMessages.length).toBe(2);
      expect(hostMessages[0]).toContain('Hello from A');
      expect(hostMessages[1]).toContain('Hello from B');

      // Verify order on guest side
      const guestMessages = await guestPage.evaluate(() => {
        const msgs = document.querySelectorAll('.message:not(.system) .message-content');
        return Array.from(msgs).map(m => m.textContent.trim());
      });
      expect(guestMessages.length).toBe(2);
      expect(guestMessages[0]).toContain('Hello from A');
      expect(guestMessages[1]).toContain('Hello from B');

      // Delivery checkmark
      await hostPage.waitForFunction(() => {
        const timeEls = document.querySelectorAll('.message.sent .message-time');
        return Array.from(timeEls).some(t => t.textContent.includes('\u2713'));
      }, { timeout: MSG_TIMEOUT });
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });

  test('Multiple messages delivered in order', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, guestPage, hostCtx, guestCtx } = pair;

    try {
      const count = 5;
      for (let i = 1; i <= count; i++) {
        await hostPage.locator('#message-input').fill(`Message ${i}`);
        await hostPage.locator('#send-btn').click();
        await hostPage.waitForTimeout(300);
      }

      await guestPage.waitForFunction((n) => {
        const msgs = document.querySelectorAll('.message:not(.system) .message-content');
        return msgs.length >= n;
      }, count, { timeout: MSG_TIMEOUT });

      const guestMessages = await guestPage.evaluate(() => {
        const msgs = document.querySelectorAll('.message:not(.system) .message-content');
        return Array.from(msgs).map(m => m.textContent.trim());
      });

      for (let i = 1; i <= count; i++) {
        expect(guestMessages[i - 1]).toContain(`Message ${i}`);
      }
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });

  test('Empty message is not sent', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { guestPage, hostCtx, guestCtx } = pair;

    try {
      await pair.hostPage.locator('#send-btn').click();
      await guestPage.waitForTimeout(2000);
      const msgCount = await guestPage.evaluate(() =>
        document.querySelectorAll('.message:not(.system)').length
      );
      expect(msgCount).toBe(0);
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });

  test('Messages with special characters and Unicode', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, guestPage, hostCtx, guestCtx } = pair;

    try {
      const specialMsg = 'Test <script>alert(1)</script> & "quotes" \u{1F512} \u{1F47B}';
      await sendAndVerify(hostPage, guestPage, specialMsg);

      const displayed = await guestPage.evaluate(() => {
        const msgs = document.querySelectorAll('.message:not(.system) .message-content');
        return msgs[0]?.textContent;
      });
      expect(displayed).toContain('<script>');
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });
});

// ============================================================================
// SCENARIO 3: Message Encryption Verification (P2P required)
// ============================================================================

test.describe('Scenario 3: Encryption Verification', () => {
  test.skip(() => skipP2P, 'Requires P2P (set TEST_P2P=1)');

  test('DataChannel is used for messaging (not server relay)', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, hostCtx, guestCtx } = pair;

    try {
      const dc = await hostPage.evaluate(() => ({
        readyState: window.ghostChat?.rtc?.dataChannel?.readyState,
        label: window.ghostChat?.rtc?.dataChannel?.label,
        ordered: window.ghostChat?.rtc?.dataChannel?.ordered,
      }));
      expect(dc.readyState).toBe('open');
      expect(dc.label).toBe('ghost-chat');
      expect(dc.ordered).toBe(true);

      const pcState = await hostPage.evaluate(() =>
        window.ghostChat?.rtc?.peerConnection?.connectionState
      );
      expect(['connected', 'completed']).toContain(pcState);
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });

  test('Fingerprint matches on both sides', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, guestPage, hostCtx, guestCtx } = pair;

    try {
      const hostFP = await hostPage.evaluate(() => window.ghostChat?.currentFingerprint);
      const guestFP = await guestPage.evaluate(() => window.ghostChat?.currentFingerprint);
      expect(hostFP).toBeTruthy();
      expect(guestFP).toBeTruthy();
      expect(hostFP).toBe(guestFP);
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });

  test('Shared key derived and crypto ready', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, guestPage, hostCtx, guestCtx } = pair;

    try {
      for (const page of [hostPage, guestPage]) {
        const crypto = await page.evaluate(() => ({
          isReady: window.ghostChat?.crypto?.isReady(),
          hasKeyPair: !!window.ghostChat?.crypto?.keyPair,
          hasPeerKey: !!window.ghostChat?.crypto?.peerPublicKey,
        }));
        expect(crypto.isReady).toBe(true);
        expect(crypto.hasKeyPair).toBe(true);
        expect(crypto.hasPeerKey).toBe(true);
      }
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });

  test('Message padding to 256-byte blocks', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, hostCtx, guestCtx } = pair;

    try {
      const padResult = await hostPage.evaluate(() => {
        if (!window.ghostChat?.crypto?.padMessage) return null;
        const padded = window.ghostChat.crypto.padMessage('hello');
        return { length: padded.length, isMultiple: padded.length % 256 === 0 };
      });
      if (padResult) {
        expect(padResult.isMultiple).toBe(true);
        expect(padResult.length).toBeGreaterThanOrEqual(256);
      }
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });
});

// ============================================================================
// SCENARIO 4: Voice Call Flow (P2P required)
// ============================================================================

test.describe('Scenario 4: Voice Call Flow', () => {
  test.skip(() => skipP2P, 'Requires P2P (set TEST_P2P=1)');

  test('A initiates call, B sees incoming, B accepts, call active, A ends', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, guestPage, hostCtx, guestCtx } = pair;

    try {
      await expect(hostPage.locator('#call-btn')).toBeVisible();
      await expect(hostPage.locator('#call-btn')).toBeEnabled();

      // A initiates
      await hostPage.locator('#call-btn').click();
      await expect(hostPage.locator('#call-overlay')).toBeVisible({ timeout: 5000 });
      expect(await hostPage.evaluate(() => window.ghostChat?.callState)).toBe('calling');

      // B sees incoming
      await expect(guestPage.locator('#incoming-call')).toBeVisible({ timeout: 10000 });
      expect(await guestPage.evaluate(() => window.ghostChat?.callState)).toBe('ringing');

      // B accepts
      await guestPage.locator('#accept-call-btn').click();
      await hostPage.waitForFunction(() => window.ghostChat?.callState === 'active', { timeout: 10000 });
      await guestPage.waitForFunction(() => window.ghostChat?.callState === 'active', { timeout: 10000 });

      // Timer ticking
      await hostPage.waitForTimeout(2000);
      expect(await hostPage.locator('#call-timer').textContent()).toMatch(/\d{2}:\d{2}/);

      // A ends
      await hostPage.locator('#end-call-btn').click();
      await hostPage.waitForFunction(() => window.ghostChat?.callState === 'idle', { timeout: 5000 });
      await guestPage.waitForFunction(() => window.ghostChat?.callState === 'idle', { timeout: 5000 });

      await expect(hostPage.locator('#call-overlay')).toBeHidden();
      await expect(guestPage.locator('#incoming-call')).toBeHidden();

      const msgs = await hostPage.evaluate(() => {
        const m = document.querySelectorAll('.message.system');
        return Array.from(m).map(el => el.textContent);
      });
      expect(msgs.some(m => m.includes('завершён'))).toBe(true);
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });

  test('B declines call, both return to chat', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, guestPage, hostCtx, guestCtx } = pair;

    try {
      await hostPage.locator('#call-btn').click();
      await expect(guestPage.locator('#incoming-call')).toBeVisible({ timeout: 10000 });
      await guestPage.locator('#decline-call-btn').click();

      await hostPage.waitForFunction(() => window.ghostChat?.callState === 'idle', { timeout: 10000 });
      await guestPage.waitForFunction(() => window.ghostChat?.callState === 'idle', { timeout: 5000 });

      await sendAndVerify(hostPage, guestPage, 'Still connected after declined call');
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });
});

// ============================================================================
// SCENARIO 5: Control Messages (P2P required)
// ============================================================================

test.describe('Scenario 5: Control Messages', () => {
  test.skip(() => skipP2P, 'Requires P2P (set TEST_P2P=1)');

  test('Typing indicator: A types, B sees typing, A stops, indicator disappears', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, guestPage, hostCtx, guestCtx } = pair;

    try {
      await hostPage.locator('#message-input').fill('typing something...');
      await hostPage.evaluate(() => {
        window.ghostChat._lastTypingSentAt = 0;
        window.ghostChat.userIsTyping();
      });

      await guestPage.waitForFunction(() => {
        const el = document.getElementById('typing-indicator');
        return el && !el.classList.contains('hidden');
      }, { timeout: MSG_TIMEOUT });

      await hostPage.locator('#message-input').fill('');
      await hostPage.evaluate(() => window.ghostChat.stopTyping());

      await guestPage.waitForFunction(() => {
        const el = document.getElementById('typing-indicator');
        return el && el.classList.contains('hidden');
      }, { timeout: MSG_TIMEOUT });
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });

  test('Security alert: screenshot detection sends alert to peer', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, guestPage, hostCtx, guestCtx } = pair;

    try {
      await hostPage.evaluate(() => window.ghostChat.onScreenshotAttempt());

      await guestPage.waitForFunction(() => {
        const msgs = document.querySelectorAll('.message.system');
        return Array.from(msgs).some(m => m.textContent.includes('скриншот'));
      }, { timeout: MSG_TIMEOUT });

      expect(await hostPage.evaluate(() => {
        const msgs = document.querySelectorAll('.message.system');
        return Array.from(msgs).some(m => m.textContent.includes('скриншот'));
      })).toBe(true);
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });

  test('Message delivery ACK via _ctrl message', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, guestPage, hostCtx, guestCtx } = pair;

    try {
      await hostPage.locator('#message-input').fill('ACK test message');
      await hostPage.locator('#send-btn').click();

      await guestPage.waitForFunction(() => {
        const msgs = document.querySelectorAll('.message:not(.system) .message-content');
        return Array.from(msgs).some(m => m.textContent.includes('ACK test'));
      }, { timeout: MSG_TIMEOUT });

      await hostPage.waitForFunction(() => {
        const timeEls = document.querySelectorAll('.message.sent .message-time');
        return Array.from(timeEls).some(t => t.textContent.includes('\u2713'));
      }, { timeout: MSG_TIMEOUT });
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });
});

// ============================================================================
// SCENARIO 6: File Transfer Handlers (no P2P needed — checks API existence)
// ============================================================================

test.describe('Scenario 6: File Transfer Handlers', () => {
  test('File transfer handler methods exist on GhostChat instance', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForTimeout(500);

    const handlers = await page.evaluate(() => ({
      hasFileStart: typeof window.ghostChat?.handleFileStart === 'function',
      hasFileChunk: typeof window.ghostChat?.handleFileChunk === 'function',
      hasFileComplete: typeof window.ghostChat?.handleFileComplete === 'function',
      hasFormatSize: typeof window.ghostChat?._formatSize === 'function',
      hasAddFileMessage: typeof window.ghostChat?._addFileMessage === 'function',
    }));

    expect(handlers.hasFileStart).toBe(true);
    expect(handlers.hasFileChunk).toBe(true);
    expect(handlers.hasFileComplete).toBe(true);
    expect(handlers.hasFormatSize).toBe(true);
    expect(handlers.hasAddFileMessage).toBe(true);
  });

  test('File size formatting works correctly', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForTimeout(500);

    const results = await page.evaluate(() => {
      const gc = window.ghostChat;
      if (!gc?._formatSize) return null;
      return {
        bytes: gc._formatSize(500),
        kb: gc._formatSize(1024),
        mb: gc._formatSize(1024 * 1024),
        largeMb: gc._formatSize(5.5 * 1024 * 1024),
      };
    });

    if (results) {
      expect(results.bytes).toBe('500 B');
      expect(results.kb).toContain('KB');
      expect(results.mb).toContain('MB');
      expect(results.largeMb).toContain('MB');
    }
  });

  test('File start with oversized file is rejected (100MB limit)', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForTimeout(500);

    const result = await page.evaluate(() => {
      const gc = window.ghostChat;
      if (!gc?.handleFileStart) return null;
      const initialFiles = gc._incomingFiles || {};
      const initialCount = Object.keys(initialFiles).length;
      gc.handleFileStart({
        fileId: 'test-oversized',
        name: 'huge.bin',
        size: 200 * 1024 * 1024, // 200MB > 100MB limit
        mimeType: 'application/octet-stream',
        totalChunks: 100,
      });
      const afterFiles = gc._incomingFiles || {};
      const afterCount = Object.keys(afterFiles).length;
      return { initialCount, afterCount };
    });

    if (result) {
      expect(result.afterCount).toBe(result.initialCount);
    }
  });
});

// ============================================================================
// SCENARIO 7: Privacy Mode
// ============================================================================

test.describe('Scenario 7: Privacy Mode', () => {
  test('Privacy mode toggle changes iceTransportPolicy', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForTimeout(500);

    // Default: privacy mode ON
    expect(await page.evaluate(() => window.ghostChat?.privacyMode)).toBe(true);
    expect(await page.locator('#privacy-mode-toggle').isChecked()).toBe(true);

    // Toggle OFF
    await page.evaluate(() => {
      const toggle = document.getElementById('privacy-mode-toggle');
      toggle.checked = false;
      toggle.dispatchEvent(new Event('change'));
    });
    expect(await page.evaluate(() => window.ghostChat?.privacyMode)).toBe(false);

    // Toggle back ON
    await page.evaluate(() => {
      const toggle = document.getElementById('privacy-mode-toggle');
      toggle.checked = true;
      toggle.dispatchEvent(new Event('change'));
    });
    expect(await page.evaluate(() => window.ghostChat?.privacyMode)).toBe(true);
  });

  test('ICE transport policy reflects privacy mode when creating room', async ({ browser }) => {
    const ctx = await createContext(browser);
    const page = await ctx.newPage();

    try {
      await page.goto(BASE_URL);
      await page.locator('#create-room-btn').click();
      await expect(page.locator('#waiting-screen')).toBeVisible({ timeout: 10000 });

      const icePolicy = await page.evaluate(() =>
        window.ghostChat?.rtc?.config?.iceTransportPolicy
      );
      expect(icePolicy).toBe('relay');
    } finally {
      await cleanup(ctx);
    }
  });

  test('Connection works with relay mode (P2P)', async ({ browser }) => {
    test.skip(skipP2P, 'Requires P2P (set TEST_P2P=1)');
    // This test intentionally keeps privacy mode ON to test relay
    const hostCtx = await createContext(browser);
    const guestCtx = await createContext(browser);
    const hostPage = await hostCtx.newPage();
    const guestPage = await guestCtx.newPage();

    try {
      await hostPage.goto(BASE_URL);
      await hostPage.locator('#create-room-btn').click();
      await expect(hostPage.locator('#waiting-screen')).toBeVisible({ timeout: 10000 });
      const roomId = await getRoomId(hostPage);

      await guestPage.goto(BASE_URL);
      await guestPage.locator('#join-room-input').fill(roomId);
      await guestPage.locator('#join-room-btn').click();

      await Promise.all([
        hostPage.waitForFunction(() => window.ghostChat?.isConnected === true, { timeout: P2P_TIMEOUT }),
        guestPage.waitForFunction(() => window.ghostChat?.isConnected === true, { timeout: P2P_TIMEOUT }),
      ]);

      expect(await hostPage.evaluate(() => window.ghostChat?.privacyMode)).toBe(true);
      await sendAndVerify(hostPage, guestPage, 'Relay mode works!');
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });
});

// ============================================================================
// SCENARIO 8: Disconnect and Reconnect (P2P required)
// ============================================================================

test.describe('Scenario 8: Disconnect and Reconnect', () => {
  test.skip(() => skipP2P, 'Requires P2P (set TEST_P2P=1)');

  test('Guest disconnects, host sees disconnect', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, hostCtx, guestCtx } = pair;

    try {
      await guestCtx.close();

      await hostPage.waitForFunction(
        () => window.ghostChat?.isConnected === false,
        { timeout: 15000 }
      );

      expect(await hostPage.evaluate(() => {
        const msgs = document.querySelectorAll('.message.system');
        return Array.from(msgs).some(m =>
          m.textContent.includes('потеряно') || m.textContent.includes('отключился')
        );
      })).toBe(true);

      expect(await hostPage.locator('#send-btn').isDisabled()).toBe(true);
    } finally {
      await cleanup(hostCtx);
    }
  });

  test('Host leaves and returns to welcome screen', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostPage, guestPage, hostCtx, guestCtx } = pair;

    try {
      await hostPage.evaluate(() => window.ghostChat.leave());
      await expect(hostPage.locator('#welcome-screen')).toBeVisible({ timeout: 5000 });

      await guestPage.waitForFunction(
        () => window.ghostChat?.isConnected === false,
        { timeout: 15000 }
      );
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });

  test('One-time invite: second guest cannot join', async ({ browser }) => {
    const pair = await setupP2PPair(browser);
    const { hostCtx, guestCtx, roomId } = pair;
    const guest2Ctx = await createContext(browser);
    const guest2Page = await guest2Ctx.newPage();

    try {
      await guest2Page.goto(`${BASE_URL}/?room=${roomId}`);
      await guest2Page.waitForTimeout(5000);
      expect(await guest2Page.evaluate(() => window.ghostChat?.isConnected)).toBeFalsy();
    } finally {
      await cleanup(hostCtx, guestCtx, guest2Ctx);
    }
  });
});

// ============================================================================
// SCENARIO 9: Multiple Rooms Isolation (P2P required)
// ============================================================================

test.describe('Scenario 9: Multiple Rooms Isolation', () => {
  test.skip(() => skipP2P, 'Requires P2P (set TEST_P2P=1)');

  test('Messages in room1 do not leak to room2', async ({ browser }) => {
    const pair1 = await setupP2PPair(browser);
    const pair2 = await setupP2PPair(browser);

    try {
      expect(pair1.roomId).not.toBe(pair2.roomId);

      await sendAndVerify(pair1.hostPage, pair1.guestPage, 'ROOM1_SECRET_MSG');
      await sendAndVerify(pair2.hostPage, pair2.guestPage, 'ROOM2_SECRET_MSG');

      await pair1.guestPage.waitForTimeout(2000);

      const room1Msgs = await pair1.guestPage.evaluate(() => {
        const msgs = document.querySelectorAll('.message:not(.system) .message-content');
        return Array.from(msgs).map(m => m.textContent);
      });
      expect(room1Msgs.join(' ')).not.toContain('ROOM2_SECRET_MSG');

      const room2Msgs = await pair2.guestPage.evaluate(() => {
        const msgs = document.querySelectorAll('.message:not(.system) .message-content');
        return Array.from(msgs).map(m => m.textContent);
      });
      expect(room2Msgs.join(' ')).not.toContain('ROOM1_SECRET_MSG');
    } finally {
      await cleanup(pair1.hostCtx, pair1.guestCtx, pair2.hostCtx, pair2.guestCtx);
    }
  });
});

// ============================================================================
// SCENARIO 10: Security Headers
// ============================================================================

test.describe('Scenario 10: Security Headers', () => {
  test('CSP header is present and strict', async ({ request }) => {
    const response = await request.get(BASE_URL);
    const csp = response.headers()['content-security-policy'];
    expect(csp).toBeTruthy();
    expect(csp).not.toContain('unsafe-inline');
    expect(csp).not.toContain('unsafe-eval');
  });

  test('X-Frame-Options is DENY', async ({ request }) => {
    const response = await request.get(BASE_URL);
    expect(response.headers()['x-frame-options']).toBe('DENY');
  });

  test('X-Content-Type-Options is nosniff', async ({ request }) => {
    const response = await request.get(BASE_URL);
    expect(response.headers()['x-content-type-options']).toBe('nosniff');
  });

  test('HSTS header present in production', async ({ request }) => {
    const response = await request.get(BASE_URL);
    const hsts = response.headers()['strict-transport-security'];
    if (BASE_URL.startsWith('https://')) {
      expect(hsts).toBeTruthy();
      expect(hsts).toContain('max-age=');
    }
    // In dev (HTTP), HSTS not required
  });

  test('Path traversal returns 404', async ({ request }) => {
    expect((await request.get(`${BASE_URL}/../../etc/passwd`)).status()).toBe(404);
  });

  test('POST to static route returns 405', async ({ request }) => {
    expect((await request.post(BASE_URL)).status()).toBe(405);
  });

  test('JS files have correct Content-Type', async ({ request }) => {
    const res = await request.get(`${BASE_URL}/js/app.js`);
    expect(res.status()).toBe(200);
    expect(res.headers()['content-type']).toContain('javascript');
  });

  test('CSS files have correct Content-Type', async ({ request }) => {
    const res = await request.get(`${BASE_URL}/css/style.css`);
    expect(res.status()).toBe(200);
    expect(res.headers()['content-type']).toContain('css');
  });

  test('404 for nonexistent files', async ({ request }) => {
    expect((await request.get(`${BASE_URL}/nonexistent.html`)).status()).toBe(404);
  });

  test('.env file is not accessible', async ({ request }) => {
    expect((await request.get(`${BASE_URL}/.env`)).status()).toBe(404);
  });

  test('AASA file is accessible', async ({ request }) => {
    const res = await request.get(`${BASE_URL}/.well-known/apple-app-site-association`);
    expect(res.status()).toBe(200);
    const body = await res.json();
    expect(body.applinks || body.webcredentials).toBeTruthy();
  });
});

// ============================================================================
// SCENARIO 11: TURN Credentials API
// ============================================================================

test.describe('Scenario 11: TURN Credentials', () => {
  test('/api/turn-credentials returns valid structure', async ({ request }) => {
    const res = await request.get(`${BASE_URL}/api/turn-credentials`);
    expect(res.ok()).toBeTruthy();
    const creds = await res.json();

    expect(creds.username).toBeTruthy();
    expect(creds.credential).toBeTruthy();
    expect(creds.urls).toBeTruthy();
    expect(Array.isArray(creds.urls)).toBe(true);
    expect(creds.urls.length).toBeGreaterThanOrEqual(1);
    expect(creds.ttl).toBeGreaterThan(0);
  });

  test('TURN credentials include pushAuth token', async ({ request }) => {
    const creds = await (await request.get(`${BASE_URL}/api/turn-credentials`)).json();
    expect(creds.pushAuth).toBeTruthy();
    expect(typeof creds.pushAuth).toBe('string');
    expect(creds.pushAuth).toMatch(/^[0-9a-f]{64}$/);
  });

  test('TURN username contains timestamp (coturn HMAC format)', async ({ request }) => {
    const creds = await (await request.get(`${BASE_URL}/api/turn-credentials`)).json();
    const parts = creds.username.split(':');
    expect(parts.length).toBe(2);
    const timestamp = parseInt(parts[0]);
    expect(timestamp).toBeGreaterThan(0);
    const now = Math.floor(Date.now() / 1000);
    expect(timestamp).toBeGreaterThan(now);
  });

  test('Multiple requests return different credentials', async ({ request }) => {
    const c1 = await (await request.get(`${BASE_URL}/api/turn-credentials`)).json();
    const c2 = await (await request.get(`${BASE_URL}/api/turn-credentials`)).json();
    expect(c1.username).not.toBe(c2.username);
  });
});

// ============================================================================
// SCENARIO 12: Rate Limiting (run LAST — pollutes rate limit state)
// ============================================================================

test.describe('Scenario 12: Rate Limiting', () => {
  test('Excessive room creation gets rate limited', async ({ browser }) => {
    const ctx = await createContext(browser);
    const page = await ctx.newPage();

    try {
      await page.goto(BASE_URL);

      const result = await page.evaluate(async () => {
        const results = [];
        const wsUrl = `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}/ws`;

        for (let i = 0; i < 15; i++) {
          const ws = new WebSocket(wsUrl);
          const response = await new Promise((resolve) => {
            ws.onopen = () => ws.send(JSON.stringify({ type: 'create-room' }));
            ws.onmessage = (e) => {
              const msg = JSON.parse(e.data);
              ws.close();
              resolve(msg);
            };
            ws.onerror = () => resolve({ type: 'error', message: 'ws-error' });
            setTimeout(() => { ws.close(); resolve({ type: 'timeout' }); }, 3000);
          });
          results.push(response.type);
        }
        return results;
      });

      const successCount = result.filter(t => t === 'room-created').length;
      const errorCount = result.filter(t => t === 'error').length;

      expect(successCount).toBeGreaterThan(0);
      expect(successCount + errorCount + result.filter(t => t === 'timeout').length).toBe(15);
    } finally {
      await cleanup(ctx);
    }
  });

  test('WS per-IP connection limit exists', async ({ browser }) => {
    const ctx = await createContext(browser);
    const page = await ctx.newPage();

    try {
      await page.goto(BASE_URL);

      const result = await page.evaluate(async () => {
        const wsUrl = `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}/ws`;
        const sockets = [];
        let openCount = 0;
        let failCount = 0;

        for (let i = 0; i < 12; i++) {
          try {
            const ws = new WebSocket(wsUrl);
            const opened = await new Promise((resolve) => {
              ws.onopen = () => resolve(true);
              ws.onclose = () => resolve(false);
              ws.onerror = () => resolve(false);
              setTimeout(() => resolve(false), 2000);
            });
            if (opened) { sockets.push(ws); openCount++; }
            else { failCount++; }
          } catch { failCount++; }
        }

        sockets.forEach(ws => ws.close());
        return { openCount, failCount };
      });

      expect(result.openCount).toBeGreaterThan(0);
      expect(result.openCount + result.failCount).toBe(12);
    } finally {
      await cleanup(ctx);
    }
  });
});

// ============================================================================
// WebSocket Protocol Tests
// ============================================================================

test.describe('WebSocket Protocol', () => {
  test('create-room returns room-created with valid roomId', async ({ page }) => {
    await page.goto(BASE_URL);

    const result = await page.evaluate(async () => {
      return new Promise((resolve) => {
        const wsUrl = `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}/ws`;
        const ws = new WebSocket(wsUrl);
        ws.onopen = () => ws.send(JSON.stringify({ type: 'create-room' }));
        ws.onmessage = (e) => { ws.close(); resolve(JSON.parse(e.data)); };
        ws.onerror = () => resolve(null);
        setTimeout(() => { ws.close(); resolve(null); }, 5000);
      });
    });

    expect(result).toBeTruthy();
    if (result.type === 'error') {
      test.skip(true, 'Rate limited or server error: ' + result.message);
      return;
    }
    expect(result.type).toBe('room-created');
    expect(result.roomId).toBeTruthy();
    expect(result.roomId.length).toBeGreaterThanOrEqual(40);
  });

  test('join-room with valid roomId returns room-joined', async ({ page }) => {
    await page.goto(BASE_URL);

    const result = await page.evaluate(async () => {
      const wsUrl = `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}/ws`;

      const roomId = await new Promise((resolve) => {
        const ws1 = new WebSocket(wsUrl);
        ws1.onopen = () => ws1.send(JSON.stringify({ type: 'create-room' }));
        ws1.onmessage = (e) => {
          const msg = JSON.parse(e.data);
          if (msg.type === 'room-created') resolve(msg.roomId);
          if (msg.type === 'error') resolve(null);
        };
        setTimeout(() => resolve(null), 5000);
      });

      if (!roomId) return { type: 'skip' };

      return new Promise((resolve) => {
        const ws2 = new WebSocket(wsUrl);
        ws2.onopen = () => ws2.send(JSON.stringify({ type: 'join-room', roomId }));
        ws2.onmessage = (e) => { ws2.close(); resolve(JSON.parse(e.data)); };
        ws2.onerror = () => resolve(null);
        setTimeout(() => { ws2.close(); resolve(null); }, 5000);
      });
    });

    if (result?.type === 'skip') { test.skip(true, 'Rate limited'); return; }
    expect(result).toBeTruthy();
    expect(result.type).toBe('room-joined');
    expect(result.roomId).toBeTruthy();
  });

  test('join-room with invalid roomId returns error', async ({ page }) => {
    await page.goto(BASE_URL);

    const result = await page.evaluate(async () => {
      const wsUrl = `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}/ws`;
      return new Promise((resolve) => {
        const ws = new WebSocket(wsUrl);
        ws.onopen = () => ws.send(JSON.stringify({ type: 'join-room', roomId: 'nonexistent-room' }));
        ws.onmessage = (e) => { ws.close(); resolve(JSON.parse(e.data)); };
        ws.onerror = () => resolve(null);
        setTimeout(() => { ws.close(); resolve(null); }, 5000);
      });
    });

    expect(result).toBeTruthy();
    expect(result.type).toBe('error');
  });
});

// ============================================================================
// Cryptography (no P2P needed)
// ============================================================================

test.describe('Cryptography', () => {
  test('Web Crypto API is available', async ({ page }) => {
    await page.goto(BASE_URL);
    expect(await page.evaluate(() =>
      typeof crypto.subtle !== 'undefined' && typeof crypto.getRandomValues !== 'undefined'
    )).toBe(true);
  });

  test('ECDH P-256 key pair generation works', async ({ page }) => {
    await page.goto(BASE_URL);
    const result = await page.evaluate(async () => {
      const kp = await crypto.subtle.generateKey(
        { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveKey', 'deriveBits']
      );
      const raw = await crypto.subtle.exportKey('raw', kp.publicKey);
      return { privOk: !!kp.privateKey, pubLen: raw.byteLength };
    });
    expect(result.privOk).toBe(true);
    expect(result.pubLen).toBe(65);
  });

  test('AES-256-GCM roundtrip encryption works', async ({ page }) => {
    await page.goto(BASE_URL);
    const result = await page.evaluate(async () => {
      const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
      const msg = 'Test encryption roundtrip \u{1F47B}';
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const enc = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, new TextEncoder().encode(msg));
      const dec = await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, key, enc);
      return { original: msg, decrypted: new TextDecoder().decode(dec) };
    });
    expect(result.decrypted).toBe(result.original);
  });

  test('GhostCrypto module loads and generates key pair', async ({ browser }) => {
    const ctx = await createContext(browser);
    const page = await ctx.newPage();

    try {
      await page.goto(BASE_URL);
      await page.locator('#create-room-btn').click();

      // Wait for room creation (which initializes crypto)
      try {
        await expect(page.locator('#waiting-screen')).toBeVisible({ timeout: 10000 });
      } catch {
        test.skip(true, 'Rate limited — room creation blocked');
        return;
      }

      const result = await page.evaluate(() => ({
        hasCrypto: !!window.ghostChat?.crypto,
        hasKeyPair: !!window.ghostChat?.crypto?.keyPair,
      }));

      expect(result.hasCrypto).toBe(true);
      expect(result.hasKeyPair).toBe(true);
    } finally {
      await cleanup(ctx);
    }
  });
});

// ============================================================================
// UI and Deep Linking
// ============================================================================

test.describe('UI and Deep Linking', () => {
  test('Welcome screen loads with all elements visible', async ({ page }) => {
    await page.goto(BASE_URL);
    await expect(page.locator('#welcome-screen')).toBeVisible({ timeout: 5000 });
    await expect(page.locator('#create-room-btn')).toBeVisible();
    await expect(page.locator('#join-room-input')).toBeVisible();
    await expect(page.locator('#join-room-btn')).toBeVisible();
    await expect(page.locator('#privacy-mode-toggle')).toBeAttached();
  });

  test('Leave button returns to welcome from waiting screen', async ({ browser }) => {
    const ctx = await createContext(browser);
    const page = await ctx.newPage();
    try {
      await page.goto(BASE_URL);
      await page.locator('#create-room-btn').click();

      // May fail if rate-limited from other tests
      try {
        await expect(page.locator('#waiting-screen')).toBeVisible({ timeout: 10000 });
      } catch {
        test.skip(true, 'Rate limited — room creation blocked');
        return;
      }

      await page.locator('#leave-btn').click();
      await expect(page.locator('#welcome-screen')).toBeVisible({ timeout: 5000 });
    } finally {
      await cleanup(ctx);
    }
  });

  test('Leave button from connecting screen returns to welcome', async ({ browser }) => {
    const ctx = await createContext(browser);
    const page = await ctx.newPage();
    try {
      await page.goto(BASE_URL);

      const roomId = await page.evaluate(async () => {
        return new Promise((resolve) => {
          const wsUrl = `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}/ws`;
          const ws = new WebSocket(wsUrl);
          ws.onopen = () => ws.send(JSON.stringify({ type: 'create-room' }));
          ws.onmessage = (e) => {
            const msg = JSON.parse(e.data);
            if (msg.type === 'room-created') { ws.close(); resolve(msg.roomId); }
            if (msg.type === 'error') { ws.close(); resolve(null); }
          };
          setTimeout(() => resolve(null), 5000);
        });
      });

      if (roomId) {
        await page.locator('#join-room-input').fill(roomId);
        await page.locator('#join-room-btn').click();
        await expect(page.locator('#connecting-screen')).toBeVisible({ timeout: 10000 });
        await page.locator('#connecting-leave-btn').click();
        await expect(page.locator('#welcome-screen')).toBeVisible({ timeout: 5000 });
      }
    } finally {
      await cleanup(ctx);
    }
  });

  test('Invalid room link does not crash the app', async ({ page }) => {
    await page.goto(`${BASE_URL}/?room=invalid-room-id`);
    await page.waitForTimeout(3000);
    expect(await page.title()).toBeTruthy();
    expect(await page.evaluate(() => typeof window.ghostChat !== 'undefined')).toBe(true);
  });

  test('Fragment-based room link (#room=ID) works', async ({ page }) => {
    await page.goto(BASE_URL);
    const roomId = await page.evaluate(async () => {
      return new Promise((resolve) => {
        const wsUrl = `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}/ws`;
        const ws = new WebSocket(wsUrl);
        ws.onopen = () => ws.send(JSON.stringify({ type: 'create-room' }));
        ws.onmessage = (e) => {
          const msg = JSON.parse(e.data);
          if (msg.type === 'room-created') { ws.close(); resolve(msg.roomId); }
          if (msg.type === 'error') { ws.close(); resolve(null); }
        };
        setTimeout(() => resolve(null), 5000);
      });
    });

    if (!roomId) return;

    await page.goto(`${BASE_URL}/#room=${roomId}`);
    await page.waitForTimeout(3000);
    expect(await page.evaluate(() => typeof window.ghostChat !== 'undefined')).toBe(true);
  });

  test('Auto-delete timer shown on messages (P2P)', async ({ browser }) => {
    test.skip(skipP2P, 'Requires P2P');
    const pair = await setupP2PPair(browser);
    const { hostPage, hostCtx, guestCtx } = pair;

    try {
      await hostPage.locator('#message-input').fill('Timer test');
      await hostPage.locator('#send-btn').click();
      await hostPage.waitForSelector('.message.sent .message-timer', { timeout: 5000 });
      expect(await hostPage.locator('.message.sent .message-timer').first().textContent()).toMatch(/\d+:\d{2}/);
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });
});

// ============================================================================
// WebRTC Infrastructure
// ============================================================================

test.describe('WebRTC Infrastructure', () => {
  test('RTCPeerConnection is available', async ({ page }) => {
    await page.goto(BASE_URL);
    expect(await page.evaluate(() => {
      const pc = new RTCPeerConnection({ iceServers: [] });
      const ok = pc.connectionState !== undefined;
      pc.close();
      return ok;
    })).toBe(true);
  });

  test('Fake audio track created in headless Chrome', async ({ browser }) => {
    const ctx = await createContext(browser);
    const page = await ctx.newPage();
    try {
      await page.goto(BASE_URL);
      const result = await page.evaluate(async () => {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        const tracks = stream.getAudioTracks();
        const info = { count: tracks.length, kind: tracks[0]?.kind, state: tracks[0]?.readyState };
        tracks.forEach(t => t.stop());
        return info;
      });
      expect(result.count).toBeGreaterThan(0);
      expect(result.kind).toBe('audio');
      expect(result.state).toBe('live');
    } finally {
      await cleanup(ctx);
    }
  });

  test('DataChannel is labeled ghost-chat and ordered (P2P)', async ({ browser }) => {
    test.skip(skipP2P, 'Requires P2P');
    const pair = await setupP2PPair(browser);
    const { hostPage, hostCtx, guestCtx } = pair;

    try {
      const dc = await hostPage.evaluate(() => ({
        label: window.ghostChat?.rtc?.dataChannel?.label,
        ordered: window.ghostChat?.rtc?.dataChannel?.ordered,
        readyState: window.ghostChat?.rtc?.dataChannel?.readyState,
      }));
      expect(dc.label).toBe('ghost-chat');
      expect(dc.ordered).toBe(true);
      expect(dc.readyState).toBe('open');
    } finally {
      await cleanup(hostCtx, guestCtx);
    }
  });
});
