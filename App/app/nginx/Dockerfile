FROM nginx:1.27-alpine

COPY app/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY app/php-fpm/index.php /var/www/html/index.php

EXPOSE 80
