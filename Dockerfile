#
# Dockerfiles for build haproxy
#

FROM fanli:centos7-base
MAINTAINER it@fanli.com

ADD binary /tmp/

RUN rpm -ivh /tmp/haproxy*

ADD cfg/haproxy.cfg /etc/haproxy/haproxy.cfg
ADD cfg/supervisord.haproxy.conf /etc/supervisord.d/haproxy.conf

WORKDIR /usr/local/src

# start services:
