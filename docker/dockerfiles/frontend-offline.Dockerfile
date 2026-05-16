# Air-gapped frontend Dockerfile - builds with offline npm cache
FROM node:20-alpine AS builder

WORKDIR /app
COPY frontend/package*.json ./

# Use offline npm cache (npm ci is more reliable than npm install for offline)
RUN --mount=type=bind,source=./offline/npm-cache,target=/home/node/.npm,ro \
    npm ci --prefer-offline --no-audit

COPY frontend ./
RUN npm run build

# Production server stage (nginx for proper API proxying)
FROM nginx:1.27.3-alpine AS runtime

COPY frontend/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/dist /usr/share/nginx/html

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
