FROM node:14-alpine
LABEL maintaner="Carlos Nunez <dev@carlosnunez.me>"
ARG VERSION 

RUN npm -g install "serverless@$VERSION"
