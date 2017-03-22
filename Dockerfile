FROM ruby:2.4

COPY Gemfile /srv

COPY messages.rb /srv

COPY xenapi.rb /srv

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

RUN apt-get update \
 && apt-get install -y supervisor \
 && apt-get clean \
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

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
