FROM ruby:3.2-slim

RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

RUN mkdir -p proposals

EXPOSE 10000

CMD bundle exec functions-framework-ruby --target main --port ${PORT:-10000} --bind 0.0.0.0
