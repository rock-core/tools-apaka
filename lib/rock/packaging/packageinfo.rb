
module Autoproj
    module Packaging
        class PackageInfo
            # rock name
            attr_accessor :name
            # time/date of latest change to the source package
            attr_accessor :latest_commit_time
            # version string
            attr_accessor :description_version
            # string containing the short documentation. newlines are
            # allowed, but may be removed.
            attr_accessor :short_documentation
            # string containing the long documentation. newlines are
            # allowed.
            attr_accessor :documentation
            # Array of strings appropriate as items in the changelog,
            # describing the origin of the package, i.E. repository,
            # revisions, source url etc.
            attr_accessor :origin_information
            # Number of parallel build processes
            attr_accessor :parallel_build_level
            # importer type, one of :git, :svn, :archive_importer
            attr_accessor :importer_type
            # build type, one of
            # :orogen, :cmake, :autotools, :ruby, :archive_importer, :importer_package
            attr_accessor :build_type
            # directory containing the source ready to be packaged
            attr_accessor :srcdir
            #for build_type == :orogen
            # orogen command invocation, only filled if build_type is :orogen
            attr_accessor :orogen_command
            #for build_type == :cmake or :orogen
            # additional defines to be passed to cmake
            attr_accessor :cmake_defines
            #for build_type == :autotools
            # if nonnil, libtool is used and contents are the executable to be
            # used for libtool
            attr_accessor :using_libtool
            # if nonnil, autogen is used and contents are the executable to
            # be used for autogen
            attr_accessor :using_autogen
            # additional configure flags to be passed to the build process
            attr_accessor :extra_configure_flags
            # imports the package to the importdir
            # generally, that is a copy if a different source dir exists, but
            # it may be a source control checkout.
            def import(package_name)
                raise "#{self.class} needs to overwrite import"
            end

            # raw dependencies
            # can be processed with filtered_dependencies to obtain old
            # behaviour
            # [:rock_pkginfo => rock_pkginfos, :osdeps => osdeps_packages, :nonnative => nonnative_packages ]
            def dependencies
                raise "#{self.class} needs to overwrite dependencies"
            end

            # environment for using external utilities on an imported
            # version of this package
            # {"VARIABLE" => "VALUE"}
            def env
                raise "#{self.class} needs to overwrite env"
            end

            # Array of PackageInfos, containing the packages that need to
            # be build for this package. Mostly just this package and
            # dependencies.
            def required_rock_packages
                raise "#{self.class} needs to overwrite required_rock_packages"
            end
        end #PackageInfo
    end #Packaging
end #Autoproj
