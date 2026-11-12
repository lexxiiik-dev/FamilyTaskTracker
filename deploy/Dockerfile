# Образ с готовым бинарником (веб-клиент встроен):
#   docker compose up -d      (в папке с собранным сервером, где лежит todod-linux-amd64)
FROM alpine:3.20
RUN adduser -D -H -u 10001 todod && mkdir -p /data && chown todod /data
COPY todod-linux-amd64 /usr/local/bin/todod
USER todod
VOLUME /data
EXPOSE 8443
# первый запуск создаёт /data/config.json, ключ доступа и сертификат; данные для подключения — в журнале
CMD ["sh", "-c", "[ -f /data/config.json ] || todod init -dir /data -data /data -port 8443 ${PUBLIC_URL:+-public-url $PUBLIC_URL}; todod info -config /data/config.json; exec todod -config /data/config.json"]