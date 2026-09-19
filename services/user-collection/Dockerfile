# user-collection — Microservice 2 (auth, favourites, reviews on DynamoDB).
# Same image shape is pushed to ECR by CodeBuild in Phase 3.
FROM node:22-alpine
WORKDIR /app

COPY package.json tsconfig.json ./
RUN npm install

COPY src ./src
COPY scripts ./scripts
RUN npm run build

ENV PORT=4002
EXPOSE 4002
CMD ["node", "dist/server.js"]