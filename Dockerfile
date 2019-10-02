FROM efrecon/mini-tcl:3.7
LABEL maintainer="Emmanuel Frecon <efrecon@gmail.com>"

ARG BUILD_DATE
LABEL org.label-schema.build-date=${BUILD_DATE}
LABEL org.label-schema.schema-version="1.0"
LABEL org.label-schema.name="efrecon/dockron"
LABEL org.label-schema.description="Docker-aware cron look-a-like"
LABEL org.label-schema.url="https://github.com/efrecon/dockron"
LABEL org.label-schema.docker.cmd="docker run --rm -it -v /var/run/docker.sock:/tmp/docker.sock:ro efrecon/dockron"

# Add glibc so we can mount docker binary from the host into the container. This
# is to ease talking to the daemon using the regular command-line interface (as
# opposed to the API))
ARG GLIBC_VER="2.30-r0"
RUN apk add --update --no-cache ca-certificates curl && \
  ALPINE_GLIBC_REPO="https://github.com/sgerrand/alpine-pkg-glibc/releases/download" && \
  curl -Ls https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub -o /etc/apk/keys/sgerrand.rsa.pub && \
  curl -Ls ${ALPINE_GLIBC_REPO}/${GLIBC_VER}/glibc-${GLIBC_VER}.apk > /tmp/${GLIBC_VER}.apk && \
  apk add /tmp/${GLIBC_VER}.apk && \
  curl -Ls ${ALPINE_GLIBC_REPO}/${GLIBC_VER}/glibc-bin-${GLIBC_VER}.apk > /tmp/${GLIBC_VER}-bin.apk && \
  apk add /tmp/${GLIBC_VER}-bin.apk && \
  apk del curl  && \
  rm -rf /tmp/*.apk /var/cache/apk/*

# Fix glibc ldd command - see https://github.com/sgerrand/alpine-pkg-glibc/issues/103.
RUN sed -i s/lib64/lib/ /usr/glibc-compat/bin/ldd

# Ensure we have socat since nc on busybox does not support UNIX
# domain sockets.
RUN apk add --no-cache socat

# COPY code
COPY *.md /opt/dockron/
COPY dockron.tcl /opt/dockron/
COPY tockler/*.tcl /opt/dockron/tockler/

# Export where we will look for the Docker UNIX socket.
VOLUME ["/tmp/docker.sock"]

ENTRYPOINT ["tclsh8.6", "/opt/dockron/dockron.tcl", "-docker", "unix:///tmp/docker.sock"]
CMD ["-verbose", "4"]
