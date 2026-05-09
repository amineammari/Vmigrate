# syntax=docker/dockerfile:1.7

ARG NODE_VERSION=20.18.1
FROM node:${NODE_VERSION}-bookworm-slim AS build

WORKDIR /app
COPY frontend/package.json frontend/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci

COPY frontend /app
RUN npm run build

FROM nginx:1.27.3-alpine AS runtime

COPY frontend/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
