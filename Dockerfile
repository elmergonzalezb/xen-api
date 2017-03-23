FROM ruby:alpine

COPY ./ /srv

RUN apk --no-cache add supervisor \
 && BUNDLE_GEMFILE=/srv/Gemfile bundler install

COPY docker/blk/amqpd-blk.rb /srv

COPY docker/net/amqpd-net.rb /srv

COPY docker/vm/amqpd-vm.rb /srv

COPY docker/rest/rest.rb /srv

ENV AMQP_URI=amqp://nowhere-rabbitmq \
    XAPI_PATH=192.168.255.254 \
    XAPI_PORT=443 \
    XAPI_SSL=true \
    XAPI_USER=root \
    XAPI_PASS=change-me

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/srv/supervisord.conf"]
