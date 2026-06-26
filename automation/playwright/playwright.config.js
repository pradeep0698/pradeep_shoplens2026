const { defineConfig, devices } = require('@playwright/test');

const defaultBaseURL = ['https://', 'cook', 'shop-dev-prj-bd7e2.web.app/'].join('');

module.exports = defineConfig({
  testDir: './tests',
  timeout: 180 * 1000,
  expect: {
    timeout: 10 * 1000,
  },
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  reporter: [['html'], ['list']],
  use: {
    baseURL: process.env.SHOPLENS_BASE_URL || defaultBaseURL,
    headless: true,
    screenshot: 'only-on-failure',
    actionTimeout: 15 * 1000,
    navigationTimeout: 30 * 1000,
  },
  projects: [
    {
      name: 'chromium',
      use: {
        browserName: 'chromium',
        ...devices['Desktop Chrome'],
      },
    },
  ],
});