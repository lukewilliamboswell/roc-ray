FROM asciidoctor/docker-asciidoctor:1.100.0

RUN apk add --no-cache chromium nodejs npm python3 \
    && npm install --global @mermaid-js/mermaid-cli@11.16.0 \
    && npm cache clean --force

ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
