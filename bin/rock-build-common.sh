usage() {
    echo "usage: build_server.sh buildconf_git buildconf_bootstrap [mail_header mail_address mail_smtp]"
    echo "where buildconf_git is the build configuration repository as a git URL"
    echo "      buildconf_bootstrap is a path to a config file"
    echo "and the mail_* arguments are the parameters to mail errors (leave blank to not send anything)"
    exit 1
}

argument_checks() {
    if test -z "$BUILDCONF_GIT"; then
	usage
    fi

    if test -n "$MAIL_HEADER"; then
	if test -z "$MAIL_ADDRESS" || test -z "$MAIL_SMTP"; then
            usage
	fi
	COMMON_ARGS="--mail-subject="$MAIL_HEADER" --mail-from=$MAIL_ADDRESS --mail-to=$MAIL_ADDRESS --mail-smtp=$MAIL_SMTP --mail-only-errors"
    else
	COMMON_ARGS=""
    fi
    
    export AUTOPROJ_BOOTSTRAP_IGNORE_NONEMPTY_DIR=1
    if test -z "$AUTOPROJ_OSDEPS_MODE"; then
	export AUTOPROJ_OSDEPS_MODE=all
    fi
}

set -e

delete_artifacts() {
    rm -rf buildconf dev
}

prepare_buildconf_git() {
# If we are bootstrapping, delete the old build artifacts and create a local
# configuration with the specified configuration file
if test -f "$BUILDCONF_FILE"; then    

    rm -rf buildconf
    git clone $BUILDCONF_GIT buildconf
    cd buildconf
    cp -f $BUILDCONF_FILE config.yml
    git add -f config.yml
    git commit -a -m "build server configuration"
    cd ..

    mkdir -p dev

    BUILDCONF_GIT=$PWD/buildconf
else
    echo "Build failed, needed to bootstrap, but no boostrap configuration was given"
    exit 1
fi
}

update() {
    if ! test -d dev/autoproj; then
	prepare_buildconf_git
    fi
    cd dev
    
    if test "x$USE_PRERELEASE" = "xtrue"; then
	BOOTSTRAP_ARGS="dev"
	BOOTSTRAP_SCRIPT_SUFFIX="-dev"
    fi

    # Check if we do need to bootstrap
    if ! test -d autoproj; then
        # do NOT run apt-get update, as it will cause problems in environments
        # where multiple installations are bootstrapped in parallel (such as a
        # build server)
        #
        # Instead, setup a separate task that does the update for you
	# sudo apt-get update
	# sudo apt-get -y install ruby rubygems wget
	rm -f autoproj_bootstrap$BOOTSTRAP_SCRIPT_SUFFIX
	wget http://rock-robotics.org/autoproj_bootstrap$BOOTSTRAP_SCRIPT_SUFFIX

	ruby1.8 autoproj_bootstrap$BOOTSTRAP_SCRIPT_SUFFIX $BOOTSTRAP_ARGS --no-color git $BUILDCONF_GIT
    fi

    #workaround for solving network problems on our build server build01
    if [ `hostname -s` = "build01" ]; then
        if test -d .gems/gems/autoproj-1.7.20; then
            echo "!! patching autoproj to retry reaching gitorious multiple times before failing!!!"
            cp /home/build/rock_admin_scripts/patches/gitorious.rb .gems/gems/autoproj-1.7.20/lib/autoproj/
        fi
        if test -d .gems/gems/autobuild-1.5.61; then
            echo "!! patching autobuild to retry reaching gitorious multiple times before failing!!!"
            cp /home/build/rock_admin_scripts/patches/importer.rb .gems/gems/autobuild-1.5.61/lib/autobuild/
        fi
    fi
    
    . ./env.sh
    if test -n "$BUILDCONF_FILE"; then
        cp -f $BUILDCONF_FILE autoproj/config.yml
    fi

    if test "x$USE_PRERELEASE" = "xtrue"; then
	gem install --prerelease autobuild autoproj
    fi
    autoproj full-build --no-color $COMMON_ARGS
}

