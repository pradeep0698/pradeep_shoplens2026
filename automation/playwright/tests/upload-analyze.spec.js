const { test } = require('@playwright/test');
const { LoginPage } = require('../pages/LoginPage');
const { ShopLensPage } = require('../pages/ShopLensPage');
const { credentials, files } = require('../testData/testData');

test('ShopLens image scan flow', async ({ page }, testInfo) => {
  const loginPage = new LoginPage(page);
  const shopLensPage = new ShopLensPage(page);

  await loginPage.open();
  await loginPage.login(credentials.regularUser.userId, credentials.regularUser.password);

  // Attach input image to Playwright report so it shows correctly in GitHub Actions report
  await testInfo.attach('uploaded-test-image', {
    path: files.imagePath,
    contentType: 'image/png',
  });

  await shopLensPage.uploadImageFromGallery(files.imagePath);
  await shopLensPage.scanImage();
  await shopLensPage.checkMatchedProducts();
  await shopLensPage.saveScreenshot(testInfo, 'image-scan-matched-products');
});
