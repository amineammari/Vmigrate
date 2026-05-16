# syntax=docker/dockerfile:1.7
# Air-gapped Frontend - Enhanced Version
# Optimized multi-stage build with offline npm cache
# Final image includes only production artifacts (no node_modules)

ARG NODE_VERSION=20
ARG NODE_BASE=node:${NODE_VERSION}-alpine

# ============================================================================
# BUILD STAGE: Compile React SPA with offline npm
# ============================================================================
FROM ${NODE_BASE} as builder

WORKDIR /build

# Copy package manifests
COPY frontend/package.json frontend/package-lock.json ./

# Install dependencies from offline npm cache
# npm ci (clean install) is preferred over npm install for reproducibility
# --prefer-offline forces use of cache over online registry
RUN --mount=type=bind,source=./offline/npm-cache,target=/root/.npm,ro \
    npm ci --prefer-offline --no-audit --cache=/root/.npm

# Copy all frontend source code
COPY frontend ./

# Build React app with Vite
# This produces optimized bundle in dist/
RUN npm run build

# Verify build artifact exists
RUN test -d dist && test "$(find dist -type f | wc -l)" -gt 0 || \
    (echo "ERROR: dist/ directory empty after build" && exit 1)

# ============================================================================
# RUNTIME STAGE: Production server with nginx for API proxying
# ============================================================================
FROM nginx:1.27.3-alpine as runtime

# Copy nginx configuration for all API routes to backend
COPY frontend/nginx.conf /etc/nginx/conf.d/default.conf

# Copy only built artifacts from build stage
COPY --from=builder /build/dist /usr/share/nginx/html

EXPOSE 80

# Health check: verify nginx responds
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
    CMD wget -q -O- http://127.0.0.1/ >/dev/null || exit 1

# Start nginx
CMD ["nginx", "-g", "daemon off;"]
