FROM ruby:2.4

RUN mkdir -p /srv/example && apt-get update && apt-get install -y supervisor && apt-get clean

COPY example/ /srv/example

COPY xenapi.rb /srv

COPY Gemfile /srv

COPY messages.rb /srv

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

ENV AMQP_URI=amqp://nowhere-rabbitmq \
    XAPI_PATH=192.168.255.254 \
    XAPI_PORT=443 \
    XAPI_SSL=true \
    XAPI_USER=root \
    XAPI_PASS=change-me \

ENTRYPOINT ["/usr/bin/supervisord"]
