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

# Compile static bundle
RUN pnpm build

# Serve stage using unprivileged Nginx (works on all cloud platforms)
FROM nginxinc/nginx-unprivileged:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 3000

CMD ["nginx", "-g", "daemon off;"]