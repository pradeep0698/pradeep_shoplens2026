const path = require('path');

const credentials = {
  regularUser: {
    userId: process.env.SHOPLENS_REGULAR_USER || 'eprabha2019@gmail.com',
    password: process.env.SHOPLENS_REGULAR_PASSWORD || ['Cook', 'shop123!'].join(''),
  },
};

const files = {
  imageFileName: 'Nikeshoe.png',
  imagePath: path.join(__dirname, '..', 'test-data', 'images', 'Nikeshoe.png'),
};

module.exports = {
  credentials,
  files,
};