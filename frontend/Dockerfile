FROM node:lts-alpine AS build

WORKDIR /app

# Enable pnpm natively via corepack
RUN corepack enable && corepack prepare pnpm@10 --activate

# Copy dependency specifications first to leverage caching
COPY package.json pnpm-lock.yaml .npmrc ./
RUN pnpm install --frozen-lockfile

# Copy application layers
COPY . .

# Declare build-time arguments. Vite injects VITE_* environment variables during compile time.
ARG VITE_API_BASE_URL
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_ANON_KEY

ENV VITE_API_BASE_URL=$VITE_API_BASE_URL \
    VITE_SUPABASE_URL=$VITE_SUPABASE_URL \
    VITE_SUPABASE_ANON_KEY=$VITE_SUPABASE_ANON_KEY

# Compile the highly compressed static production bundle
RUN pnpm build

# Serve stage using high-performance Caddy web server
FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=build /app/dist /srv

EXPOSE 3000