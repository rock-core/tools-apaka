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

bootstrap() {
# If we are bootstrapping, delete the old build artifacts and create a local
# configuration with the specified configuration file
if test -f "$BUILDCONF_FILE"; then    

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
    if !(test -d dev)
    then
	bootstrap
    fi
    cd dev
    
    # Check if we do need to bootstrap
    if ! test -d autoproj; then
	sudo apt-get update
	sudo apt-get -y install ruby rubygems wget
	rm -f autoproj_bootstrap
	wget http://rock-robotics.org/autoproj_bootstrap
	ruby autoproj_bootstrap git $BUILDCONF_GIT
    fi
    
    . ./env.sh
    if test -n "$BUILDCONF_FILE"; then
        cp -f $BUILDCONF_FILE autoproj/config.yml
    fi
    autoproj full-build $COMMON_ARGS
}

