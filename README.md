# Rock admin scripts

* https://github.com/rock-core/base-admin_scripts

## Available Scripts

 * deb_package
 * deb_package-available
 * deb_local
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

`deb_local` provides a way to generate debian packages from autoproj information
for use with the rock_osdeps package set.

When creating a new release, the reprepro repository and build environment need
to be prepared:

    deb_local --prepare --architecture amd64 --distribution xenial --release-name master-17.09

Creating a new rock_osdeps release requires the packages to be built using:

    deb_local --patch-dir deb_patches --architecture amd64 --distribution xenial --release-name master-17.09 <packages, package sets>

If autoproj meta packages should be represented as debian meta packages, add
`--build-meta`. This will only create meta packages of packages it finds on
the commandline, not any that may be referenced through package sets or
similar. The resulting packages are automatically added to the local reprepro
repository.

As a final step, the yaml descriptions for rock_osdeps need to be generated and
integrated into rock_osdeps:

    dep_package --architectures amd64 --distributions xenial --release-name master-17.11 --update-osedps-lists <rock_osdeps yaml dir>


### Examples:

1. Deregistration of a package in reprepro

    `deb_local --deregister --distribution xenial --release-name master-17.04 *orocos.rb*`
    
1. Registration of a debian package using the dsc file, which needs to be in the same folder as the deb and orig.tar.gz

    `deb_local --register --distribution xenial --release-name master-17.04 build/rock-packager/rock-master-17.04-ruby-tools-orocos.rb/xenial-amd64/rock-master-17.04-ruby-tools-orocos.rb_0.1.0-1~xenial.dsc`
    
1. Preparing for building

    `deb_local --architecture amd64 --distribution xenial --release-name master-17.09 --prepare`
    
1. Building a set of packages

    `deb_local --architecture amd64 --distribution xenial --release-name master-17.09 control/visp`
    
    This includes creating the .dsc file and orig.tar.gz using deb_package,
    building using cowbuilder and registering the package in reprepro.
    
1. Generating .dsc source package description and orig.tar.gz

    `deb_package --architectures amd64 --distributions xenial --release-name master-17.11 --package tools/service_discovery`
    
1. Generate osdeps description file for use in rock_osdeps package set

    `deb_local --update-osdeps-lists rock.core`

### deb_package

    deb_package <global options> <action> <action specific options>

#### Global options:

    deb_package [--[no-]verbose] [--[no-]debug] [--config-file CONFIG]

#### Actions and options:

    deb_package --package [--patch-dir DIR] [--architectures ARCHS] [--distributions DISTS] [--release-name NAME] [--package-version VERSION] [--rebuild] [--skip] [--dest-dir DIR] [--build-dir DIR] [--use-remote-repository] [--package-set-dir DIR] [--rock-base-install-dir DIR] SELECTION
    deb_package --meta NAME [--patch-dir DIR] [--architectures ARCHS] [--distributions DISTS] [--release-name NAME] [--package-version VERSION] [--rebuild] [--build-dir DIR] [--package-set-dir DIR] [--rock-base-install-dir DIR] SELECTION
    deb_package --build-local [--architectures ARCHS] [--distributions DISTS] [--release-name NAME] [--package-version VERSION] [--dest-dir DIR] [--build-dir DIR] [--rock-base-install-dir DIR] SELECTION
    deb_package --install [--build-dir DIR] [--architectures ARCHS] [--distributions DISTS] [--release-name NAME] [--package-version VERSION] [--rock-base-install-dir DIR] SELECTION
    deb_package --update-osdeps-lists DIR [--package-version VERSION] SELECTION
    deb_package --exists TUPLE
    deb_package --activation-status [--architectures ARCHS] [--distributions DISTS]

    deb_package --create-job [--architectures ARCHS] [--distributions DISTS] [--package-version VERSION] [--overwrite] SELECTION
    deb_package --create-ruby-job [--architectures ARCHS] [--distributions DISTS] [--package-version VERSION] [--overwrite] SELECTION
    deb_package --create-flow-job NAME [--architectures ARCHS] [--distributions DISTS] [--package-version VERSION] [--overwrite] [--parallel] [--flavor name] SELECTION
    deb_package --create-control-job NAME [--overwrite]
    deb_package --create-control-jobs [--overwrite]
    deb_package --create-cleanup-jobs
    deb_package --cleanup-job NAME
    deb_package --cleanup-all-jobs
    deb_package --remove-job NAME
    deb_package --remove-all-jobs

    deb_package --show-config

The order of the options is not important.

#### Global options:
Option | Description
-------|------------
`--[no-]verbose` | display output of commands on stdout
`--[no-]debug` | debug information (for debugging purposes)
`--config-file CONFIG` | Read configuration file

#### Actions for rock_osdeps on Debian:
Option | Description
-------|------------
`--package` | Create chosen packages
`--meta NAME` | Create a meta package for the chosen packages
`--update-osdeps-lists DIR` | Update the osdeps files in the given directory
`--build-local` | Build a debian-package locally and without Buildserver (Jenkins)
`--install` | Build an environment up to the given package based on debian-packages
`--exists TUPLE` | Test availablility of a package in a given distribution <distribution>,<package_name>
`--activation-status` | Check the configuration setting for building this particualr distribution and release combination
`--update-list FILE` | deprecated, use `--update-osdeps-lists` instead

#### Actions for Jenkins jobs:
Option | Description
-------|------------
`--create-job` | Create jenkins-jobs
`--create-ruby-job` | Create jenkins-ruby-job
`--create-flow-job NAME` | Create the jenkins-FLOW-job
`--create-control-job NAME` | Create control-job named 0_<NAME>
`--create-control-jobs` | Create all control-jobs in the templates-folder
`--create-cleanup-jobs` | Create cleanup jobs
`--cleanup-job Name` | Cleanup jenkins-job
`--cleanup-all-jobs` | Cleanup all jenkins jobs
`--remove-job Name` | Remove jenkins-job
`--remove-all-jobs` | Remove all jenkins jobs except flow- and control-jobs (a_/0_)

#### Actions for Configuration:
Option | Description
-------|------------
`--show-config` | Show the current configuration

#### Action dependent options:
Option | Description
-------|------------
`--skip` | Skip existing packages
`--dest-dir DIR` | Destination Folder of the source-package
`--build-dir DIR` | Build Folder of the source package -- needs to be within an autoproj installation
`--patch-dir DIR` | Overlay directory to patch existing packages (and created gems) during the packaging process
`--rebuild` | rebuild package
`--use-remote-repository` | don't use local repository, but import from known remote
`--package-set-dir DIR` | Directory with the binary-package set to update
`--architectures ARCHS` | Comma separated list of architectures to build for (only the first one is actually built!)
`--distributions DISTS` | Comma separated list of distributions to build for (only the first one is actually built!)
`--overwrite` | Overwrite existing Jenkins Jobs (History-loss!)
`--flavor name` | Use a specific flavor (defaults to directory-name)
`--rock-base-install-dir DIR` | Rock base installation directory (prefix) for deployment of debian packages
`--release-name NAME` | Release name for the generated set of packages -- debian package will be installed in a subfolder with this name in base dir
`--package-version VERSION` | The version requirement for the package to install use 'noversion' if no specific version is required, but option needs to be present

The default configuration file has support for distributions: trusty, xenial, jessie and architectures: amd64, i386, armel(jessie only), armhf(jessie only).

#### Unused options:
Option | Description
-------|------------
`--parallel` | Build jenkins-jobs in parallel, might be more unstable but much faster. Only useful with `--create-flow-job`
`--recursive` | package and/or build packages with their recursive dependencies

### deb_local

    deb_local [--patch-dir DIR] [--architecture NAME] [--distribution NAME] [--release-name NAME] [--rebuild] [--jobs JOBS] [--build-meta] [--meta-only] [--custom-meta NAME] [--reinstall] [--dry-run] [--rock-base-install-dir DIR]
    deb_local --prepare [--architecture NAME] [--distribution NAME] [--release-name NAME]
    deb_local --register [--distribution NAME] [--release-name NAME] SELECTION
    deb_local --deregister [--distribution NAME] [--release-name NAME] SELECTION


#### Actions
Option | Description
-------|------------
default | Build all packages in SELECTION
`--prepare` | Prepare the local building of packages
`--register` | Register a package
`--deregister` | Deregister/remove a package. SELECTION also allows wildcards: "*".

#### General options
Option | Description
-------|------------
`--architecture NAME` | Target architecture to build for
`--distribution NAME` | Target distribution release to build for, e.g. trusty
`--release-name NAME` | Release name for the generated set of packages -- debian package will be installed in a subfolder with this name in base dir

#### Options for building packages
Option | Description
-------|------------
`--patch-dir DIR` | Overlay directory to patch existing packages (and created gems) during the packaging process
`--rock-base-install-dir DIR` | Rock base installation directory (prefix) for deployment of the local debian packages
`--rebuild` | Rebuild package (otherwise the existing packaged deb will be used)
`--custom-meta NAME` | Build a meta package for all packages on the command line
`--build-meta` | Build meta packages from autoproj meta packages found on the command line
`--meta-only` | Build only meta packages(from `--custom-meta` and `--build-meta`)
`--reinstall` | Reinstall already installed packages
`--dry-run` | Show the packages that will be build
`-j JOBS`, `--jobs JOBS` | Maximum number of parallel jobs

#### Unused options
Option | Description
-------|------------
`--verbose` | Display output
`--no-deps` | Ignore building dependencies


