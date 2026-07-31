FROM nginx:stable-alpine

COPY app/index.html /usr/share/nginx/html/index.html

EXPOSE 80