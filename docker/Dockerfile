FROM ubuntu:xenial

RUN apt-get update && \
    apt-get install -y \
      ruby \
      ruby-dev \
      git \
      build-essential \
      curl

WORKDIR /app
COPY .rmk/rmk-0.1.0.gem /app/
RUN gem install rmk-0.1.0.gem