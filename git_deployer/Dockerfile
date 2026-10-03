FROM alpine:3.20
RUN apk add --no-cache bash git rsync curl jq ca-certificates tzdata
ENV TZ=Europe/Berlin
COPY run.sh deploy.sh /
RUN chmod a+x /run.sh /deploy.sh
CMD ["/run.sh"]
