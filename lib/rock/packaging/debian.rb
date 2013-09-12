require 'find'
require 'autoproj'
require 'tmpdir'
require 'utilrb'

module Autoproj
    module Packaging

        # Directory for temporary data to 
        # validate obs_packages
        OBS_BUILD_DIR=File.join(Autoproj.root_dir, "build/obs")
        OBS_LOCAL_TMP = File.join(OBS_BUILD_DIR,".obs_package")

        class Packager
            extend Logger::Root("Packager", Logger::INFO)

            def prepare_source_dir(pkg, options = Hash.new)
                Packager.debug "Preparing source dir #{pkg.name}"
                if existing_source_dir = options[:existing_source_dir]
                    Packager.debug "Preparing source dir #{pkg.name} from existing: '#{existing_source_dir}'"
                    pkg_dir = File.join(OBS_BUILD_DIR, debian_name(pkg))
                    if not File.directory?(pkg_dir)
                        FileUtils.mkdir_p pkg_dir
                    end

                    target_dir = File.join(pkg_dir, dir_name(pkg))
                    FileUtils.cp_r existing_source_dir, target_dir

                    pkg.srcdir = target_dir
                else
                    Autoproj.manifest.load_package_manifest(pkg.name)

                    if pkg.importer.kind_of?(Autobuild::Git)
                        pkg.importer.repository = pkg.srcdir
                    end
                    pkg.srcdir = File.join(OBS_BUILD_DIR, debian_name(pkg), dir_name(pkg))
                    begin
                        pkg.importer.import(pkg)
                    rescue Exception => e
                        if not e.message =~ /failed in patch phase/
                            raise
                        else
                            Packager.warn "Patching #{pkg.name} failed"
                        end
                    end

                    Dir.glob(File.join(pkg.srcdir, "*-stamp")) do |file|
                        FileUtils.rm_f file
                    end
                end
            end

            def self.obs_package_name(pkg)
                "rock-" + pkg.name.gsub(/[\/_]/, '-').downcase
            end
        end

        class OBS

            @@obs_cmd = "osc"

            def self.obs_cmd
                @@obs_cmd
            end

            # Update the open build local checkout
            # using a given checkout directory and the pkg name
            # use a specific file pattern to set allowed files
            # source directory
            # obs_dir target obs checkout directory
            # src_dir wher the source dir is
            # pkg_name
            # allowed file patterns
            def self.update_dir(obs_dir, src_dir, pkg_obs_name, file_suffix_patterns = ".*", commit = true)
                pkg_obs_dir = File.join(obs_dir, pkg_obs_name)
                if !File.directory?(pkg_obs_dir)
                    FileUtils.mkdir_p pkg_obs_dir
                    system("#{obs_cmd} add #{pkg_obs_dir}")
                end

                # sync the directory in build/obs and the target directory based on an existing
                # files pattern
                files = []
                file_suffix_patterns.map do |p|
                    # Finding files that exist in the source directory
                    # needs to handle ruby-hoe_0.20130113/*.dsc vs. ruby-hoe-yard_0.20130113/*.dsc
                    # and ruby-hoe/_service
                    glob_exp = File.join(src_dir,pkg_obs_name,"*#{p}")
                    files += Dir.glob(glob_exp)
                end
                files = files.flatten.uniq
                Packager.debug "update directory: files in src #{files}"

                # prepare pattern for target directory
                expected_files = files.map do |f|
                    File.join(pkg_obs_dir, File.basename(f))
                end
                Packager.debug "target directory: expected files: #{expected_files}"

                existing_files = Dir.glob(File.join(pkg_obs_dir,"*"))
                Packager.debug "target directory: existing files: #{existing_files}"

                existing_files.each do |existing_path|
                    if not expected_files.include?(existing_path)
                        Packager.warn "OBS: deleting #{existing_path} -- not present in the current packaging"
                        FileUtils.rm_f existing_path
                        system("#{obs_cmd} rm #{existing_path}")
                    end
                end

                # Add the new unchanged files
                files.each do |path|
                    target_file = File.join(pkg_obs_dir, File.basename(path))
                    exists = File.exists?(target_file)
                    if exists 
                        if File.read(path) == File.read(target_file)
                            Packager.info "OBS: #{target_file} is unchanged, skipping"
                        else
                            Packager.info "OBS: #{target_file} updated"
                            FileUtils.cp path, target_file
                        end
                    else
                        FileUtils.cp path, target_file 
                        system("#{obs_cmd} add #{target_file}")
                    end
                end

                if commit 
                    Packager.info "OBS: committing #{pkg_obs_dir}"
                    system("#{obs_cmd} ci #{pkg_obs_dir} -m \"autopackaged using autoproj-packaging tools\"")
                else 
                    Packager.info "OBS: not commiting #{pkg_obs_dir}"
                end
            end

            # List the existing package in the projects
            # The list will contain only the name, suffix '.deb' has 
            # been removed
            def self.list_packages(project, repository, architecture = "i586")
                result = %x[#{obs_cmd} ls -b -r #{repository} -a #{architecture} #{project}].split("\n")
                pkg_list = result.collect { |pkg| pkg.sub(/(_.*)?.deb/,"") }
                pkg_list
            end

            def self.resolve_dependencies(package_name)
                record = `apt-cache depends #{package_name}`.split("\n").map(&:strip)
                if $?.exitstatus != 0
                    raise
                end
                
                depends_on = []
                record.each do |line|
                    if line =~ /^\s*Depends:\s*[<]?([^>]*)[>]?/
                        depends_on << $1.strip
                    end
                end
                
                depends_on
            end
        end

        # Packaging details:
        # - one main temporary folder in use: <autoproj-root>/build/obs/
        # - in the temp folder we create one folder per package to handle the packaging
        #   this folder can be synced with the target folder of the local checkout of the OBS
        # - checking update currently on checks for changes on the source data (so if patches change it
        #   is not recognized)
        # - to facilitate patching etc. an 'overlay' directory is used which is just copied during the
        #   build process -- currently only for gem handling and injecting fixes
        #
        # Resources:
        # * http://www.debian.org/doc/manuals/maint-guide/dreq.en.html
        # * http://cdbs-doc.duckcorp.org/en/cdbs-doc.xhtml
        class Debian < Packager
            TEMPLATES = File.expand_path(File.join("templates", "debian"), File.dirname(__FILE__))

            attr_reader :existing_debian_directories

            # List of gems, which need to be converted to debian packages
            attr_accessor :ruby_gems

            # List of rock gems, ruby_packages that have been converted to debian packages
            attr_accessor :ruby_rock_gems

            # List of osdeps, which are needed by the set of packages
            attr_accessor :osdeps

            def initialize(existing_debian_directories)
                @existing_debian_directories = existing_debian_directories
                @ruby_gems = Array.new
                @ruby_rock_gems = Array.new
                @osdeps = Array.new

                if not File.exists?(OBS_LOCAL_TMP)
                    FileUtils.mkdir_p OBS_LOCAL_TMP
                end
            end

            def canonize(name)
                name.gsub(/[\/_]/, '-').downcase
            end

            # Extract the base name from a path description
            # e.g. tools/metaruby => metaruby
            def basename(name)
                if name =~ /.*\/(.*)/
                    name = $1
                end
                name
            end

            # The debian name of a package -- either 
            # rock-<canonized-package-name>
            # or for ruby packages
            # ruby-<canonized-package-name>
            def debian_name(pkg)
                if pkg.kind_of?(Autoproj::RubyPackage)
                    debian_ruby_name(pkg.name)
                else
                   "rock-" + canonize(pkg.name)
                end
            end

            def debian_ruby_name(name)
               "ruby-" + canonize(name)
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

            def packaging_dir(pkg)
                File.join(Autoproj::Packaging::OBS_BUILD_DIR, debian_name(pkg))
            end

            # Commit changes of a debian package using dpkg-source --commit
            # in a given directory (or the current one by default)
            def dpkg_commit_changes(patch_name, directory = Dir.pwd)
                Dir.chdir(directory) do
                    Packager.info ("commit changes to debian pkg: #{patch_name}")
                    # Since dpkg-source will open an editor we have to
                    # take this approach to make it pass directly in an
                    # automated workflow
                    ENV['EDITOR'] = "/bin/true"
                    `dpkg-source --commit . #{patch_name}`
                end
            end

            # Compute dependencies of this package
            # Returns [rock_packages, osdeps_packages]
            def dependencies(pkg)
                pkg.resolve_optional_dependencies
                deps_rock_packages = pkg.dependencies.map do |pkg_name|
                    debian_name(Autoproj.manifest.package(pkg_name).autobuild)
                end.sort

                pkg_osdeps = Autoproj.osdeps.resolve_os_dependencies(pkg.os_packages)
                # There are limitations regarding handling packages with native dependencies
                #
                # Currently gems need to converted into debs using gem2deb
                # These deps dependencies are updated here before uploading a package
                # 
                # Generation of the debian packages from the gems can be done in postprocessing step
                # i.e. see convert_gems
               
                deps_osdeps_packages = []
                native_package_manager = Autoproj.osdeps.os_package_handler
                _, native_pkg_list = pkg_osdeps.find { |handler, _| handler == native_package_manager }

                deps_osdeps_packages += native_pkg_list if native_pkg_list

                # Update global list
                @osdeps += deps_osdeps_packages

                non_native_handlers = pkg_osdeps.collect do |handler, pkg_list| 
                    if handler != native_package_manager
                        [handler, pkg_list]
                    end
                end.compact

                non_native_handlers.each do |pkg_handler, pkg_list|
                    # Convert native ruby gems package names to rock-xxx  
                    if pkg_handler.kind_of?(Autoproj::PackageManagers::GemManager)
                        pkg_list.flatten.each do |name|
                            @ruby_gems << name
                            deps_osdeps_packages << debian_ruby_name(name)
                        end
                    else
                        raise ArgumentError, "cannot package #{pkg.name} as it has non-native dependencies (#{pkg_list}) -- #{pkg_handler.class} #{pkg_handler}"
                    end
                end

                # Remove duplicates
                @osdeps.uniq!
                @ruby_gems.uniq!

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
            def package(pkg, options = Hash.new)

                options, unknown_options = Kernel.filter_options options,
                    :force_update => false,
                    :existing_source_dir => nil,
                    :patch_dir => nil

                if options[:force_update]
                    dirname = File.join(OBS_BUILD_DIR, debian_name(pkg))
                    if File.directory?(dirname)
                        Packager.info "Debian: rebuild requested -- removing #{dirname}"
                        FileUtils.rm_rf(dirname)
                    end
                end

                prepare_source_dir(pkg, options)

                if pkg.kind_of?(Autobuild::CMake) || pkg.kind_of?(Autobuild::Autotools)
                    package_deb(pkg, options)
                elsif pkg.kind_of?(Autoproj::RubyPackage)
                    package_ruby(pkg, options)
                else
                    raise ArgumentError, "Debian: Unsupported package type #{pkg.class} for #{pkg.name}"
                end
            end

            # Create an osc package of an existing ruby package
            def package_ruby(pkg, options) 
                # update dependencies in any case, i.e. independant if package exists or not
                deps = dependencies(pkg)
                Dir.chdir(pkg.srcdir) do
                    begin
                        logname = "obs-#{pkg.name.sub("/","-")}" + "-" + Time.now.strftime("%Y%m%d-%H%M%S").to_s + ".log"
                        gem = FileList["pkg/*.gem"].first
                        if not gem 
                            Packager.info "Debian: creating gem from package #{pkg.name}"
                            if system("rake gem 2> #{File.join(OBS_BUILD_DIR, logname)}")
                                gem = FileList["pkg/*.gem"].first

                                # Make the naming of the gem consistent with the naming schema of
                                # rock packages
                                #
                                # Make sure the gem has the fullname, e.g.
                                # tools-metaruby instead of just metaruby
                                gem_rename = gem.sub(basename(pkg.name), canonize(pkg.name)) 
                                if gem != gem_rename
                                    Packager.info "Debian: renaming #{gem} to #{gem_rename}"
                                    FileUtils.mv gem, gem_rename
                                    gem = gem_rename
                                end

                                Packager.debug "Debian: copy #{gem} to #{packaging_dir(pkg)}"
                                FileUtils.cp gem, packaging_dir(pkg)
                                gem_final_path = File.join(packaging_dir(pkg), File.basename(gem))

                                # Prepare injection of dependencies
                                options[:deps] = deps
                                convert_gem(gem_final_path, options)
                            else
                                Packager.warn "Debian: failed to create gem from RubyPackage #{pkg.name}"
                                Packager.warn "        check: #{File.expand_path(logname)}"
                            end
                        end

                        # register gem with the correct naming schema
                        # to make sure dependency naming and gem naming are consistent
                        @ruby_rock_gems << debian_name(pkg)
                    rescue Exception => e
                        raise "Debian: failed to create gem from RubyPackage #{pkg.name} -- #{e.message}\n#{e.backtrace.join("\n")}"
                    end
                end
            end

            def package_deb(pkg, options) 
                Dir.chdir(packaging_dir(pkg)) do
                    dir_name = versioned_name(pkg)
                    FileUtils.rm_rf File.join(pkg.srcdir, "debian")
                    FileUtils.rm_rf File.join(pkg.srcdir, "build")

                    # First, generate the source tarball
                    tarball = "#{dir_name}.orig.tar.gz"

                    # Check first if actual source contains newer information than existing 
                    # orig.tar.gz -- only then we create a new debian package
                    if package_updated?(pkg)

                        Packager.warn "Package: #{pkg.name} requires update #{pkg.srcdir}"
                        system("tar czf #{tarball} --exclude .git --exclude .svn --exclude CVS --exclude debian --exclude build #{File.basename(pkg.srcdir)}")

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
                        Packager.info "Package: #{pkg.name} is up to date"
                    end
                    FileUtils.rm_rf( File.basename(pkg.srcdir) )
                end
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
                    Packager.warn "Multiple version of package #{debian_name(pkg)} in #{Dir.pwd} -- you have to fix this first"
                else
                    orig_file_name = orig_file_name.first
                end

                # Create a local copy/backup of the current orig.tar.gz in .obs_package 
                # and extract it there -- compare the actual source package
                FileUtils.cp(orig_file_name, OBS_LOCAL_TMP) 
                Dir.chdir(OBS_LOCAL_TMP) do
                    `tar xzf #{orig_file_name}`
                    base_name = orig_file_name.sub(".orig.tar.gz","")
                    Dir.chdir(base_name) do
                        diff_name = "#{orig_file_name}.diff"
                        `diff -urN --exclude .git --exclude .svn --exclude CVS --exclude debian --exclude build #{pkg.srcdir} . > #{diff_name}`
                        if File.open(diff_name).lines.any? 
                            return true
                        end
                    end
                end
                return false
            end

            # Prepare the build directory, i.e. cleanup and obsolete file
            def prepare
                if not File.exists?(OBS_BUILD_DIR)
                    FileUtils.mkdir_p OBS_BUILD_DIR
                end
                cleanup
            end

            # Cleanup an existing local tmp folder in the build dir
            def cleanup
                tmpdir = File.join(OBS_BUILD_DIR,OBS_LOCAL_TMP)
                if File.exists?(tmpdir)
                    FileUtils.rm_rf(tmpdir)
                end
            end

            def file_suffix_patterns
                [".dsc", ".orig.tar.gz", ".debian.tar.gz"]
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
                    Packager.warn "Autoproj::Packaging Unknown options provided to convert gems: #{unknown_options}"
                end

                # We use gem2deb for the job of converting the gems
                # However, since we require some gems to be patched we split the process into the
                # individual step 
                # This allows to add an overlay (patch) to be added to the final directory -- which 
                # requires to be commited via dpkg-source --commit
                @ruby_gems.each do |gem_name|
                    gem_dir_name = debian_ruby_name(gem_name)

                    # Assuming if the .gem file has been download we do not need to update
                    if options[:force_update] or not Dir.glob("#{gem_dir_name}/#{gem_name}*.gem").size > 0
                        Packager.debug "Converting gem: '#{gem_name}' to debian source package"
                        if not File.directory?(gem_dir_name)
                            FileUtils.mkdir gem_dir_name
                        end

                        Dir.chdir(gem_dir_name) do 
                            `gem fetch #{gem_name}`
                        end
                        gem_file_name = Dir.glob("#{gem_dir_name}/#{gem_name}*.gem").first
                        convert_gem(gem_file_name, options)
                    else 
                        Autoproj.info "gem: #{gem_name} up to date"
                    end
                end
            end

            # When providing the path to a gem file converts the gem into
            # a debian package (files will be residing in the same folder
            # as the gem)
            #
            # When provided a patch directory with the name of the gem, 
            # e.g. hoe, nokogiri, utilrb
            # the corresponding files will be copy into the built package during
            # the gem building process
            def convert_gem(gem_path, options = Hash.new)
                Packager.debug "Convert gem: '#{gem_path}' with options: #{options}"

                options, unknown_options = Kernel.filter_options options,
                    :patch_dir => nil,
                    :deps => [[],[]]

                Dir.chdir(File.dirname(gem_path)) do 
                    gem_file_name = File.basename(gem_path)
                    gem_versioned_name = gem_file_name.sub("\.gem","")

                    # Dealing with _ in original file name, since gem2deb
                    # will debianize it
                    if gem_versioned_name =~ /(.*)([-_][0-9\.]*)/
                        base_name = $1
                        version_suffix = $2
                        gem_versioned_name = base_name.gsub("_","-") + version_suffix
                    else
                        raise ArgumentError, "Converting gem: unknown formatting"
                    end

                    Packager.debug "Converting gem: #{gem_versioned_name} in #{Dir.pwd}"
                    # Convert .gem to .tar.gz
                    if not system("gem2tgz #{gem_file_name}")
                        raise RuntimeError, "Converting gem: '#{gem_path}' failed -- gem2tgz failed"
                    end

                    # Create ruby-<name>-<version> folder including debian/ folder 
                    # from .tar.gz
                    `dh-make-ruby #{gem_versioned_name}.tar.gz`

                    debian_ruby_name = debian_ruby_name(gem_versioned_name)

                    # Check if patching is needed
                    # To allow patching we need to split `gem2deb -S #{gem_name}`
                    # into its substeps
                    Dir.chdir(debian_ruby_name) do

                        # Only if a patch directory is given then update
                        if patch_dir = options[:patch_dir]
                            gem_name = ""
                            if gem_versioned_name =~ /(.*)[-_][0-9\.]*/
                                gem_name = $1
                            end

                            gem_patch_dir = File.join(patch_dir, gem_name)
                            if File.directory?(gem_patch_dir)
                                Packager.warn "Applying overlay (patch) to: gem '#{gem_name}'"
                                FileUtils.cp_r("#{gem_patch_dir}/.", ".")

                                # We need to commit if original files have been modified
                                # so add a commit
                                orig_files = Dir["#{gem_patch_dir}/**"].reject { |f| f["#{gem_patch_dir}/debian/"] }
                                if orig_files.size > 0
                                    dpkg_commit_changes("ocl_autopackaging_overlay")
                                end
                            else 
                                Packager.warn "No patch dir: #{gem_patch_dir}"
                            end
                        end

                        # Injecting dependencies into debian/control
                        # Since we do not differentiate between build and runtime dependencies
                        # at Rock level -- we add them to both
                        #
                        # Enforces to have all dependencies available when building the packages
                        # at the build server
                        deps = options[:deps].flatten.uniq
                        if not deps.empty?
                            Packager.info "#{debian_ruby_name}: injecting gem dependencies: #{deps.join(",")}"
                            `sed -i "s#^\\(^Build-Depends: .*\\)#\\1, #{deps.join(",")}#" debian/control`
                            `sed -i "s#^\\(^Depends: .*\\)#\\1, #{deps.join(",")}#" debian/control`

                            dpkg_commit_changes("ocl_extra_dependencies")
                        end

                        # Ignore all ruby test results when the binary package is build (on the build server)
                        # via:
                        # dpkg-buildpackage -us -uc
                        #
                        # Thus uncommented line of
                        # export DH_RUBY_IGNORE_TESTS=all
                        Packager.debug "Disabling ruby test result evaluation"
                        `sed -i 's/#\\(export DH_RUBY_IGNORE_TESTS=all\\)/\\1/' debian/rules`
                    end

                    # Build only a debian source package -- do not compile binary package
                    `dpkg-source -I -b #{debian_ruby_name}`
                end
            end
        end
    end
end

