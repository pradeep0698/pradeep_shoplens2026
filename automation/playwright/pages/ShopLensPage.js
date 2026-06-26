const { expect } = require('@playwright/test');

class ShopLensPage {
  constructor(page) {
    this.page = page;
    this.galleryButton = page.locator('[aria-label="Gallery"], [aria-label*="gallery" i], [role="button"][aria-label*="gallery" i]').first();
    this.scanImageButton = page.getByRole('button', { name: /scan image/i }).first();
    this.buyButtons = page.getByRole('button', { name: /buy/i });
    this.emptyProductsMessage = page.getByText(/Matched products will appear here/i);
  }

  async uploadImageFromGallery(imagePath) {
    const fileChooserPromise = this.page.waitForEvent('filechooser');
    await this.galleryButton.click({ force: true });

    const fileChooser = await fileChooserPromise;
    await fileChooser.setFiles(imagePath);

    await expect(this.scanImageButton, 'Scan Image button should appear after image upload').toBeVisible({ timeout: 30000 });
    await expect(this.scanImageButton, 'Scan Image button should be enabled').toBeEnabled({ timeout: 30000 });
  }

  async scanImage() {
    await this.scanImageButton.click({ force: true });

    await expect
      .poll(
        async () => this.page.locator('body').innerText(),
        { message: 'Image scan should finish and show matched products', timeout: 120000 }
      )
      .toMatch(/Done![\s\S]*Matched[\s\S]*Buy/i);
  }

  async checkMatchedProducts() {
    await expect(this.buyButtons.first(), 'At least one matched product should be visible').toBeVisible({ timeout: 30000 });
    await expect(this.emptyProductsMessage, 'Empty matched-products message should disappear').toBeHidden({ timeout: 30000 });
  }

  async saveScreenshot(testInfo, name) {
    await testInfo.attach(name, {
      body: await this.page.screenshot({ fullPage: true }),
      contentType: 'image/png',
    });
  }
}

module.exports = { ShopLensPage };