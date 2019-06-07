FROM ubuntu:18.04

MAINTAINER 2maz "https://github.com/2maz"

# Optional arguments
ARG PKG_BRANCH="master"
ENV PKG_BRANCH=${PKG_BRANCH}

ARG PKG_PULL_REQUEST="false"
ENV PKG_PULL_REQUEST=${PKG_PULL_REQUEST}

ARG PKG_PULL_REQUEST_BRANCH=""
ENV PKG_PULL_REQUEST_BRANCH=${PKG_PULL_REQUEST_BRANCH}
## END ARGUMENTS

RUN apt update
RUN apt upgrade -y
RUN export DEBIAN_FRONTEND=noninteractive; apt install -y ruby ruby-dev git locales tzdata vim wget gem2deb reprepro apache2 cmake automake pbuilder cowdancer curl
RUN apt-file update
RUN service apache2 start
RUN echo "Europe/Berlin" > /etc/timezone; dpkg-reconfigure -f noninteractive tzdata
RUN export LANGUAGE=de_DE.UTF-8; export LANG=de_DE.UTF-8; export LC_ALL=de_DE.UTF-8; locale-gen de_DE.UTF-8; DEBIAN_FRONTEND=noninteractive dpkg-reconfigure locales

RUN useradd -ms /bin/bash docker
RUN echo "docker ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

USER docker
WORKDIR /home/docker
ENV LANG de_DE.UTF-8
ENV LANG de_DE:de
ENV LC_ALL de_DE.UTF-8
ENV GEM_HOME=/home/docker/.gems/ruby/2.3.0
ENV PATH=$GEM_HOME/bin:$PATH

RUN git clone https://github.com/rock-core/tools-apaka /home/docker/apaka
COPY --chown=docker .ci/prepare-package.sh prepare-package.sh
RUN /bin/bash prepare-package.sh /home/docker/apaka

RUN sed -i 's#gems_install_path.*#gems_install_path: /home/docker/.gems#' /home/docker/apaka/test/workspace/.autoproj/config.yml
RUN git config --global user.name 'Apaka4docker'
RUN git config --global user.email 'apaka@docker'
RUN gem install bundler
RUN gem install autoproj
RUN gem install yard
