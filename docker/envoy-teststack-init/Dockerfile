FROM alpine:latest

RUN apk add --no-cache inotify-tools bash

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
