# Rock admin scripts

* https://github.com/rock-core/base-admin_scripts

## Available Scripts

 * deb_package
 * deb_package-available
 * gem_dependencies
 * obs_package
 * obs_ubuntu_universe_package
 * rock-build-common.sh
 * rock-build-incremental
 * rock-build-server
 * rock-clone-gitorious
 * rock-directory
 * rock-directory-pages
 * rock-make-doc
 * rock-push-flavor
 * rock-release
 * rock-status
 * rock-tag-delta
 * rock-update-branch
 * rock-widget-parser.rb



## Debian Packaging

### Examples:

0. Deregistration of a package in reprepro
    deb_local --deregister --distribution xenial --release-name master-17.04 *orocos.rb*
0. Registration of a debian package using the dsc file, which needs to be in the same folder as the deb and orig.tar.gz
    deb_local --register --distribution xenial --release-name master-17.04 build/rock-packager/rock-master-17.04-ruby-tools-orocos.rb/xenial-amd64/rock-master-17.04-ruby-tools-orocos.rb_0.1.0-1~xenial.dsc
