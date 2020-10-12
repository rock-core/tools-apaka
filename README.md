# apaka: Automated PAcKaging for Autoproj
[![Build Status](https://travis-ci.org/rock-core/tools-apaka.svg?branch=master)](https:///travis-ci.org/rock-core/tools-apaka)


* https://github.com/rock-core/tools-apaka

Apaka allows you to create Debian packages for a given autoproj based workspace.
A description of the general architecture is part for the following publication:

## Installation

Clone the repository into an existing autoproj installation
```
    git clone https://github.com/rock-core/tools-apaka tools/apaka
```
Add "- tools/apaka" to your autoproj/manifest under the layout section

call
```
    aup apaka
    amake apaka
```

Start a new shell and source the env.sh.


## Creating an new Rock release with apaka

The command line tool `apaka` provides a way to generate Debian packages from autoproj information
for use with the rock_osdeps package set.

When creating a new release, the reprepro repository and build environment need
to be prepared first, i.e. required dependencies will be installed, including among others pbuilder, cowdancer, and apache2.
A new site will be added to your apache2 configuration under /etc/apache/sites-enabled/100_apaka-reprepro.conf

```
    apaka prepare
```

Creating a new Rock release requires some adaption to existing packages, so that an overlay can be applied, here using the
optional `--patch-dir`. The current recipes for Rock can be found in [apaka-rock_patches](https://github.com/rock-core/tools-apaka-rock_patches).
To build all packages that are bootstrapped with a currently active autoproj manifest:

```
    apaka build --patch-dir tools/apaka-rock_patches --architecture amd64 --distribution bionic --release-name master-20.06
```

To build only a particular package or package_set add it as parameter, e.g., here for base/cmake:

```
    apaka build --patch-dir tools/apaka-rock_patches --architecture amd64 --distribution bionic --release-name master-20.06 base/cmake
```

The package repository can be browsed under:
```
    http://<hostname>/apaka-releases
```

As a final step, the yaml descriptions known as *.osdeps file can be generated and
integrated into a packages set such as [rock-osdeps](https://github.com/rock-core/rock-osdeps)

    apaka osdeps --release-name master-20.06 <rock_osdeps yaml dir>


### Examples:

1. Deregistration of a package in reprepro

    `apaka reprepro --deregister --distribution bionic --release-name master-20.06 *orocos.rb*`

1. Registration of a debian package using the dsc file, which needs to be in the same folder as the deb and orig.tar.gz

    `apaka reprepro --register --distribution bionic --release-name master-20.06 build/rock-packager/rock-master-20.06-ruby-tools-orocos.rb/xenial-amd64/rock-master-20.06-ruby-tools-orocos.rb_0.1.0-1~xenial.dsc`

1. Preparing for building

    `apaka prepare --architecture amd64 --distribution bionic --release-name master-20.06`

1. Building a package

    `apaka build --architecture amd64 --distribution bionic --release-name master-20.06 control/visp`

    This includes creating the .dsc file and orig.tar.gz using deb_package,
    building using cowbuilder and registering the package in reprepro.

1. Generating .dsc source package description and orig.tar.gz

    `apaka package --architectures amd64 --distributions bionic --release-name master-20.06 tools/service_discovery`

1. Generate osdeps description file for use in rock_osdeps package set

    `apaka osdeps --release-name master-20.06 --dest-dir /tmp/osdep-files`

### Meta package support

If autoproj meta packages should be represented as debian meta packages, you can
use:
    `apaka build_meta --release-name master-20.06 --distribution bionic --architecture amd64`

This will only create meta packages of packages it finds currently on reprepro
for the corresponding release, distribution, architecture combination.


## How to use an apaka release in combination with Rock
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
You can find an example at http://github.com/rock-core/rock-osdeps-package_set
The package set has to contain the required osdeps definition and setup of environment variables:
Hence, a minimal package set could look like the following:

```
    package_sets:
    - github: rock-core/package_set
    - github: rock-core/rock-osdeps-package_set
    layout:
    - rock.core
```

After adding the package set use autoproj as usual:

```
    source env.sh
    autoproj update
```

Follow the questions for configuration and select your prepared release for the Debian packages.
Finally start a new shell, reload the env.sh and call amake.
This should finally install all required Debian packages and remaining required packages, which might have not been packaged.

### Features

* packages have separate installation folder and each provide and env.sh to
  setup the environment, but note that this env.sh does not include the settings for
  a packages dependencies
* multiple autoproj workspace can reuse the existing set of Rock Debian packages
* multiple releases of the Rock Debian packages can be installed in parallel, the target folder is typically /opt/rock/*release-name*
* in order to enforce the usage of a source package in a workspace create a file
  autoproj/deb_blacklist.yml containing the name of the particular package. This
  will disable automatically the use of this Debian package and all that depend
  on that package, e.g., to disable base/types add all packages that start with
  simulation/ create a deb_blacklist.yml with the following content:

```
    ---
    - base/types
    - simulation/.*
    - ^orogen$
```

You will be informed about the disabled packages:

Triggered regeneration of rock-osdeps.osdeps: /opt/workspace/rock_autoproj_v2/.autoproj/remotes git_git_github_com_rock_core_rock_osdeps_git/lib/../rock-osdeps.osdeps, blacklisted packages: ["base/types"]
Disabling osdeps: ["base/types", "tools/service_discovery", "tools/pocolog_cpp", ...


### Maintaining apaka

#### Adding new distributions

In order to add a new distributions a few things have to be done.
Firstly, the default configuration file should be extended with the particular
distribution, i.e., add the desired distribution here.
Call 'deb_local --show-current-os' to retrieve the corrensponding
labels for your current operating system.
Examples:
```
distributions:
    bionic:
        type: ubuntu,debian
        labels: 18.04,bionic,beaver,default
    stretch:
        type: debian
        labels: 9.4,stretch,default
        ruby_version: ruby23
```

Adapt the template for /etc/pbuilderrc i.e., lib/apaka/packaging/templates/etc-pbuilderrc
In order to bootstrap new images, pbuilder has to be informed, whether an
distribution label such as 'bionic' or 'stretch' has to be interpreted as
Ubuntu or Debian distribution (currently apaka consider only these two).
New distributions should be added to the list in the above mentioned template of /etc/pbuilderrc.
This update will not be automatically applied to existing installations, hence,
you will have change existing installations of apaka manually.
Furthermore, reprepro only accounts for the new distribution, if you create a
new release. To add it to existing releases you have to add the distribution
(architecture) manually to /var/www/apaka-releases/*rock-release*/conf/distributions.

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
    export BUNDLE_GEMFILE=$PWD/test/workspace
    ruby -Ilib test/test_packaging.rb
```
To run only individual tests, use the -n option, e.g.,
for the test_canonize
```
    export BUNDLE_GEMFILE=$PWD/test/workspace
    ruby -Ilib test/test_packaging.rb -n test_canonize
```

## Package Signing and Usage
### Maintainer

Generate key pair gpg2 (use RSA and RSA)
```
    gpg2 --full-gen-key
```
List proper key-ID-format of the generated key pair. For the next step use the 16 character long key ID that is shown in the line starting with pub after rsa4096/.
```
    gpg2 --list-key --keyid-format long
```
Edit /var/www/akala-releases/_releaseName_/config/distributions and add the following line to the block matching the distribution that is to be signed (e.g. bionic). 
```
    SignWith: insert_short_pub_key_ID
```

Rebuild one new package that **has not been build before**, in order to have deb_local sign the entire release (of this distribution).
If all packages have already been build, remove a small package from the release with reprepro and rebuild it.
E.g. search for base/cmake and remove matching packages on the bionic distribution.
```
    reprepro -b . listmatched bionic '*base-cmake*'
    reprepro -b . removematched bionic '*base-cmake*'
```
Rebuild base/cmake with deb_local or using apaka-make-deb with --package base/cmake option.

Export public key to file. Replace _releaseName_ and _bionic_ as needed.
```
    gpg2 --armor --output /var/www/apaka-releases/_releaseName_/dists/_bionic_/Release_pub --export insert_short_pub_key_ID
```

### User
Get the public key file Release_pub and make it known to apt and update.
```
    sudo apt-key add Release_pub && apt-get update
```
Open /etc/apt/sources.list (sudo required) and add deb URL dsitribution.
E.g. _deb http://rock.hb.dfki.de/rock-releases/mantis-19.05/ bionic main_


## Script interface description

The main interface is the 'apaka' binary which can be used with a number of
modes:
```
$>apaka --help                                                                                                                                                    [23:11:47]
Commands:
  apaka build [PackageName]         # Build a (debian) package from a given autoproj package, or a gem
  apaka build_meta [PackageName]    # Build a (debian) meta package
  apaka config                      # Show the current configuration
  apaka help [COMMAND]              # Describe available commands or one specific command
  apaka osdeps                      # Generate osdeps files for a package release
  apaka package [PackageName]       # Prepare the artifact to build a (debian) package from a given autoproj package
  apaka package_meta [PackageName]  # Create artifacts required to build a (debian) meta package
  apaka query [Package]             # Query the current database
  apaka reprepro [Package]          # Manipulate the reprepro instance for a particular release

Options:
  [--verbose], [--no-verbose]    # turns verbose output
  [--debug], [--no-debug]        # turns debug output on of off
  [--config-file=CONFIG_FILE]    # Configuration file to use
  [--release-name=RELEASE_NAME]  # Release name to use
                                 # Default: release-20.06
```

The help for each mode can be called by:
```
$>apaka help package
Usage:
  apaka package [PackageName]

Options:
  [--package-set-dir=PACKAGE_SET_DIR]   # Directory with the binary-package set to update
  [--version=VERSION]                   # Version of the package to create for
  [--architecture=ARCHITECTURE]         # Architecture to build for
  [--distribution=DISTRIBUTION]         # Distribution to build for
  [--build-dir=BUILD_DIR]               # Build folder of the source package -- needs to be within
  [--dest-dir=DEST_DIR]                 # Destination folder of the source package
  [--patch-dir=PATCH_DIR]               # Overlay directory to patch existing packages
  [--pkg-set-dir=PKG_SET_DIR]           # Package set directory
  [--rebuild], [--no-rebuild]           # Force rebuilding / repackaging
  [--no-deps], [--no-no-deps]           # Do not package dependencies
  [--ancestor-blacklist=one two three]  # Packages added to the ancestor blacklist, i.e., if needed as dependency, use a package from the current release name
  [--verbose], [--no-verbose]           # turns verbose output
  [--debug], [--no-debug]               # turns debug output on of off
  [--config-file=CONFIG_FILE]           # Configuration file to use
  [--release-name=RELEASE_NAME]         # Release name to use
                                        # Default: release-20.06

Prepare the artifact to build a (debian) package from a given autoproj package
```

## A typical workflow

A typical workflow to build all packages for `drivers/orogen/iodrivers_base` will look as follows:
```
$>apaka build --patch-dir tools/apaka-rock_patches --config-file apaka-master-20.06.yml --release-name master-20.06 drivers/orogen/iodrivers_base
```

If you want to create a meta package for your release which will be named
`rock-master-20.06-meta-full`, then you can use the following call:

```
$>apaka build_meta --config-file apaka-master-20.06.yml --release-name master-20.06
```

## References and Publications
Please refer to the following publication when citing Apaka:

```
    Binary software packaging for the Robot Construction Kit
    Thomas M. Roehr, Pierre Willenbrock
    In Proceedings of the 14th International Symposium on Artificial Intelligence, (iSAIRAS-2018), 04.6.-06.6.2018, Madrid, ESA, Jun/2018.
```

## Merge Request and Issue Tracking

Github will be used for pull requests and issue tracking: https://github.com/rock-core/tools-apaka

## License

This software is distributed under the [New/3-clause BSD license](https://opensource.org/licenses/BSD-3-Clause)

## Copyright

Copyright (c) 2014-2018, DFKI GmbH Robotics Innovation Center
