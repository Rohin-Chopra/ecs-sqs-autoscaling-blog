FROM node:21 as base

COPY . .

RUN npm install

RUN npm run build

FROM node:21-alpine

COPY package*.json .

RUN npm ci --omit=dev

COPY --from=base dist .

ENTRYPOINT [ "node", "consumer" ]