# syntax=docker/dockerfile:1

# 1) Web (React + Vite)
FROM node:22-alpine AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
RUN npm run build

# 2) Backend (Go, binario estático)
FROM golang:1.24-alpine AS api
WORKDIR /src
COPY backend/go.mod ./
COPY backend/*.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/transcriptor .

# 3) Imagen final: solo el binario, la web compilada y ffmpeg
FROM alpine:3.21
RUN apk add --no-cache ffmpeg tzdata ca-certificates
WORKDIR /app
COPY --from=api /out/transcriptor /app/transcriptor
COPY --from=web /web/dist /app/web
ENV ADDR=:8080 DATA_DIR=/data WEB_DIR=/app/web TMP_DIR=/tmp/transcriptor
USER 1000:1000
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/api/sessions || exit 1
ENTRYPOINT ["/app/transcriptor"]
