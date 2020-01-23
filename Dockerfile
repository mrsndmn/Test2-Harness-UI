FROM ubuntu:18.10 as base

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y apt-utils build-essential \
        postgresql postgresql-contrib postgresql-client \
        perl cpanminus libdbd-pg-perl \
        rsync uuid-dev libcurl4-gnutls-dev libncurses5-dev libreadline-dev \
        locales-all \
        libdbix-class-perl libdbix-class-uuidcolumns-perl \
        libdbix-class-schema-config-perl libdbix-class-schema-loader-perl \
        libdbix-class-timestamp-perl libdbix-class-tree-nestedset-perl libnet-ssleay-perl \
        libipc-run-perl libipc-run3-perl libuuid-perl libdata-uuid-libuuid-perl libxml-parser-perl \
        libxml-libxml-perl libterm-readline-perl-perl libterm-readline-gnu-perl \
    && (ln -s /usr/lib/postgresql/10/bin/* /usr/bin/ 2>/dev/null || true)

RUN cpanm LWP File::ShareDir::Install App::cpanminus Test2::Harness \
    && cpanm -n -v DBIx::QuickDB \
    && cpanm --installdeps -v Test2::Harness::UI

RUN groupadd -g 999 appuser && useradd -r -u 999 -g appuser appuser

FROM base as demo

ADD cpanfile /app/cpanfile

RUN ["cpanm", "--installdeps", "-v", "/app"]

ADD . /app

RUN ["chown", "-R", "999:999", "/app"]

USER appuser

ENV T2_HARNESS_UI_ENV=dev
EXPOSE 8081

WORKDIR /app

ENTRYPOINT ["perl", "-I", "/app/lib", "/app/demo/demo.pl"]
