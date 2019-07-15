FROM scratch

COPY build.rmk /test/build.rmk
COPY main/.rmk/i486-linux/hello /app/

ENTRYPOINT [ "/app/hello" ]