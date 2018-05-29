# apaka: Automated PAcKaging for Autoproj

* https://github.com/rock-core/apaka

Apaka allows you to create Debian packages for a given autoproj based workspace.
A description of the general architecture is part for the following publication:

## Installation

Clone the repository into an existing autoproj installation
```
    git clone https://github.com/rock-core/apaka
```
call
```
    amake apaka
```

Start a new shell and source the env.sh.


## Creating an new Rock release with Apaka

The command line tool `deb_local` provides a way to generate debian packages from autoproj information
for use with the rock_osdeps package set.

When creating a new release, the reprepro repository and build environment need
to be prepared first, i.e. required dependencies will be installed, including among others pbuilder, cowdancer, and apache2.
A new site will be added to your apache2 configuration under /etc/apache/sites-enabled/100_apaka-reprepro.conf

```
    deb_local --prepare
```

Creating a new Rock release requires some adaption to existing packages, so that an overlay can be applied, here using the
optional `--patch-dir`. The current recipes for Rock can be found in [deb_patches](https://github.com/2maz/deb_patches).
To build all packages that are bootstrapped with a currently active autoproj manifest:

```
    deb_local --patch-dir deb_patches --architecture amd64 --distribution xenial --release-name master-18.01
```

To build only a particular package or package_set add it as parameter, e.g., here for base/cmake:

```
    deb_local --patch-dir deb_patches --architecture amd64 --distribution xenial --release-name master-18.01 base/cmake
```

The package respository can be browsed under:
```
    http://<hostname>/apaka-releases
```

As a final step, the yaml descriptions known as *.osdeps file can be generated and
integrated into a packages set such as [rock-osdeps](https://github.com/rock-core/rock-osdeps)

    dep_package --architectures amd64 --distributions xenial --release-name master-18.01 --update-osdeps-lists <rock_osdeps yaml dir>


### Examples:

1. Deregistration of a package in reprepro

    `deb_local --deregister --distribution xenial --release-name master-18.01 *orocos.rb*`

1. Registration of a debian package using the dsc file, which needs to be in the same folder as the deb and orig.tar.gz

    `deb_local --register --distribution xenial --release-name master-18.01 build/rock-packager/rock-master-18.01-ruby-tools-orocos.rb/xenial-amd64/rock-master-18.01-ruby-tools-orocos.rb_0.1.0-1~xenial.dsc`

1. Preparing for building

    `deb_local --architecture amd64 --distribution xenial --release-name master-18.01 --prepare`

1. Building a set of packages

    `deb_local --architecture amd64 --distribution xenial --release-name master-18.01 control/visp`

    This includes creating the .dsc file and orig.tar.gz using deb_package,
    building using cowbuilder and registering the package in reprepro.

1. Generating .dsc source package description and orig.tar.gz

    deb_package --architectures amd64 --distributions xenial --release-name master-18.01 --package tools/service_discovery

1. Generate osdeps description file for use in rock_osdeps package set

    deb_package --update-osdeps-lists rock.core --release-name master-18.01

### Meta package support

If autoproj meta packages should be represented as debian meta packages, add
`--build-meta`. This will only create meta packages of packages it finds on
the commandline, not any that may be referenced through package sets or
similar. The resulting packages are automatically added to the local reprepro
repository.




## How to use an Apaka release in combination with Rock
Either start with a fresh bootstrap:

```
    sudo apt install ruby ruby-dev wget
    wget http://www.rock-robotics.org/autoproj...
    ruby autoproj_bootstrap
```
If you want to use an already defined build configuration then replace the last step with something like:

```
    ruby autoproj_bootstrap git git://github.com/yourownproject/yours...
```
or remove the install folder in order to get rid of old packages.

If a release has been created with default settings all its Debian Packages
install their files into /opt/rock/release-name and now to activate debian
packages for your autoproj workspace:

adapt the autoproj/manifest to contain only the packages in the layout that you require as source packages. However, the layout section should not be empty, e.g. to bootstrap all precompiled packages of the rock-core package set add:

```
layout:
- rock.core

```

After the package_sets that you would require for a normal bootstrap, you require a package set that contains the overrides for
your release.
You can find an example at http://github.com/2maz/rock-osdeps
The package set has to contains the required osdeps definition and setup of environment variables:
Hence, a minimal package set could look like the following:

```
    package_sets:
    - github: rock-core/package_set
    - github: rock-core/rock-osdeps
    layout:
    - rock.core
```

After adding the package set use autoproj as usual:

```
    source env.sh
    autoproj update
```

Follow the questions for configuration and select your prepared release for the debian packages.
Finally start a new shell, reload the env.sh and call amake.
This should finall install all required Debian packages and remaining required packages, which might have not been packaged.

### Features

* multiple autoproj workspace can reuse the existing set of Rock Debian packages
* multiple releases of the Rock Debian packages can be installed in parallel, the target folder is typically /opt/rock/release-name
* in order to enforce the usage of a source package in a workspace create a file autoproj/deb_blacklist.yml containing the name of the particular package. This will disable automatically the use of this debian package and all that depend on that package, e.g., to disable base/types and all packages that start with simulation/ create a deb_blacklist.yml with the following content:

```
    ---
    - base/types
    - simulation/*
```

You will be informed about the disabled packages:

Triggered regeneration of rock-osdeps.osdeps: /opt/workspace/rock_autoproj_v2/.autoproj/remotes git_git_github_com_2maz_rock_osdeps_git/lib/../rock-osdeps.osdeps, blacklisted packages: ["base/types"]
Disabling osdeps: ["base/types", "tools/service_discovery", "tools/pocolog_cpp", ...

### Known Issues
1.  If you get a message like
    ```
        error loading "/opt/rock/master-18.01/lib/ruby/vendor_ruby/hoe/yard.rb": yard is not part of the bundle. Add it to Gemfile.. skipping...
    ```

    Then add the following to install/gems/Gemfile (in the corresponding autoproj installation)
    ```
       gem 'yard'
    ```



## Autogenerate the API Documentation
You can call

```
   rake doc
```

to autogenerate the documentation, which can then
be found in a doc/ subfolder.

## Running the test suite
To run the test suite you can either call
```
    rake test
```
or
```
    ruby -Ilib test/test_packaging.rb
```
To run only individual tests, use the -n option, e.g.,
for the test_canonize
```
    ruby -Ilib test/test_packaging.rb -n test_canonize
```

## Script interface description

### deb_package

    deb_package <global options> <action> <action specific options>

#### Global options:

    deb_package [--[no-]verbose] [--[no-]debug] [--config-file CONFIG]

#### Actions and options:

    deb_package --package [--patch-dir DIR] [--architectures ARCHS] [--distributions DISTS] [--release-name NAME] [--package-version VERSION] [--rebuild] [--skip] [--dest-dir DIR] [--build-dir DIR] [--use-remote-repository] [--package-set-dir DIR] [--rock-base-install-dir DIR] SELECTION
    deb_package --meta NAME [--patch-dir DIR] [--architectures ARCHS] [--distributions DISTS] [--release-name NAME] [--package-version VERSION] [--rebuild] [--build-dir DIR] [--package-set-dir DIR] [--rock-base-install-dir DIR] SELECTION
    deb_package --build-local [--architectures ARCHS] [--distributions DISTS] [--release-name NAME] [--package-version VERSION] [--dest-dir DIR] [--build-dir DIR] [--rock-base-install-dir DIR] SELECTION
    deb_package --install [--build-dir DIR] [--architectures ARCHS] [--distributions DISTS] [--release-name NAME] [--package-version VERSION] [--rock-base-install-dir DIR] SELECTION
    deb_package --update-osdeps-lists DIR --release-name NAME [--package-version VERSION] SELECTION
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
Option | Descriptioncopyright
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


## References and Publications
Please refer to the following publication when citing Apaka:

```
    Binary software packaging for the Robot Construction Kit
    Thomas M. Roehr, Pierre Willenbrock
    In Proceedings of the 14th International Symposium on Artificial Intelligence, (iSAIRAS-2018), 04.6.-06.6.2018, Madrid, ESA, Jun/2018.
```

## Merge Request and Issue Tracking

Github will be used for pull requests and issue tracking: https://github.com/rock-core/apaka

## License

This software is distributed under the [New/3-clause BSD license](https://opensource.org/licenses/BSD-3-Clause)

## Copyright

(c) Copyright 2014-2018, DFKI GmbH Robotics Innovation Center
