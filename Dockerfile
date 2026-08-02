FROM node:20-bullseye
WORKDIR /app
COPY . .
RUN npm install -g pm2 typescript ts-node
RUN npm install
RUN apt-get update && apt-get install -y python3 build-essential -y
RUN echo 'DOMAIN=0.0.0.0' > .env && echo 'PORT=8000' >> .env && echo 'NODE_ENV="production"' >> .env && echo 'DATABASE_URL="file:./database.db"' >> .env
RUN node -e "c=require('crypto');console.log('CSRF_SECRET=\"'+c.randomBytes(64).toString('hex')+'\"\nJWT_SECRET_KEY=\"'+c.randomBytes(64).toString('hex')+'\"\nJWT_SECRET_REFRESH=\"'+c.randomBytes(64).toString('hex')+'\"')" >> .env
RUN npx prisma generate && npx prisma db push
RUN npx tsc || true
EXPOSE 8000
CMD ["sh", "-c", "node create_admin.js; npm start"]
