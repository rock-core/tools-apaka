require 'thor'
require 'tty/color'
require 'autoproj'

require_relative '../../apaka/packaging/packager'

module Apaka
    module CLI
        class Main < Thor
            class_option :verbose, type: :boolean, default: false,
                 desc: 'turns verbose output'
            class_option :debug, type: :boolean, default: false,
                 desc: 'turns debug output on of off'

            class_option :config_file, type: :string,
                desc: "Configuration file to use"
            class_option :release_name, type: :string, default: Apaka::Packaging.default_release_name,
                desc: "Release name to use"

            desc "meta_package [PackageName]", "Prepare a metapackage from an existing package set"
            option :package_set_dir, type: :string,
                desc: "Directory with the binary-package set to update"


            desc "package [PackageName]", "Prepare the artifact to build a (debian) package from a given autoproj package"
            option :version, type: :string,
                desc: "Version of the package to create for"
            option :architecture, type: :string,
                desc: "Architecture to build for"
            option :distribution, type: :string,
                desc: "Distribution to build for"
            option :build_dir, type: :string,
                desc: "Build folder of the source package -- needs to be within"
                    "an autoproj installation"
            option :dest_dir, type: :string,
                desc: "Destination folder of the source package"
            option :patch_dir, type: :string,
                desc: "Overlay directory to patch existing packages"
            option :pkg_set_dir, type: :string,
                desc: "Package set directory"
            option :rebuild, type: :boolean,
                desc: "Force rebuilding / repackaging"
            option :no_deps, type: :boolean, default: false,
                desc: "Do not package dependencies"
            option :ancestor_blacklist , type: :array,
                desc: "Packages added to the ancestor blacklist, i.e., if needed as dependency, use a package from the current release name"
                    " instead of an ancesotr release"
            def package(*args)
                run_apaka_cli(:package, "Package", Hash[], *args)
            end

            desc "build [PackageName]", "Build a (debian) package from a given autoproj package, or a gem"
            option :version, type: :string,
                desc: "Version of the package to create for"
            option :architecture, type: :string,
                desc: "Architecture to build for"
            option :distribution, type: :string,
                desc: "Distribution to build for"
            option :build_dir, type: :string,
                desc: "Build folder of the source package -- needs to be within"
                    "an autoproj installation"
            option :dest_dir, type: :string,
                desc: "Destination folder of the source package"
            option :patch_dir, type: :string,
                desc: "Overlay directory to patch existing packages"
            option :pkg_set_dir, type: :string,
                desc: "Package set directory"
            option :rebuild, type: :boolean,
                desc: "Force rebuilding / repackaging"
            option :no_deps, type: :boolean, default: false,
                desc: "Do not build dependencies"
            option :ancestor_blacklist , type: :array,
                desc: "Packages added to the ancestor blacklist, i.e., if needed as dependency, use a package from the current release name"
                    " instead of an ancesotr release"
            option :install, type: :boolean, default: false,
                desc: "Install the built package on the local platform"
            option :parallel, type: :numeric, default: 1,
                desc: "Number of threads to use for building"
            option :dry_run, type: :boolean, default: false,
                desc: "Do not perform the actual building"
            option :log_dir, type: :string,
                desc: "Directory for the result report yaml"
            def build(*args)
                run_apaka_cli(:build, "Build", Hash[], *args)
            end

            desc "package_meta [PackageName]", "Create artifacts required to build a (debian) meta package"
            option :dependencies, type: :array,
                desc: "The list of packages this meta package should depend upon."
                    " If no dependencies are listed, all available / already"
                    " built and registered dependencies in this release are"
                    " used."
            option :package_version, type: :string, default: "0.1",
                desc: "The version of this meta package"
            option :build_dir, type: :string,
                desc: "Build folder of the source package -- needs to be within"
                    "an autoproj installation"
            def package_meta(*args)
                run_apaka_cli(:package_meta, "PackageMeta", Hash[], *args)
            end

            desc "build_meta [PackageName]", "Build a (debian) meta package"
            option :dependencies, type: :array,
                desc: "The list of packages this meta package should depend upon."
                    " If no dependencies are listed, all available / already"
                    " built and registered dependencies in this release are"
                    " used."
            option :package_version, type: :string, default: "0.1",
                desc: "The version of this meta package"
            option :build_dir, type: :string,
                desc: "Build folder of the source package -- needs to be within"
                    "an autoproj installation"
            option :rebuild, type: :boolean, default: false,
                desc: "Force rebuilding / repackaging"
            option :install, type: :boolean, default: false,
                desc: "Install the built package on the local platform"
            def build_meta(*args)
                run_apaka_cli(:build_meta, "BuildMeta", Hash[], *args)
            end

            desc "osdeps", "Generate osdeps files for a package release"
            option :dest_dir, type: :string,
                desc: "Destination folder of the generated osdeps files"
            def osdeps(*args)
                run_apaka_cli(:osdeps, "Osdeps", Hash[], *args)
            end

            desc "config", "Show the current configuration"
            option :show, type: :boolean,
                desc: "Show the current configuration"
            def config(*args)
                run_apaka_cli(:config, "Config", Hash[], *args)
            end

            desc "query [Package]", "Query the current database"
            option :architectures, type: :array,
                desc: "Comma separated list of architectures to build for"
            option :distributions, type: :array,
                desc: "Comma separated list of architectures to build for"
            option :activation_status, type: :boolean,
                desc: "Retrieve activation status of distribution"
            option :exists, type: :boolean,
                desc: "Test if package exists for distribution/architecture"
            option :current_os, type: :boolean,
                desc: "Output the currently detected os"
            def query(*args)
                run_apaka_cli(:query, "Query", Hash[], *args)
            end

            desc "reprepro [Package]", "Manipulate the reprepro instance for a particular release"
            option :architecture, type: :string,
                desc: "Architecture to build for"
            option :distribution, type: :string,
                desc: "Distribution to build for"
            option :register, type: :boolean,
                desc: "Register the build artifacts of the selected packages (by debian package name)"
            option :deregister, type: :boolean,
                desc: "Deregister the build artifact of the selected packages (by debian package name)"
            def reprepro(*args)
                run_apaka_cli(:reprepro, "Reprepro", Hash[], *args)
            end

            no_commands do
                def default_report_on_package_failures
                   if (override = Main.default_report_on_package_failures)
                       override
                   elsif options[:debug]
                       :raise
                   else
                       :exit
                   end
                end

                # Generate a command line for internal option parsers based on OptionParse,e.g.,
                # (to be
                # self-sufficient)
                def thor_options_to_optparse
                    flags = []
                    %i[color progress debug interactive].each do |option|
                        if options[option] then flags << "--#{option}"
                        else flags << "--no-#{option}"
                        end
                    end
                    flags
                end

                def run_apaka_cli(filename, classname, report_options, *args, tool_failure_mode: :exit_silent, **extra_options)
                    require_relative "#{filename}"
                    if Autobuild::Subprocess.transparent_mode = options[:tool]
                        Autobuild.silent = true
                        Autobuild.color = false
                        report_options[:silent] = true
                        report_options[:on_package_failures] = tool_failure_mode
                        extra_options[:silent] = true
                    end

                    Autoproj.report(**Hash[silent: !options[:debug], debug: options[:debug]].merge(report_options)) do
                        options = self.options.dup
                        # We use --local on the CLI but the APIs are expecting
                        # only_local
                        if options.has_key?('local')
                            options[:only_local] = options.delete('local')
                        end
                        cli = Apaka::CLI.const_get(classname).new
                        begin
                            run_args = cli.validate_options(args, options.merge(extra_options))
                            cli.run(*run_args)
                        ensure
                        end
                    end
                end
            end
        end
    end
end
