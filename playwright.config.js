import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 60000,
  retries: 0,
  use: {
    headless: true,
    // Разрешаем микрофон (fake audio для WebRTC)
    launchOptions: {
      args: [
        '--use-fake-ui-for-media-stream',
        '--use-fake-device-for-media-stream',
        '--allow-file-access-from-files',
      ],
    },
    permissions: ['microphone'],
  },
  projects: [
    {
      name: 'chromium',
      use: { browserName: 'chromium' },
    },
  ],
  webServer: {
    command: 'node server/index.js',
    port: 3000,
    env: {
      PORT: '3000',
      NODE_ENV: 'development',
      TURN_SECRET: 'test-turn-secret',
      TURN_DOMAIN: 'localhost',
    },
    reuseExistingServer: true,
  },
});
