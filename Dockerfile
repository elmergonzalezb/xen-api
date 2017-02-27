FROM ruby:2.4

RUN mkdir -p /srv/example && apt-get update && apt-get install -y supervisor

COPY example/ /srv/example

COPY xenapi.rb /srv

COPY Gemfile /srv

COPY messages.rb /srv

ENV AMQP_URI amqp://nowhere-rabbitmq
ENV XAPI_PATH 192.168.255.254
ENV XAPI_PORT 443
ENV XAPI_SSL true
ENV XAPI_USER root
ENV XAPI_PASS change-me

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

CMD ["/usr/bin/supervisord"]
