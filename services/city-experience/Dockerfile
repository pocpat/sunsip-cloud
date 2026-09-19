# city-experience — Microservice 1 (weather, cocktail match, AI image).
# Same image shape is pushed to ECR by CodeBuild in Phase 3.
FROM node:22-alpine
WORKDIR /app

COPY package.json tsconfig.json ./
RUN npm install

COPY src ./src
RUN npm run build

ENV PORT=4001
EXPOSE 4001
CMD ["node", "dist/server.js"]