FROM alpine:3.20
RUN apk add --no-cache bash curl jq
COPY keeper.sh /keeper.sh
RUN chmod +x /keeper.sh
ENTRYPOINT ["/keeper.sh"]
