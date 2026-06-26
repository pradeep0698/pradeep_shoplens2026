const path = require('path');

const credentials = {
  regularUser: {
    userId: 'your-email',
    password: 'your-password',
  },
};

const files = {
  imagePath: path.join(process.cwd(), 'test-data', 'images', 'Nikeshoe.png'),
};

module.exports = { credentials, files };
