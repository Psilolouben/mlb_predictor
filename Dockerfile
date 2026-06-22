FROM ruby:3.2-slim

RUN apt-get update && apt-get install -y \
    build-essential \
    chromium \
    chromium-driver \
    && rm -rf /var/lib/apt/lists/*

ENV CHROME_BIN=/usr/bin/chromium
ENV CHROMEDRIVER_PATH=/usr/bin/chromedriver

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

RUN mkdir -p proposals

EXPOSE 10000

CMD bundle exec functions-framework-ruby --target main --port ${PORT:-10000}
