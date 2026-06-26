const { expect } = require('@playwright/test');

class LoginPage {
  constructor(page) {
    this.page = page;
    this.userIdInput = page.getByRole('textbox', { name: /user@shoplens\.com/i }).first();
    this.passwordInput = page.locator('input[type="password"]').first();
    this.signInButton = page.getByRole('button', { name: /sign in|login/i }).first();
  }

  async open() {
    await this.page.goto('/');
    await this.page.waitForLoadState('domcontentloaded');
    await this.enableFlutterAccessibility();
    await expect(this.passwordInput, 'Login page should be visible').toBeVisible({ timeout: 120000 });
  }

  async login(userId, password) {
    await this.passwordInput.click({ force: true });
    await this.passwordInput.fill(password, { force: true });

    await this.userIdInput.click({ force: true });
    await this.userIdInput.fill(userId, { force: true });

    await this.signInButton.click({ force: true });
    await this.page.waitForURL(/#\/main/, { timeout: 120000 });
  }

  async enableFlutterAccessibility() {
    await this.page.waitForTimeout(5000);

    const accessibilityButton = this.page.locator('flt-semantics-placeholder[aria-label*="accessibility" i]').first();
    if (await accessibilityButton.count()) {
      await accessibilityButton.evaluate((button) => button.click());
      await this.page.waitForTimeout(5000);
    }
  }
}

module.exports = { LoginPage };
