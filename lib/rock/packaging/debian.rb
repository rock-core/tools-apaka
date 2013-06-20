require 'find'
require 'autoproj'
require 'tmpdir'
module Autoproj
    module Packaging
        class Packager
            def prepare_source_dir(pkg)
                pkg.importer.import(pkg)
                Autoproj.manifest.load_package_manifest(pkg.name)

                if pkg.importer.kind_of?(Autobuild::Git)
                    pkg.importer.repository = pkg.srcdir
                end
                pkg.srcdir = dir_name(pkg)
                pkg.importer.import(pkg)

                Dir.glob(File.join(pkg.srcdir, "*-stamp")) do |file|
                    FileUtils.rm_f file
                end
            end

            def self.osc_package_name(pkg)
                "rock-" + pkg.name.gsub(/[\/_]/, '-').downcase
            end
        end

        class Debian < Packager
            TEMPLATES = File.expand_path(File.join("templates", "debian"), File.dirname(__FILE__))

            attr_reader :existing_debian_directories

            def initialize(existing_debian_directories)
                @existing_debian_directories = existing_debian_directories
            end

            def debian_name(pkg)
                debianize_pkg_name(pkg.name)
            end

            def debianize_pkg_name(name)
               "rock-" + name.gsub(/[\/_]/, '-').downcase
            end

            def debian_version(pkg)
                (pkg.description.version || "0") + "." + Time.now.strftime("%Y%m%d")
            end

            def versioned_name(pkg)
                debian_name(pkg) + "_" + debian_version(pkg)
            end

            def dir_name(pkg)
                versioned_name(pkg)
            end

            def generate_debian_dir(pkg, dir)
                existing_dir = File.join(existing_debian_directories, pkg.name)
                template_dir = 
                    if File.directory?(existing_dir)
                        existing_dir
                    else
                        TEMPLATES
                    end

                dir = File.join(dir, "debian")
                FileUtils.mkdir_p dir
                package = pkg
                debian_name = debian_name(pkg)
                debian_version = debian_version(pkg)
                versioned_name = versioned_name(pkg)
                pkg.resolve_optional_dependencies
                deps_rock_packages = pkg.dependencies.map do |pkg_name|
                    debian_name(Autoproj.manifest.package(pkg_name))
                end.sort

                osdeps = Autoproj.osdeps.resolve_os_dependencies(pkg.os_packages)
                deps_osdeps_packages = []
                if !osdeps.empty?
                    deps_osdeps_packages = osdeps[0][1]
                end

                # There are limitations regarding handling packages with native dependencies
                #
                # Currently gems need to converted into debs using gem2deb
                # These deps dependencies are update here before uploading a package
                native_package_manager = Autoproj.osdeps.os_package_handler
                pkg_handler, pkg_list = osdeps.find { |handler, _| handler != native_package_manager }
                if pkg_handler
                    # Convert native ruby gems package names to rock-xxx  
                    if pkg_handler.kind_of?(Autoproj::PackageManagers::GemManager)
                        pkg_list.flatten.each do |name|
                            deps_osdeps_packages << debianize_pkg_name(name)
                        end
                    else
                        raise ArgumentError, "cannot package #{pkg.name} as it has non-native dependencies (#{pkg_list})"
                    end
                end

                Find.find(template_dir) do |path|
                    next if File.directory?(path)
                    template = ERB.new(File.read(path), nil, "%<>", path.gsub(/[^w]/, '_'))
                    rendered = template.result(binding)

                    target_path = File.join(dir, Pathname.new(path).relative_path_from(Pathname.new(template_dir)).to_s)
                    FileUtils.mkdir_p File.dirname(target_path)
                    File.open(target_path, "w") do |io|
                        io.write(rendered)
                    end
                end
            end

            def package(pkg)
                prepare_source_dir(pkg)
                dir_name = versioned_name(pkg)
                FileUtils.rm_rf File.join(pkg.srcdir, "debian")

                # First, generate the source tarball
                tarball = "#{dir_name}.orig.tar.gz"
                system("tar czf #{tarball} --exclude .git --exclude .svn --exclude CVS --exclude debian #{File.basename(pkg.srcdir)}")
                # Generate the debian directory
                generate_debian_dir(pkg, pkg.srcdir)
                # Run dpkg-source
                system("dpkg-source", "-I", "-b", pkg.srcdir)
                ["#{versioned_name(pkg)}.debian.tar.gz",
                 "#{versioned_name(pkg)}.orig.tar.gz",
                 "#{versioned_name(pkg)}.dsc"]
            end

            def file_patterns
                ["*.dsc", "*.orig.tar.gz", "*.debian.tar.gz"]
            end

            def system(*args)
                Kernel.system(*args)
            end
        end
    end
end

