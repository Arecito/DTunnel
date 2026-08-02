const { PrismaClient } = require('@prisma/client');
const bcrypt = require('bcrypt');
const prisma = new PrismaClient();
async function createAdmin() {
  try {
    const hashedPassword = await bcrypt.hash('123456', 10);
    const user = await prisma.user.create({
      data: {
        username: 'admin',
        email: 'admin@admin.com',
        password: hashedPassword
      }
    });
    console.log('✅ Admin creado:', user.username);
  } catch (err) {
    console.log('Admin ya existe o error:', err.message);
  } finally {
    await prisma.$disconnect();
  }
}
createAdmin();
