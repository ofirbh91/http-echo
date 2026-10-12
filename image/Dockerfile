# Same upstream application, pinned source and supported runtime.
FROM node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS source
ADD --checksum=sha256:99a9c2e38b1f45d1ec44f5543d0508bc1f34dc0911a12ffa3ac213f728cb5fd4 https://codeload.github.com/Ealenn/Echo-Server/tar.gz/2b735482f942cbd889f1d49f3ff892364d0519ac /tmp/source.tar.gz
RUN mkdir /source && tar -xzf /tmp/source.tar.gz -C /source --strip-components=1

FROM node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS dependencies
WORKDIR /app
COPY image/package.json image/package-lock.json ./
RUN npm ci --omit=dev --omit=optional --ignore-scripts --no-audit --no-fund

FROM node:24-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1
LABEL org.opencontainers.image.source="https://github.com/Ealenn/Echo-Server" \
      org.opencontainers.image.revision="2b735482f942cbd889f1d49f3ff892364d0519ac" \
      org.opencontainers.image.licenses="GPL-3.0"
WORKDIR /app
COPY --from=dependencies /app/ ./
COPY --from=source /source/src/ ./src/
COPY image/request.js ./src/response/request.js
COPY --from=source /source/LICENSE.txt /usr/share/licenses/http-echo/LICENSE
RUN rm -rf /usr/local/lib/node_modules/npm /opt/yarn-* \
    /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/yarn /usr/local/bin/yarnpkg
ENV PORT=8080 ENABLE__ENVIRONMENT=false ENABLE__FILE=false ENABLE__HEADER=false ENABLE__COOKIES=false LOGS__IGNORE__PING=true LOGS__LEVEL=warn
USER 1000:1000
EXPOSE 8080
CMD ["node", "src/webserver.js"]
