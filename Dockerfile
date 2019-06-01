FROM alpine:3.9

LABEL maintainer="Ruud van Engelenhoven <ruud.vanengelenhoven@gmail.com"

ENV PHPIZE_DEPS \
  autoconf \
  dpkg-dev dpkg \
  file \
  g++ \
  gcc \
  libc-dev \
  make \
  pcre-dev \
  pkgconf \
  re2c

RUN apk --update add --no-cache --virtual .persistent-deps \
  ca-certificates \
  curl \
  git \
  tar \
  wget \
  xz

# Make sure that the user www-data exist
RUN set -x \
  && addgroup -g 82 -S www-data \
  && adduser -u 82 -D -S -G www-data www-data

# Create the directory for PHP INI
ENV PHP_INI_DIR="/usr/local/etc/php"
RUN mkdir -p $PHP_INI_DIR/conf.d

ENV PHP_EXTRA_CONFIGURE_ARGS="--enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data"

# Apply Stack Smash protection
ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -Wl,--hash-style=both -pie"

ENV GPG_KEYS CBAF69F173A0FEA4B537F470D66C9593118BCCB6 F38252826ACD957EF380D39F2F7956BC5DA04B5D

ENV PHP_VERSION 7.3.6
ENV PHP_URL="https://secure.php.net/get/php-7.3.6.tar.xz/from/this/mirror"
ENV PHP_ASC_URL="https://secure.php.net/get/php-7.3.6.tar.xz.asc/from/this/mirror"
ENV PHP_SHA256="fefc8967daa30ebc375b2ab2857f97da94ca81921b722ddac86b29e15c54a164"
ENV PHP_MD5=""

RUN set -xe; \
  \
  apk add --no-cache --virtual .fetch-deps \
  gnupg \
  openssl \
  ; \
  \
  mkdir -p /usr/src; \
  cd /usr/src; \
  \
  wget -O php.tar.xz "$PHP_URL"; \
  \
  if [ -n "$PHP_SHA256" ]; then \
  echo "$PHP_SHA256 *php.tar.xz" | sha256sum -c -; \
  fi; \
  \
  if [ -n "$PHP_MD5" ]; then \
  echo "$PHP_MD5 *php.tar.xz" | sha256sum -c -; \
  fi; \
  \
  if [ -n "$PHP_ASC_URL" ]; then \
  wget -O php.tar.xz.asc "$PHP_ASC_URL"; \
  export GNUPGHOME="$(mktemp -d)"; \
  for key in $GPG_KEYS; do \
  gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
  done; \
  gpg --batch --verify php.tar.xz.asc php.tar.xz; \
  rm -rf "$GNUPGHOME"; \
  fi; \
  apk del .fetch-deps

COPY docker-php-source /usr/local/bin/

RUN chmod +x /usr/local/bin/docker-php-source

RUN set -xe \
  && apk add --no-cache --virtual .build-deps \
  $PHPIZE_DEPS \
  argon2-dev \
  coreutils \
  curl-dev \
  libedit-dev \
  libsodium-dev \
  libxml2-dev \
  openssl-dev \
  sqlite-dev \
  \
  && export CFLAGS="$PHP_CFLAGS" \
  CPPFLAGS="$PHP_CPPFLAGS" \
  LDFLAGS="$PHP_LDFLAGS" \
  && docker-php-source extract \
  && cd /usr/src/php \
  && gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
  && ./configure \
  --build="$gnuArch" \
  --with-config-file-path="$PHP_INI_DIR" \
  --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
  \
  # make sure invalid --configure-flags are fatal errors intead of just warnings
  --enable-option-checking=fatal \
  \
  # https://github.com/docker-library/php/issues/439
  --with-mhash \
  \
  # --enable-ftp is included here because ftp_ssl_connect() needs ftp to be compiled statically (see https://github.com/docker-library/php/issues/236)
  --enable-ftp \
  # --enable-mbstring is included here because otherwise there's no way to get pecl to use it properly (see https://github.com/docker-library/php/issues/195)
  --enable-mbstring \
  # --enable-mysqlnd is included here because it's harder to compile after the fact than extensions are (since it's a plugin for several extensions, not an extension in itself)
  --enable-mysqlnd \
  # https://wiki.php.net/rfc/argon2_password_hash (7.2+)
  --with-password-argon2 \
  # https://wiki.php.net/rfc/libsodium
  --with-sodium=shared \
  \
  --with-curl \
  --with-libedit \
  --with-openssl \
  --with-zlib \
  \
  # bundled pcre does not support JIT on s390x
  # https://manpages.debian.org/stretch/libpcre3-dev/pcrejit.3.en.html#AVAILABILITY_OF_JIT_SUPPORT
  $(test "$gnuArch" = 's390x-linux-gnu' && echo '--without-pcre-jit') \
  \
  $PHP_EXTRA_CONFIGURE_ARGS \
  && make -j "$(nproc)" \
  && find -type f -name '*.a' -delete \
  && make install \
  && { find /usr/local/bin /usr/local/sbin -type f -perm +0111 -exec strip --strip-all '{}' + || true; } \
  && make clean \
  \
  # https://github.com/docker-library/php/issues/692 (copy default example "php.ini" files somewhere easily discoverable)
  && cp -v php.ini-* "$PHP_INI_DIR/" \
  \
  && cd / \
  && docker-php-source delete \
  \
  && runDeps="$( \
  scanelf --needed --nobanner --format '%n#p' --recursive /usr/local \
  | tr ',' '\n' \
  | sort -u \
  | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
  )" \
  && apk add --no-cache $runDeps \
  \
  && apk del --no-network .build-deps \
  \
  # https://github.com/docker-library/php/issues/443
  && pecl update-channels \
  && rm -rf /tmp/pear ~/.pearrc

COPY docker-php-ext-* docker-php-entrypoint /usr/local/bin/

# sodium was built as a shared module (so that it can be replaced later if so desired), so let's enable it too (https://github.com/docker-library/php/issues/598)
RUN chmod +x /usr/local/bin/docker-php-ext-*
RUN chmod +x /usr/local/bin/docker-php-entrypoint
RUN docker-php-ext-enable sodium

ENTRYPOINT ["docker-php-entrypoint"]
##<autogenerated>##
WORKDIR /var/www/html

RUN set -ex \
  && cd /usr/local/etc \
  && if [ -d php-fpm.d ]; then \
  # for some reason, upstream's php-fpm.conf.default has "include=NONE/etc/php-fpm.d/*.conf"
  sed 's!=NONE/!=!g' php-fpm.conf.default | tee php-fpm.conf > /dev/null; \
  cp php-fpm.d/www.conf.default php-fpm.d/www.conf; \
  else \
  # PHP 5.x doesn't use "include=" by default, so we'll create our own simple config that mimics PHP 7+ for consistency
  mkdir php-fpm.d; \
  cp php-fpm.conf.default php-fpm.d/www.conf; \
  { \
  echo '[global]'; \
  echo 'include=etc/php-fpm.d/*.conf'; \
  } | tee php-fpm.conf; \
  fi \
  && { \
  echo '[global]'; \
  echo 'error_log = /proc/self/fd/2'; \
  echo; echo '; https://github.com/docker-library/php/pull/725#issuecomment-443540114'; echo 'log_limit = 8192'; \
  echo; \
  echo '[www]'; \
  echo '; if we send this to /proc/self/fd/1, it never appears'; \
  echo 'access.log = /proc/self/fd/2'; \
  echo; \
  echo 'clear_env = no'; \
  echo; \
  echo '; Ensure worker stdout and stderr are sent to the main error log.'; \
  echo 'catch_workers_output = yes'; \
  echo 'decorate_workers_output = no'; \
  } | tee php-fpm.d/docker.conf \
  && { \
  echo '[global]'; \
  echo 'daemonize = no'; \
  echo; \
  echo '[www]'; \
  echo 'listen = 9000'; \
  } | tee php-fpm.d/zz-docker.conf

# Override stop signal to stop process gracefully
# https://github.com/php/php-src/blob/17baa87faddc2550def3ae7314236826bc1b1398/sapi/fpm/php-fpm.8.in#L163
STOPSIGNAL SIGQUIT

EXPOSE 9000
CMD ["php-fpm"]
##</autogenerated>##
