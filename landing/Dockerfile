# Static landing for system-load.moone.dev — served by nginx.
# Dokploy: build type = Dockerfile · build path = /landing · port = 80
FROM nginx:1.27-alpine

# Copy the static site (build context is this folder; Dockerfile/.dockerignore excluded)
COPY . /usr/share/nginx/html

# Long cache for immutable assets, short for HTML.
RUN printf '%s\n' \
  'server {' \
  '  listen 80;' \
  '  root /usr/share/nginx/html;' \
  '  index index.html;' \
  '  location / { try_files $uri $uri/ =404; }' \
  '  location ~* \.(png|jpg|jpeg|webp|avif|svg|css|js|woff2?)$ { expires 7d; add_header Cache-Control "public"; }' \
  '  location ~* \.html$ { add_header Cache-Control "no-cache"; }' \
  '}' > /etc/nginx/conf.d/default.conf

EXPOSE 80
