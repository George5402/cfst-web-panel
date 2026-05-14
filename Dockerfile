FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm install --no-audit --no-fund
COPY . .
RUN npm run build:min

FROM node:18-alpine
WORKDIR /app

RUN apk add --no-cache wget tar

COPY package*.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY --from=builder /app/public ./public
COPY server.js .

# Download cfst engine; override with --build-arg CFST_ARCH=arm64 for ARM hosts
ARG CFST_ARCH=amd64
RUN wget -q -O /tmp/cfst.tar.gz \
      "https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/cfst_linux_${CFST_ARCH}.tar.gz" \
    && tar -xzf /tmp/cfst.tar.gz -C /app cfst ip.txt ipv6.txt \
    && chmod +x /app/cfst \
    && rm /tmp/cfst.tar.gz

EXPOSE 3088
CMD ["node", "server.js"]
