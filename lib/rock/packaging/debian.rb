require 'find'
require 'autoproj'
require 'tmpdir'
require 'pry'

module Autoproj
    module Packaging

        # Directory for temporary data to 
        # validate osc_packages
        OSC_LOCAL_TMP = ".osc_package"
        OSC_BUILD_DIR=File.join(Autoproj.root_dir, "build/osc")

        class Packager
            def prepare_source_dir(pkg)
                Autoproj.info "Preparing source dir #{pkg.name}"
                Autoproj.manifest.load_package_manifest(pkg.name)

                if pkg.importer.kind_of?(Autobuild::Git)
                    pkg.importer.repository = pkg.srcdir
                end
                pkg.srcdir = File.join(OSC_BUILD_DIR, dir_name(pkg))
                begin 
                    pkg.importer.import(pkg)
                rescue Exception => e
                    if not e.message =~ /failed in patch phase/
                        raise
                    else
                        Autoproj.warn "Patching #{pkg.name} failed"
                    end
                end

                Dir.glob(File.join(pkg.srcdir, "*-stamp")) do |file|
                    FileUtils.rm_f file
                end
            end

            def self.osc_package_name(pkg)
                "rock-" + pkg.name.gsub(/[\/_]/, '-').downcase
            end
        end

        class OSC
            # Update the open build local checkout
            # using a given checkout directory and the pkg name
            def self.update_dir(packager, osc_dir, pkg_osc_name)
                pkg_osc_dir = File.join(osc_dir, pkg_osc_name)
                if !File.directory?(pkg_osc_dir)
                    FileUtils.mkdir_p pkg_osc_dir
                    system("osc add #{pkg_osc_dir}")
                end

                # sync the directory in build/osc and the target directory
                files = []
                patterns = packager.file_patterns.map do |p|
                    puts File.join(Autoproj::Packaging::OSC_BUILD_DIR,"#{pkg_osc_name}#{p}")
                    files << Dir.glob(File.join(Autoproj::Packaging::OSC_BUILD_DIR,"#{pkg_osc_name}#{p}"))
                    File.join(pkg_osc_dir, p)
                end
                files.flatten!.uniq!

                # Delete files that don't exist in the build dir 
                Dir.glob(patterns) do |existing_path|
                    expected_path = File.join(Autoproj::Packaging::OSC_BUILD_DIR,File.basename(existing_path))
                    if not File.exists?(expected_path)
                        puts "deleting #{existing_path} -- '#{expected_path}' not present in the current packaging"
                        FileUtils.rm_f existing_path
                        system("osc rm #{existing_path}")
                    end
                end

                # Add the new unchanged files
                files.each do |path|
                    target_file = File.join(pkg_osc_dir, File.basename(path))
                    exists = File.exists?(target_file)
                    if exists 
                        if File.read(path) == File.read(target_file)
                            puts "#{target_file} is unchanged, skipping"
                        else
                            FileUtils.cp path, target_file
                        end
                    else
                        FileUtils.cp path, target_file 
                        system("osc add #{target_file}")
                    end
                end
                puts "OSC: checking in #{pkg_osc_dir}"
                system("osc ci #{pkg_osc_dir} -m \"autopackaged using autoproj-packaging tools\"")
            end
        end

        class Debian < Packager
            TEMPLATES = File.expand_path(File.join("templates", "debian"), File.dirname(__FILE__))

            attr_reader :existing_debian_directories

            # List of gems, which need to be converted to debian packages
            attr_accessor :ruby_gems

            def initialize(existing_debian_directories)
                @existing_debian_directories = existing_debian_directories
                @ruby_gems = Array.new
            end

            def debian_name(pkg)
               "rock-" + pkg.name.gsub(/[\/_]/, '-').downcase
            end

            def debian_ruby_name(name)
               "ruby-" + name.gsub(/[\/_]/, '-').downcase
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

            # Compute dependencies of this package
            # Returns [rock_packages, osdeps_packages]
            def dependencies(pkg)
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
                # These deps dependencies are updated here before uploading a package
                # 
                # Generation of the debian packages from the gems can be done in postprocessing step
                # i.e. see convert_gems
                native_package_manager = Autoproj.osdeps.os_package_handler
                pkg_handler, pkg_list = osdeps.find { |handler, _| handler != native_package_manager }
                if pkg_handler
                    # Convert native ruby gems package names to rock-xxx  
                    if pkg_handler.kind_of?(Autoproj::PackageManagers::GemManager)
                        pkg_list.flatten.each do |name|
                            @ruby_gems << name
                            deps_osdeps_packages << debian_ruby_name(name)

                            ## Since ruby header and library need to be available
                            ## for extensions
                            #if not deps_osdeps_packages.include?("ruby1.9.1-dev")
                            #    deps_osdeps_packages << "ruby1.9.1-dev"
                            #end
                            #if not deps_osdeps_packages.include?("ruby1.8-dev")
                            #    deps_osdeps_packages << "ruby1.8-dev"
                            #end
                        end
                    else
                        raise ArgumentError, "cannot package #{pkg.name} as it has non-native dependencies (#{pkg_list})"
                    end
                end

                # Remove duplicates
                @ruby_gems.uniq

                # Return rock packages and osdeps
                [deps_rock_packages, deps_osdeps_packages]
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

                deps_rock_packages, deps_osdeps_packages = dependencies(pkg)

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

            # Package the given package
            # if an existing source directory is given this will be used
            # for packaging, otherwise the package will be bootstrapped
            def package(pkg, existing_source_dir = nil)
                if existing_source_dir 
                    pkg.srcdir = existing_source_dir
                else
                    prepare_source_dir(pkg)
                end
                dir_name = versioned_name(pkg)
                FileUtils.rm_rf File.join(pkg.srcdir, "debian")

                # First, generate the source tarball
                tarball = "#{dir_name}.orig.tar.gz"
                if not File.exists?(OSC_LOCAL_TMP)
                    FileUtils.mkdir_p OSC_LOCAL_TMP
                end

                # Check first if actual source contains newer information than existing 
                # orig.tar.gz -- only then we create a new debian package
                if package_updated?(pkg)
                    Autoproj.warn "Package: #{pkg.name} requires update #{pkg.srcdir}"
                    system("tar czf #{tarball} --exclude .git --exclude .svn --exclude CVS --exclude debian #{File.basename(pkg.srcdir)}")

                    # Generate the debian directory
                    generate_debian_dir(pkg, pkg.srcdir)

                    # Run dpkg-source
                    # Use the new tar ball as source
                    system("dpkg-source", "-I", "-b", pkg.srcdir)
                    ["#{versioned_name(pkg)}.debian.tar.gz",
                     "#{versioned_name(pkg)}.orig.tar.gz",
                     "#{versioned_name(pkg)}.dsc"]
                else 
                    # just to update the required gem property
                    dependencies(pkg)
                    Autoproj.warn "Package: #{pkg.name} is up to date"
                end
                FileUtils.rm_rf("#{File.basename(pkg.srcdir)}")
            end

            # We create a diff between the existing orig.tar.gz and the source directory
            # to identify if there have been any updates
            #
            # Using 'diff' allows us to apply this test to all kind of packages
            def package_updated?(pkg)
                # Find an existing orig.tar.gz in the build directory
                # ignoring the current version-timestamp
                orig_file_name = Dir.glob("#{debian_name(pkg)}*.orig.tar.gz")
                if orig_file_name.empty?
                    return true
                elsif orig_file_name.size > 1
                    Autoproj.warn "Multiple version of package #{debian_name(pkg)} in #{Dir.pwd} -- you have to fix this first"
                else
                    orig_file_name = orig_file_name.first
                end
                # Create a local copy/backup of the current orig.tar.gz in .osc_package 
                # and extract it there -- compare the actual source package
                FileUtils.mkdir_p(OSC_LOCAL_TMP)
                FileUtils.cp(orig_file_name, OSC_LOCAL_TMP) 
                Dir.chdir(OSC_LOCAL_TMP) do
                    `tar xzf #{orig_file_name}`
                    base_name = orig_file_name.sub(".orig.tar.gz","")
                    Dir.chdir(base_name) do
                        diff_name = "#{orig_file_name}.diff"
                        `diff -urN --exclude .git --exclude .svn --exclude CVS --exclude debian #{pkg.srcdir} . > #{diff_name}`
                        if File.open(diff_name).lines.any? 
                            return true
                        end
                    end
                end
                return false
            end

            # Prepare the build directory, i.e. cleanup and obsolete file
            def prepare
                if not File.exists?(OSC_BUILD_DIR)
                    FileUtils.mkdir_p OSC_BUILD_DIR
                end
                cleanup
            end

            # Cleanup an existing local tmp folder in the build dir
            def cleanup
                tmpdir = File.join(OSC_BUILD_DIR,OSC_LOCAL_TMP)
                if File.exists?(tmpdir)
                    FileUtils.rm_rf(tmpdir)
                end
            end

            def file_patterns
                ["*.dsc", "*.orig.tar.gz", "*.debian.tar.gz"]
            end

            def system(*args)
                Kernel.system(*args)
            end

            # Convert all gems that are required 
            # by package build with the debian packager
            def convert_gems(options = Hash.new)

                options, unknown_options = Kernel.filter_options options,
                    :force_update => false,
                    :patch_dir => nil

                if unknown_options.size > 0
                    Autoproj.warn "Autoproj::Packaging Unknown options provided to convert gems: #{unknown_options}"
                end

                # We use gem2deb for the job of converting the gems
                # However, since we require some gems to be patched we split the process into the
                # individual step 
                # This allows to add an overlay (patch) to be added to the final directory -- which 
                # requires to be commited via dpkg-source --commit
                @ruby_gems.each do |gem_name|
                    # Assuming if the .gem file has been download we do not need to update
                    if options[:force_update] or not Dir.glob("#{gem_name}*.gem").size > 0
                        Autoproj.warn "Converting gem: '#{gem_name}' to debian source package"

                        `gem fetch #{gem_name}`
                        gem_file_name = Dir.glob("#{gem_name}*.gem").first
                        gem_versioned_name = gem_file_name.sub("\.gem","")

                        # Convert .gem to .tar.gz
                        `gem2tgz #{gem_file_name}`

                        # Create ruby-<name>-<version> folder including debian/ folder 
                        # from .tar.gz
                        `dh-make-ruby #{gem_versioned_name}.tar.gz`

                        debian_ruby_name = debian_ruby_name(gem_versioned_name)

                        # Check if patching is needed
                        Dir.chdir(debian_ruby_name) do
                            # Only if a patch directory is given then update
                            if patch_dir = options[:patch_dir]
                                gem_patch_dir = File.join(patch_dir, gem_name)
                                if File.directory?(gem_patch_dir)
                                    FileUtils.cp_r("#{gem_patch_dir}/.", ".")

                                    # We need to commit if original files have been modified
                                    # so add a commit
                                    orig_files = Dir["#{gem_patch_dir}/**"].reject { |f| f["#{gem_patch_dir}/debian/"] }
                                    if orig_files.size > 0
                                        # Since dpkg-source will open an editor we have to 
                                        # take this approach to make it pass directly in an 
                                        # automated workflow
                                        ENV['EDITOR'] = "/bin/true"
                                        `dpkg-source --commit . ocl_autopackaging_overlay`
                                    end
                                end
                            end

                            # Ignore all ruby test results when the binary package is build (on the build server)
                            # via:
                            # dpkg-buildpackage -us -uc
                            #
                            # Thus uncommented line of
                            # export DH_RUBY_IGNORE_TESTS=all
                            Autoproj.warn "Disabling ruby test result evaluation"
                            `sed -i 's/#\\(export DH_RUBY_IGNORE_TESTS=all\\)/\\1/' debian/rules`
                        end

                        # Build only a debian source package -- do not build
                        # To allow patching we need to split `gem2deb -S #{gem_name}`
                        # into its substeps
                        `dpkg-source -I -b #{debian_ruby_name}`
                    else 
                        Autoproj.warn "gem: #{gem_name} up to date"
                    end
                end
            end
        end
    end
end

