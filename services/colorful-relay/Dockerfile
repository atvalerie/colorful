FROM oven/bun:1.3.14-alpine

WORKDIR /app
COPY package.json tsconfig.json ./
COPY src ./src

ENV COLORFUL_RELAY_HOST=0.0.0.0
EXPOSE 8787

USER bun
CMD ["bun", "src/main.ts"]
